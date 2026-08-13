import Combine
import Foundation

public enum WorkerRecoveryAction: Equatable, Sendable {
    case computer(UUID)
    case provider(WorkerProviderRecovery)
}

public enum WorkerDeletionResult: Equatable, Sendable {
    case deleted
    case blocked(String)
    case failed(String)
}

public enum DurableConfigurationMutationResult: Equatable, Sendable {
    case succeeded
    case failed(String)
}

public enum ProviderDeletionResult: Equatable, Sendable {
    case deleted
    case deletedWithWarning(String)
    case failed(String)
}

public enum ProviderSaveResult: Equatable, Sendable {
    case saved(Provider)
    case savedWithProbeFailure(Provider, String)
    case failed(String)
}

public enum ActiveRunOrigin: Equatable, Sendable {
    case local(runID: UUID)
    case remote(workerID: UUID)
}

/// UI-ready execution facts. Values such as model, reasoning, speed and route
/// stay optional unless they were observed in the local telemetry snapshot or
/// in the exact remote launch accepted by Workjet.
public struct ActiveRunPresentation: Identifiable, Equatable, Sendable {
    public var id: String
    public var origin: ActiveRunOrigin
    public var workerName: String
    public var computerName: String
    public var model: String?
    public var reasoning: ReasoningEffort?
    public var speed: RunSpeed?
    public var providerRoute: String?
    public var startedAt: Date?
    public var state: String
    public var activity: String
    public var recoveryComputerID: UUID?
}

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
    @Published public private(set) var workjetActivationStatus: WorkjetActivationStatus
    /// Retained for source compatibility. Workjet cannot observe which Claude
    /// sessions have reloaded a prompt, so it must never claim that a restart
    /// is still required after the prompt is durably current on disk.
    @Published public private(set) var claudeRestartRequired = false
    @Published public private(set) var harnessStatuses: [UUID: [Harness: HarnessComputerStatus]] = [:]
    @Published public private(set) var workerProvisioningFailures: [UUID: RemoteProvisioningFailure] = [:]
    @Published public private(set) var workerHealth: [UUID: WorkjetCLIWorkerHealth] = [:]
    @Published public private(set) var workerHealthCheckedAt: Date?
    @Published public private(set) var workerHealthProbeInFlight = false
    @Published public private(set) var workerHealthProbeError: String?

    @Published public var skillRules: String { didSet { persistIfReady(handwrittenRulesChanged: true) } }
    @Published public var skillLoaderInstructions: String { didSet { persistIfReady() } }
    @Published public private(set) var modelPrompts: [String: String] { didSet { persistIfReady() } }
    @Published public var progressBoardRules: String { didSet { persistIfReady() } }
    @Published public var adHocLearnings: String { didSet { persistLearningsIfReady() } }
    @Published public var technicalRules: String { didSet { persistIfReady() } }
    @Published public var skillActivation: SkillActivation { didSet { persistIfReady() } }
    @Published public var injectWorkerDeclarations: Bool { didSet { persistIfReady() } }
    @Published public var telemetryClaudeCodeEvents: Bool { didSet { persistIfReady(); if ready { refreshRuns() } } }
    @Published public var telemetrySidecarEvents: Bool { didSet { persistIfReady(); if ready { refreshRuns() } } }
    @Published public var telemetryRetentionDays: Int {
        didSet {
            lastTelemetryCleanupAt = nil
            persistIfReady()
            if ready { refreshRuns() }
        }
    }
    @Published public var providerSlots: Int { didSet { persistIfReady() } }
    @Published public var probeTimeoutSeconds: Int { didSet { persistIfReady() } }
    @Published public var turnTimeoutSeconds: Int { didSet { persistIfReady() } }
    @Published public var degradationAllowed: Bool { didSet { persistIfReady() } }
    @Published public var cliProxyConfiguration: CLIProxyConfiguration { didSet { persistIfReady() } }

    @Published public var searchQuery = ""
    @Published public private(set) var selectedComputerID: UUID { didSet { persistIfReady() } }

    private let service: any WorkjetService
    private let telemetryMaintenance: RunTelemetryStore?
    private let persistenceDelay: TimeInterval
    private lazy var persistence = PersistenceCoordinator(service: service, delay: persistenceDelay) { [weak self] outcome in
        Task { @MainActor in self?.applyPersistenceOutcome(outcome) }
    }
    private var ready = false
    private var pollingTask: Task<Void, Never>?
    private var runRefreshTask: Task<Void, Never>?
    private var providerRefreshTask: Task<Void, Never>?
    private var harnessRefreshTask: Task<Void, Never>?
    private var learningRefreshTask: Task<Void, Never>?
    private var learningPersistenceTask: Task<Void, Never>?
    private var remoteRefreshTask: Task<Void, Never>?
    private var lastTelemetryCleanupAt: Date?
    private var workjetActivationCheckGeneration = 0
    private var remoteSessions: [UUID: RemoteSession] = [:]
    private var remoteRunIssues: [UUID: RemoteRunIssue] = [:]
    private var applyingExternalLearnings = false
    private var applyingProviderObservation = false
    private var providerSavesInFlight: Set<UUID> = []
    private var harnessOperationGenerations: [HarnessStatusKey: Int] = [:]

    private struct HarnessStatusKey: Hashable {
        var computerID: UUID
        var harness: Harness
    }

    private struct DurableConfigurationSnapshot {
        var workers: [Worker]
        var computers: [Computer]
        var providers: [Provider]
        var providerAccessStored: Set<UUID>
        var selectedComputerID: UUID
    }

    private enum RemoteRunIssue: Equatable {
        case connection
        case historyIncomplete
    }

    private struct RemoteSession {
        var worker: Worker
        var computer: Computer
        var ledger: RemoteRunLedger
        var supervisor: RemoteConnectionSupervisor
    }

    /// Stable across app launches because Worker IDs are persisted in the
    /// configuration. No model/name inference is permitted for ownership.
    private static func remoteOwnerID(for workerID: UUID) -> String {
        "workjet-worker-\(workerID.uuidString.lowercased())"
    }

    public init(configuration: WorkjetConfiguration, service: any WorkjetService = NullWorkjetService(), messages: [String] = [], persistenceDelay: TimeInterval = 0.25, telemetryMaintenance: RunTelemetryStore? = nil) {
        let value = WorkjetBootstrap.normalized(configuration)
        self.service = service
        self.telemetryMaintenance = telemetryMaintenance
        self.persistenceDelay = persistenceDelay
        workers = value.workers
        computers = value.computers
        providers = value.providers
        // A credential reference is non-secret configuration metadata. Do not
        // read credential files while constructing the UI; validation belongs
        // to an explicit provider test or execution action.
        providerAccessStored = Set(value.providers.compactMap { provider in
            provider.credentialReference == nil ? nil : provider.id
        })
        selectedComputerID = value.selectedComputerID
        skillRules = value.skillRules
        skillLoaderInstructions = value.skillLoaderInstructions ?? WorkjetDefaults.skillLoaderInstructions
        modelPrompts = value.modelPrompts ?? [:]
        progressBoardRules = value.progressBoardRules ?? WorkjetDefaults.progressBoardRules
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
        promptSyncStatus = messages.isEmpty ? .pending : .failed(messages.last ?? "Prompt konnte nicht synchronisiert werden.")
        workjetActivationStatus = .checking
        ready = true
        seedRemoteRunForUITestingIfRequested()
        refreshWorkjetActivationStatus()
    }

    public static func live(paths: WorkjetPaths = .live) -> WorkjetViewModel {
        let bootstrap = WorkjetBootstrap.live(paths: paths)
        return WorkjetViewModel(
            configuration: bootstrap.configuration,
            service: bootstrap.service,
            messages: bootstrap.messages,
            telemetryMaintenance: RunTelemetryStore(paths: paths)
        )
    }

    public var visibleWorkers: [Worker] { WorkerFilter.filtered(workers, query: searchQuery, computerID: selectedComputerID) }
    public var activeRunPresentations: [ActiveRunPresentation] {
        let activeRemoteRuns = remoteRuns.values.filter { !$0.state.isTerminal }
        let remoteWorkerIDs = Set(activeRemoteRuns.map(\.workerID))
        let remote = activeRemoteRuns.map(remotePresentation)
        let local = activeRuns
            .filter { run in run.workerID.map { !remoteWorkerIDs.contains($0) } ?? true }
            .map(localPresentation)
        return (remote + local).sorted {
            ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
    }
    public var runtimeStatus: WorkjetRuntimeStatus {
        if case .failed = promptSyncStatus { return .attention }
        if [.missing, .outOfDate, .failed].contains(workjetActivationStatus.state) { return .attention }
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
            return "Änderungen konnten nicht übernommen werden"
        case .synchronized:
            break
        }
        if let issue = runtimeHealthIssues.first { return issue }
        let remoteCount = remoteRuns.values.filter { !$0.state.isTerminal }.count
        if !activeRuns.isEmpty || remoteCount > 0 {
            let count = activeRuns.count + remoteCount
            return count == 1 ? "1 Ausführung aktiv" : "\(count) Ausführungen aktiv"
        }
        return "Prompt aktuell"
    }

    public var runtimeHealthIssues: [String] {
        var issues: [String] = []
        if let selected = computer(for: selectedComputerID), !selected.isLocal {
            if selected.deploymentStatus != .installed {
                issues.append("Computer nicht vollständig eingerichtet")
            } else if remoteHostProbes[selected.id] == nil {
                issues.append("Computerverbindung prüfen")
            }
        }
        let relevantWorkers = workers.filter { $0.computerID == selectedComputerID }
        let unavailableRoutes = relevantWorkers.filter { worker in
            switch worker.providerRoute {
            case let .account(providerID):
                return !providers.contains(where: { $0.id == providerID })
            case let .pool(modelProvider):
                return providerPool(for: modelProvider).accounts.isEmpty
            case nil:
                return true
            }
        }.count
        if unavailableRoutes > 0 {
            issues.append("\(unavailableRoutes) Worker ohne Anbieterzugang")
        }
        return issues
    }
    public var generatedPromptPreview: String {
        String(data: ManagedPrompt.workerBody(configuration: configuration), encoding: .utf8) ?? "Prompt kann nicht dargestellt werden."
    }
    public var generatedWorkerPreview: String {
        workers
            .map { ManagedPrompt.generatedWorkerConfiguration(for: $0, configuration: configuration) }
            .joined(separator: "\n\n")
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
        WorkjetConfiguration(workers: workers, computers: computers, providers: providers, selectedComputerID: selectedComputerID, skillRules: skillRules, skillLoaderInstructions: skillLoaderInstructions, modelPrompts: modelPrompts, progressBoardRules: progressBoardRules, adHocLearnings: adHocLearnings, technicalRules: technicalRules, transparentWorkerPromptsMigrated: true, skillActivation: skillActivation, injectWorkerDeclarations: injectWorkerDeclarations, telemetryClaudeCodeEvents: telemetryClaudeCodeEvents, telemetrySidecarEvents: telemetrySidecarEvents, telemetryRetentionDays: telemetryRetentionDays, providerSlots: providerSlots, probeTimeoutSeconds: probeTimeoutSeconds, turnTimeoutSeconds: turnTimeoutSeconds, degradationAllowed: degradationAllowed, cliProxy: cliProxyConfiguration)
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

    public func generatedWorkerConfiguration(for worker: Worker) -> String {
        ManagedPrompt.generatedWorkerConfiguration(for: worker, configuration: configuration)
    }

    public func computer(for id: UUID) -> Computer? { computers.first { $0.id == id } }
    public func harnessStatus(_ harness: Harness, on computerID: UUID) -> HarnessComputerStatus {
        harnessStatuses[computerID]?[harness] ?? .unknown
    }

    @discardableResult
    public func inspectHarness(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        let key = HarnessStatusKey(computerID: computer.id, harness: harness)
        let previous = harnessStatus(harness, on: computer.id)
        let generation = beginHarnessOperation(for: key)
        setHarnessStatus(HarnessComputerStatus(state: .checking, detail: "Wird geprüft …", action: .check), harness: harness, computerID: computer.id)
        let status = await service.inspectHarness(harness, on: computer)
        guard harnessOperationGenerations[key] == generation else {
            return harnessStatus(harness, on: computer.id)
        }
        guard !Task.isCancelled else {
            setHarnessStatus(previous, harness: harness, computerID: computer.id)
            return previous
        }
        setHarnessStatus(status, harness: harness, computerID: computer.id)
        if status.state == .installed {
            clearResolvedProvisioningFailures(
                on: computer.id,
                matching: { failure in
                    failure.component.kind == .harness
                        && Self.harness(forRemoteID: failure.component.id) == harness
                }
            )
        }
        return status
    }

    public func inspectHarnesses(on computer: Computer) async {
        for harness in Harness.allCases { _ = await inspectHarness(harness, on: computer) }
    }

    public func refreshConfiguredHarnessesNow() async {
        var seen: Set<HarnessStatusKey> = []
        for worker in workers {
            guard !Task.isCancelled,
                  let computer = computers.first(where: { $0.id == worker.computerID }) else { continue }
            let key = HarnessStatusKey(computerID: computer.id, harness: worker.harness)
            guard seen.insert(key).inserted else { continue }
            _ = await inspectHarness(worker.harness, on: computer)
        }
    }

    @discardableResult
    public func performHarnessAction(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        guard action != .unavailable else { return harnessStatus(harness, on: computer.id) }
        let key = HarnessStatusKey(computerID: computer.id, harness: harness)
        let previous = harnessStatus(harness, on: computer.id)
        let generation = beginHarnessOperation(for: key)
        setHarnessStatus(HarnessComputerStatus(state: .checking, detail: "Aktion läuft …", action: action), harness: harness, computerID: computer.id)
        let status = await service.performHarnessAction(action, harness: harness, on: computer)
        guard harnessOperationGenerations[key] == generation else {
            return harnessStatus(harness, on: computer.id)
        }
        guard !Task.isCancelled else {
            setHarnessStatus(previous, harness: harness, computerID: computer.id)
            return previous
        }
        setHarnessStatus(status, harness: harness, computerID: computer.id)
        return status
    }

    private func beginHarnessOperation(for key: HarnessStatusKey) -> Int {
        let generation = (harnessOperationGenerations[key] ?? 0) + 1
        harnessOperationGenerations[key] = generation
        return generation
    }

    private func setHarnessStatus(_ status: HarnessComputerStatus, harness: Harness, computerID: UUID) {
        var values = harnessStatuses[computerID] ?? [:]
        values[harness] = status
        harnessStatuses[computerID] = values
    }

    @discardableResult
    public func provisionRemoteWorker(_ worker: Worker, on computer: Computer) async -> RemoteWorkerProvisioningResult {
        let result = await service.provisionRemoteWorker(worker, on: computer)
        applyProvisioningResult(result, workers: [worker], computer: computer)
        return result
    }

    @discardableResult
    public func provisionConfiguredWorkers(on computer: Computer) async -> RemoteWorkerProvisioningResult {
        let assigned = workers.filter { $0.computerID == computer.id }
        guard !assigned.isEmpty else {
            let capabilities = (try? await service.probeRemoteHost(computer))?.capabilities ?? []
            let result = RemoteWorkerProvisioningResult(workerIDs: [], computerID: computer.id, verifiedCapabilities: capabilities)
            if !result.verifiedCapabilities.isEmpty {
                remoteHostProbes[computer.id] = RemoteHostResponse(ok: true, capabilities: result.verifiedCapabilities)
                remoteHostErrors[computer.id] = nil
            }
            return result
        }
        let result = await service.provisionRemoteWorkers(assigned, on: computer)
        applyProvisioningResult(result, workers: assigned, computer: computer)
        return result
    }

    private func applyProvisioningResult(_ result: RemoteWorkerProvisioningResult, workers: [Worker], computer: Computer) {
        if !result.verifiedCapabilities.isEmpty {
            remoteHostProbes[computer.id] = RemoteHostResponse(ok: true, capabilities: result.verifiedCapabilities)
        }
        for component in result.components where component.kind == .harness {
            guard let harness = Self.harness(forRemoteID: component.id) else { continue }
            let status: HarnessComputerStatus
            switch component.state {
            case .installed:
                let actions: [HarnessComputerAction] = harness == .piSidecar ? [.check] : [.update, .remove]
                status = HarnessComputerStatus(state: .installed, detail: component.detail, version: component.version, action: actions[0], actions: actions)
            case .missing:
                status = HarnessComputerStatus(state: .missing, detail: component.detail, version: component.version, action: .install, actions: [.install])
            case .broken:
                status = HarnessComputerStatus(state: .broken, detail: component.detail, version: component.version, action: .check, actions: [.check])
            case .unavailable:
                status = HarnessComputerStatus(state: .broken, detail: component.detail, version: component.version, action: .check, actions: [.check])
            }
            setHarnessStatus(status, harness: harness, computerID: computer.id)
        }
        if let failure = result.failure {
            remoteHostErrors[computer.id] = failure.userVisibleDetail
            for worker in workers {
                workerProvisioningFailures[worker.id] = failure
                if harnessStatus(worker.harness, on: computer.id).state == .checking {
                    setHarnessStatus(
                        HarnessComputerStatus(
                            state: .broken,
                            detail: "Remote-Bereitstellung fehlgeschlagen. \(failure.userVisibleDetail)",
                            action: .check,
                            actions: [.check]
                        ),
                        harness: worker.harness,
                        computerID: computer.id
                    )
                }
            }
        } else {
            remoteHostErrors[computer.id] = nil
            for worker in workers { workerProvisioningFailures[worker.id] = nil }
        }
    }

    private static func harness(forRemoteID id: String) -> Harness? {
        switch id {
        case "claude-code": return .claudeCode
        case "pi-code": return .piSidecar
        case "codex-cli": return .codexCLI
        case "opencode": return .openCode
        case "cursor-agent": return .cursorAgent
        case "grok-cli": return .grokCLI
        default: return nil
        }
    }

    private func clearResolvedProvisioningFailures(
        on computerID: UUID,
        matching predicate: (RemoteProvisioningFailure) -> Bool
    ) {
        for worker in workers where worker.computerID == computerID {
            guard let failure = workerProvisioningFailures[worker.id], predicate(failure) else { continue }
            workerProvisioningFailures[worker.id] = nil
        }
    }

    public func toggleComputerSelection(_ id: UUID) {
        guard computers.contains(where: { $0.id == id }) else { return }
        selectedComputerID = id
    }

    public func providerPresentation(for provider: Provider) -> ProviderPresentation {
        if provider.kind.isLocalGateway, provider.modelProvider?.usesWebLogin == true {
            return ProviderPresentation(
                state: "Im Gateway registriert",
                detail: "Die Account-Identität ist registriert. CLIProxy kann diesen einzelnen Account nicht für eine Probe pinnen; nur der gemeinsame Workerpfad ist prüfbar.",
                tone: .neutral,
                capacity: provider.capacity
            )
        }
        let evidence = workerHealthEvidence(for: provider)
        return runtimePresentation(
            evidence: evidence,
            uncheckedState: providerAccessStored.contains(provider.id) || provider.authentication == .none
                ? "Konfiguriert · nicht per Worker geprüft"
                : "Zugang fehlt",
            uncheckedDetail: "Grün erscheint erst nach einer erfolgreichen Worker-Probe mit echter Modellantwort.",
            capacity: provider.capacity
        )
    }

    public func providerPoolPresentation(for modelProvider: ModelProvider) -> ProviderPresentation {
        let accounts = providerAccounts(for: modelProvider)
        guard !accounts.isEmpty else {
            return ProviderPresentation(state: "Kein Zugang", detail: "Für diesen Anbieter ist kein Zugang registriert.", tone: .critical, capacity: .unavailable(reason: "Kein Zugang registriert."))
        }
        let ids = Set(accounts.map(\.id))
        let evidence = workers.compactMap { worker -> WorkjetCLIWorkerHealth? in
            switch worker.providerRoute {
            case let .pool(provider) where provider == modelProvider:
                return workerHealth[worker.id]
            case let .account(id) where ids.contains(id):
                return workerHealth[worker.id]
            default:
                return nil
            }
        }
        return runtimePresentation(
            evidence: evidence,
            uncheckedState: "Workerpfad nicht geprüft",
            uncheckedDetail: "Starte „Alle Worker prüfen“, um einen echten kurzen Modellturn auszuführen.",
            capacity: providerPool(for: modelProvider).capacity
        )
    }

    public var workerHealthFreshnessText: String {
        guard let checkedAt = workerHealthCheckedAt else { return "Noch keine echte Worker-Probe ausgeführt" }
        let age = max(0, Int(Date().timeIntervalSince(checkedAt)))
        if age < 60 { return "Zuletzt geprüft vor \(age) s" }
        return "Zuletzt geprüft vor \(age / 60) min"
    }

    public func probeAllWorkersNow() async {
        await probeWorkersNow(workerIDs: nil)
    }

    private func probeWorkersNow(workerIDs: [UUID]?) async {
        guard !workerHealthProbeInFlight else { return }
        workerHealthProbeInFlight = true
        workerHealthProbeError = nil
        defer { workerHealthProbeInFlight = false }
        do {
            let results: [WorkjetCLIWorkerHealth]
            if let workerIDs {
                // An authorization change invalidates the previous runtime
                // evidence. Keep no unrelated result artificially fresh.
                workerHealth = [:]
                results = try await service.probeConfiguredWorkers(
                    workerIDs: workerIDs,
                    timeoutSeconds: probeTimeoutSeconds
                )
            } else {
                results = try await service.probeConfiguredWorkers(timeoutSeconds: probeTimeoutSeconds)
            }
            workerHealth = Dictionary(uniqueKeysWithValues: results.map { ($0.workerID, $0) })
            workerHealthCheckedAt = Date()
            refreshRuns()
        } catch {
            workerHealth = [:]
            workerHealthCheckedAt = Date()
            workerHealthProbeError = error.localizedDescription
        }
    }

    private func workerIDsAffectedByAuthorization(
        providerID: UUID,
        modelProvider: ModelProvider
    ) -> [UUID] {
        workers.compactMap { worker in
            switch worker.providerRoute {
            case let .account(id):
                guard id == providerID
                        || providers.first(where: { $0.id == id })?.modelProvider == modelProvider else { return nil }
                return worker.id
            case let .pool(provider):
                return provider == modelProvider ? worker.id : nil
            case nil:
                return nil
            }
        }
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
                label: "Ausführungsart fehlt",
                detail: "\(worker.harness.rawValue) ist auf diesem Computer noch nicht eingerichtet."
            )
        }
        if !computer.isLocal, let failure = workerProvisioningFailures[worker.id] {
            let label: String
            switch failure.component.kind {
            case .host: label = "Computer nicht bereit"
            case .harness: label = failure.component.state == .missing ? "Harness fehlt" : "Harness fehlerhaft"
            case .managedSkill: label = failure.component.state == .missing ? "Skill fehlt" : "Skill fehlerhaft"
            }
            return WorkerOperationalStatus(state: .unavailable, label: label, detail: failure.userVisibleDetail)
        }
        guard !worker.invocation.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WorkerOperationalStatus(state: .unavailable, label: "Ausführungsart fehlt", detail: "\(worker.harness.rawValue) ist noch nicht vollständig eingerichtet.")
        }

        do {
            _ = try ProviderRuntimeRouteResolver.resolve(
                worker: worker,
                providers: providers,
                target: computer.isLocal ? .local : .remote
            )
        } catch let error as ProviderRuntimeRouteError {
            let label = error == .remoteProfileUnavailable ? "Remote-Zugang fehlt" : "Anbieter fehlt"
            return WorkerOperationalStatus(state: .unavailable, label: label, detail: error.localizedDescription)
        } catch {
            return WorkerOperationalStatus(state: .unavailable, label: "Anbieter fehlt", detail: error.localizedDescription)
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
                return WorkerOperationalStatus(state: .unavailable, label: "Kein Zugang", detail: "Für \(modelProvider.rawValue) ist kein Zugang konfiguriert.")
            }
        case nil:
            return WorkerOperationalStatus(state: .unavailable, label: "Anbieter fehlt", detail: "Wähle einen Zugang oder „Alle Zugänge“.")
        }

        let lifecycle = harnessStatus(worker.harness, on: computer.id)
        guard lifecycle.state == .installed else {
            let label: String
            switch lifecycle.state {
            case .unknown: label = "Harness nicht geprüft"
            case .checking: label = "Harness wird geprüft"
            case .missing: label = "Harness fehlt"
            case .broken: label = "Harness fehlerhaft"
            case .installed: label = "Harness installiert"
            }
            return WorkerOperationalStatus(state: lifecycle.state == .checking || lifecycle.state == .unknown ? .unverified : .unavailable, label: label, detail: lifecycle.detail)
        }
        let requiredSkills = WorkerSkillCatalog.effectiveSkills(for: worker)
        if !computer.isLocal, !requiredSkills.isEmpty {
            guard let probe = remoteHostProbes[computer.id] else {
                return WorkerOperationalStatus(state: .unverified, label: "Skills nicht geprüft", detail: "Die verwalteten Skills wurden auf diesem Computer noch nicht bestätigt.")
            }
            for skill in requiredSkills where !probe.capabilities.contains(skill.id) {
                return WorkerOperationalStatus(state: .unavailable, label: "Skill fehlt", detail: "Skill \(skill.id): Die verwaltete Installation wurde auf diesem Computer nicht als bereit bestätigt.")
            }
        }
        guard workerHealthIsFresh else {
            return WorkerOperationalStatus(
                state: .unverified,
                label: workerHealthCheckedAt == nil ? "Nicht geprüft" : "Prüfung veraltet",
                detail: "„Alle Worker prüfen“ startet einen echten kurzen Modellturn. Erst dessen Antwort darf diesen Worker grün markieren."
            )
        }
        guard let health = workerHealth[worker.id] else {
            return WorkerOperationalStatus(state: .unverified, label: "Nicht geprüft", detail: "Für diesen Worker liegt aus der letzten Probe kein Ergebnis vor.")
        }
        if health.status == "ready", health.responseTokenObserved {
            return WorkerOperationalStatus(state: .ready, label: "Geprüft", detail: "Echte Modellantwort in \(health.latencyMilliseconds) ms über \(health.providerRoute ?? "die konfigurierte Route").")
        }
        return WorkerOperationalStatus(
            state: .unavailable,
            label: health.status == "timeout" ? "Zeitüberschreitung" : "Probe fehlgeschlagen",
            detail: health.message ?? "Der Worker hat die erwartete Health-Antwort nicht geliefert."
        )
    }

    public func providerRecovery(for worker: Worker) -> WorkerProviderRecovery? {
        let inferredProvider = ModelProvider.inferred(from: worker.model)
        switch worker.providerRoute {
        case nil:
            guard let inferredProvider else { return .configure(nil) }
            if !providerAccounts(for: inferredProvider).isEmpty {
                return .configure(inferredProvider)
            }
            return inferredProvider.usesWebLogin ? .connect(inferredProvider) : .configure(inferredProvider)
        case let .account(accountID):
            guard let account = providers.first(where: { $0.id == accountID }) else {
                guard let inferredProvider else { return .configure(nil) }
                return inferredProvider.usesWebLogin ? .connect(inferredProvider) : .configure(inferredProvider)
            }
            let observedFailure = workerHealthIsFresh
                && workerHealth[worker.id].map { $0.status != "ready" } == true
            guard account.status == .offline || observedFailure else { return nil }
            guard let provider = account.modelProvider else { return .configure(inferredProvider) }
            return provider.usesWebLogin
                ? .reauthenticate(accountID: accountID, provider: provider)
                : .configure(provider)
        case let .pool(provider):
            let accounts = providerAccounts(for: provider)
            let observedFailure = workerHealthIsFresh
                && workerHealth[worker.id].map { $0.status != "ready" } == true
            guard accounts.allSatisfy({ $0.status == .offline }) || observedFailure else { return nil }
            if provider.usesWebLogin, let existing = accounts.first {
                return .reauthenticate(accountID: existing.id, provider: provider)
            }
            return provider.usesWebLogin ? .connect(provider) : .configure(provider)
        }
    }

    public func recoveryAction(for worker: Worker) -> WorkerRecoveryAction? {
        guard let computer = computers.first(where: { $0.id == worker.computerID }) else { return nil }
        if !computer.isLocal, computer.deploymentStatus != .installed {
            return .computer(computer.id)
        }
        return providerRecovery(for: worker).map(WorkerRecoveryAction.provider)
    }

    public func upsertWorker(_ worker: Worker) {
        if let index = workers.firstIndex(where: { $0.id == worker.id }) { workers[index] = worker }
        else { workers.append(worker) }
    }

    public func saveWorkerDurably(_ worker: Worker) async -> DurableConfigurationMutationResult {
        guard let computer = computers.first(where: { $0.id == worker.computerID }) else {
            return .failed("„\(worker.name)“ wurde nicht gespeichert. Der ausgewählte Computer ist nicht mehr vorhanden.")
        }
        let result = await performDurableConfigurationMutation(
            failureMessage: { failure in
                "„\(worker.name)“ wurde nicht gespeichert. Die vorherige Konfiguration wurde wiederhergestellt. Persistenzfehler: \(failure)"
            },
            mutation: { upsertWorker(worker) }
        )
        guard result == .succeeded, !computer.isLocal else { return result }

        setHarnessStatus(
            HarnessComputerStatus(state: .checking, detail: "Remote-Komponenten werden im Hintergrund eingerichtet.", action: .check),
            harness: worker.harness,
            computerID: computer.id
        )
        Task { [weak self] in
            guard let self else { return }
            _ = await self.provisionRemoteWorker(worker, on: computer)
        }
        return result
    }

    public func workerDeletionBlockReason(id: UUID) -> String? {
        guard let worker = workers.first(where: { $0.id == id }) else { return nil }
        let hasLocalRun = activeRuns.contains { $0.workerID == id }
        let hasRemoteRun = remoteRuns[id].map { !$0.state.isTerminal } == true
        guard hasLocalRun || hasRemoteRun else { return nil }
        return "„\(worker.name)“ läuft gerade. Stoppe den Worker zuerst im Bereich Aktiv und versuche es danach erneut."
    }

    /// Deletes only the persisted worker declaration. Shared model rules and
    /// historical run records are deliberately outside this mutation.
    public func deleteWorker(id: UUID) async -> WorkerDeletionResult {
        guard let worker = workers.first(where: { $0.id == id }) else {
            return .failed("Der Worker ist nicht mehr vorhanden.")
        }
        if let reason = workerDeletionBlockReason(id: id) { return .blocked(reason) }

        let result = await performDurableConfigurationMutation(
            failureMessage: { failure in
                "„\(worker.name)“ wurde nicht gelöscht. Die vorherige Konfiguration wurde wiederhergestellt. Persistenzfehler: \(failure)"
            },
            mutation: { workers.removeAll { $0.id == id } }
        )
        switch result {
        case .succeeded:
            return .deleted
        case let .failed(message):
            return .failed(message)
        }
    }

    public func upsertComputer(_ computer: Computer) {
        if let index = computers.firstIndex(where: { $0.id == computer.id }) { computers[index] = computer }
        else { computers.append(computer) }
        if ready { refreshRuns() }
    }

    public func saveComputerDurably(_ computer: Computer) async -> DurableConfigurationMutationResult {
        await performDurableConfigurationMutation(
            failureMessage: { failure in
                "„\(computer.name)“ wurde nicht gespeichert. Die vorherige Konfiguration wurde wiederhergestellt. Persistenzfehler: \(failure)"
            },
            mutation: { upsertComputer(computer) }
        )
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

    public func deleteComputerDurably(id: UUID) async -> DurableConfigurationMutationResult {
        guard let computer = computers.first(where: { $0.id == id }) else {
            return .failed("Der Computer ist nicht mehr vorhanden.")
        }
        guard !computer.isLocal else {
            return .failed("Der lokale Computer kann nicht gelöscht werden.")
        }
        guard computers.contains(where: \.isLocal) else {
            return .failed("Der lokale Computer für die Worker-Wiederherstellung fehlt.")
        }
        return await performDurableConfigurationMutation(
            failureMessage: { failure in
                "„\(computer.name)“ wurde nicht gelöscht. Die vorherige Konfiguration wurde wiederhergestellt. Persistenzfehler: \(failure)"
            },
            mutation: { removeComputer(id: id) }
        )
    }

    public func addProvider(_ provider: Provider) { providers.append(provider) }

    @discardableResult
    public func connectCustomProvider(
        name: String,
        endpoint: String,
        authentication: ProviderAuthentication,
        apiKey: String
    ) async -> Provider? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanEndpoint.isEmpty else {
            statusMessages.append("Name und kompatibler Endpunkt sind erforderlich.")
            return nil
        }
        if authentication != .none, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessages.append("Für diese Authentifizierung fehlt der API-Key.")
            return nil
        }
        let provider = Provider(
            name: cleanName,
            kind: .directAPI,
            endpoint: cleanEndpoint,
            authentication: authentication,
            modelProvider: nil
        )
        providers.append(provider)
        await testProvider(id: provider.id, secret: apiKey)
        return providers.first(where: { $0.id == provider.id })
    }
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
            modelIDs: modelProvider.requestedModelSuggestions,
            credentialReference: modelProvider.usesWebLogin ? CLIProxyGatewayCredentialStore.reference : nil
        )
        providers.append(provider)
        return provider
    }
    public func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    /// Commits one existing provider editor draft, its intended credential and
    /// the explicit probe result as one rollback-capable operation. The caller
    /// owns the draft until this method returns; typing never enters the model.
    public func saveAndTestProviderDurably(_ draft: Provider, secret: String = "") async -> ProviderSaveResult {
        guard !providerSavesInFlight.contains(draft.id) else {
            return .failed("Für diesen Zugang läuft bereits ein Speichern-und-Prüfen-Vorgang.")
        }
        guard let existing = providers.first(where: { $0.id == draft.id }) else {
            return .failed("Der Zugang ist nicht mehr vorhanden. Schließe den Editor, aktualisiere die Ansicht und versuche es erneut.")
        }

        providerSavesInFlight.insert(draft.id)
        defer { providerSavesInFlight.remove(draft.id) }

        let suppliedSecret = draft.authentication == .none
            ? nil
            : (secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Data(secret.utf8))
        var tested = draft
        let replacementReference: String?
        if draft.authentication == .none {
            replacementReference = nil
        } else if suppliedSecret == nil {
            replacementReference = existing.credentialReference
        } else {
            replacementReference = "provider-\(draft.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        }
        tested.credentialReference = replacementReference

        if let suppliedSecret {
            guard let replacementReference else {
                return .failed("Für den neuen Zugangsschlüssel konnte keine sichere Referenz erzeugt werden.")
            }
            do {
                try service.storeCredential(suppliedSecret, reference: replacementReference)
            } catch {
                return .failed("Der neue Zugangsschlüssel konnte nicht für die Prüfung vorbereitet werden. Die bisherige Konfiguration und der bisherige Schlüssel blieben unverändert. \(error.localizedDescription)")
            }
        }

        let probe = await service.inspectProvider(tested)
        applyProbe(probe, to: &tested)
        if let modelProvider = tested.modelProvider {
            markOAuthAccountRoutingUnavailable(&tested, modelProvider: modelProvider)
        }
        let persistenceResult = await performDurableConfigurationMutation(
            failureMessage: { failure in
                "„\(existing.name)“ wurde nicht gespeichert. Die vorherige Konfiguration und der bisherige Zugangsschlüssel wurden wiederhergestellt. Prüfe den Speicherzugriff und versuche es erneut. Persistenzfehler: \(failure)"
            },
            mutation: {
                guard let index = providers.firstIndex(where: { $0.id == draft.id }) else { return }
                providers[index] = tested
                refreshProviderCredentialStatus()
            }
        )
        if case let .failed(message) = persistenceResult {
            if suppliedSecret != nil, let replacementReference {
                removeUnusedProviderCredential(reference: replacementReference)
            }
            return .failed(message)
        }

        if let previousReference = existing.credentialReference,
           previousReference != replacementReference,
           credentialCanBeDeleted(previousReference, excludingProviderID: existing.id) {
            removeUnusedProviderCredential(reference: previousReference)
        }

        guard let committed = providers.first(where: { $0.id == draft.id }) else {
            return .failed("Der gespeicherte Zugang konnte nach dem Speichern nicht mehr gefunden werden.")
        }
        switch committed.status {
        case .connected, .degraded:
            return .saved(committed)
        case .offline, .unverified:
            return .savedWithProbeFailure(committed, committed.statusDetail)
        }
    }
    /// Persists provider removal before attempting any exclusive credential cleanup.
    /// Worker routes intentionally keep their provider IDs and become unavailable.
    public func deleteProviderDurably(id: UUID) async -> ProviderDeletionResult {
        guard let provider = providers.first(where: { $0.id == id }) else {
            return .failed("Der Anbieter ist nicht mehr vorhanden. Aktualisiere die Ansicht und versuche es erneut.")
        }

        let reference = provider.credentialReference
        let persistenceResult = await performDurableConfigurationMutation(
            failureMessage: { failure in
                "„\(provider.name)“ wurde nicht gelöscht. Die vorherige Konfiguration wurde wiederhergestellt und der Zugangsschlüssel blieb unverändert. Prüfe den Speicherzugriff und versuche es erneut. Persistenzfehler: \(failure)"
            },
            mutation: {
                providers.removeAll { $0.id == id }
                providerAccessStored.remove(id)
            }
        )
        if case let .failed(message) = persistenceResult { return .failed(message) }

        guard let reference else { return .deleted }
        let referencedByLegacyCLIProxy = reference == cliProxyConfiguration.inferenceCredentialReference
            || reference == cliProxyConfiguration.managementCredentialReference
        let sharedByAnotherProvider = providers.contains { $0.credentialReference == reference }
        let ownedByCLIProxy = reference == CLIProxyGatewayCredentialStore.reference
        guard !referencedByLegacyCLIProxy, !sharedByAnotherProvider, !ownedByCLIProxy else {
            return .deleted
        }
        do {
            try service.deleteCredential(reference: reference)
            return .deleted
        } catch {
            let warning = "„\(provider.name)“ wurde gelöscht, aber der nicht mehr verwendete Zugangsschlüssel konnte nicht entfernt werden. Prüfe `~/.config/workjet/credentials/` oder versuche die Bereinigung später erneut. \(error.localizedDescription)"
            if !statusMessages.contains(warning) { statusMessages.append(warning) }
            return .deletedWithWarning(warning)
        }
    }

    public func refreshProviderCredentialStatus() {
        // This status is deliberately metadata-only. Verifying a secret must
        // happen only after an explicit user action such as “Speichern &
        // prüfen” or “Verbindung prüfen”.
        providerAccessStored = Set(providers.compactMap { provider in
            provider.credentialReference == nil ? nil : provider.id
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
            let reference = modelProvider.usesWebLogin
                ? CLIProxyGatewayCredentialStore.reference
                : (provider.credentialReference ?? Provider.credentialReference(for: provider.id))
            provider.credentialReference = reference
            if modelProvider.usesWebLogin {
                let identity = try await service.authenticateCLIProxyAccount(modelProvider, credentialReference: reference)
                provider.accountLabel = identity.label
                provider.externalCredentialID = identity.externalID
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
            assignUnboundWorkers(to: modelProvider)
            refreshProviderCredentialStatus()
            providerLoginStates[modelProvider] = .connected(modelCount: provider.modelIDs.count)
            guard await flushPersistence() else { return }
            let affectedWorkerIDs = workerIDsAffectedByAuthorization(
                providerID: provider.id,
                modelProvider: modelProvider
            )
            if !affectedWorkerIDs.isEmpty {
                await probeWorkersNow(workerIDs: affectedWorkerIDs)
            }
        } catch {
            provider.status = .offline
            provider.statusDetail = error.localizedDescription
            updateOrAppend(provider)
            providerLoginStates[modelProvider] = .failed(error.localizedDescription)
            expose(error)
        }
    }

    /// Creates a distinct account only when the login proves a distinct external
    /// identity. Repeating the same web login reuses the existing account.
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
            credentialReference: modelProvider.usesWebLogin ? CLIProxyGatewayCredentialStore.reference : nil,
            routingPriority: (existing.map(\.routingPriority).max() ?? -1) + 1
        )
        providerLoginStates[modelProvider] = .authenticating
        do {
            let reference = modelProvider.usesWebLogin
                ? CLIProxyGatewayCredentialStore.reference
                : (provider.credentialReference ?? Provider.credentialReference(for: provider.id))
            provider.credentialReference = reference
            if modelProvider.usesWebLogin {
                let identity = try await service.authenticateCLIProxyAccount(modelProvider, credentialReference: reference)
                if var existingAccount = providers.first(where: {
                    $0.modelProvider == modelProvider && $0.externalCredentialID == identity.externalID
                }) {
                    existingAccount.accountLabel = identity.label
                    existingAccount.credentialReference = reference
                    let result = await service.inspectProvider(existingAccount)
                    applyProbe(result, to: &existingAccount)
                    if !result.modelIDs.isEmpty {
                        existingAccount.modelIDs = Provider.normalizedModels(
                            existingAccount.modelIDs + result.modelIDs + modelProvider.requestedModelSuggestions
                        )
                    }
                    markOAuthAccountRoutingUnavailable(&existingAccount, modelProvider: modelProvider)
                    updateOrAppend(existingAccount)
                    assignUnboundWorkers(to: modelProvider)
                    refreshProviderCredentialStatus()
                    providerLoginStates[modelProvider] = .connected(modelCount: existingAccount.modelIDs.count)
                    await flushPersistence()
                    return existingAccount
                }
                provider.accountLabel = identity.label
                provider.externalCredentialID = identity.externalID
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
            assignUnboundWorkers(to: modelProvider)
            refreshProviderCredentialStatus()
            providerLoginStates[modelProvider] = .connected(modelCount: provider.modelIDs.count)
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

    /// A provider login is shared by default. Workers that have never had a
    /// route selected can immediately use the matching provider pool; an
    /// explicit or dangling selection is never replaced behind the user's back.
    private func assignUnboundWorkers(to modelProvider: ModelProvider) {
        for index in workers.indices where workers[index].providerRoute == nil {
            guard ModelProvider.inferred(from: workers[index].model) == modelProvider else { continue }
            workers[index].providerRoute = .pool(modelProvider)
        }
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
            let reference = CLIProxyGatewayCredentialStore.reference
            provider.credentialReference = reference
            let identity = try await service.authenticateCLIProxyAccount(modelProvider, credentialReference: reference)
            provider.accountLabel = identity.label
            provider.externalCredentialID = identity.externalID
            let result = await service.inspectProvider(provider)
            applyProbe(result, to: &provider)
            if !result.modelIDs.isEmpty { provider.modelIDs = Provider.normalizedModels(result.modelIDs + modelProvider.requestedModelSuggestions) }
            markOAuthAccountRoutingUnavailable(&provider, modelProvider: modelProvider)
            updateOrAppend(provider)
            assignUnboundWorkers(to: modelProvider)
            refreshProviderCredentialStatus()
            providerLoginStates[modelProvider] = .connected(modelCount: provider.modelIDs.count)
            guard await flushPersistence() else { return }
            let affectedWorkerIDs = workerIDsAffectedByAuthorization(
                providerID: provider.id,
                modelProvider: modelProvider
            )
            if !affectedWorkerIDs.isEmpty {
                await probeWorkersNow(workerIDs: affectedWorkerIDs)
            }
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
            // Background refreshes must never unlock or read a direct API key.
            // Local OAuth gateways use their non-Keychain gateway credential;
            // unauthenticated endpoints need no secret. Direct authenticated
            // providers are checked only from the explicit Test button.
            guard provider.credentialReference == CLIProxyGatewayCredentialStore.reference
                    || provider.authentication == .none else { continue }
            let result = await service.inspectProvider(provider)
            guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { continue }
            var current = providers[index]
            applyProbe(result, to: &current)
            if let modelProvider = current.modelProvider {
                markOAuthAccountRoutingUnavailable(&current, modelProvider: modelProvider)
            }
            if current != providers[index] {
                // Probe results are runtime observations, not user-authored
                // configuration. Publishing them must refresh the UI without
                // scheduling a configuration/prompt write on app launch.
                applyingProviderObservation = true
                providers[index] = current
                applyingProviderObservation = false
            }
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
            provider.capacity = result.capacity
        }
    }

    private func markOAuthAccountRoutingUnavailable(_ provider: inout Provider, modelProvider: ModelProvider) {
        guard modelProvider.usesWebLogin, provider.kind.isLocalGateway else { return }
        guard provider.status != .offline else { return }
        // CLIProxy owns account selection and failover. A gateway model-list
        // response cannot prove that this specific OAuth identity can answer.
        provider.status = .unverified
        provider.statusDetail = "Im Gateway registriert; der einzelne Account ist technisch nicht separat prüfbar. Nutze die Worker-Probe für den gemeinsamen Laufzeitpfad."
        if case .observed = provider.capacity {
            // A provider-specific local protocol (for example Codex app-server)
            // may prove capacity for the exact OAuth identity even though the
            // shared gateway's model-list request cannot prove account routing.
        } else {
            provider.capacity = .unavailable(reason: "Für diesen Zugang sind keine Nutzungsdaten verfügbar.")
        }
    }

    private var workerHealthIsFresh: Bool {
        guard let checkedAt = workerHealthCheckedAt else { return false }
        return Date().timeIntervalSince(checkedAt) <= 15 * 60
    }

    private func workerHealthEvidence(for provider: Provider) -> [WorkjetCLIWorkerHealth] {
        workers.compactMap { worker in
            guard case let .account(providerID) = worker.providerRoute, providerID == provider.id else { return nil }
            return workerHealth[worker.id]
        }
    }

    private func runtimePresentation(
        evidence: [WorkjetCLIWorkerHealth],
        uncheckedState: String,
        uncheckedDetail: String,
        capacity: CapacityStatus
    ) -> ProviderPresentation {
        guard workerHealthIsFresh else {
            return ProviderPresentation(
                state: workerHealthCheckedAt == nil ? uncheckedState : "Prüfung veraltet",
                detail: uncheckedDetail,
                tone: .neutral,
                capacity: capacity
            )
        }
        if let ready = evidence.first(where: { $0.status == "ready" && $0.responseTokenObserved }) {
            return ProviderPresentation(
                state: "Nutzbar · \(ready.latencyMilliseconds) ms",
                detail: "Durch eine echte Worker-Antwort über \(ready.providerRoute ?? "die konfigurierte Route") bestätigt.",
                tone: .connected,
                capacity: capacity
            )
        }
        if let failed = evidence.first {
            return ProviderPresentation(
                state: failed.status == "timeout" ? "Zeitüberschreitung" : "Probe fehlgeschlagen",
                detail: failed.message ?? "Der Workerpfad hat keine gültige Modellantwort geliefert.",
                tone: .critical,
                capacity: capacity
            )
        }
        return ProviderPresentation(state: uncheckedState, detail: uncheckedDetail, tone: .neutral, capacity: capacity)
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
        harnessRefreshTask = Task { [weak self] in
            await self?.refreshConfiguredHarnessesNow()
            self?.harnessRefreshTask = nil
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
        harnessRefreshTask?.cancel(); harnessRefreshTask = nil
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
        let retentionDays = telemetryRetentionDays
        let shouldRunMaintenance = lastTelemetryCleanupAt.map { Date().timeIntervalSince($0) >= 3_600 } ?? true
        let telemetryMaintenance = shouldRunMaintenance ? telemetryMaintenance : nil
        if telemetryMaintenance != nil { lastTelemetryCleanupAt = Date() }
        runRefreshTask = Task { [weak self] in
            let records = await Task.detached(priority: .utility) {
                telemetryMaintenance?.cleanup(retentionDays: retentionDays)
                return service.runs(workers: workers)
            }.value
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
            _ = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: providers, target: .remote)
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
            _ = try await ledger.start(RemoteHostRequest(
                operation: .start,
                launch: launch,
                ownerID: Self.remoteOwnerID(for: workerID),
                workerName: worker.name
            ))
            let supervisor = RemoteConnectionSupervisor(ledger: ledger)
            remoteSessions[workerID] = RemoteSession(worker: worker, computer: computer, ledger: ledger, supervisor: supervisor)
            let run = try RemoteWorkerRun(workerID: workerID, computerID: computer.id, snapshot: await ledger.snapshot())
            remoteRunIssues[workerID] = nil
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
            remoteRunIssues[workerID] = nil
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
                    self.clearResolvedProvisioningFailures(on: computer.id) { failure in
                        switch failure.component.kind {
                        case .host:
                            return true
                        case .managedSkill:
                            return response.capabilities.contains(failure.component.id)
                        case .harness:
                            return false
                        }
                    }
                    let listed = try await self.service.listRemoteRuns(on: computer, ownerID: nil)
                    let workersByOwner = Dictionary(uniqueKeysWithValues: self.workers
                        .filter { $0.computerID == computer.id }
                        .map { (Self.remoteOwnerID(for: $0.id), $0) })
                    let activeDescriptors = listed.runs.filter { !$0.state.isTerminal }
                    let attributed = Dictionary(grouping: activeDescriptors.compactMap { descriptor -> (String, RemoteHostRunDescriptor)? in
                        guard let ownerID = descriptor.ownerID else { return nil }
                        return (ownerID, descriptor)
                    }, by: { $0.0 })
                    var ignored = activeDescriptors.filter { $0.ownerID == nil }.count

                    for (ownerID, pairs) in attributed {
                        let descriptors = pairs.map(\.1)
                        guard let worker = workersByOwner[ownerID], descriptors.count == 1 else {
                            ignored += descriptors.count
                            continue
                        }
                        let descriptor = descriptors[0]
                        if let existing = self.remoteSessions[worker.id] {
                            let snapshot = await existing.ledger.snapshot()
                            if snapshot.runID != descriptor.runID { ignored += 1 }
                            continue
                        }
                        if let existing = self.remoteRuns[worker.id], !existing.state.isTerminal, existing.runID != descriptor.runID {
                            ignored += 1
                            continue
                        }
                        do {
                            let ledger = RemoteRunLedger(client: RemoteServiceHostClient(service: self.service, computer: computer))
                            _ = try await ledger.adopt(runID: descriptor.runID, ownerID: ownerID)
                            let supervisor = RemoteConnectionSupervisor(ledger: ledger)
                            self.remoteSessions[worker.id] = RemoteSession(worker: worker, computer: computer, ledger: ledger, supervisor: supervisor)
                            self.remoteRuns[worker.id] = try RemoteWorkerRun(workerID: worker.id, computerID: computer.id, snapshot: await ledger.snapshot())
                            self.remoteRunIssues[worker.id] = await ledger.lostThroughSequence == nil ? nil : .historyIncomplete
                        } catch {
                            ignored += 1
                        }
                    }
                    self.remoteHostErrors[computer.id] = ignored == 0
                        ? nil
                        : "Ein laufender Remote-Worker konnte nicht zugeordnet werden. Öffne den Computer und prüfe die Verbindung."
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
                    self.remoteRunIssues[workerID] = await session.ledger.lostThroughSequence == nil ? nil : .historyIncomplete
                } catch {
                    self.remoteRuns[workerID] = try? RemoteWorkerRun(
                        workerID: workerID,
                        computerID: session.computer.id,
                        snapshot: await session.ledger.snapshot(),
                        connectionError: error.localizedDescription
                    )
                    self.remoteRunIssues[workerID] = .connection
                }
            }
            self.remoteRefreshTask = nil
        }
    }

    private func localPresentation(_ run: ActiveRun) -> ActiveRunPresentation {
        ActiveRunPresentation(
            id: "local:\(run.sourceRunID)",
            origin: .local(runID: run.id),
            workerName: run.workerName,
            computerName: "Local",
            model: run.effectiveModel,
            reasoning: run.effectiveReasoning,
            speed: run.effectiveSpeed,
            providerRoute: run.effectiveProviderRoute,
            startedAt: run.startedAt,
            state: "Läuft",
            activity: Self.localActivity(run.activity),
            recoveryComputerID: nil
        )
    }

    private func remotePresentation(_ run: RemoteWorkerRun) -> ActiveRunPresentation {
        let metadata = run.metadata
        let workerName = Self.nonEmpty(metadata?.workerName) ?? "Remote-Worker · Name nicht erfasst"
        let computerName = computers.first(where: { $0.id == run.computerID })?.name ?? "—"
        let issue = remoteRunIssues[run.workerID]
        let hasConnectionIssue = run.connectionError != nil || issue != nil
        let heartbeatIsFresh = run.heartbeatAt.map { Date().timeIntervalSince($0) <= 45 } ?? false
        let state: String
        if issue == .historyIncomplete {
            state = "Aktivitätsverlauf unvollständig"
        } else if hasConnectionIssue {
            state = "Verbindung unterbrochen"
        } else {
            switch run.state {
            case .starting: state = "Startet"
            case .running where heartbeatIsFresh: state = "Läuft"
            case .running: state = "Status nicht bestätigt"
            case .unknown: state = "Status nicht bestätigt"
            case .completed: state = "Abgeschlossen"
            case .failed: state = "Fehlgeschlagen"
            case .stopped: state = "Gestoppt"
            case .error: state = "Fehler"
            }
        }
        return ActiveRunPresentation(
            id: "remote:\(run.runID)",
            origin: .remote(workerID: run.workerID),
            workerName: workerName,
            computerName: computerName,
            model: Self.nonEmpty(metadata?.model),
            reasoning: metadata?.reasoning.flatMap(ReasoningEffort.init(rawValue:)),
            speed: metadata?.speed.flatMap(RunSpeed.init(rawValue:)),
            providerRoute: Self.nonEmpty(metadata?.providerAccountLabel) ?? Self.nonEmpty(metadata?.providerRoute),
            startedAt: metadata?.startedAt.flatMap(ISO8601DateFormatter().date(from:)) ?? Self.earliestEventDate(in: run.events),
            state: state,
            activity: Self.remoteActivity(from: run.events),
            recoveryComputerID: hasConnectionIssue ? run.computerID : nil
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func earliestEventDate(in events: [RemoteHostEvent]) -> Date? {
        let formatter = ISO8601DateFormatter()
        return events.compactMap { formatter.date(from: $0.timestamp) }.min()
    }

    private static func localActivity(_ activity: String) -> String {
        ["Direkte Claude-Code-Ausführung", "Worker läuft"].contains(activity) ? "Arbeitet" : activity
    }

    private static func remoteActivity(from events: [RemoteHostEvent]) -> String {
        switch events.last?.kind.lowercased() {
        case "started", "start": return "Gestartet"
        case "stdout", "output", "heartbeat": return "Arbeitet"
        case "stderr", "warning": return "Hinweis vom Worker"
        case "completed", "final": return "Antwort erhalten"
        default: return "Aktivitätsdetails —"
        }
    }

    private func seedRemoteRunForUITestingIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WORKJET_UI_TEST_WINDOW"] == "1",
              environment["WORKJET_UI_TEST_SEED"] == "1",
              environment["WORKJET_UI_TEST_REMOTE_RUN"] == "1",
              let worker = workers.first(where: { $0.name == "Kimi · UI/UX" }),
              let computer = computers.first(where: { $0.id == worker.computerID && !$0.isLocal }) else { return }
        let startedAt = Date().addingTimeInterval(-73)
        let timestamp = ISO8601DateFormatter().string(from: startedAt)
        let snapshot = RemoteLedgerSnapshot(
            runID: "ui-test-remote-run",
            state: .running,
            cursor: 1,
            events: [RemoteHostEvent(sequence: 1, timestamp: timestamp, kind: "stdout")],
            heartbeatAt: Date(),
            lastError: "Verbindung unterbrochen",
            metadata: RemoteRunMetadata(
                workerID: worker.id,
                workerName: worker.name,
                harnessID: worker.harness.rawValue,
                model: "kimi-k3-256k",
                reasoning: ReasoningEffort.high.rawValue,
                speed: RunSpeed.fast.rawValue,
                providerRoute: "Kimi Testzugang",
                startedAt: timestamp
            )
        )
        guard let run = try? RemoteWorkerRun(workerID: worker.id, computerID: computer.id, snapshot: snapshot) else { return }
        remoteRunIssues[worker.id] = .connection
        remoteRuns[worker.id] = run
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
        return await service.bootstrapRemotePi(checking)
    }

    public func scanRemoteHostKey(for computer: Computer) async throws -> RemoteHostKeyCandidate {
        try await service.scanRemoteHostKey(computer)
    }

    public func confirmRemoteHostKey(_ candidate: RemoteHostKeyCandidate, for computer: Computer) throws {
        try service.confirmRemoteHostKey(candidate, for: computer)
    }

    public func storeCredential(_ value: String, reference: String) {
        guard !value.isEmpty else { expose(CredentialError.emptyReference); return }
        do { try service.storeCredential(Data(value.utf8), reference: reference); refreshCLIProxy() }
        catch { expose(error) }
    }

    public func dismissMessage(_ message: String) { statusMessages.removeAll { $0 == message } }

    public func refreshWorkjetActivationStatus() {
        workjetActivationStatus = .checking
        workjetActivationCheckGeneration += 1
        let generation = workjetActivationCheckGeneration
        let service = self.service
        let configuration = self.configuration
        Task { [weak self] in
            let status = await service.inspectWorkjetActivation(configuration)
            guard self?.workjetActivationCheckGeneration == generation,
                  self?.configuration == configuration else { return }
            self?.workjetActivationStatus = status
            if let promptStatus = status.promptStatus {
                self?.promptSyncStatus = promptStatus
            }
        }
    }

    public func installOrRepairWorkjetSkill() async {
        workjetActivationStatus = .checking
        workjetActivationCheckGeneration += 1
        let generation = workjetActivationCheckGeneration
        do {
            let status = try await service.installOrRepairWorkjetSkill(configuration)
            guard workjetActivationCheckGeneration == generation else { return }
            workjetActivationStatus = status
            if let promptStatus = status.promptStatus {
                self.promptSyncStatus = promptStatus
            }
        } catch {
            guard workjetActivationCheckGeneration == generation else { return }
            let detail = error.localizedDescription
            workjetActivationStatus = WorkjetActivationStatus(state: .failed, detail: detail)
            if !statusMessages.contains(detail) { statusMessages.append(detail) }
        }
    }

    @discardableResult
    public func flushPersistence() async -> Bool {
        switch await flushPersistenceOutcome() {
        case .synchronized, .nothingPending:
            return true
        case .failed:
            return false
        }
    }

    private func flushPersistenceOutcome() async -> PersistenceCoordinator.Outcome {
        guard ready else { return .failed("Workjet ist noch nicht bereit, Änderungen zu speichern.") }
        if let learningPersistenceTask {
            await learningPersistenceTask.value
            if case let .failed(message) = promptSyncStatus { return .failed(message) }
        }
        return await persistence.flush()
    }

    private func durableConfigurationSnapshot() -> DurableConfigurationSnapshot {
        DurableConfigurationSnapshot(
            workers: workers,
            computers: computers,
            providers: providers,
            providerAccessStored: providerAccessStored,
            selectedComputerID: selectedComputerID
        )
    }

    private func credentialCanBeDeleted(_ reference: String, excludingProviderID: UUID) -> Bool {
        let sharedByAnotherProvider = providers.contains {
            $0.id != excludingProviderID && $0.credentialReference == reference
        }
        let ownedByCLIProxy = reference == CLIProxyGatewayCredentialStore.reference
            || reference == cliProxyConfiguration.inferenceCredentialReference
            || reference == cliProxyConfiguration.managementCredentialReference
        return !sharedByAnotherProvider && !ownedByCLIProxy
    }

    private func removeUnusedProviderCredential(reference: String) {
        do {
            try service.deleteCredential(reference: reference)
        } catch {
            let message = "Ein nicht mehr verwendeter Zugangsschlüssel konnte nach dem Anbieter-Speichern nicht entfernt werden. Prüfe „\(reference)“ unter `~/.config/workjet/credentials/`. \(error.localizedDescription)"
            if !statusMessages.contains(message) { statusMessages.append(message) }
        }
    }

    private func performDurableConfigurationMutation(
        failureMessage: (String) -> String,
        mutation: () -> Void
    ) async -> DurableConfigurationMutationResult {
        let snapshot = durableConfigurationSnapshot()
        mutation()
        if ready { refreshRuns() }

        let outcome = await flushPersistenceOutcome()
        guard case let .failed(originalFailure) = outcome else { return .succeeded }

        workers = snapshot.workers
        computers = snapshot.computers
        providers = snapshot.providers
        providerAccessStored = snapshot.providerAccessStored
        selectedComputerID = snapshot.selectedComputerID
        if ready { refreshRuns() }
        _ = await flushPersistenceOutcome()

        let message = failureMessage(originalFailure)
        if !statusMessages.contains(message) { statusMessages.append(message) }
        return .failed(message)
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
        guard ready, !applyingProviderObservation else { return }
        promptSyncStatus = .pending
        persistence.schedule(configuration, handwrittenChanged: handwrittenRulesChanged)
    }

    private func persistLearningsIfReady() {
        guard ready, !applyingExternalLearnings else { return }
        promptSyncStatus = .pending
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
                self?.promptSyncStatus = .synchronized(Date())
                self?.refreshWorkjetActivationStatus()
            } catch {
                self?.applyPersistenceOutcome(.failed(error.localizedDescription))
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
            refreshWorkjetActivationStatus()
        case let .failed(message):
            promptSyncStatus = .failed(message)
            if !statusMessages.contains(message) { statusMessages.append(message) }
        }
    }
}
