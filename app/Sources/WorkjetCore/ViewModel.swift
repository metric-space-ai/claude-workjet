import Combine
import Foundation

@MainActor
public final class WorkjetViewModel: ObservableObject {
    @Published public private(set) var workers: [Worker] { didSet { persistIfReady() } }
    @Published public private(set) var computers: [Computer] { didSet { persistIfReady() } }
    @Published public private(set) var providers: [Provider] { didSet { persistIfReady() } }
    @Published public private(set) var activeRuns: [ActiveRun] = []
    @Published public private(set) var remoteRuns: [UUID: RemoteWorkerRun] = [:]
    @Published public private(set) var remoteHostProbes: [UUID: RemoteHostResponse] = [:]
    @Published public private(set) var remoteHostErrors: [UUID: String] = [:]
    @Published public private(set) var cliProxyStatus: CLIProxyStatus
    @Published public private(set) var providerAccessStored: Set<UUID> = []
    @Published public private(set) var providerLoginStates: [ModelProvider: CLIProxyLoginState] = [:]
    @Published public private(set) var tailscaleDevices: [TailscaleDevice] = []
    @Published public private(set) var tailscaleError: String?
    @Published public private(set) var tailscaleLoading = false
    @Published public private(set) var statusMessages: [String]
    @Published public private(set) var promptSyncStatus: PromptSyncStatus

    @Published public var skillRules: String { didSet { persistIfReady(handwrittenRulesChanged: true) } }
    @Published public private(set) var modelPrompts: [String: String] { didSet { persistIfReady() } }
    @Published public var adHocLearnings: String { didSet { persistLearningsIfReady() } }
    @Published public var technicalRules: String { didSet { persistIfReady() } }
    @Published public var skillActivation: SkillActivation { didSet { persistIfReady() } }
    @Published public var injectWorkerDeclarations: Bool { didSet { persistIfReady() } }
    @Published public var telemetryClaudeCodeEvents: Bool { didSet { persistIfReady(); if ready { refreshRuns() } } }
    @Published public var telemetrySidecarEvents: Bool { didSet { persistIfReady(); if ready { refreshRuns() } } }
    @Published public var telemetryRetentionDays: Int { didSet { persistIfReady() } }
    @Published public var providerSlots: Int { didSet { persistIfReady() } }
    @Published public var probeTimeoutSeconds: Int { didSet { persistIfReady() } }
    @Published public var turnTimeoutSeconds: Int { didSet { persistIfReady() } }
    @Published public var degradationAllowed: Bool { didSet { persistIfReady() } }
    @Published public var cliProxyConfiguration: CLIProxyConfiguration { didSet { persistIfReady() } }

    @Published public var searchQuery = ""
    @Published public private(set) var selectedComputerID: UUID { didSet { persistIfReady() } }

    private let service: any WorkjetService
    private let persistenceDelay: TimeInterval
    private lazy var persistence = PersistenceCoordinator(service: service, delay: persistenceDelay) { [weak self] outcome in
        Task { @MainActor in self?.applyPersistenceOutcome(outcome) }
    }
    private var ready = false
    private var pollingTask: Task<Void, Never>?
    private var runRefreshTask: Task<Void, Never>?
    private var providerRefreshTask: Task<Void, Never>?
    private var learningRefreshTask: Task<Void, Never>?
    private var learningPersistenceTask: Task<Void, Never>?
    private var remoteRefreshTask: Task<Void, Never>?
    private var remoteSessions: [UUID: RemoteSession] = [:]
    private var applyingExternalLearnings = false

    private struct RemoteSession {
        var worker: Worker
        var computer: Computer
        var ledger: RemoteRunLedger
        var supervisor: RemoteConnectionSupervisor
    }

    public init(configuration: WorkjetConfiguration, service: any WorkjetService = NullWorkjetService(), messages: [String] = [], persistenceDelay: TimeInterval = 0.25) {
        let value = WorkjetBootstrap.normalized(configuration)
        self.service = service
        self.persistenceDelay = persistenceDelay
        workers = value.workers
        computers = value.computers
        providers = value.providers
        selectedComputerID = value.selectedComputerID
        skillRules = value.skillRules
        modelPrompts = value.modelPrompts ?? [:]
        adHocLearnings = value.adHocLearnings ?? ""
        technicalRules = value.technicalRules ?? ""
        skillActivation = value.skillActivation
        injectWorkerDeclarations = value.injectWorkerDeclarations
        telemetryClaudeCodeEvents = value.telemetryClaudeCodeEvents
        telemetrySidecarEvents = value.telemetrySidecarEvents
        telemetryRetentionDays = value.telemetryRetentionDays
        providerSlots = value.providerSlots
        probeTimeoutSeconds = value.probeTimeoutSeconds
        turnTimeoutSeconds = value.turnTimeoutSeconds
        degradationAllowed = value.degradationAllowed
        cliProxyConfiguration = value.cliProxy
        cliProxyStatus = CLIProxyStatus(endpoint: value.cliProxy.endpoint, state: .unverified, detail: "Status wurde noch nicht geprüft.", capacity: .unavailable(reason: "CLIProxy wurde noch nicht geprüft."))
        statusMessages = messages
        promptSyncStatus = messages.isEmpty ? .synchronized(Date()) : .failed(messages.last ?? "Prompt konnte nicht synchronisiert werden.")
        ready = true
    }

