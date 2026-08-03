import Combine
import Foundation

/// Central view model. Holds all popover state and routes side effects
/// through the `WorkjetService` seam. Everything here is UI-framework-free.
public final class WorkjetViewModel: ObservableObject {
    // MARK: - Entities
    @Published public private(set) var workers: [Worker]
    @Published public private(set) var computers: [Computer]
    @Published public var providers: [Provider]
    @Published public private(set) var activeRuns: [ActiveRun]
    @Published public var cliProxy: CLIProxyStatus

    // MARK: - Skill settings
    @Published public var skillRules: String
    @Published public var skillActivation: SkillActivation
    @Published public var injectWorkerDeclarations: Bool

    // MARK: - Telemetry settings
    @Published public var telemetryClaudeCodeEvents: Bool
    @Published public var telemetrySidecarEvents: Bool
    @Published public var telemetryRetentionDays: Int

    // MARK: - Execution infrastructure defaults (no workflow controls)
    @Published public var providerSlots: Int
    @Published public var probeTimeoutSeconds: Int
    @Published public var turnTimeoutSeconds: Int
    @Published public var degradationAllowed: Bool

    // MARK: - Selection state
    @Published public var searchQuery: String = ""
    /// nil = all computers.
    @Published public private(set) var selectedComputerID: UUID?

    private let service: WorkjetService

    public init(
        service: WorkjetService = NullWorkjetService(),
        workers: [Worker] = [],
        computers: [Computer] = [],
        providers: [Provider] = [],
        activeRuns: [ActiveRun] = [],
        cliProxy: CLIProxyStatus = CLIProxyStatus(endpoint: "", status: .offline, account: ""),
        skillRules: String = "",
        skillActivation: SkillActivation = .skillOnly,
        injectWorkerDeclarations: Bool = true,
        telemetryClaudeCodeEvents: Bool = true,
        telemetrySidecarEvents: Bool = true,
        telemetryRetentionDays: Int = 14,
        providerSlots: Int = 3,
        probeTimeoutSeconds: Int = 20,
        turnTimeoutSeconds: Int = 900,
        degradationAllowed: Bool = true
    ) {
        self.service = service
        self.workers = workers
        self.computers = computers
        self.providers = providers
        self.activeRuns = activeRuns
        self.cliProxy = cliProxy
        self.skillRules = skillRules
        self.skillActivation = skillActivation
        self.injectWorkerDeclarations = injectWorkerDeclarations
        self.telemetryClaudeCodeEvents = telemetryClaudeCodeEvents
        self.telemetrySidecarEvents = telemetrySidecarEvents
        self.telemetryRetentionDays = telemetryRetentionDays
        self.providerSlots = providerSlots
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.turnTimeoutSeconds = turnTimeoutSeconds
        self.degradationAllowed = degradationAllowed
    }

    // MARK: - Derived state

    public var visibleWorkers: [Worker] {
        WorkerFilter.filtered(workers, query: searchQuery, computerID: selectedComputerID)
    }

    public var promptPreview: String {
        SkillPrompt.compose(
            rules: skillRules,
            activation: skillActivation,
            injectWorkers: injectWorkerDeclarations,
            workers: workers
        )
    }

    public func computer(for id: UUID) -> Computer? {
        computers.first { $0.id == id }
    }

    // MARK: - Intents

    public func toggleComputerSelection(_ id: UUID) {
        selectedComputerID = selectedComputerID == id ? nil : id
    }

    public func upsertWorker(_ worker: Worker) {
        if let index = workers.firstIndex(where: { $0.id == worker.id }) {
            workers[index] = worker
        } else {
            workers.append(worker)
        }
        service.persistWorker(worker)
    }

    public func upsertComputer(_ computer: Computer) {
        if let index = computers.firstIndex(where: { $0.id == computer.id }) {
            computers[index] = computer
        } else {
            computers.append(computer)
        }
        service.persistComputer(computer)
    }

    public func addProvider(_ provider: Provider) {
        providers.append(provider)
        service.persistProvider(provider)
    }

    public func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        service.persistProvider(provider)
    }

    public func stopRun(id: UUID) {
        activeRuns.removeAll { $0.id == id }
        service.stopRun(id: id)
    }
}
