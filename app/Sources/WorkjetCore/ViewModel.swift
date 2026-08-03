import Combine
import Foundation

@MainActor
public final class WorkjetViewModel: ObservableObject {
    @Published public private(set) var workers: [Worker] { didSet { persistIfReady() } }
    @Published public private(set) var computers: [Computer] { didSet { persistIfReady() } }
    @Published public private(set) var providers: [Provider] { didSet { persistIfReady() } }
    @Published public private(set) var activeRuns: [ActiveRun] = []
    @Published public private(set) var cliProxyStatus: CLIProxyStatus
    @Published public private(set) var providerAccessStored: Set<UUID> = []
    @Published public private(set) var tailscaleDevices: [TailscaleDevice] = []
    @Published public private(set) var tailscaleError: String?
    @Published public private(set) var tailscaleLoading = false
    @Published public private(set) var statusMessages: [String]

    @Published public var skillRules: String { didSet { persistIfReady(handwrittenRulesChanged: true) } }
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
    private lazy var persistence = PersistenceCoordinator(service: service, delay: persistenceDelay) { [weak self] error in
        Task { @MainActor in self?.expose(error) }
    }
    private var ready = false
    private var pollingTask: Task<Void, Never>?
    private var runRefreshTask: Task<Void, Never>?

    public init(configuration: WorkjetConfiguration, service: any WorkjetService = NullWorkjetService(), messages: [String] = [], persistenceDelay: TimeInterval = 0.25) {
        let value = WorkjetBootstrap.normalized(configuration)
        self.service = service
        self.persistenceDelay = persistenceDelay
        workers = value.workers
        computers = value.computers
        providers = value.providers
        selectedComputerID = value.selectedComputerID
        skillRules = value.skillRules
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
        ready = true
    }

    public static func live(paths: WorkjetPaths = .live) -> WorkjetViewModel {
        let bootstrap = WorkjetBootstrap.live(paths: paths)
        return WorkjetViewModel(configuration: bootstrap.configuration, service: bootstrap.service, messages: bootstrap.messages)
    }

    public var visibleWorkers: [Worker] { WorkerFilter.filtered(workers, query: searchQuery, computerID: selectedComputerID) }
    public var promptPreview: String {
        String(data: ManagedPrompt.workerBody(configuration: configuration), encoding: .utf8) ?? "Prompt kann nicht dargestellt werden."
    }
    public var configuration: WorkjetConfiguration {
        WorkjetConfiguration(workers: workers, computers: computers, providers: providers, selectedComputerID: selectedComputerID, skillRules: skillRules, skillActivation: skillActivation, injectWorkerDeclarations: injectWorkerDeclarations, telemetryClaudeCodeEvents: telemetryClaudeCodeEvents, telemetrySidecarEvents: telemetrySidecarEvents, telemetryRetentionDays: telemetryRetentionDays, providerSlots: providerSlots, probeTimeoutSeconds: probeTimeoutSeconds, turnTimeoutSeconds: turnTimeoutSeconds, degradationAllowed: degradationAllowed, cliProxy: cliProxyConfiguration)
    }

    public func computer(for id: UUID) -> Computer? { computers.first { $0.id == id } }
    public func toggleComputerSelection(_ id: UUID) { if computers.contains(where: { $0.id == id }) { selectedComputerID = id } }

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
        guard let providerID = worker.providerID else { return worker.capacity }
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            return .unavailable(reason: "Die gespeicherte Anbieterroute wurde gelöscht oder ist nicht verfügbar.")
        }
        return providerPresentation(for: provider).capacity
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

    public func addProvider(_ provider: Provider) { providers.append(provider) }
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
            provider.status = result.status
            provider.statusDetail = result.detail
            if !result.modelIDs.isEmpty { provider.modelIDs = result.modelIDs }
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
        refreshCLIProxy()
        refreshProviderCredentialStatus()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { break }
                self.refreshRuns()
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel(); pollingTask = nil
        runRefreshTask?.cancel(); runRefreshTask = nil
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

    public func flushPersistence() async {
        guard ready else { return }
        await persistence.flush()
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
        persistence.schedule(configuration, handwrittenChanged: handwrittenRulesChanged)
    }

    private func expose(_ error: Error) {
        let message = error.localizedDescription
        if !statusMessages.contains(message) { statusMessages.append(message) }
    }
}