    public static func live(paths: WorkjetPaths = .live) -> WorkjetViewModel {
        let bootstrap = WorkjetBootstrap.live(paths: paths)
        return WorkjetViewModel(configuration: bootstrap.configuration, service: bootstrap.service, messages: bootstrap.messages)
    }

    public var visibleWorkers: [Worker] { WorkerFilter.filtered(workers, query: searchQuery, computerID: selectedComputerID) }
    public var runtimeStatus: WorkjetRuntimeStatus {
        if case .failed = promptSyncStatus { return .attention }
        if !statusMessages.isEmpty || !runtimeHealthIssues.isEmpty { return .attention }
        let remoteCount = remoteRuns.values.filter { !$0.state.isTerminal }.count
        if !activeRuns.isEmpty || remoteCount > 0 { return .active(count: activeRuns.count + remoteCount) }
        return .ready
    }
    public var runtimeSubtitle: String {
        switch promptSyncStatus {
        case .pending:
            return "Änderungen werden übernommen …"
        case .failed:
            return "Prompt nicht synchronisiert"
        case .synchronized:
            break
        }
        if let issue = runtimeHealthIssues.first { return issue }
        let remoteCount = remoteRuns.values.filter { !$0.state.isTerminal }.count
        if !activeRuns.isEmpty || remoteCount > 0 { return "\(activeRuns.count + remoteCount) Worker aktiv"
        }
        return "Für nächsten Workjet-Aufruf synchron"
    }

    public var runtimeHealthIssues: [String] {
        var issues: [String] = []
        if let selected = computer(for: selectedComputerID), !selected.isLocal {
            if selected.deploymentStatus != .installed {
                issues.append("Computer nicht vollständig eingerichtet")
            } else if remoteHostProbes[selected.id] == nil {
                issues.append("Remote-Telemetrie nicht verbunden")
            }
        }
        let relevantWorkers = workers.filter { $0.computerID == selectedComputerID }
        let unavailableRoutes = relevantWorkers.filter { worker in
            switch worker.providerRoute {
            case let .account(providerID):
                guard let provider = providers.first(where: { $0.id == providerID }) else { return true }
                return provider.status != .connected
            case let .pool(modelProvider):
                return providerPool(for: modelProvider).accounts.allSatisfy { $0.status != .connected }
            case nil:
                return true
            }
        }.count
        if unavailableRoutes > 0 {
            issues.append("\(unavailableRoutes) Worker ohne verbundene Anbieterroute")
        }
        return issues
    }
    public var generatedPromptPreview: String {
        String(data: ManagedPrompt.workerBody(configuration: configuration), encoding: .utf8) ?? "Prompt kann nicht dargestellt werden."
    }
    public var generatedWorkerPreview: String {
        String(data: ManagedPrompt.workerBody(configuration: configuration, includeModelPrompts: false, includeWorkerInstructions: false), encoding: .utf8) ?? "Worker-Konfiguration kann nicht dargestellt werden."
    }
    public var usedModelPromptNames: [String] {
        var seen = Set<String>()
        return workers.compactMap {
            let name = ModelPromptCatalog.canonicalName(for: $0.model)
            return !name.isEmpty && seen.insert(name).inserted ? name : nil
        }
    }
    public var promptPreview: String {
        [skillRules.trimmingCharacters(in: .whitespacesAndNewlines), generatedPromptPreview]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    public var configuration: WorkjetConfiguration {
        WorkjetConfiguration(workers: workers, computers: computers, providers: providers, selectedComputerID: selectedComputerID, skillRules: skillRules, modelPrompts: modelPrompts, adHocLearnings: adHocLearnings, technicalRules: technicalRules, transparentWorkerPromptsMigrated: true, skillActivation: skillActivation, injectWorkerDeclarations: injectWorkerDeclarations, telemetryClaudeCodeEvents: telemetryClaudeCodeEvents, telemetrySidecarEvents: telemetrySidecarEvents, telemetryRetentionDays: telemetryRetentionDays, providerSlots: providerSlots, probeTimeoutSeconds: probeTimeoutSeconds, turnTimeoutSeconds: turnTimeoutSeconds, degradationAllowed: degradationAllowed, cliProxy: cliProxyConfiguration)
    }

    public func modelPrompt(for model: String) -> String {
        ModelPromptCatalog.prompt(for: model, in: modelPrompts)
    }

    public func setModelPrompt(_ prompt: String, for model: String) {
        let key = ModelPromptCatalog.canonicalName(for: model)
        guard !key.isEmpty else { return }
        modelPrompts[key] = prompt
    }

    public func setWorkerInstructions(_ instructions: String, for id: UUID) {
        guard let index = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[index].instructions = instructions
    }

    public func runtimeNotes(for worker: Worker) -> String {
        ManagedPrompt.runtimeNotes(for: worker, configuration: configuration)
    }

    public func computer(for id: UUID) -> Computer? { computers.first { $0.id == id } }
    public func toggleComputerSelection(_ id: UUID) {
        guard computers.contains(where: { $0.id == id }) else { return }
        selectedComputerID = id
        searchQuery = ""
    }

    public func providerPresentation(for provider: Provider) -> ProviderPresentation {
        let tone: ProviderPresentationTone
        switch provider.status {
        case .unverified: tone = .neutral
        case .connected: tone = .connected
        case .degraded: tone = .warning
        case .offline: tone = .critical
        }
        return ProviderPresentation(state: provider.status.rawValue, detail: provider.statusDetail, tone: tone, capacity: provider.capacity)
    }

    public func effectiveCapacity(for worker: Worker) -> CapacityStatus {
        switch worker.providerRoute {
        case let .account(providerID):
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                return .unavailable(reason: "Die gespeicherte Anbieterroute wurde gelöscht oder ist nicht verfügbar.")
            }
            return providerPresentation(for: provider).capacity
        case let .pool(modelProvider):
            return providerPool(for: modelProvider).capacity
        case nil:
            return worker.capacity
        }
    }

