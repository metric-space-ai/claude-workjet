import Combine
import Foundation

@MainActor
public final class WorkjetViewModel: ObservableObject {
    @Published public private(set) var workers: [Worker] { didSet { persistIfReady() } }
    @Published public private(set) var computers: [Computer] { didSet { persistIfReady() } }
    @Published public private(set) var providers: [Provider] { didSet { persistIfReady() } }
    @Published public private(set) var activeRuns: [ActiveRun] = []
    @Published public private(set) var cliProxyStatus: CLIProxyStatus
    @Published public private(set) var statusMessages: [String]

    @Published public var skillRules: String { didSet { persistIfReady(handwrittenRulesChanged: true) } }
    @Published public var skillActivation: SkillActivation { didSet { persistIfReady() } }
    @Published public var injectWorkerDeclarations: Bool { didSet { persistIfReady() } }
    @Published public var telemetryClaudeCodeEvents: Bool { didSet { persistIfReady() } }
    @Published public var telemetrySidecarEvents: Bool { didSet { persistIfReady() } }
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
        cliProxyStatus = CLIProxyStatus(endpoint: value.cliProxy.endpoint, state: .offline, detail: "Status wird geprüft …", capacity: .unavailable(reason: "Status wird geprüft."))
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

    public func upsertWorker(_ worker: Worker) {
        if let index = workers.firstIndex(where: { $0.id == worker.id }) { workers[index] = worker }
        else { workers.append(worker) }
    }

    public func upsertComputer(_ computer: Computer) {
        if let index = computers.firstIndex(where: { $0.id == computer.id }) { computers[index] = computer }
        else { computers.append(computer) }
    }

    public func addProvider(_ provider: Provider) { providers.append(provider) }
    public func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }
    public func removeProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        // Worker references intentionally remain stable and render as unavailable.
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        refreshRuns()
        refreshCLIProxy()
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
        runRefreshTask = Task { [weak self] in
            let records = await Task.detached(priority: .utility) { service.runs(workers: workers) }.value
            guard !Task.isCancelled, let self else { return }
            self.activeRuns = records.compactMap { $0.state == .running ? $0.activeRun : nil }
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

    private func persistIfReady(handwrittenRulesChanged: Bool = false) {
        guard ready else { return }
        persistence.schedule(configuration, handwrittenChanged: handwrittenRulesChanged)
    }

    private func expose(_ error: Error) {
        let message = error.localizedDescription
        if !statusMessages.contains(message) { statusMessages.append(message) }
    }
}