    public func operationalStatus(for worker: Worker) -> WorkerOperationalStatus {
        if activeRuns.contains(where: { $0.workerID == worker.id }) || remoteRuns[worker.id].map({ !$0.state.isTerminal }) == true {
            return WorkerOperationalStatus(
                state: .active,
                label: "Aktiv",
                detail: "Für diesen Worker liegt ein frischer laufender Run vor."
            )
        }

        guard let computer = computers.first(where: { $0.id == worker.computerID }) else {
            return WorkerOperationalStatus(state: .unavailable, label: "Computer fehlt", detail: "Der gespeicherte Ziel-Computer existiert nicht mehr.")
        }
        if !computer.isLocal, computer.deploymentStatus != .installed {
            return WorkerOperationalStatus(
                state: .unavailable,
                label: "Computer nicht bereit",
                detail: computer.deploymentDetail.isEmpty ? computer.deploymentStatus.rawValue : computer.deploymentDetail
            )
        }
        if !computer.isLocal, !RemoteHarnessAdapterRegistry().supports(worker.harness) {
            return WorkerOperationalStatus(
                state: .unavailable,
                label: "Remote-Harness blockiert",
                detail: RemoteHarnessAdapterError.unsupportedHarness(worker.harness.rawValue).localizedDescription
            )
        }
        guard !worker.invocation.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WorkerOperationalStatus(state: .unavailable, label: "Harness fehlt", detail: "Für \(worker.harness.rawValue) ist keine ausführbare Invocation gespeichert.")
        }

        let routeProviders: [Provider]
        switch worker.providerRoute {
        case let .account(providerID):
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                return WorkerOperationalStatus(state: .unavailable, label: "Anbieter fehlt", detail: "Der gespeicherte Anbieterzugang wurde gelöscht oder ist nicht verfügbar.")
            }
            routeProviders = [provider]
        case let .pool(modelProvider):
            routeProviders = providerPool(for: modelProvider).accounts
            if routeProviders.isEmpty {
                return WorkerOperationalStatus(state: .unavailable, label: "Pool leer", detail: "Für \(modelProvider.rawValue) ist kein Zugang konfiguriert.")
            }
        case nil:
            return WorkerOperationalStatus(state: .unavailable, label: "Anbieter fehlt", detail: "Wähle einen Anbieterzugang oder einen Anbieter-Pool.")
        }

        if routeProviders.contains(where: { $0.status == .connected }) {
            return WorkerOperationalStatus(
                state: .ready,
                label: "Bereit",
                detail: "Computer, Harness und mindestens eine Anbieterroute sind konfiguriert und verbunden."
            )
        }
        if routeProviders.contains(where: { $0.status == .degraded }) {
            let detail = routeProviders.first(where: { $0.status == .degraded })?.statusDetail ?? "Die Anbieterroute ist eingeschränkt."
            return WorkerOperationalStatus(state: .degraded, label: "Eingeschränkt", detail: detail)
        }
        if routeProviders.allSatisfy({ $0.status == .unverified }) {
            return WorkerOperationalStatus(state: .unverified, label: "Nicht geprüft", detail: "Die Anbieterroute wurde noch nicht erfolgreich geprüft.")
        }
        let detail = routeProviders.first(where: { $0.status == .offline })?.statusDetail ?? "Keine Anbieterroute ist erreichbar."
        return WorkerOperationalStatus(state: .unavailable, label: "Anbieter offline", detail: detail)
    }

    public func upsertWorker(_ worker: Worker) {
        if let index = workers.firstIndex(where: { $0.id == worker.id }) { workers[index] = worker }
        else { workers.append(worker) }
    }

    public func upsertComputer(_ computer: Computer) {
        if let index = computers.firstIndex(where: { $0.id == computer.id }) { computers[index] = computer }
        else { computers.append(computer) }
        if ready { refreshRuns() }
    }

    public func removeComputer(id: UUID) {
        guard let computer = computers.first(where: { $0.id == id }), !computer.isLocal,
              let local = computers.first(where: \.isLocal) else { return }
        for index in workers.indices where workers[index].computerID == id {
            workers[index].computerID = local.id
        }
        computers.removeAll { $0.id == id }
        if selectedComputerID == id { selectedComputerID = local.id }
        if ready { refreshRuns() }
    }

    public func addProvider(_ provider: Provider) { providers.append(provider) }
    public func providerAccounts(for modelProvider: ModelProvider) -> [Provider] {
        Provider.deterministicPool(providers, for: modelProvider)
    }
    public func providerPool(for modelProvider: ModelProvider) -> ProviderPool {
        ProviderPool(provider: modelProvider, accounts: providers)
    }
    public func configuredProvider(for modelProvider: ModelProvider) -> Provider? {
        providerAccounts(for: modelProvider).first
    }

    @discardableResult
    public func ensureProvider(for modelProvider: ModelProvider) -> Provider {
        if let existing = configuredProvider(for: modelProvider) { return existing }
        let provider = Provider(
            name: modelProvider.rawValue,
            kind: modelProvider.usesWebLogin ? .cliProxyAPI : .directAPI,
            endpoint: modelProvider.usesWebLogin ? "http://127.0.0.1:8317" : (modelProvider.defaultEndpoint ?? ""),
            authentication: modelProvider.defaultAuthentication,
            modelProvider: modelProvider,
            modelIDs: modelProvider.requestedModelSuggestions
        )
        providers.append(provider)
        return provider
    }
    public func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }
    public func removeProvider(id: UUID) {
        if let reference = providers.first(where: { $0.id == id })?.credentialReference {
            let stillUsedByLegacyCLIProxy = reference == cliProxyConfiguration.inferenceCredentialReference
                || reference == cliProxyConfiguration.managementCredentialReference
            if !stillUsedByLegacyCLIProxy {
                do { try service.deleteCredential(reference: reference) }
                catch { expose(error); return }
            }
        }
        providers.removeAll { $0.id == id }
        providerAccessStored.remove(id)
        // Worker references intentionally remain stable and render as unavailable.
    }

    public func refreshProviderCredentialStatus() {
        let service = self.service
        providerAccessStored = Set(providers.compactMap { provider in
            guard let reference = provider.credentialReference, service.hasCredential(reference: reference) else { return nil }
            return provider.id
        })
    }

    public func testProvider(id: UUID, secret: String = "") async {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        var provider = providers[index]
        let reference = provider.credentialReference ?? Provider.credentialReference(for: provider.id)
        provider.credentialReference = reference
        do {
            if provider.authentication != .none, !secret.isEmpty {
                try service.storeCredential(Data(secret.utf8), reference: reference)
            }
            let result = await service.inspectProvider(provider)
            applyProbe(result, to: &provider)
            providers[index] = provider
            refreshProviderCredentialStatus()
            await flushPersistence()
        } catch {
            provider.status = .offline
            provider.statusDetail = error.localizedDescription
            providers[index] = provider
            expose(error)
        }
    }

    public func connect(_ modelProvider: ModelProvider, apiKey: String = "") async {
        var provider = ensureProvider(for: modelProvider)
        providerLoginStates[modelProvider] = .authenticating
        do {
            let reference = provider.credentialReference ?? Provider.credentialReference(for: provider.id)
            provider.credentialReference = reference
            if modelProvider.usesWebLogin {
                try await service.authenticateCLIProxyAccount(modelProvider, credentialReference: reference)
            } else {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw CLIProxyAccountError.apiKeyRequired }
                try service.storeCredential(Data(key.utf8), reference: reference)
            }
            let result = await service.inspectProvider(provider)
            applyProbe(result, to: &provider)
            if !result.modelIDs.isEmpty { provider.modelIDs = Provider.normalizedModels(result.modelIDs + modelProvider.requestedModelSuggestions) }
            markOAuthAccountRoutingUnavailable(&provider, modelProvider: modelProvider)
            updateOrAppend(provider)
            refreshProviderCredentialStatus()
            providerLoginStates[modelProvider] = provider.status == .connected
                ? .connected(modelCount: provider.modelIDs.count)
                : .failed(provider.statusDetail)
            await flushPersistence()
        } catch {
            provider.status = .offline
            provider.statusDetail = error.localizedDescription
            updateOrAppend(provider)
            providerLoginStates[modelProvider] = .failed(error.localizedDescription)
            expose(error)
        }
    }

    /// Creates a distinct, named account. It never mutates or silently replaces
    /// an existing account of the same provider.
    @discardableResult
    public func connectNewAccount(_ modelProvider: ModelProvider, name requestedName: String = "", apiKey: String = "") async -> Provider? {
        let existing = providerAccounts(for: modelProvider)
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "\(modelProvider.rawValue) \(existing.count + 1)" : trimmedName
        var provider = Provider(
            name: name,
            kind: modelProvider.usesWebLogin ? .cliProxyAPI : .directAPI,
            endpoint: modelProvider.usesWebLogin ? "http://127.0.0.1:8317" : (modelProvider.defaultEndpoint ?? ""),
            authentication: modelProvider.defaultAuthentication,
            modelProvider: modelProvider,
            modelIDs: modelProvider.requestedModelSuggestions,
            routingPriority: (existing.map(\.routingPriority).max() ?? -1) + 1
        )
        providerLoginStates[modelProvider] = .authenticating
        do {
            let reference = provider.credentialReference ?? Provider.credentialReference(for: provider.id)
            provider.credentialReference = reference
            if modelProvider.usesWebLogin {
                try await service.authenticateCLIProxyAccount(modelProvider, credentialReference: reference)
            } else {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw CLIProxyAccountError.apiKeyRequired }
                try service.storeCredential(Data(key.utf8), reference: reference)
            }
            let result = await service.inspectProvider(provider)
            applyProbe(result, to: &provider)
            if !result.modelIDs.isEmpty { provider.modelIDs = Provider.normalizedModels(result.modelIDs + modelProvider.requestedModelSuggestions) }
            markOAuthAccountRoutingUnavailable(&provider, modelProvider: modelProvider)
            providers.append(provider)
            refreshProviderCredentialStatus()
            providerLoginStates[modelProvider] = provider.status == .connected
                ? .connected(modelCount: provider.modelIDs.count)
                : .failed(provider.statusDetail)
            await flushPersistence()
            return provider
        } catch {
            providerLoginStates[modelProvider] = .failed(error.localizedDescription)
            expose(error)
            return nil
        }
    }

    private func updateOrAppend(_ provider: Provider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) { providers[index] = provider }
        else { providers.append(provider) }
    }

    /// Re-opens the provider login and re-probes the local gateway. CLIProxy's
    /// provider login does not return a stable auth-file identity here, so this
    /// deliberately does not claim that a concrete OAuth account was pinned.
    public func reauthenticateProvider(id: UUID) async {
        guard let existing = providers.first(where: { $0.id == id }),
              let modelProvider = existing.modelProvider else { return }
        guard modelProvider.usesWebLogin else {
            expose(CLIProxyAccountError.apiKeyRequired)
            return
        }
        providerLoginStates[modelProvider] = .authenticating
        var provider = existing
        do {
            let reference = provider.credentialReference ?? Provider.credentialReference(for: provider.id)
            provider.credentialReference = reference
            try await service.authenticateCLIProxyAccount(modelProvider, credentialReference: reference)
            let result = await service.inspectProvider(provider)
            applyProbe(result, to: &provider)
            if !result.modelIDs.isEmpty { provider.modelIDs = Provider.normalizedModels(result.modelIDs + modelProvider.requestedModelSuggestions) }
            markOAuthAccountRoutingUnavailable(&provider, modelProvider: modelProvider)
            updateOrAppend(provider)
            refreshProviderCredentialStatus()
            providerLoginStates[modelProvider] = .failed(provider.statusDetail)
            await flushPersistence()
        } catch {
            provider.status = .offline
            provider.statusDetail = error.localizedDescription
            updateOrAppend(provider)
            providerLoginStates[modelProvider] = .failed(error.localizedDescription)
            expose(error)
        }
    }

    /// Refreshes only facts which the configured provider probe actually
    /// returned. No global CLIProxy quota is assigned to an individual account.
    public func refreshProvidersNow() async {
        let snapshot = providers
        for provider in snapshot {
            guard !Task.isCancelled else { return }
            let result = await service.inspectProvider(provider)
            guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { continue }
            var current = providers[index]
            applyProbe(result, to: &current)
            if let modelProvider = current.modelProvider {
                markOAuthAccountRoutingUnavailable(&current, modelProvider: modelProvider)
            }
            if current != providers[index] { providers[index] = current }
        }
        refreshProviderCredentialStatus()
    }

    private func applyProbe(_ result: ProviderProbeResult, to provider: inout Provider) {
        provider.status = result.status
        provider.statusDetail = result.detail
        if !result.modelIDs.isEmpty { provider.modelIDs = result.modelIDs }
        if case .userConfigured = provider.capacity {
            // Explicit user input remains labelled as such.
        } else {
            provider.capacity = .unavailable(reason: "Diese Anbieterprobe liefert keine account-spezifische Quote oder Rate.")
        }
    }

    private func markOAuthAccountRoutingUnavailable(_ provider: inout Provider, modelProvider: ModelProvider) {
        guard modelProvider.usesWebLogin, provider.kind.isLocalGateway else { return }
        guard provider.status == .connected || provider.status == .degraded else { return }
        provider.status = .degraded
        provider.statusDetail = "Gateway erreichbar; konkrete OAuth-Account-Zuordnung und automatischer Account-Fallback sind noch nicht verfügbar."
        provider.capacity = .unavailable(reason: "CLIProxy-Nutzung ist ohne belegte Account-Identität keiner Subscription zuordenbar.")
    }

    public func refreshTailscaleDevices() {
        guard !tailscaleLoading else { return }
        tailscaleLoading = true
        tailscaleError = nil
        let service = self.service
        Task { [weak self] in
            do {
                let devices = try await service.discoverTailscaleDevices()
                guard let self else { return }
                self.tailscaleDevices = devices
                self.tailscaleLoading = false
            } catch {
                guard let self else { return }
                self.tailscaleDevices = []
                self.tailscaleError = error.localizedDescription
                self.tailscaleLoading = false
            }
        }
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        refreshRuns()
        refreshAdHocLearnings()
        providerRefreshTask = Task { [weak self] in
            await self?.refreshProvidersNow()
            self?.providerRefreshTask = nil
        }
        pollingTask = Task { [weak self] in
            var providerTicks = 0
            var remoteTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { break }
                self.refreshRuns()
                self.refreshAdHocLearnings()
                providerTicks += 1
                remoteTicks += 1
                if providerTicks >= 15 {
                    providerTicks = 0
                    if self.providerRefreshTask == nil {
                        self.providerRefreshTask = Task { [weak self] in
                            await self?.refreshProvidersNow()
                            self?.providerRefreshTask = nil
                        }
                    }
                }
                if remoteTicks >= 5 {
                    remoteTicks = 0
                    self.refreshRemoteTelemetry()
                }
            }
        }
        refreshRemoteTelemetry()
    }

    public func stopPolling() {
        pollingTask?.cancel(); pollingTask = nil
        runRefreshTask?.cancel(); runRefreshTask = nil
        providerRefreshTask?.cancel(); providerRefreshTask = nil
        learningRefreshTask?.cancel(); learningRefreshTask = nil
        learningPersistenceTask?.cancel(); learningPersistenceTask = nil
        remoteRefreshTask?.cancel(); remoteRefreshTask = nil
    }
    public func refreshRuns() {
        runRefreshTask?.cancel()
        let service = self.service
        let workers = self.workers
        let computers = self.computers
        let claudeEventsEnabled = telemetryClaudeCodeEvents
        let sidecarEventsEnabled = telemetrySidecarEvents
        runRefreshTask = Task { [weak self] in
            let records = await Task.detached(priority: .utility) { service.runs(workers: workers) }.value
            guard !Task.isCancelled, let self else { return }
            self.activeRuns = Self.applyingTelemetryPolicy(
                to: records.compactMap { $0.state == .running ? $0.activeRun : nil },
                workers: workers,
                computers: computers,
                claudeEventsEnabled: claudeEventsEnabled,
                sidecarEventsEnabled: sidecarEventsEnabled
            )
        }
    }
    public func refreshCLIProxy() {
        let configuration = cliProxyConfiguration
        Task { [weak self] in
            guard let self else { return }
            let status = await service.inspectCLIProxy(configuration)
            guard !Task.isCancelled else { return }
            self.cliProxyStatus = status
        }
    }

    public func refreshAdHocLearnings() {
        guard learningRefreshTask == nil else { return }
        let service = self.service
        learningRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { try? service.loadAdHocLearnings() }.value
            guard let self else { return }
            self.learningRefreshTask = nil
            guard let external = result ?? nil, external != self.adHocLearnings else { return }
            self.applyingExternalLearnings = true
            self.adHocLearnings = external
            self.applyingExternalLearnings = false
        }
    }

    public func stopRun(id: UUID) {
        guard let run = activeRuns.first(where: { $0.id == id }) else { return }
        let service = self.service
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { try service.stop(run) }.value
                self?.refreshRuns()
            } catch { self?.expose(error) }
        }
    }

    @discardableResult
    public func probeRemoteComputer(_ computer: Computer) async -> RemoteHostResponse? {
        guard !computer.isLocal else {
            expose(RemoteHostProtocolError.computerNotInstalled)
            return nil
        }
        do {
            let response = try await service.probeRemoteHost(computer)
            remoteHostProbes[computer.id] = response
            remoteHostErrors[computer.id] = nil
            return response
        } catch {
            remoteHostProbes[computer.id] = nil
            remoteHostErrors[computer.id] = error.localizedDescription
            expose(error)
            return nil
        }
    }

    /// Executes the real probe -> start path and records a durable exclusive
    /// event cursor for subsequent reconnects. Unsupported adapters fail before
    /// any remote process can be claimed as started.
    @discardableResult
    public func startRemoteWorker(id workerID: UUID, input: Data) async -> RemoteWorkerRun? {
        guard let worker = workers.first(where: { $0.id == workerID }),
              let computer = computers.first(where: { $0.id == worker.computerID }),
              !computer.isLocal else { return nil }
        do {
            let registry = RemoteHarnessAdapterRegistry()
            let launch = try registry.launch(worker: worker, computer: computer, input: input)
            let probe = try await service.probeRemoteHost(computer)
            remoteHostProbes[computer.id] = probe
            remoteHostErrors[computer.id] = nil
            for capability in ["start", "events-after-exclusive-cursor", "stop", launch.harnessID]
                where !probe.capabilities.contains(capability) {
                throw RemoteHostProtocolError.missingCapability(capability)
            }

            let ledger = RemoteRunLedger(client: RemoteServiceHostClient(service: service, computer: computer))
            _ = try await ledger.start(RemoteHostRequest(operation: .start, launch: launch))
            let supervisor = RemoteConnectionSupervisor(ledger: ledger)
            remoteSessions[workerID] = RemoteSession(worker: worker, computer: computer, ledger: ledger, supervisor: supervisor)
            let run = try RemoteWorkerRun(workerID: workerID, computerID: computer.id, snapshot: await ledger.snapshot())
            remoteRuns[workerID] = run
            return run
        } catch {
            remoteHostErrors[computer.id] = error.localizedDescription
            expose(error)
            return nil
        }
    }

    public func stopRemoteWorker(id workerID: UUID) async {
        guard let session = remoteSessions[workerID] else { return }
        do {
            try await session.ledger.stop()
            remoteRuns[workerID] = try RemoteWorkerRun(
                workerID: workerID,
                computerID: session.computer.id,
                snapshot: await session.ledger.snapshot()
            )
        } catch { expose(error) }
    }

    public func refreshRemoteTelemetry(staleHeartbeatAfter: TimeInterval = 45) {
        guard remoteRefreshTask == nil else { return }
        remoteRefreshTask = Task { [weak self] in
            guard let self else { return }
            let remoteComputers = self.computers.filter { !$0.isLocal && $0.deploymentStatus == .installed }
            for computer in remoteComputers {
                do {
                    let response = try await self.service.probeRemoteHost(computer)
                    self.remoteHostProbes[computer.id] = response
                    self.remoteHostErrors[computer.id] = nil
                } catch {
                    self.remoteHostProbes[computer.id] = nil
                    self.remoteHostErrors[computer.id] = error.localizedDescription
                }
            }
            for (workerID, session) in self.remoteSessions {
                let current = await session.ledger.snapshot()
                guard !current.state.isTerminal else { continue }
                do {
                    _ = try await session.supervisor.refreshAndReapGhosts(staleAfter: staleHeartbeatAfter)
                    self.remoteRuns[workerID] = try RemoteWorkerRun(
                        workerID: workerID,
                        computerID: session.computer.id,
                        snapshot: await session.ledger.snapshot()
                    )
                } catch {
                    self.remoteRuns[workerID] = try? RemoteWorkerRun(
                        workerID: workerID,
                        computerID: session.computer.id,
                        snapshot: await session.ledger.snapshot(),
                        connectionError: error.localizedDescription
                    )
                }
            }
            self.remoteRefreshTask = nil
        }
    }

    @discardableResult
    public func bootstrapRemoteComputer(_ computer: Computer) async -> Computer {
        guard !computer.isLocal else {
            expose(RemotePiBootstrapError.localComputer)
            return computer
        }
        var checking = computer
        checking.deploymentStatus = .checking
        checking.deploymentDetail = "Prüfung läuft …"
        upsertComputer(checking)
        let deployed = await service.bootstrapRemotePi(checking)
        upsertComputer(deployed)
        await flushPersistence()
        return deployed
    }

    public func storeCredential(_ value: String, reference: String) {
        guard !value.isEmpty else { expose(CredentialError.emptyReference); return }
        do { try service.storeCredential(Data(value.utf8), reference: reference); refreshCLIProxy() }
        catch { expose(error) }
    }

    public func dismissMessage(_ message: String) { statusMessages.removeAll { $0 == message } }

    @discardableResult
    public func flushPersistence() async -> Bool {
        guard ready else { return false }
        let outcome = await persistence.flush()
        switch outcome {
        case .synchronized:
            return true
        case .nothingPending:
            if case .failed = promptSyncStatus { return false }
            return true
        case .failed:
            return false
        }
    }

    static func applyingTelemetryPolicy(
        to runs: [ActiveRun],
        workers: [Worker],
        computers: [Computer],
        claudeEventsEnabled: Bool,
        sidecarEventsEnabled: Bool
    ) -> [ActiveRun] {
        let workersByID = Dictionary(uniqueKeysWithValues: workers.map { ($0.id, $0) })
        let computersByID = Dictionary(uniqueKeysWithValues: computers.map { ($0.id, $0) })
        return runs.map { run in
            guard let workerID = run.workerID, let worker = workersByID[workerID] else { return run }
            let detailsEnabled: Bool
            switch worker.harness {
            case .claudeCode:
                detailsEnabled = claudeEventsEnabled
            case .piSidecar:
                let computer = computersByID[worker.computerID]
                let computerAllowsRemoteDetails = computer?.isLocal == true || computer?.telemetryEnabled == true
                detailsEnabled = sidecarEventsEnabled && computerAllowsRemoteDetails
            case .codexCLI, .cursorAgent, .openCode, .grokCLI:
                // These adapters are configurable, but Workjet has no verified
                // event decoder for their app-server/ACP/server streams yet.
                detailsEnabled = false
            }
            guard !detailsEnabled else { return run }
            var masked = run
            masked.activity = "läuft"
            masked.delivery = .unavailable
            return masked
        }
    }

    private func persistIfReady(handwrittenRulesChanged: Bool = false) {
        guard ready else { return }
        promptSyncStatus = .pending
        persistence.schedule(configuration, handwrittenChanged: handwrittenRulesChanged)
    }

    private func persistLearningsIfReady() {
        guard ready, !applyingExternalLearnings else { return }
        learningPersistenceTask?.cancel()
        let service = self.service
        let value = adHocLearnings
        let configuration = self.configuration
        learningPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try service.saveAdHocLearnings(value, configuration: configuration)
                }.value
            } catch {
                self?.expose(error)
            }
            self?.learningPersistenceTask = nil
        }
    }

    private func expose(_ error: Error) {
        let message = error.localizedDescription
        if !statusMessages.contains(message) { statusMessages.append(message) }
    }

    private func applyPersistenceOutcome(_ outcome: PersistenceCoordinator.Outcome) {
        switch outcome {
        case .nothingPending:
            break
        case .synchronized:
            promptSyncStatus = .synchronized(Date())
        case let .failed(message):
            promptSyncStatus = .failed(message)
            if !statusMessages.contains(message) { statusMessages.append(message) }
        }
    }
}
