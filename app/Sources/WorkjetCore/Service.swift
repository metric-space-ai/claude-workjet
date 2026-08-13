import Darwin
import Foundation

public enum HarnessComputerState: String, Equatable, Sendable {
    case unknown
    case checking
    case missing
    case installed
    case broken
}

public enum HarnessComputerAction: String, Equatable, Sendable {
    case check
    case install
    case update
    case remove
    case unavailable

    public var label: String {
        switch self {
        case .check: return "Prüfen"
        case .install: return "Installieren"
        case .update: return "Aktualisieren"
        case .remove: return "Entfernen"
        case .unavailable: return "Noch nicht verfügbar"
        }
    }
}

public struct HarnessComputerStatus: Equatable, Sendable {
    public var state: HarnessComputerState
    public var detail: String
    public var version: String?
    public var action: HarnessComputerAction
    public var actions: [HarnessComputerAction]

    public init(state: HarnessComputerState, detail: String, version: String? = nil, action: HarnessComputerAction, actions: [HarnessComputerAction]? = nil) {
        self.state = state
        self.detail = detail
        self.version = version
        self.action = action
        self.actions = actions ?? (action == .unavailable ? [] : [action])
    }

    public static let unknown = HarnessComputerStatus(state: .unknown, detail: "Noch nicht geprüft.", action: .check)
}

public enum RemoteProvisioningComponentKind: String, Equatable, Sendable {
    case host
    case harness
    case managedSkill
}

public struct RemoteProvisioningComponent: Equatable, Sendable {
    public var kind: RemoteProvisioningComponentKind
    public var id: String
    public var state: RemoteHarnessLifecycleState
    public var version: String?
    public var detail: String

    public init(kind: RemoteProvisioningComponentKind, id: String, state: RemoteHarnessLifecycleState, version: String? = nil, detail: String) {
        self.kind = kind
        self.id = id
        self.state = state
        self.version = version
        self.detail = detail
    }
}

public struct RemoteProvisioningFailure: Equatable, Sendable {
    public var component: RemoteProvisioningComponent

    public init(component: RemoteProvisioningComponent) {
        self.component = component
    }

    public var userVisibleDetail: String {
        let label: String
        switch component.kind {
        case .host: label = "Remote-Host"
        case .harness: label = "Harness \(component.id)"
        case .managedSkill: label = "Skill \(component.id)"
        }
        return "\(label): \(component.detail)"
    }
}

public struct RemoteWorkerProvisioningResult: Equatable, Sendable {
    public var workerIDs: [UUID]
    public var computerID: UUID
    public var components: [RemoteProvisioningComponent]
    public var verifiedCapabilities: [String]
    public var failure: RemoteProvisioningFailure?

    public init(workerIDs: [UUID], computerID: UUID, components: [RemoteProvisioningComponent] = [], verifiedCapabilities: [String] = [], failure: RemoteProvisioningFailure? = nil) {
        self.workerIDs = workerIDs
        self.computerID = computerID
        self.components = components
        self.verifiedCapabilities = verifiedCapabilities
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil }
}

/// Provisions only server-registered components. It intentionally has no API
/// for executable paths, package URLs, argv, or download commands.
public struct RemoteWorkerProvisioningCoordinator: Sendable {
    private let remoteClient: @Sendable (Computer) -> any RemoteHostCalling

    public init(remoteClient: @escaping @Sendable (Computer) -> any RemoteHostCalling = { RemoteHostClient(computer: $0) }) {
        self.remoteClient = remoteClient
    }

    public func provision(worker: Worker, on computer: Computer) async -> RemoteWorkerProvisioningResult {
        await provision(workers: [worker], on: computer)
    }

    public func provision(workers: [Worker], on computer: Computer) async -> RemoteWorkerProvisioningResult {
        let workerIDs = workers.map(\.id)
        guard !computer.isLocal,
              computer.deploymentStatus == .installed,
              computer.installedSidecarVersion == PiSidecarRuntime.version else {
            let component = RemoteProvisioningComponent(kind: .host, id: "workjet-host", state: .unavailable, detail: "Der Computer ist nicht vollständig eingerichtet.")
            return RemoteWorkerProvisioningResult(workerIDs: workerIDs, computerID: computer.id, failure: RemoteProvisioningFailure(component: component))
        }
        guard workers.allSatisfy({ $0.computerID == computer.id }) else {
            let component = RemoteProvisioningComponent(kind: .host, id: "worker-assignment", state: .unavailable, detail: "Mindestens ein Worker ist einem anderen Computer zugeordnet.")
            return RemoteWorkerProvisioningResult(workerIDs: workerIDs, computerID: computer.id, failure: RemoteProvisioningFailure(component: component))
        }

        let client = remoteClient(computer)
        var components: [RemoteProvisioningComponent] = []
        var capabilities: [String] = []
        var currentKind: RemoteProvisioningComponentKind = .host
        var currentID = "workjet-host"
        do {
            let initialProbe = try await client.call(RemoteHostRequest(operation: .probe))
            capabilities = initialProbe.capabilities
            guard initialProbe.capabilities.contains("harness-lifecycle-v2") else {
                return failed(workerIDs: workerIDs, computerID: computer.id, components: components, capabilities: capabilities, kind: .host, id: "harness-lifecycle-v2", state: .unavailable, detail: "Aktualisiere zuerst den Workjet-Host auf diesem Computer.")
            }

            var seenHarnesses = Set<String>()
            let requiredHarnessIDs = workers.flatMap { worker -> [String] in
                var ids = [HarnessAdapterRegistry.descriptor(for: worker.harness).id]
                if WorkerSkillCatalog.effectiveSkills(for: worker).contains(where: { $0.id == WorkerSkillCatalog.webResearchID }) {
                    ids.append(HarnessAdapterRegistry.descriptor(for: .codexCLI).id)
                }
                return ids
            }
            for harnessID in requiredHarnessIDs {
                guard seenHarnesses.insert(harnessID).inserted else { continue }
                currentKind = .harness
                currentID = harnessID
                let result = try await ensureHarness(harnessID, client: client)
                let component = RemoteProvisioningComponent(kind: .harness, id: harnessID, state: result.state, version: result.version, detail: result.detail ?? defaultDetail(for: result.state))
                components.append(component)
                guard result.state == .installed else {
                    return RemoteWorkerProvisioningResult(workerIDs: workerIDs, computerID: computer.id, components: components, verifiedCapabilities: capabilities, failure: RemoteProvisioningFailure(component: component))
                }
            }

            let managedSkills = workers.flatMap(WorkerSkillCatalog.effectiveSkills(for:)).filter(\.usesManagedRemoteBinary)
            var seenSkills = Set<String>()
            let uniqueSkills = managedSkills.filter { seenSkills.insert($0.id).inserted }
            if !uniqueSkills.isEmpty && !initialProbe.capabilities.contains("managed-skill-lifecycle-v1") {
                return failed(workerIDs: workerIDs, computerID: computer.id, components: components, capabilities: capabilities, kind: .host, id: "managed-skill-lifecycle-v1", state: .unavailable, detail: "Aktualisiere zuerst den Workjet-Host, um verwaltete Skills einzurichten.")
            }
            for skill in uniqueSkills {
                currentKind = .managedSkill
                currentID = skill.id
                let result = try await ensureManagedSkill(skill.id, client: client)
                let component = RemoteProvisioningComponent(kind: .managedSkill, id: skill.id, state: result.state, version: result.version, detail: result.detail ?? defaultDetail(for: result.state))
                components.append(component)
                guard result.state == .installed else {
                    return RemoteWorkerProvisioningResult(workerIDs: workerIDs, computerID: computer.id, components: components, verifiedCapabilities: capabilities, failure: RemoteProvisioningFailure(component: component))
                }
            }

            currentKind = .host
            currentID = "final-probe"
            let finalProbe = try await client.call(RemoteHostRequest(operation: .probe))
            capabilities = finalProbe.capabilities
            for component in components where component.state == .installed {
                let capability = component.id
                guard finalProbe.capabilities.contains(capability) else {
                    return failed(workerIDs: workerIDs, computerID: computer.id, components: components, capabilities: capabilities, kind: component.kind, id: component.id, state: .broken, detail: "Die abschließende Host-Prüfung meldet diese Komponente nicht als bereit.")
                }
            }
            return RemoteWorkerProvisioningResult(workerIDs: workerIDs, computerID: computer.id, components: components, verifiedCapabilities: capabilities)
        } catch {
            let detail: String
            if case let RemoteHostProtocolError.rejected(hostDetail) = error {
                detail = hostDetail
            } else {
                detail = error.localizedDescription
            }
            return failed(workerIDs: workerIDs, computerID: computer.id, components: components, capabilities: capabilities, kind: currentKind, id: currentID, state: .broken, detail: detail)
        }
    }

    private func ensureHarness(_ harnessID: String, client: any RemoteHostCalling) async throws -> RemoteHarnessLifecycleResult {
        var result = try await harness(harnessID, action: .inspect, client: client)
        if result.state == .missing {
            result = try await harness(harnessID, action: .install, client: client)
            guard result.state == .installed else { return result }
            result = try await harness(harnessID, action: .inspect, client: client)
        }
        return result
    }

    private func ensureManagedSkill(_ skillID: String, client: any RemoteHostCalling) async throws -> RemoteManagedSkillLifecycleResult {
        var result = try await managedSkill(skillID, action: .inspect, client: client)
        if result.state == .missing || result.state == .broken {
            result = try await managedSkill(skillID, action: .install, client: client)
            guard result.state == .installed else { return result }
            result = try await managedSkill(skillID, action: .inspect, client: client)
        }
        return result
    }

    private func harness(_ id: String, action: RemoteHarnessMaintenanceAction, client: any RemoteHostCalling) async throws -> RemoteHarnessLifecycleResult {
        let response = try await client.call(RemoteHostRequest(harnessID: id, action: action))
        guard let result = response.harnessResult, result.harnessID == id, result.action == action else { throw RemoteHostProtocolError.malformedResponse }
        return result
    }

    private func managedSkill(_ id: String, action: RemoteManagedSkillMaintenanceAction, client: any RemoteHostCalling) async throws -> RemoteManagedSkillLifecycleResult {
        let response = try await client.call(RemoteHostRequest(skillID: id, action: action))
        guard let result = response.managedSkillResult, result.skillID == id, result.action == action else { throw RemoteHostProtocolError.malformedResponse }
        return result
    }

    private func failed(workerIDs: [UUID], computerID: UUID, components: [RemoteProvisioningComponent], capabilities: [String], kind: RemoteProvisioningComponentKind, id: String, state: RemoteHarnessLifecycleState, detail: String) -> RemoteWorkerProvisioningResult {
        let component = RemoteProvisioningComponent(kind: kind, id: id, state: state, detail: detail)
        return RemoteWorkerProvisioningResult(workerIDs: workerIDs, computerID: computerID, components: components + [component], verifiedCapabilities: capabilities, failure: RemoteProvisioningFailure(component: component))
    }

    private func defaultDetail(for state: RemoteHarnessLifecycleState) -> String {
        switch state {
        case .installed: return "Installiert und verifiziert."
        case .missing: return "Nicht installiert."
        case .broken: return "Installiert, aber nicht einsatzbereit."
        case .unavailable: return "Auf diesem Computer nicht automatisch verwaltbar."
        }
    }
}

public struct HarnessLifecycleCoordinator: Sendable {
    public let runner: any CommandRunning
    public let locator: any HarnessBinaryLocating
    private let remoteClient: @Sendable (Computer) -> any RemoteHostCalling

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        locator: any HarnessBinaryLocating = FileSystemHarnessBinaryLocator(),
        remoteClient: @escaping @Sendable (Computer) -> any RemoteHostCalling = { RemoteHostClient(computer: $0) }
    ) {
        self.runner = runner
        self.locator = locator
        self.remoteClient = remoteClient
    }

    public func inspect(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        guard computer.isLocal else { return await inspectRemote(harness, on: computer) }
        guard HarnessAdapterRegistry.supportsLocalExecution(harness) else {
            return HarnessComputerStatus(
                state: .broken,
                detail: "Für dieses Harness ist noch keine lokale One-Shot-Schnittstelle implementiert.",
                action: .unavailable,
                actions: []
            )
        }
        let driver = HarnessLifecycleRegistry.driver(for: harness)
        let report = await driver.doctor(locator: locator, runner: runner)
        return status(from: report, driver: driver)
    }

    public func perform(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        guard computer.isLocal else { return await performRemote(action, harness: harness, on: computer) }
        guard HarnessAdapterRegistry.supportsLocalExecution(harness) else {
            return HarnessComputerStatus(state: .broken, detail: "Dieses Harness ist lokal noch nicht ausführbar.", action: .unavailable, actions: [])
        }
        guard action != .check else { return await inspect(harness, on: computer) }
        guard action != .unavailable else {
            return HarnessComputerStatus(state: .unknown, detail: "Diese Aktion ist noch nicht verfügbar.", action: .unavailable)
        }

        let driver = HarnessLifecycleRegistry.driver(for: harness)
        let discovery = await driver.discover(locator: locator, runner: runner)
        let availability: HarnessMaintenancePlanAvailability
        switch action {
        case .install: availability = driver.installPlan(locator: locator)
        case .update: availability = driver.updatePlan(for: discovery)
        case .remove: availability = driver.removePlan(for: discovery)
        case .check, .unavailable: return await inspect(harness, on: computer)
        }
        guard case let .supported(plan) = availability,
              plan.executable.hasPrefix("/"),
              plan.executable != "/bin/sh", plan.executable != "/bin/zsh",
              !plan.arguments.contains("-c") else {
            return HarnessComputerStatus(state: state(from: discovery.status), detail: "Für diese Installation ist keine sichere Aktion verfügbar.", version: discovery.status.detectedVersion, action: .check)
        }
        do {
            let result = try await runner.run(CommandSpec(executable: plan.executable, arguments: plan.arguments, timeout: 300, stdoutLimit: 65_536, stderrLimit: 65_536))
            guard result.exitCode == 0, !result.stdoutTruncated, !result.stderrTruncated else {
                return HarnessComputerStatus(state: .broken, detail: "Die Aktion ist fehlgeschlagen. Prüfe die Installation und versuche es erneut.", action: .check)
            }
            return await inspect(harness, on: computer)
        } catch {
            return HarnessComputerStatus(state: .broken, detail: "Die Aktion konnte nicht ausgeführt werden. Prüfe die Installation und versuche es erneut.", action: .check)
        }
    }

    private func status(from report: HarnessDoctorReport, driver: any HarnessLifecycleDriving) -> HarnessComputerStatus {
        switch report.discovery.status {
        case .missing:
            let install = driver.installPlan(locator: locator)
            return HarnessComputerStatus(state: .missing, detail: "Nicht installiert.", action: isSupported(install) ? .install : .check)
        case let .broken(_, detail):
            return HarnessComputerStatus(state: .broken, detail: detail, action: .check)
        case .installed, .version, .updateUnknown:
            if driver.harness == .piSidecar {
                let version = report.discovery.status.detectedVersion
                return HarnessComputerStatus(state: .installed, detail: "Pi Code ist in Workjet enthalten. Der gewählte Computer wird separat geprüft.", version: version, action: .check)
            }
            guard case .capable = report.deployment.local else {
                return HarnessComputerStatus(state: .broken, detail: "Die benötigte Schnittstelle wurde nicht bestätigt.", version: report.discovery.status.detectedVersion, action: .check)
            }
            let update = driver.updatePlan(for: report.discovery)
            let remove = driver.removePlan(for: report.discovery)
            let action: HarnessComputerAction = isSupported(update) ? .update : (isSupported(remove) ? .remove : .check)
            let version = report.discovery.status.detectedVersion
            let actions: [HarnessComputerAction] = [
                isSupported(update) ? .update : nil,
                isSupported(remove) ? .remove : nil
            ].compactMap { $0 }
            return HarnessComputerStatus(state: .installed, detail: version.map { "Version \($0) installiert." } ?? "Installiert.", version: version, action: action, actions: actions.isEmpty ? [.check] : actions)
        }
    }

    private func inspectRemote(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        await remoteRequest(.inspect, harness: harness, on: computer)
    }

    private func performRemote(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        guard let remoteAction = remoteAction(action) else {
            return HarnessComputerStatus(state: .unknown, detail: "Diese Aktion ist nicht verfügbar.", action: .unavailable)
        }
        return await remoteRequest(remoteAction, harness: harness, on: computer)
    }

    private func remoteRequest(_ action: RemoteHarnessMaintenanceAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        let client = remoteClient(computer)
        do {
            let probe = try await client.call(RemoteHostRequest(operation: .probe))
            guard probe.capabilities.contains("harness-lifecycle-v2") else {
                return HarnessComputerStatus(state: .unknown, detail: "Aktualisiere Workjet auf diesem Computer, um Installationen zu verwalten.", action: .unavailable)
            }
            let harnessID = HarnessAdapterRegistry.descriptor(for: harness).id
            let response = try await client.call(RemoteHostRequest(harnessID: harnessID, action: action))
            guard let result = response.harnessResult,
                  result.harnessID == harnessID,
                  result.action == action else {
                return HarnessComputerStatus(state: .broken, detail: "Der Computer hat keine gültige Antwort geliefert.", action: .check)
            }
            return remoteStatus(result, harness: harness)
        } catch {
            return HarnessComputerStatus(state: .broken, detail: "Computer nicht erreichbar.", action: .check)
        }
    }

    private func remoteStatus(_ result: RemoteHarnessLifecycleResult, harness: Harness) -> HarnessComputerStatus {
        switch result.state {
        case .installed:
            if harness == .piSidecar {
                return HarnessComputerStatus(
                    state: .installed,
                    detail: result.version.map { "Auf diesem Computer eingerichtet · \($0)" } ?? "Auf diesem Computer eingerichtet.",
                    version: result.version,
                    action: .check,
                    actions: [.check]
                )
            }
            let inspectOnly = harness == .cursorAgent || harness == .grokCLI
            let actions: [HarnessComputerAction] = inspectOnly ? [.check] : [.update, .remove]
            return HarnessComputerStatus(
                state: .installed,
                detail: result.version.map { "Installiert · \($0)" } ?? "Installiert.",
                version: result.version,
                action: actions[0],
                actions: actions
            )
        case .missing:
            let inspectOnly = harness == .piSidecar || harness == .cursorAgent || harness == .grokCLI
            return HarnessComputerStatus(
                state: .missing,
                detail: harness == .piSidecar ? "Computer erneut einrichten." : "Nicht installiert.",
                action: inspectOnly ? .check : .install,
                actions: inspectOnly ? [.check] : [.install]
            )
        case .broken:
            return HarnessComputerStatus(state: .broken, detail: result.detail ?? "Installation prüfen.", version: result.version, action: .check)
        case .unavailable:
            return HarnessComputerStatus(state: .unknown, detail: result.detail ?? "Auf diesem Computer nicht verwaltbar.", version: result.version, action: .check, actions: [.check])
        }
    }

    private func remoteAction(_ action: HarnessComputerAction) -> RemoteHarnessMaintenanceAction? {
        switch action {
        case .check: return .inspect
        case .install: return .install
        case .update: return .update
        case .remove: return .remove
        case .unavailable: return nil
        }
    }

    private func isSupported(_ value: HarnessMaintenancePlanAvailability) -> Bool {
        if case .supported = value { return true }
        return false
    }

    private func state(from status: HarnessLifecycleStatus) -> HarnessComputerState {
        switch status {
        case .missing: return .missing
        case .installed, .version, .updateUnknown: return .installed
        case .broken: return .broken
        }
    }
}

public protocol WorkjetService: AnyObject, Sendable {
    func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws
    func runs(workers: [Worker]) -> [RunRecord]
    func stop(_ run: ActiveRun) throws
    func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult
    func probeConfiguredWorkers(timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth]
    func probeConfiguredWorkers(workerIDs: [UUID], timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth]
    func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount
    func discoverTailscaleDevices() async throws -> [TailscaleDevice]
    func inspectWorkjetActivation(_ configuration: WorkjetConfiguration) async -> WorkjetActivationStatus
    func installOrRepairWorkjetSkill(_ configuration: WorkjetConfiguration) async throws -> WorkjetActivationStatus
    func inspectHarness(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus
    func performHarnessAction(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus
    func provisionRemoteWorker(_ worker: Worker, on computer: Computer) async -> RemoteWorkerProvisioningResult
    func provisionRemoteWorkers(_ workers: [Worker], on computer: Computer) async -> RemoteWorkerProvisioningResult
    func scanRemoteHostKey(_ computer: Computer) async throws -> RemoteHostKeyCandidate
    func confirmRemoteHostKey(_ candidate: RemoteHostKeyCandidate, for computer: Computer) throws
    func bootstrapRemotePi(_ computer: Computer) async -> Computer
    func probeRemoteHost(_ computer: Computer) async throws -> RemoteHostResponse
    func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data) async throws -> RemoteHostResponse
    func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data, ownerID: String) async throws -> RemoteHostResponse
    func startRemoteWorker(_ worker: Worker, on computer: Computer, route: ResolvedProviderRuntimeRoute, input: Data, ownerID: String) async throws -> RemoteHostResponse
    func listRemoteRuns(on computer: Computer, ownerID: String?) async throws -> RemoteHostResponse
    func adoptRemoteRun(on computer: Computer, runID: String, ownerID: String) async throws -> RemoteHostResponse
    func remoteEvents(on computer: Computer, runID: String, after sequence: UInt64) async throws -> RemoteHostResponse
    func stopRemoteWorker(on computer: Computer, runID: String) async throws -> RemoteHostResponse
    func importRemoteWorkspaceResult(on computer: Computer, runID: String) async throws -> WorkspaceResultImportReceipt
    func markRemoteWorkspace(on computer: Computer, runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt
    func storeCredential(_ secret: Data, reference: String) throws
    func deleteCredential(reference: String) throws
    func hasCredential(reference: String) -> Bool
    func loadAdHocLearnings() throws -> String?
    func saveAdHocLearnings(_ value: String, configuration: WorkjetConfiguration) throws
}

public extension WorkjetService {
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult {
        ProviderProbeResult(status: .unverified, detail: "Dieser Dienst prüft keine Anbieter.")
    }
    func probeConfiguredWorkers(timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth] {
        throw WorkjetCLIError(code: "health_unavailable", message: "Dieser Dienst kann keine Worker prüfen.", exitCode: .unsupported)
    }
    func probeConfiguredWorkers(workerIDs: [UUID], timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth] {
        let selected = Set(workerIDs)
        return try await probeConfiguredWorkers(timeoutSeconds: timeoutSeconds).filter { selected.contains($0.workerID) }
    }
    func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount { throw CLIProxyAccountError.executableUnavailable }
    func discoverTailscaleDevices() async throws -> [TailscaleDevice] { throw TailscaleDeviceError.unavailable }
    func inspectWorkjetActivation(_ configuration: WorkjetConfiguration) async -> WorkjetActivationStatus {
        WorkjetActivationStatus(state: .failed, detail: "Dieser Dienst kann die Workjet-Installation nicht prüfen.")
    }
    func installOrRepairWorkjetSkill(_ configuration: WorkjetConfiguration) async throws -> WorkjetActivationStatus {
        throw LocalStateError.io("Dieser Dienst kann den Workjet-Loader nicht installieren.")
    }
    func inspectHarness(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus { .unknown }
    func performHarnessAction(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        HarnessComputerStatus(state: .unknown, detail: "Diese Aktion ist in der Vorschau nicht verfügbar.", action: .unavailable)
    }
    func provisionRemoteWorker(_ worker: Worker, on computer: Computer) async -> RemoteWorkerProvisioningResult {
        await provisionRemoteWorkers([worker], on: computer)
    }
    func provisionRemoteWorkers(_ workers: [Worker], on computer: Computer) async -> RemoteWorkerProvisioningResult {
        let component = RemoteProvisioningComponent(kind: .host, id: "workjet-host", state: .unavailable, detail: "Dieser Dienst kann Remote-Worker nicht einrichten.")
        return RemoteWorkerProvisioningResult(workerIDs: workers.map(\.id), computerID: computer.id, components: [component], failure: RemoteProvisioningFailure(component: component))
    }
    func scanRemoteHostKey(_ computer: Computer) async throws -> RemoteHostKeyCandidate { throw RemotePiBootstrapError.hostKeyScanFailed("Die Identität dieses Computers kann hier nicht geprüft werden.") }
    func confirmRemoteHostKey(_ candidate: RemoteHostKeyCandidate, for computer: Computer) throws { throw RemotePiBootstrapError.hostKeyScanFailed("Die Identität dieses Computers kann hier nicht bestätigt werden.") }
    func deleteCredential(reference: String) throws {}
    func hasCredential(reference: String) -> Bool { false }
    func loadAdHocLearnings() throws -> String? { nil }
    func saveAdHocLearnings(_ value: String, configuration: WorkjetConfiguration) throws {}
    func probeRemoteHost(_ computer: Computer) async throws -> RemoteHostResponse { throw RemoteHostProtocolError.computerNotInstalled }
    func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data) async throws -> RemoteHostResponse { throw RemoteHostProtocolError.computerNotInstalled }
    func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data, ownerID: String) async throws -> RemoteHostResponse {
        try await startRemoteWorker(worker, on: computer, input: input)
    }
    func startRemoteWorker(_ worker: Worker, on computer: Computer, route: ResolvedProviderRuntimeRoute, input: Data, ownerID: String) async throws -> RemoteHostResponse {
        try await startRemoteWorker(worker, on: computer, input: input, ownerID: ownerID)
    }
    func listRemoteRuns(on computer: Computer, ownerID: String? = nil) async throws -> RemoteHostResponse { throw RemoteHostProtocolError.computerNotInstalled }
    func adoptRemoteRun(on computer: Computer, runID: String, ownerID: String) async throws -> RemoteHostResponse { throw RemoteHostProtocolError.computerNotInstalled }
    func remoteEvents(on computer: Computer, runID: String, after sequence: UInt64) async throws -> RemoteHostResponse { throw RemoteHostProtocolError.computerNotInstalled }
    func stopRemoteWorker(on computer: Computer, runID: String) async throws -> RemoteHostResponse { throw RemoteHostProtocolError.computerNotInstalled }
    func importRemoteWorkspaceResult(on computer: Computer, runID: String) async throws -> WorkspaceResultImportReceipt { throw WorkspaceResultError.recordNotFound }
    func markRemoteWorkspace(on computer: Computer, runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt { throw WorkspaceResultError.recordNotFound }
    func bootstrapRemotePi(_ computer: Computer) async -> Computer {
        var value = computer
        value.deploymentStatus = .failed
        value.deploymentDetail = "Dieser Dienst unterstützt keine Remote-Pi-Einrichtung."
        return value
    }
}

/// Adapts the app service's remote methods to the cursor ledger without
/// bypassing dependency injection in ViewModel tests or previews.
public struct RemoteServiceHostClient: RemoteHostCalling, @unchecked Sendable {
    private let service: any WorkjetService
    private let computer: Computer

    public init(service: any WorkjetService, computer: Computer) {
        self.service = service
        self.computer = computer
    }

    public func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
        switch request.wireOperation {
        case "list":
            return try await service.listRemoteRuns(on: computer, ownerID: request.ownerID)
        case "adopt":
            guard let runID = request.runID, let ownerID = request.ownerID else { throw RemoteRunLedgerError.missingRunID }
            return try await service.adoptRemoteRun(on: computer, runID: runID, ownerID: ownerID)
        case .some(let operation):
            throw RemoteHostProtocolError.rejected("Unbekannte Remote-Operation: \(operation)")
        case nil:
            break
        }
        switch request.operation {
        case .probe:
            return try await service.probeRemoteHost(computer)
        case .start:
            guard let launch = request.launch else {
                throw RemoteHostProtocolError.rejected("Start-Anfrage enthält keinen Harness-Launch.")
            }
            let response = try await RemoteHostClientRequestBridge(service: service, computer: computer).start(launch, ownerID: request.ownerID)
            return response
        case .events:
            guard let runID = request.runID else { throw RemoteRunLedgerError.missingRunID }
            return try await service.remoteEvents(on: computer, runID: runID, after: request.afterSequence ?? 0)
        case .stop:
            guard let runID = request.runID else { throw RemoteRunLedgerError.missingRunID }
            return try await service.stopRemoteWorker(on: computer, runID: runID)
        case .relayLost:
            throw RemoteHostProtocolError.rejected("Tunnel-Verlust ist nur über den sicheren Remote-Host-Client verfügbar.")
        case .workspaceFinalize:
            throw RemoteHostProtocolError.rejected("Workspace-Lifecycle ist nur über den sicheren Remote-Host-Client verfügbar.")
        case .harnessInspect, .harnessInstall, .harnessUpdate, .harnessRemove:
            // Harness maintenance has its own typed RemoteHostClient path. This
            // legacy WorkjetService adapter must not pretend it can execute it.
            throw RemoteHostProtocolError.rejected("Harness-Wartung ist über diesen Service-Adapter nicht verfügbar.")
        case .managedSkillInspect, .managedSkillInstall:
            throw RemoteHostProtocolError.rejected("Skill-Wartung ist über diesen Service-Adapter nicht verfügbar.")
        }
    }
}

private struct RemoteHostClientRequestBridge: @unchecked Sendable {
    let service: any WorkjetService
    let computer: Computer

    func start(_ launch: RemoteHarnessLaunch, ownerID: String?) async throws -> RemoteHostResponse {
        // The service API historically accepted Worker + Data. Preserve that
        // public API while making the ledger's exact encoded launch testable.
        guard let input = Data(base64Encoded: launch.inputBase64) else {
            throw RemoteHarnessAdapterError.invalidInput("Remote-Launch enthält keine gültige Base64-Eingabe.")
        }
        var worker = Worker(
            name: launch.harnessID,
            harness: harness(for: launch.harnessID),
            model: launch.model,
            reasoningEffort: launch.reasoning.flatMap(ReasoningEffort.init(rawValue:)),
            computerID: computer.id,
            invocation: WorkerInvocation(
                executable: launch.harnessID,
                arguments: launch.allowedTools.map { ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", $0.joined(separator: ",")] } ?? [],
                options: launch.options
            )
        )
        worker.invocation.options = launch.options
        if let ownerID {
            return try await service.startRemoteWorker(worker, on: computer, input: input, ownerID: ownerID)
        }
        return try await service.startRemoteWorker(worker, on: computer, input: input)
    }

    private func harness(for id: String) -> Harness {
        switch id {
        case "pi-code": return .piSidecar
        case "codex-cli": return .codexCLI
        case "opencode": return .openCode
        case "cursor-agent": return .cursorAgent
        case "grok-cli": return .grokCLI
        default: return .claudeCode
        }
    }
}

public final class NullWorkjetService: WorkjetService, @unchecked Sendable {
    public init() {}
    public func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {}
    public func runs(workers: [Worker]) -> [RunRecord] { [] }
    public func stop(_ run: ActiveRun) throws {}
    public func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
        CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "Die Vorschau prüft keine Anbieterzugänge.", capacity: .unavailable(reason: "In der Vorschau nicht geprüft."))
    }
    public func bootstrapRemotePi(_ computer: Computer) async -> Computer {
        var value = computer
        value.deploymentStatus = .failed
        value.deploymentDetail = "Vorschau führt keine Remote-Befehle aus."
        return value
    }
    public func storeCredential(_ secret: Data, reference: String) throws {}
}

public final class RemoteGatewayTunnelManager: RemoteGatewayTunnelManaging, @unchecked Sendable {
    private final class DiagnosticBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ value: Data) { lock.withLock { if data.count < 65_536 { data.append(value.prefix(65_536 - data.count)) } } }
        func text() -> String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
    private struct ManagedTunnel {
        var lease: RemoteGatewayTunnelLease
        var process: Process
        var runID: String?
    }

    private let lock = NSLock()
    private let processProbe: any ProcessProbing
    private var tunnels: [UUID: ManagedTunnel] = [:]

    public init(processProbe: any ProcessProbing = SystemProcessProbe()) {
        self.processProbe = processProbe
    }

    public func open(for computer: Computer) async throws -> RemoteGatewayTunnelLease {
        let command = try RemoteGatewayTunnelCommandBuilder.command(for: computer)
        try validateKnownHosts(
            RemoteGatewayTunnelCommandBuilder.knownHostsPath(for: computer),
            containsOnlyPublicMaterial: computer.usesManagedTailscaleSSH
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let diagnostic = DiagnosticBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            diagnostic.append(data)
        }
        do { try process.run() }
        catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            throw RemoteGatewayTunnelError.startFailed("OpenSSH konnte nicht gestartet werden.")
        }

        let deadline = Date().addingTimeInterval(12)
        var remotePort: Int?
        while Date() < deadline, process.isRunning, remotePort == nil {
            let text = diagnostic.text()
            if let match = text.range(of: #"Allocated port ([0-9]{1,5}) for remote forward"#, options: [.regularExpression, .caseInsensitive]) {
                let fragment = String(text[match])
                remotePort = fragment.split(separator: " ").compactMap { Int($0) }.first
            }
            if remotePort == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        guard let remotePort, (1...65535).contains(remotePort), process.isRunning,
              let identity = processProbe.identity(for: process.processIdentifier) else {
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            throw RemoteGatewayTunnelError.allocationUnconfirmed(Self.actionableTunnelDiagnostic(diagnostic.text()))
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        let lease = RemoteGatewayTunnelLease(remotePort: remotePort, processIdentity: identity)
        lock.withLock { tunnels[lease.id] = ManagedTunnel(lease: lease, process: process, runID: nil) }
        return lease
    }

    private static func actionableTunnelDiagnostic(_ raw: String) -> String {
        let lines = raw
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let actionableFragments = [
            "permission denied", "remote port forwarding failed", "administratively prohibited",
            "host key verification failed", "connection refused", "connection timed out",
            "no route to host", "could not resolve hostname", "identity file"
        ]
        if let line = lines.reversed().first(where: { line in
            let lower = line.lowercased()
            return actionableFragments.contains(where: lower.contains)
        }) {
            let compact = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return String(compact.prefix(320))
        }
        return "OpenSSH hat die dynamische Portfreigabe nicht bestätigt."
    }

    public func bind(_ lease: RemoteGatewayTunnelLease, to runID: String) {
        lock.withLock {
            guard var managed = tunnels[lease.id], managed.lease == lease else { return }
            managed.runID = runID
            tunnels[lease.id] = managed
        }
    }

    public func close(leaseID: UUID) {
        let managed = lock.withLock { tunnels.removeValue(forKey: leaseID) }
        guard let managed,
              processProbe.identity(for: managed.lease.processIdentity.pid) == managed.lease.processIdentity else { return }
        managed.process.terminate()
    }

    public func close(runID: String) {
        let leaseID = lock.withLock { tunnels.first(where: { $0.value.runID == runID })?.key }
        if let leaseID { close(leaseID: leaseID) }
    }

    public func hasTunnel(for runID: String) -> Bool {
        lock.withLock { tunnels.values.contains(where: { $0.runID == runID }) }
    }

    public func isAlive(runID: String) -> Bool {
        guard let managed = lock.withLock({ tunnels.values.first(where: { $0.runID == runID }) }) else { return false }
        return processProbe.identity(for: managed.lease.processIdentity.pid) == managed.lease.processIdentity
    }

    deinit {
        let ids = lock.withLock { Array(tunnels.keys) }
        ids.forEach(close(leaseID:))
    }

    private func validateKnownHosts(_ path: String, containsOnlyPublicMaterial: Bool) throws {
        guard path.hasPrefix("/") else { throw RemoteGatewayTunnelError.missingKnownHosts }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (containsOnlyPublicMaterial ? (info.st_mode & 0o022) == 0 : (info.st_mode & 0o077) == 0) else {
            throw RemoteGatewayTunnelError.invalidKnownHosts
        }
    }
}

public final class LocalWorkjetService: WorkjetService, @unchecked Sendable {
    private let configurationStore: any ConfigurationStoring
    private let promptStore: any PromptSynchronizing
    private let telemetryStore: any RunTelemetryReading
    private let cliProxyInspector: CLIProxyInspector
    private let providerInspector: ProviderInspector
    private let gatewayProviderInspector: ProviderInspector
    private let codexCapacityReader: CodexAppServerCapacityReader
    private let credentialStore: any CredentialStoring
    private let tailscaleDiscovery: TailscaleDeviceDiscovery
    private let remoteBootstrap: RemotePiBootstrap
    private let cliProxyAccounts: CLIProxyAccountAuthenticator
    private let learningStore: AdHocLearningStore
    private let workjetActivationStore: WorkjetActivationStore
    private let harnessLifecycle: HarnessLifecycleCoordinator
    private let remoteProvisioning: RemoteWorkerProvisioningCoordinator
    private let gatewayTunnels: any RemoteGatewayTunnelManaging
    private let workspaceSnapshots: any WorkspaceSnapshotPreparing
    private let workspaceRuns: RemoteWorkspaceRunStore
    private let workspaceResultImporter: LocalWorkspaceResultImporter
    private let commandRunner: any CommandRunning
    private let workingDirectory: URL
    private let persistenceBlock: Error?

    public init(configurationStore: any ConfigurationStoring, promptStore: any PromptSynchronizing, telemetryStore: any RunTelemetryReading, cliProxyInspector: CLIProxyInspector, providerInspector: ProviderInspector? = nil, credentialStore: any CredentialStoring, tailscaleDiscovery: TailscaleDeviceDiscovery = TailscaleDeviceDiscovery(), remoteBootstrap: RemotePiBootstrap = RemotePiBootstrap(), cliProxyAccounts: CLIProxyAccountAuthenticator? = nil, learningStore: AdHocLearningStore? = nil, workjetActivationStore: WorkjetActivationStore? = nil, harnessLifecycle: HarnessLifecycleCoordinator = HarnessLifecycleCoordinator(), remoteProvisioning: RemoteWorkerProvisioningCoordinator = RemoteWorkerProvisioningCoordinator(), gatewayTunnels: any RemoteGatewayTunnelManaging = RemoteGatewayTunnelManager(), workspaceSnapshots: any WorkspaceSnapshotPreparing = GitWorkspaceSnapshotPreparer(), workspaceRuns: RemoteWorkspaceRunStore = RemoteWorkspaceRunStore(), workspaceResultImporter: LocalWorkspaceResultImporter = LocalWorkspaceResultImporter(), commandRunner: any CommandRunning = ProcessCommandRunner(), codexCapacityReader: CodexAppServerCapacityReader? = nil, workingDirectory: URL? = nil, persistenceBlock: Error? = nil) {
        self.configurationStore = configurationStore
        self.promptStore = promptStore
        self.telemetryStore = telemetryStore
        self.cliProxyInspector = cliProxyInspector
        self.providerInspector = providerInspector ?? ProviderInspector(credentials: credentialStore)
        self.gatewayProviderInspector = ProviderInspector(credentials: CLIProxyGatewayCredentialStore())
        self.codexCapacityReader = codexCapacityReader ?? CodexAppServerCapacityReader(runner: commandRunner)
        self.credentialStore = credentialStore
        self.tailscaleDiscovery = tailscaleDiscovery
        self.remoteBootstrap = remoteBootstrap
        self.cliProxyAccounts = cliProxyAccounts ?? CLIProxyAccountAuthenticator(credentials: credentialStore)
        self.learningStore = learningStore ?? AdHocLearningStore(fileURL: WorkjetPaths.live.learningsFile)
        self.workjetActivationStore = workjetActivationStore ?? WorkjetActivationStore(paths: .live)
        self.harnessLifecycle = harnessLifecycle
        self.remoteProvisioning = remoteProvisioning
        self.gatewayTunnels = gatewayTunnels
        self.workspaceSnapshots = workspaceSnapshots
        self.workspaceRuns = workspaceRuns
        self.workspaceResultImporter = workspaceResultImporter
        self.commandRunner = commandRunner
        self.workingDirectory = (workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        self.persistenceBlock = persistenceBlock
    }

    public func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
        if let persistenceBlock { throw persistenceBlock }
        _ = handwrittenRulesChanged // skillRules in configuration is authoritative.
        try persistConfigurationAndActivation(configuration)
    }

    public func runs(workers: [Worker]) -> [RunRecord] { telemetryStore.scan(workers: workers) }
    public func stop(_ run: ActiveRun) throws { try telemetryStore.stop(run) }
    public func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus { await cliProxyInspector.inspect(configuration) }
    public func inspectProvider(_ provider: Provider) async -> ProviderProbeResult {
        if provider.credentialReference == CLIProxyGatewayCredentialStore.reference {
            var result = await gatewayProviderInspector.inspect(provider)
            if provider.modelProvider == .openAI,
               let snapshot = await codexCapacityReader.read(),
               let accountCapacity = snapshot.capacity(matchingAccountLabel: provider.accountLabel) {
                result.capacity = accountCapacity
                let plan = snapshot.plan.map { " · \($0.capitalized)" } ?? ""
                result.detail += " Codex-Kontingent für diesen Account gemessen\(plan)."
            }
            return result
        }
        return await providerInspector.inspect(provider)
    }
    public func probeConfiguredWorkers(timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth] {
        try await probeConfiguredWorkers(workerIDs: [], timeoutSeconds: timeoutSeconds)
    }
    public func probeConfiguredWorkers(workerIDs: [UUID], timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth] {
        let executable = try workjetCLIExecutable()
        let healthDirectory = try privateHealthProbeDirectory()
        let workerArguments = workerIDs.flatMap { ["--worker", $0.uuidString] }
        let result = try await commandRunner.run(CommandSpec(
            executable: executable,
            arguments: ["health", "--probe-workers"] + workerArguments + ["--timeout", String(min(max(timeoutSeconds, 5), 600)), "--json"],
            currentDirectory: healthDirectory.path,
            timeout: TimeInterval(min(max(timeoutSeconds, 5), 600) * 8 + 30),
            stdoutLimit: 1_048_576,
            stderrLimit: 65_536
        ))
        guard !result.stdoutTruncated,
              let response = try? JSONDecoder().decode(WorkjetCLIResponse.self, from: result.standardOutput),
              response.command == "health",
              let health = response.health else {
            throw WorkjetCLIError(code: "health_response_invalid", message: "Der Worker-Healthcheck hat keine gültige Antwort geliefert.", exitCode: .state)
        }
        return health
    }

    private func privateHealthProbeDirectory() throws -> URL {
        let paths = workjetActivationStore.paths
        let state = paths.stateDirectory.standardizedFileURL
        let directory = paths.healthProbeDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == state,
              state.path.hasPrefix("/"),
              !state.path.contains("\0") else {
            throw LocalStateError.insecurePath(directory.path)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for value in [state, directory] {
            var info = stat()
            guard lstat(value.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw LocalStateError.insecurePath(value.path)
            }
            _ = chmod(value.path, 0o700)
            guard lstat(value.path, &info) == 0, (info.st_mode & 0o077) == 0 else {
                throw LocalStateError.insecurePath(value.path)
            }
        }
        return directory
    }
    public func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount {
        try await cliProxyAccounts.authenticate(provider, credentialReference: credentialReference)
    }

    private func workjetCLIExecutable() throws -> String {
        let bundleCandidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/workjet", isDirectory: false)
            .standardizedFileURL
        let installedCandidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/workjet", isDirectory: false)
            .standardizedFileURL
        for candidate in [bundleCandidate, installedCandidate] {
            var info = stat()
            if lstat(candidate.path, &info) == 0,
               (info.st_mode & S_IFMT) == S_IFREG,
               info.st_uid == geteuid(),
               access(candidate.path, X_OK) == 0 {
                return candidate.path
            }
        }
        throw WorkjetCLIError(code: "health_executable_missing", message: "Die Workjet-CLI für den Worker-Healthcheck ist nicht installiert.", exitCode: .state)
    }
    public func discoverTailscaleDevices() async throws -> [TailscaleDevice] { try await tailscaleDiscovery.discover() }
    public func inspectWorkjetActivation(_ configuration: WorkjetConfiguration) async -> WorkjetActivationStatus {
        workjetActivationStore.inspect(configuration: configuration)
    }
    public func installOrRepairWorkjetSkill(_ configuration: WorkjetConfiguration) async throws -> WorkjetActivationStatus {
        try workjetActivationStore.installOrRepair(configuration: configuration)
        return workjetActivationStore.inspect(configuration: configuration)
    }
    public func inspectHarness(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        await harnessLifecycle.inspect(harness, on: computer)
    }
    public func performHarnessAction(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
        await harnessLifecycle.perform(action, harness: harness, on: computer)
    }
    public func provisionRemoteWorker(_ worker: Worker, on computer: Computer) async -> RemoteWorkerProvisioningResult {
        await remoteProvisioning.provision(worker: worker, on: computer)
    }
    public func provisionRemoteWorkers(_ workers: [Worker], on computer: Computer) async -> RemoteWorkerProvisioningResult {
        await remoteProvisioning.provision(workers: workers, on: computer)
    }
    public func scanRemoteHostKey(_ computer: Computer) async throws -> RemoteHostKeyCandidate { try await remoteBootstrap.scanHostKey(for: computer) }
    public func confirmRemoteHostKey(_ candidate: RemoteHostKeyCandidate, for computer: Computer) throws { try remoteBootstrap.confirmHostKey(candidate, for: computer) }
    public func bootstrapRemotePi(_ computer: Computer) async -> Computer { await remoteBootstrap.deploy(computer) }
    public func probeRemoteHost(_ computer: Computer) async throws -> RemoteHostResponse {
        try await RemoteHostClient(computer: computer).probe()
    }
    public func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data) async throws -> RemoteHostResponse {
        let route = try configuredRemoteRoute(for: worker)
        let ownerID = "workjet-worker-\(worker.id.uuidString.lowercased())"
        return try await startRemoteWorker(worker, on: computer, route: route, input: input, ownerID: ownerID)
    }
    public func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data, ownerID: String) async throws -> RemoteHostResponse {
        let route = try configuredRemoteRoute(for: worker, ownerID: ownerID)
        return try await startRemoteWorker(worker, on: computer, route: route, input: input, ownerID: ownerID)
    }
    public func startRemoteWorker(_ worker: Worker, on computer: Computer, route: ResolvedProviderRuntimeRoute, input: Data, ownerID: String) async throws -> RemoteHostResponse {
        let runtimeConfiguration = try configurationStore.load()
        let technicalRules = runtimeConfiguration?.technicalRules ?? ""
        let turnTimeoutSeconds = min(max(runtimeConfiguration?.turnTimeoutSeconds ?? 3_600, 60), 10_800)
        let snapshot: WorkspaceSnapshot?
        let healthProbe = worker.invocation.options["workjet.health-probe"] == "v1"
        if worker.harness == .piSidecar || healthProbe {
            snapshot = nil // Pi keeps its explicit in-memory turn request contract.
        } else {
            guard [.claudeCode, .codexCLI, .openCode].contains(worker.harness) else {
                throw RemoteHarnessAdapterError.unsupportedHarness(worker.harness.rawValue)
            }
            snapshot = try await workspaceSnapshots.prepare(from: workingDirectory)
        }

        var execution = try remoteProviderExecution(route)
        var tunnel: RemoteGatewayTunnelLease?
        if RemoteProviderRoutePolicy.requiresGatewayRelay(route) {
            let lease = try await gatewayTunnels.open(for: computer)
            tunnel = lease
            execution = try relayedExecution(execution, through: lease)
        }
        let client = RemoteHostClient(computer: computer)
        do {
            let probe = try await client.probe()
            guard probe.capabilities.contains("provider-execution-v1") else {
                throw RemoteHostProtocolError.missingCapability("provider-execution-v1")
            }
            if healthProbe, !probe.capabilities.contains("health-probe-v1") {
                throw RemoteHostProtocolError.missingCapability("health-probe-v1")
            }
            if !healthProbe, !probe.capabilities.contains("turn-timeout-v1") {
                throw RemoteHostProtocolError.missingCapability("turn-timeout-v1")
            }
            if tunnel != nil, !probe.capabilities.contains("gateway-relay-v1") {
                throw RemoteHostProtocolError.missingCapability("gateway-relay-v1")
            }
            if !healthProbe,
               WorkerSkillCatalog.effectiveSkills(for: worker).contains(where: { $0.id == WorkerSkillCatalog.greppyID }),
               !WorkerSkillCatalog.availableSkillIDs(verifiedCapabilities: probe.capabilities).contains(WorkerSkillCatalog.greppyID) {
                throw RemoteHostProtocolError.missingCapability(WorkerSkillCatalog.greppyCapability)
            }
            if !healthProbe,
               WorkerSkillCatalog.effectiveSkills(for: worker).contains(where: { $0.id == WorkerSkillCatalog.webResearchID }) {
                guard probe.capabilities.contains(WorkerSkillCatalog.webResearchCapability) else {
                    throw RemoteHostProtocolError.missingCapability(WorkerSkillCatalog.webResearchCapability)
                }
                guard route.candidates.allSatisfy({ $0.kind == .gatewayPool }) else {
                    throw RemoteHostProtocolError.rejected("Web Research benötigt auf Remote-Computern eine Workjet-Gateway-Route mit OpenAI-Zugang.")
                }
            }
            var workspace: RemoteWorkspaceDescriptor?
            var systemPrompt: String?
            if let snapshot {
                guard probe.capabilities.contains("workspace-git-v1") else {
                    throw RemoteHostProtocolError.missingCapability("workspace-git-v1")
                }
                workspace = try await client.importWorkspace(snapshot, verifiedCapabilities: probe.capabilities)
                // Skill instructions become a real harness system-prompt
                // appendix only after this exact snapshot exists and the target
                // reported the pinned skill binary. The user brief stays exact.
                systemPrompt = Self.preparedRemoteSystemPrompt(
                    worker: worker,
                    workspaceImported: true,
                    verifiedCapabilities: probe.capabilities,
                    technicalRules: technicalRules
                )
            }
            let response = try await client.start(
                worker: worker,
                input: input,
                systemPrompt: systemPrompt,
                providerExecution: execution,
                ownerID: ownerID,
                workerName: worker.name,
                workspace: workspace,
                turnTimeoutSeconds: turnTimeoutSeconds,
                verifiedCapabilities: probe.capabilities
            )
            guard let runID = response.runID else { throw RemoteHostProtocolError.malformedResponse }
            if let snapshot {
                do {
                    guard let sourceRoot = snapshot.sourceRepositoryRoot else { throw WorkspaceResultError.repositoryUnsafe }
                    // The remote run already exists at this point. If this durable,
                    // local-only mapping fails, stop and abandon its workspace
                    // before propagating the original persistence failure.
                    _ = try await workspaceRuns.create(runID: runID, sourceRepositoryRoot: sourceRoot, computerID: computer.id, ownerID: ownerID, manifest: snapshot.manifest)
                } catch {
                    await Self.cleanupRemoteWorkspaceAfterPersistenceFailure(client: client, runID: runID, ownerID: ownerID)
                    throw error
                }
            }
            if let tunnel { gatewayTunnels.bind(tunnel, to: runID) }
            return response
        } catch {
            if let tunnel { gatewayTunnels.close(leaseID: tunnel.id) }
            throw error
        }
    }

    static func preparedRemoteSystemPrompt(
        worker: Worker,
        workspaceImported: Bool,
        verifiedCapabilities: [String],
        technicalRules: String
    ) -> String? {
        guard worker.invocation.options["workjet.health-probe"] != "v1" else { return nil }
        return WorkerSkillCatalog.systemPrompt(
            for: worker,
            repositoryAvailable: workspaceImported,
            availableSkillIDs: WorkerSkillCatalog.availableSkillIDs(verifiedCapabilities: verifiedCapabilities),
            technicalRules: technicalRules
        )
    }

    static func cleanupRemoteWorkspaceAfterPersistenceFailure(client: any RemoteHostCalling, runID: String, ownerID: String) async {
        _ = try? await client.call(RemoteHostRequest(operation: .stop, runID: runID))
        _ = try? await client.call(RemoteHostRequest(operation: .workspaceFinalize, runID: runID, ownerID: ownerID, workspaceDisposition: .abandoned))
    }
    public func listRemoteRuns(on computer: Computer, ownerID: String? = nil) async throws -> RemoteHostResponse {
        let client = RemoteHostClient(computer: computer)
        let response = try await client.list(ownerID: ownerID)
        for descriptor in response.runs {
            if descriptor.state.isTerminal {
                gatewayTunnels.close(runID: descriptor.runID)
            }
        }
        // Listing is observational. Another Workjet CLI process may own the
        // run-scoped tunnel, so absence from this process's in-memory manager
        // is never evidence that the remote run lost its relay.
        return response
    }
    public func adoptRemoteRun(on computer: Computer, runID: String, ownerID: String) async throws -> RemoteHostResponse {
        // Tunnel ownership is process-local. The menu-bar app, a later CLI
        // invocation, and the detached CLI supervisor can all observe the same
        // run, but only one of them owns its SSH Process object. Absence from
        // this instance is therefore never evidence of relay loss and must not
        // be allowed to kill a healthy run owned by another Workjet process.
        try await RemoteHostClient(computer: computer).adopt(runID: runID, ownerID: ownerID)
    }
    public func remoteEvents(on computer: Computer, runID: String, after sequence: UInt64) async throws -> RemoteHostResponse {
        let client = RemoteHostClient(computer: computer)
        let tunnelKnown = gatewayTunnels.hasTunnel(for: runID)
        if tunnelKnown, !gatewayTunnels.isAlive(runID: runID) {
            let response = try await client.relayLost(runID: runID)
            gatewayTunnels.close(runID: runID)
            return response
        }
        let response = try await client.events(runID: runID, after: sequence)
        if response.state.isTerminal { gatewayTunnels.close(runID: runID) }
        return response
    }
    public func stopRemoteWorker(on computer: Computer, runID: String) async throws -> RemoteHostResponse {
        let response = try await RemoteHostClient(computer: computer).stop(runID: runID)
        if response.state.isTerminal { gatewayTunnels.close(runID: runID) }
        return response
    }

    public func importRemoteWorkspaceResult(on computer: Computer, runID: String) async throws -> WorkspaceResultImportReceipt {
        var record = try workspaceRuns.load(runID: runID)
        guard record.computerID == computer.id else { throw WorkspaceResultError.identityMismatch }
        if record.lifecycle == .integrated || record.lifecycle == .abandoned { throw WorkspaceResultError.dispositionConflict }
        let client = RemoteHostClient(computer: computer)
        let probe = try await client.probe()
        guard probe.capabilities.contains("workspace-result-v1") else { throw RemoteHostProtocolError.missingCapability("workspace-result-v1") }
        let request = RemoteWorkspaceResultRequest(runID: runID, ownerID: record.ownerID, repoID: record.repoID, snapshotCommitOID: record.snapshotCommitOID)
        let result = try await client.exportWorkspaceResult(request, verifiedCapabilities: probe.capabilities)
        let receipt = try await workspaceResultImporter.importResult(result, for: record, temporaryRoot: workspaceRuns.paths.remoteWorkspaceImportsDirectory)
        record.lifecycle = .imported
        record.resultCommitOID = receipt.resultCommitOID
        record.resultRef = receipt.resultRef
        record.terminalState = receipt.terminalState
        try workspaceRuns.save(record)
        return receipt
    }

    public func markRemoteWorkspace(on computer: Computer, runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt {
        var record = try workspaceRuns.load(runID: runID)
        guard record.computerID == computer.id else { throw WorkspaceResultError.identityMismatch }
        let targetLifecycle: RemoteWorkspaceLifecycle = disposition == .integrated ? .integrated : .abandoned
        if record.lifecycle == .integrated || record.lifecycle == .abandoned {
            guard record.lifecycle == targetLifecycle, let terminal = record.terminalState else { throw WorkspaceResultError.dispositionConflict }
            return WorkspaceLifecycleReceipt(runID: runID, lifecycle: targetLifecycle, resultRef: record.resultRef, resultCommitOID: record.resultCommitOID, terminalState: terminal)
        }
        if disposition == .integrated {
            guard record.lifecycle == .imported, record.resultRef == "refs/workjet/\(runID)", record.resultCommitOID != nil else {
                throw WorkspaceResultError.integratedBeforeImport
            }
        }
        let response = try await RemoteHostClient(computer: computer).finalizeWorkspace(runID: runID, ownerID: record.ownerID, disposition: disposition)
        guard response.state.isTerminal, response.workspaceDisposition == disposition else { throw WorkspaceResultError.runNotTerminal }
        record.lifecycle = targetLifecycle
        record.terminalState = response.state
        do { try workspaceRuns.save(record) }
        catch { throw WorkspaceResultError.localPersistenceAfterRemoteCleanup }
        return WorkspaceLifecycleReceipt(runID: runID, lifecycle: targetLifecycle, resultRef: record.resultRef, resultCommitOID: record.resultCommitOID, terminalState: response.state)
    }

    public func storeCredential(_ secret: Data, reference: String) throws { try credentialStore.write(secret, reference: reference) }
    public func deleteCredential(reference: String) throws {
        guard reference != CLIProxyGatewayCredentialStore.reference else { return }
        try credentialStore.delete(reference: reference)
    }
    public func hasCredential(reference: String) -> Bool {
        if reference == CLIProxyGatewayCredentialStore.reference {
            return (try? CLIProxyGatewayCredentialStore().read(reference: reference)) != nil
        }
        return (try? credentialStore.read(reference: reference)) != nil
    }
    public func loadAdHocLearnings() throws -> String? { try learningStore.load() }
    public func saveAdHocLearnings(_ value: String, configuration: WorkjetConfiguration) throws {
        let previousLearning = try snapshotFile(at: learningStore.fileURL, maximumBytes: 1_048_576)
        do {
            try learningStore.replace(with: value)
            try persistConfigurationAndActivation(configuration)
        } catch {
            do { try restoreFile(previousLearning, at: learningStore.fileURL) }
            catch { throw LocalStateError.io("Workjet konnte fehlgeschlagene Learnings nicht vollständig zurückrollen.") }
            throw error
        }
    }

    private func persistConfigurationAndActivation(_ configuration: WorkjetConfiguration) throws {
        let previousConfiguration = try configurationStore.snapshot()
        do {
            try workjetActivationStore.installOrRepair(configuration: configuration) {
                try configurationStore.save(configuration)
            }
        } catch {
            do { try configurationStore.restore(previousConfiguration) }
            catch { throw LocalStateError.io("Workjet konnte eine fehlgeschlagene Speicherung nicht vollständig zurückrollen.") }
            throw error
        }
    }

    private struct FileSnapshot {
        var existed: Bool
        var data: Data?
    }

    private func snapshotFile(at url: URL, maximumBytes: Int) throws -> FileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return FileSnapshot(existed: false, data: nil) }
        return FileSnapshot(existed: true, data: try SecureFile.readRegularOwnedFile(at: url, maximumBytes: maximumBytes))
    }

    private func restoreFile(_ snapshot: FileSnapshot, at url: URL) throws {
        if let data = snapshot.data {
            try AtomicFile.write(data, to: url, directoryMode: 0o700, fileMode: 0o600)
        } else if !snapshot.existed, FileManager.default.fileExists(atPath: url.path) {
            try SecureFile.checkRegularOwnedFile(at: url)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func configuredRemoteRoute(for worker: Worker, ownerID: String? = nil) throws -> ResolvedProviderRuntimeRoute {
        guard let configuration = try configurationStore.load() else { throw ProviderRuntimeRouteError.routeMissing }
        var configuredWorker = worker
        if configuredWorker.providerRoute == nil,
           let ownerID,
           ownerID.hasPrefix("workjet-worker-"),
           let workerID = UUID(uuidString: String(ownerID.dropFirst("workjet-worker-".count))),
           let persisted = configuration.workers.first(where: { $0.id == workerID }) {
            configuredWorker = persisted
        }
        return try ProviderRuntimeRouteResolver.resolve(worker: configuredWorker, providers: configuration.providers, target: .remote)
    }

    private func remoteProviderExecution(_ route: ResolvedProviderRuntimeRoute) throws -> RemoteProviderExecution {
        try RemoteProviderRoutePolicy.validate(route)
        let candidates = try route.candidates.map { candidate -> RemoteProviderExecutionCandidate in
            let secret: String?
            if candidate.authentication == .none {
                secret = nil
            } else {
                guard let reference = candidate.credentialReference else {
                    throw ProviderRuntimeRouteError.credentialMissing(candidate.displayName)
                }
                let store: any CredentialStoring = reference == CLIProxyGatewayCredentialStore.reference
                    ? CLIProxyGatewayCredentialStore()
                    : credentialStore
                guard let data = try store.read(reference: reference), data.count <= 65_536,
                      let value = String(data: data, encoding: .utf8),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProviderRuntimeRouteError.credentialMissing(candidate.displayName)
                }
                secret = value
            }
            return RemoteProviderExecutionCandidate(
                kind: candidate.kind,
                providerID: candidate.providerID,
                modelProvider: candidate.modelProvider,
                displayName: candidate.displayName,
                endpoint: candidate.endpoint,
                authentication: candidate.authentication,
                secret: secret
            )
        }
        return RemoteProviderExecution(displayName: route.displayName, candidates: candidates)
    }

    private func relayedExecution(_ execution: RemoteProviderExecution, through lease: RemoteGatewayTunnelLease) throws -> RemoteProviderExecution {
        var value = execution
        for index in value.candidates.indices where value.candidates[index].kind == .gatewayPool {
            guard var endpoint = URLComponents(string: value.candidates[index].endpoint) else {
                throw ProviderRuntimeRouteError.endpointInvalid(value.candidates[index].displayName)
            }
            endpoint.scheme = "http"
            endpoint.host = "127.0.0.1"
            endpoint.port = lease.remotePort
            guard let rewritten = endpoint.url?.absoluteString else {
                throw ProviderRuntimeRouteError.endpointInvalid(value.candidates[index].displayName)
            }
            value.candidates[index].endpoint = rewritten
            value.candidates[index].relay = RemoteGatewayRelay(id: lease.id, remotePort: lease.remotePort)
        }
        return value
    }
}

public struct WorkjetBootstrap {
    public var configuration: WorkjetConfiguration
    public var service: any WorkjetService
    public var messages: [String]

    public static func live(
        paths: WorkjetPaths = .live,
        harnessLifecycle: HarnessLifecycleCoordinator = HarnessLifecycleCoordinator(),
        remoteProvisioning: RemoteWorkerProvisioningCoordinator = RemoteWorkerProvisioningCoordinator(),
        workingDirectory: URL? = nil
    ) -> WorkjetBootstrap {
        let configStore = JSONConfigurationStore(fileURL: paths.configurationFile)
        let promptStore = ManagedPromptStore(fileURL: paths.promptFile)
        let learningStore = AdHocLearningStore(fileURL: paths.learningsFile)
        let credentials = PrivateFileCredentialStore(homeDirectory: paths.homeDirectory)
        var messages: [String] = []
        var block: Error?
        var configuration: WorkjetConfiguration
        var isFirstLaunch = false
        var configurationWasMigrated = false
        var configurationSnapshotBeforeLoad: ConfigurationStoreSnapshot?
        do {
            configurationSnapshotBeforeLoad = try configStore.snapshot()
            if let loaded = try configStore.load() {
                configuration = normalized(loaded)
                configurationWasMigrated = configurationSnapshotBeforeLoad != (try configStore.snapshot())
            } else {
                configuration = WorkjetDefaults.configuration()
                isFirstLaunch = true
            }
        } catch {
            configuration = WorkjetDefaults.configuration()
            block = error
            messages.append(error.localizedDescription)
        }
        let configurationBeforeIdentityImport = configuration
        configuration = bindingCLIProxyAccountIdentities(configuration, homeDirectory: paths.homeDirectory)
        let importedExternalIdentityChanged = configuration != configurationBeforeIdentityImport
        if let persistedLearnings = try? learningStore.load() {
            configuration.adHocLearnings = persistedLearnings
        }
        var handwrittenChanged = false
        do {
            if let handwritten = try promptStore.loadHandwrittenRules(), !handwritten.isEmpty {
                configuration.skillRules = handwritten
                let normalized = normalized(configuration)
                handwrittenChanged = normalized.skillRules != handwritten
                configuration = normalized
            }
        } catch { messages.append(error.localizedDescription) }
        let service = LocalWorkjetService(configurationStore: configStore, promptStore: promptStore, telemetryStore: RunTelemetryStore(paths: paths), cliProxyInspector: CLIProxyInspector(credentials: credentials), credentialStore: credentials, learningStore: learningStore, workjetActivationStore: WorkjetActivationStore(paths: paths), harnessLifecycle: harnessLifecycle, remoteProvisioning: remoteProvisioning, workspaceRuns: RemoteWorkspaceRunStore(paths: paths), workingDirectory: workingDirectory, persistenceBlock: block)
        let bootstrapMustPersist = isFirstLaunch
            || configurationWasMigrated
            || importedExternalIdentityChanged
            || handwrittenChanged
        if block == nil, bootstrapMustPersist {
            do { try service.save(configuration, handwrittenRulesChanged: handwrittenChanged) }
            catch {
                var reportedError = error
                if configurationWasMigrated, let configurationSnapshotBeforeLoad {
                    do { try configStore.restore(configurationSnapshotBeforeLoad) }
                    catch { reportedError = LocalStateError.migrationFailed }
                }
                messages.append(reportedError.localizedDescription)
            }
        }
        return WorkjetBootstrap(configuration: configuration, service: service, messages: messages)
    }

    public static func normalized(_ configuration: WorkjetConfiguration) -> WorkjetConfiguration {
        var value = configuration
        var prompts = value.modelPrompts ?? [:]
        if let migration = LegacyPromptMigration.split(value.skillRules) {
            value.skillRules = migration.generalRules
            prompts.merge(migration.modelPrompts) { _, migrated in migrated }
        }
        // Grok 4.6 replaces the exact former Workjet model ID. Preserve a
        // customized model prompt while moving it to the new key, and do not
        // touch other owner-defined Grok variants.
        if let previousPrompt = prompts.removeValue(forKey: "grok-4.5"),
           prompts["grok-4.6"] == nil {
            prompts["grok-4.6"] = previousPrompt
        }
        for index in value.workers.indices where value.workers[index].model == "grok-4.5" {
            value.workers[index].model = "grok-4.6"
            if value.workers[index].name == "Prototype A · Grok 4.5" {
                value.workers[index].name = "Prototype A · Grok 4.6"
            }
        }
        value.skillRules = LegacyPromptMigration.correctingKnownSkillDefaults(in: value.skillRules)
        value.skillRules = LegacyPromptMigration.removingKnownProgressBoardDefault(from: value.skillRules)
        for worker in value.workers {
            let name = ModelPromptCatalog.canonicalName(for: worker.model)
            if prompts[name] == nil, let defaultPrompt = ModelPromptCatalog.defaults[name] {
                prompts[name] = defaultPrompt
            }
        }
        let knownBrokenTerraPrompt = "Terra performs online research only. Permit WebSearch and WebFetch, forbid repository, file, shell, and code work, require current primary sources with direct links, and require facts, inference, conflicts, and unknowns to be separated."
        let previousTerraPrompt = "Use Terra only for current online research through its verified Codex native live-web-search harness. Require primary sources, direct links, careful separation of confirmed and uncertain evidence, no subagents, and no repository editing or shell/code work."
        if let terraPrompt = prompts["gpt-5.6-terra"],
           [knownBrokenTerraPrompt, previousTerraPrompt].contains(terraPrompt),
           let corrected = ModelPromptCatalog.defaults["gpt-5.6-terra"] {
            prompts["gpt-5.6-terra"] = corrected
        }
        value.modelPrompts = prompts
        if value.progressBoardRules == nil { value.progressBoardRules = WorkjetDefaults.progressBoardRules }
        if value.adHocLearnings == nil { value.adHocLearnings = "" }
        if value.skillLoaderInstructions == nil {
            value.skillLoaderInstructions = WorkjetDefaults.skillLoaderInstructions
        }
        let defaultTechnicalRules = WorkjetDefaults.configuration().technicalRules ?? ""
        let editableTechnicalRules = value.technicalRules.map {
            LegacyPromptMigration.correctingKnownTechnicalDefaults(in: $0)
        } ?? defaultTechnicalRules
        value.technicalRules = LegacyPromptMigration.synchronizingManagedTechnicalBlocks(
            in: editableTechnicalRules,
            defaults: defaultTechnicalRules
        )
        value.transparentWorkerPromptsMigrated = true
        value.workers = LegacyPromptMigration.removingKnownLegacyStandardCodingTask(from: value.workers)
        // WorkerEditor versions before this contract persisted a Claude Code
        // one-shot that could never grant tools in headless mode. Migrate only
        // that exact generated default; never rewrite owner-custom invocations.
        for index in value.workers.indices where value.workers[index].harness == .claudeCode {
            if value.workers[index].invocation.arguments == ["-p", "<WORKJET_BRIEF>"] {
                value.workers[index].invocation.arguments = [
                    "--bare", "-p", "<WORKJET_BRIEF>",
                    "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"
                ]
            }
        }
        // The old Terra default merely granted Claude-Code tool names that are
        // absent from bare third-party-provider sessions. Migrate only that
        // exact generated worker contract to Codex's empirically verified
        // native web-search path; owner-defined research workers stay intact.
        if let terraDefault = WorkjetDefaults.configuration().workers.first(where: { $0.name == "Web Research · Terra" }) {
            for index in value.workers.indices {
                let worker = value.workers[index]
                let legacyArguments = ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "WebSearch,WebFetch"]
                if worker.name == "Web Research · Terra",
                   worker.model == "gpt-5.6-terra",
                   worker.harness == .claudeCode,
                   worker.invocation.arguments == legacyArguments {
                    value.workers[index].harness = terraDefault.harness
                    value.workers[index].instructions = terraDefault.instructions
                    value.workers[index].invocation = terraDefault.invocation
                    value.workers[index].skillOverrides[WorkerSkillCatalog.greppyID] = false
                    value.workers[index].skillOverrides[WorkerSkillCatalog.webResearchID] = true
                } else if worker.name == "Web Research · Terra",
                          worker.model == "gpt-5.6-terra",
                          worker.harness == terraDefault.harness,
                          worker.invocation == terraDefault.invocation,
                          worker.skillOverrides[WorkerSkillCatalog.webResearchID] == nil {
                    value.workers[index].skillOverrides[WorkerSkillCatalog.webResearchID] = true
                }
            }
        }
        // Workjet is a global Claude prompt extension. The persisted enum is
        // retained for version-1 decoding, but opt-in /workjet configurations
        // are migrated to the globally installed include.
        value.skillActivation = .global
        value.injectWorkerDeclarations = true
        value.providerSlots = min(max(value.providerSlots, 1), 3)
        value.probeTimeoutSeconds = min(max(value.probeTimeoutSeconds, 5), 600)
        value.turnTimeoutSeconds = min(max(value.turnTimeoutSeconds, 60), 10_800)
        let legacyCLIProxy = value.cliProxy
        let hasLegacyCLIProxy = legacyCLIProxy.inferenceCredentialReference != nil
            || legacyCLIProxy.managementCredentialReference != nil
            || legacyCLIProxy.endpoint != CLIProxyConfiguration().endpoint
        if hasLegacyCLIProxy, !value.providers.contains(where: { $0.kind == .cliProxyAPI }) {
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000c1a0")!
            value.providers.append(Provider(
                id: id,
                name: "Lokaler Zugangsdienst",
                kind: .cliProxyAPI,
                endpoint: legacyCLIProxy.endpoint,
                credentialReference: legacyCLIProxy.inferenceCredentialReference
            ))
        }
        if hasLegacyCLIProxy { value.cliProxy = CLIProxyConfiguration() }
        for index in value.providers.indices {
            if value.providers[index].modelProvider?.usesWebLogin == true,
               value.providers[index].kind.isLocalGateway {
                value.providers[index].credentialReference = CLIProxyGatewayCredentialStore.reference
            }
        }
        let local: Computer
        if let existing = value.computers.first(where: \.isLocal) { local = existing }
        else { local = WorkjetDefaults.localComputer; value.computers.insert(local, at: 0) }
        if !value.computers.contains(where: { $0.id == value.selectedComputerID }) { value.selectedComputerID = local.id }
        for index in value.computers.indices {
            value.computers[index].pinnedSidecarVersion = PiSidecarRuntime.version
            if !value.computers[index].isLocal,
               value.computers[index].sandboxEnabled,
               value.computers[index].deploymentStatus == .installed,
               value.computers[index].bubblewrapExecutablePath?.hasPrefix("/") != true {
                value.computers[index].deploymentStatus = .notConfigured
                value.computers[index].deploymentDetail = "Die Minimal-Sandbox ist noch nicht einsatzbereit. Prüfe und richte den Computer erneut ein."
                value.computers[index].installedContentHash = nil
                value.computers[index].installedSidecarVersion = nil
            }
        }
        value = collapsingDuplicateCLIProxyIdentities(value)
        migrateLegacySharedOAuthStatus(&value)
        migrateOAuthAccountRoutesToPools(&value)
        return value
    }

    private static func migrateLegacySharedOAuthStatus(_ configuration: inout WorkjetConfiguration) {
        for index in configuration.providers.indices {
            guard configuration.providers[index].kind.isLocalGateway,
                  configuration.providers[index].modelProvider?.usesWebLogin == true,
                  configuration.providers[index].status != .offline else { continue }
            // Persisted "connected" values from older builds were only a
            // successful gateway metadata request, never proof for this OAuth
            // identity. Normalize the fact on every load so prompts and UI do
            // not resurrect that false claim.
            configuration.providers[index].status = .unverified
            configuration.providers[index].statusDetail = "Im Gateway registriert; der einzelne Account ist technisch nicht separat prüfbar. Nutze die Worker-Probe für den gemeinsamen Laufzeitpfad."
            configuration.providers[index].capacity = .unavailable(reason: "Für diesen Zugang sind keine Nutzungsdaten verfügbar.")
        }
    }

    /// CLIProxy exposes a provider gateway, not a pin to one OAuth record.
    /// Preserve direct API account routes, but make gateway routing truthful.
    private static func migrateOAuthAccountRoutesToPools(_ configuration: inout WorkjetConfiguration) {
        for index in configuration.workers.indices {
            guard let providerID = configuration.workers[index].providerID,
                  let account = configuration.providers.first(where: { $0.id == providerID }),
                  account.kind.isLocalGateway,
                  let modelProvider = account.modelProvider,
                  modelProvider.usesWebLogin else { continue }
            configuration.workers[index].providerRoute = .pool(modelProvider)
        }
    }

    /// A CLIProxy auth record represents one reusable provider account. Older
    /// builds could append the same web login more than once; retain the first
    /// account in deterministic routing order and redirect all worker routes.
    private static func collapsingDuplicateCLIProxyIdentities(
        _ configuration: WorkjetConfiguration
    ) -> WorkjetConfiguration {
        var value = configuration
        var canonicalByIdentity: [String: UUID] = [:]
        var canonicalIndexByID: [UUID: Int] = [:]
        var replacementIDs: [UUID: UUID] = [:]
        var retained: [Provider] = []

        let ordered = value.providers.sorted {
            if $0.routingPriority != $1.routingPriority { return $0.routingPriority < $1.routingPriority }
            let names = $0.name.localizedCaseInsensitiveCompare($1.name)
            if names != .orderedSame { return names == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        for provider in ordered {
            guard let modelProvider = provider.modelProvider, modelProvider.usesWebLogin,
                  let externalID = provider.externalCredentialID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !externalID.isEmpty else {
                canonicalIndexByID[provider.id] = retained.count
                retained.append(provider)
                continue
            }
            let key = "\(modelProvider.rawValue)\u{0}\(externalID)"
            guard let canonicalID = canonicalByIdentity[key],
                  let canonicalIndex = canonicalIndexByID[canonicalID] else {
                canonicalByIdentity[key] = provider.id
                canonicalIndexByID[provider.id] = retained.count
                retained.append(provider)
                continue
            }

            replacementIDs[provider.id] = canonicalID
            var canonical = retained[canonicalIndex]
            canonical.modelIDs = Provider.normalizedModels(canonical.modelIDs + provider.modelIDs)
            if canonical.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                canonical.accountLabel = provider.accountLabel
            }
            if providerStatusRank(provider.status) > providerStatusRank(canonical.status) {
                canonical.status = provider.status
                canonical.statusDetail = provider.statusDetail
                canonical.capacity = provider.capacity
            }
            retained[canonicalIndex] = canonical
        }

        guard !replacementIDs.isEmpty else { return value }
        value.providers = retained
        for index in value.workers.indices {
            if let providerID = value.workers[index].providerID,
               let canonicalID = replacementIDs[providerID] {
                value.workers[index].providerID = canonicalID
            }
        }
        return value
    }

    private static func providerStatusRank(_ status: ProviderStatus) -> Int {
        switch status {
        case .connected: return 3
        case .degraded: return 2
        case .unverified: return 1
        case .offline: return 0
        }
    }

    private static func bindingCLIProxyAccountIdentities(
        _ configuration: WorkjetConfiguration,
        homeDirectory: URL
    ) -> WorkjetConfiguration {
        var value = configuration
        for provider in ModelProvider.allCases where provider.usesWebLogin {
            let identities = CLIProxyAccountAuthenticator.availableAccounts(for: provider, homeDirectory: homeDirectory)
            guard !identities.isEmpty else { continue }
            var claimedIdentityIDs = Set<String>()
            for index in value.providers.indices
            where value.providers[index].modelProvider == provider && value.providers[index].externalCredentialID != nil {
                let storedID = value.providers[index].externalCredentialID
                if let identity = identities.first(where: { identity in
                    identity.externalID == storedID
                        || (storedID.map { identity.sourceRecordIDs.contains($0) } ?? false)
                        || (storedID.map { identity.migrationAliases.contains($0) } ?? false)
                }) {
                    value.providers[index].accountLabel = identity.label
                    value.providers[index].externalCredentialID = identity.externalID
                    claimedIdentityIDs.insert(identity.externalID)
                }
            }
            var available = identities.filter { !claimedIdentityIDs.contains($0.externalID) }
            let unbound = value.providers.indices.filter {
                value.providers[$0].modelProvider == provider && value.providers[$0].externalCredentialID == nil
            }.sorted {
                value.providers[$0].routingPriority < value.providers[$1].routingPriority
            }
            for index in unbound {
                guard !available.isEmpty else { break }
                let identity = available.removeFirst()
                value.providers[index].accountLabel = identity.label
                value.providers[index].externalCredentialID = identity.externalID
                value.providers[index].credentialReference = CLIProxyGatewayCredentialStore.reference
                claimedIdentityIDs.insert(identity.externalID)
            }
            for identity in available {
                let existingCount = value.providers.count(where: { $0.modelProvider == provider })
                value.providers.append(Provider(
                    name: "\(provider.rawValue) \(existingCount + 1)",
                    kind: .cliProxyAPI,
                    endpoint: "http://127.0.0.1:8317",
                    authentication: provider.defaultAuthentication,
                    modelProvider: provider,
                    accountLabel: identity.label,
                    externalCredentialID: identity.externalID,
                    modelIDs: provider.requestedModelSuggestions,
                    status: .unverified,
                    statusDetail: "Zugang erkannt; Verbindung wird geprüft.",
                    credentialReference: CLIProxyGatewayCredentialStore.reference,
                    routingPriority: existingCount
                ))
            }
        }
        value = collapsingDuplicateCLIProxyIdentities(value)
        migrateLegacySharedOAuthStatus(&value)
        migrateOAuthAccountRoutesToPools(&value)
        for index in value.workers.indices where value.workers[index].providerRoute == nil {
            guard let inferred = ModelProvider.inferred(from: value.workers[index].model),
                  value.providers.contains(where: { $0.modelProvider == inferred }) else { continue }
            value.workers[index].providerPool = inferred
        }
        return value
    }
}

// MARK: - Workjet command-line bridge

public enum WorkjetCLIExitCode: Int32, Sendable {
    case success = 0
    case usage = 2
    case notFound = 3
    case ambiguous = 4
    case unsupported = 5
    case rejected = 6
    case transport = 7
    case state = 8
}

public struct WorkjetCLIError: LocalizedError, Equatable, Sendable {
    public var code: String
    public var message: String
    public var exitCode: WorkjetCLIExitCode

    public init(code: String, message: String, exitCode: WorkjetCLIExitCode) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }

    public var errorDescription: String? { message }

    public static func usage(_ message: String) -> Self {
        Self(code: "usage", message: message, exitCode: .usage)
    }
}

public enum WorkjetCLICommand: Equatable, Sendable {
    case workersList(json: Bool)
    case workerDescribe(identifier: String, json: Bool)
    case computerSetup(identifier: String, json: Bool)
    case healthProbeWorkers(identifiers: [String], timeoutSeconds: Int?, json: Bool)
    case run(identifier: String, brief: WorkjetCLIBrief, json: Bool)
    case events(runID: String, after: UInt64, json: Bool)
    case stop(runID: String, json: Bool)
    case resultImport(runID: String, json: Bool)
    case runsMark(runID: String, disposition: RemoteWorkspaceDisposition, json: Bool)
}

public enum WorkjetCLIBrief: Equatable, Sendable {
    case inline(String)
    case file(String)
}

public enum WorkjetCLIParser {
    public static let usage = """
    Verwendung:
      workjet workers list --json
      workjet workers describe <uuid-oder-exakter-name> --json
      workjet computers setup <uuid-oder-exakter-name> --json
      workjet health --probe-workers [--worker <uuid-oder-exakter-name>] [--timeout <sekunden>] --json
      workjet run <uuid-oder-exakter-name> (--brief <text> | --brief-file <pfad>) --json
      workjet events <run-id> --after <exklusive-sequenz> --json
      workjet stop <run-id> --json
      workjet result import <run-id> [--json]
      workjet runs mark <run-id> integrated|abandoned [--json]
      workjet learn --systematic <regel> | workjet learn --list
    """

    public static func parse(_ arguments: [String]) throws -> WorkjetCLICommand {
        guard let verb = arguments.first else { throw WorkjetCLIError.usage(usage) }
        switch verb {
        case "workers":
            guard arguments.count >= 2 else { throw WorkjetCLIError.usage(usage) }
            switch arguments[1] {
            case "list":
                try requireOnlyJSON(Array(arguments.dropFirst(2)))
                return .workersList(json: arguments.contains("--json"))
            case "describe":
                guard arguments.count >= 3 else { throw WorkjetCLIError.usage(usage) }
                try requireOnlyJSON(Array(arguments.dropFirst(3)))
                return .workerDescribe(identifier: arguments[2], json: arguments.contains("--json"))
            default:
                throw WorkjetCLIError.usage(usage)
            }
        case "run":
            guard arguments.count >= 4 else { throw WorkjetCLIError.usage(usage) }
            let identifier = arguments[1]
            var brief: WorkjetCLIBrief?
            var json = false
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--json":
                    json = true
                    index += 1
                case "--brief", "--brief-file":
                    guard brief == nil, index + 1 < arguments.count else { throw WorkjetCLIError.usage(usage) }
                    brief = arguments[index] == "--brief" ? .inline(arguments[index + 1]) : .file(arguments[index + 1])
                    index += 2
                default:
                    throw WorkjetCLIError.usage("Unbekannte Option: \(arguments[index])\n\(usage)")
                }
            }
            guard let brief else { throw WorkjetCLIError.usage(usage) }
            return .run(identifier: identifier, brief: brief, json: json)
        case "computers":
            guard arguments.count >= 3, arguments[1] == "setup" else { throw WorkjetCLIError.usage(usage) }
            try requireOnlyJSON(Array(arguments.dropFirst(3)))
            return .computerSetup(identifier: arguments[2], json: arguments.contains("--json"))
        case "health":
            var probeWorkers = false
            var identifiers: [String] = []
            var timeoutSeconds: Int?
            var json = false
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--probe-workers":
                    guard !probeWorkers else { throw WorkjetCLIError.usage(usage) }
                    probeWorkers = true
                    index += 1
                case "--timeout":
                    guard timeoutSeconds == nil, index + 1 < arguments.count,
                          let value = Int(arguments[index + 1]), (5...600).contains(value) else {
                        throw WorkjetCLIError.usage("--timeout erwartet 5 bis 600 Sekunden.\n\(usage)")
                    }
                    timeoutSeconds = value
                    index += 2
                case "--worker":
                    guard index + 1 < arguments.count,
                          !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw WorkjetCLIError.usage("--worker erwartet eine UUID oder einen exakten Namen.\n\(usage)")
                    }
                    identifiers.append(arguments[index + 1])
                    index += 2
                case "--json":
                    guard !json else { throw WorkjetCLIError.usage(usage) }
                    json = true
                    index += 1
                default:
                    throw WorkjetCLIError.usage("Unbekannte Option: \(arguments[index])\n\(usage)")
                }
            }
            guard probeWorkers else { throw WorkjetCLIError.usage(usage) }
            return .healthProbeWorkers(identifiers: identifiers, timeoutSeconds: timeoutSeconds, json: json)
        case "events":
            guard arguments.count >= 4 else { throw WorkjetCLIError.usage(usage) }
            let runID = arguments[1]
            var after: UInt64?
            var json = false
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--json": json = true; index += 1
                case "--after":
                    guard after == nil, index + 1 < arguments.count, let value = UInt64(arguments[index + 1]) else {
                        throw WorkjetCLIError.usage("--after erwartet eine nichtnegative Ganzzahl.\n\(usage)")
                    }
                    after = value
                    index += 2
                default: throw WorkjetCLIError.usage("Unbekannte Option: \(arguments[index])\n\(usage)")
                }
            }
            guard let after else { throw WorkjetCLIError.usage(usage) }
            return .events(runID: runID, after: after, json: json)
        case "stop":
            guard arguments.count >= 2 else { throw WorkjetCLIError.usage(usage) }
            try requireOnlyJSON(Array(arguments.dropFirst(2)))
            return .stop(runID: arguments[1], json: arguments.contains("--json"))
        case "result":
            guard arguments.count >= 3, arguments[1] == "import" else { throw WorkjetCLIError.usage(usage) }
            try requireOnlyJSON(Array(arguments.dropFirst(3)))
            return .resultImport(runID: arguments[2], json: arguments.contains("--json"))
        case "runs":
            guard arguments.count >= 4, arguments[1] == "mark", let disposition = RemoteWorkspaceDisposition(rawValue: arguments[3]) else { throw WorkjetCLIError.usage(usage) }
            try requireOnlyJSON(Array(arguments.dropFirst(4)))
            return .runsMark(runID: arguments[2], disposition: disposition, json: arguments.contains("--json"))
        default:
            throw WorkjetCLIError.usage(usage)
        }
    }

    private static func requireOnlyJSON(_ arguments: [String]) throws {
        guard arguments.allSatisfy({ $0 == "--json" }), arguments.count(where: { $0 == "--json" }) <= 1 else {
            throw WorkjetCLIError.usage(usage)
        }
    }
}

public struct WorkjetCLIWorker: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var harness: String
    public var model: String
    public var reasoning: String?
    public var computerID: UUID
    public var computerName: String
    public var remote: Bool
    public var instructions: String?
}

public struct WorkjetCLIComputer: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var state: String
    public var detail: String?
    public var sidecarVersion: String?
    public var contentHash: String?
}

public struct WorkjetCLIEvent: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var timestamp: String
    public var kind: String
    public var text: String?
    public var exitCode: Int32?
}

public struct WorkjetCLIWorkerHealth: Codable, Equatable, Sendable {
    public var workerID: UUID
    public var workerName: String
    public var model: String
    public var computerName: String
    public var providerRoute: String?
    public var status: String
    public var latencyMilliseconds: Int
    public var runID: String?
    public var responseTokenObserved: Bool
    public var error: String?
    public var message: String?
}

public struct WorkjetCLIResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var command: String
    public var workers: [WorkjetCLIWorker]?
    public var worker: WorkjetCLIWorker?
    public var computer: WorkjetCLIComputer?
    public var runID: String?
    public var state: String?
    public var cursor: UInt64?
    public var events: [WorkjetCLIEvent]?
    public var health: [WorkjetCLIWorkerHealth]?
    public var checkedAt: String?
    public var resultRef: String?
    public var resultOID: String?
    public var lifecycle: String?

    public init(ok: Bool = true, command: String, workers: [WorkjetCLIWorker]? = nil, worker: WorkjetCLIWorker? = nil, computer: WorkjetCLIComputer? = nil, runID: String? = nil, state: String? = nil, cursor: UInt64? = nil, events: [WorkjetCLIEvent]? = nil, health: [WorkjetCLIWorkerHealth]? = nil, checkedAt: String? = nil, resultRef: String? = nil, resultOID: String? = nil, lifecycle: String? = nil) {
        self.ok = ok
        self.command = command
        self.workers = workers
        self.worker = worker
        self.computer = computer
        self.runID = runID
        self.state = state
        self.cursor = cursor
        self.events = events
        self.health = health
        self.checkedAt = checkedAt
        self.resultRef = resultRef
        self.resultOID = resultOID
        self.lifecycle = lifecycle
    }
}

public struct WorkjetCLIErrorResponse: Codable, Equatable, Sendable {
    public var ok = false
    public var error: String
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}

public protocol WorkjetCLIBacking: Sendable {
    var configuration: WorkjetConfiguration { get }
    func startLocal(worker: Worker, brief: Data) async throws -> RemoteHostResponse
    func startLocal(worker: Worker, route: ResolvedProviderRuntimeRoute, brief: Data) async throws -> RemoteHostResponse
    func localEvents(runID: String, after: UInt64) async throws -> RemoteHostResponse?
    func stopLocal(runID: String) async throws -> RemoteHostResponse?
    func start(worker: Worker, computer: Computer, brief: Data, ownerID: String) async throws -> RemoteHostResponse
    func start(worker: Worker, computer: Computer, route: ResolvedProviderRuntimeRoute, brief: Data, ownerID: String) async throws -> RemoteHostResponse
    func list(computer: Computer, ownerID: String) async throws -> RemoteHostResponse
    func events(computer: Computer, runID: String, after: UInt64) async throws -> RemoteHostResponse
    func stop(computer: Computer, runID: String) async throws -> RemoteHostResponse
    func importResult(runID: String) async throws -> WorkspaceResultImportReceipt
    func mark(runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt
    func setup(computer: Computer) async throws -> Computer
}

public extension WorkjetCLIBacking {
    func startLocal(worker: Worker, brief: Data) async throws -> RemoteHostResponse {
        throw WorkjetCLIError(code: "local_run_unsupported", message: "Dieser CLI-Dienst unterstützt keine lokalen Starts.", exitCode: .unsupported)
    }
    func startLocal(worker: Worker, route: ResolvedProviderRuntimeRoute, brief: Data) async throws -> RemoteHostResponse {
        try await startLocal(worker: worker, brief: brief)
    }
    func start(worker: Worker, computer: Computer, route: ResolvedProviderRuntimeRoute, brief: Data, ownerID: String) async throws -> RemoteHostResponse {
        try await start(worker: worker, computer: computer, brief: brief, ownerID: ownerID)
    }
    func localEvents(runID: String, after: UInt64) async throws -> RemoteHostResponse? { nil }
    func stopLocal(runID: String) async throws -> RemoteHostResponse? { nil }
    func importResult(runID: String) async throws -> WorkspaceResultImportReceipt { throw WorkspaceResultError.recordNotFound }
    func mark(runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt { throw WorkspaceResultError.recordNotFound }
    func setup(computer: Computer) async throws -> Computer {
        throw WorkjetCLIError(code: "computer_setup_unsupported", message: "Dieser CLI-Dienst kann keine Computer einrichten.", exitCode: .unsupported)
    }
}

public struct LiveWorkjetCLIBacking: WorkjetCLIBacking, @unchecked Sendable {
    private struct RemoteSupervisorRequest: Codable {
        var workerID: UUID
        var computerID: UUID
        var ownerID: String
        var route: ResolvedProviderRuntimeRoute
        var brief: Data
        var workingDirectory: String
    }

    private struct RemoteSupervisorHandshake: Codable {
        var ok: Bool
        var runID: String?
        var state: RemoteHostRunState?
        var cursor: UInt64?
        var error: String?
    }

    public let configuration: WorkjetConfiguration
    private let service: any WorkjetService
    private let localRuns: LocalRunService
    private let workspaceRuns: RemoteWorkspaceRunStore
    private let workingDirectory: URL
    private let supervisorExecutable: URL
    private let paths: WorkjetPaths

    public init(
        paths: WorkjetPaths = .live,
        workingDirectory: URL? = nil,
        supervisorExecutable: URL? = nil
    ) throws {
        let directory = (workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL
        let bootstrap = WorkjetBootstrap.live(paths: paths, workingDirectory: directory)
        guard bootstrap.messages.isEmpty else {
            throw WorkjetCLIError(code: "state_load_failed", message: bootstrap.messages.joined(separator: " "), exitCode: .state)
        }
        configuration = bootstrap.configuration
        service = bootstrap.service
        localRuns = LocalRunService(paths: paths)
        workspaceRuns = RemoteWorkspaceRunStore(paths: paths)
        self.paths = paths
        self.workingDirectory = directory
        self.supervisorExecutable = try (supervisorExecutable ?? Self.currentExecutableURL())
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// A PATH launch may expose only `workjet` as argv[0]. Ask the kernel for
    /// the image it actually loaded so the detached supervisor never becomes
    /// `<current-directory>/workjet` by accident.
    static func currentExecutableURL() throws -> URL {
        var capacity: UInt32 = 1_024
        while capacity <= 1_048_576 {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            var required = capacity
            if _NSGetExecutablePath(&buffer, &required) == 0 {
                let path = String(cString: buffer)
                guard path.hasPrefix("/") else {
                    throw WorkjetCLIError(code: "supervisor_executable_invalid", message: "Die laufende Workjet-CLI konnte nicht eindeutig aufgelöst werden.", exitCode: .state)
                }
                return URL(fileURLWithPath: path, isDirectory: false)
            }
            capacity = max(required, capacity * 2)
        }
        throw WorkjetCLIError(code: "supervisor_executable_invalid", message: "Die laufende Workjet-CLI konnte nicht eindeutig aufgelöst werden.", exitCode: .state)
    }

    public func startLocal(worker: Worker, brief: Data) async throws -> RemoteHostResponse {
        let route = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: configuration.providers, target: .local)
        return try await startLocal(worker: worker, route: route, brief: brief)
    }
    public func startLocal(worker: Worker, route: ResolvedProviderRuntimeRoute, brief: Data) async throws -> RemoteHostResponse {
        let repositoryAvailable = await Self.repositoryAvailable(at: workingDirectory)
        let availableSkillIDs = await Self.availableLocalSkillIDs(at: workingDirectory, route: route)
        if worker.invocation.options["workjet.health-probe"] != "v1",
           Self.requiresGreppy(worker) {
            guard repositoryAvailable else {
                throw WorkjetCLIError(
                    code: "skill_workspace_required",
                    message: "Greppy 0.3.1 ist für diesen Worker aktiviert. Starte Workjet aus einem Git-Repository oder deaktiviere Greppy für diesen Worker.",
                    exitCode: .state
                )
            }
            guard availableSkillIDs.contains(WorkerSkillCatalog.greppyID) else {
                throw WorkjetCLIError(
                    code: "skill_runtime_unavailable",
                    message: "Greppy 0.3.1 ist für diesen Worker aktiviert, aber die erwartete Binary und Befehlsoberfläche wurden auf diesem Computer nicht bestätigt.",
                    exitCode: .state
                )
            }
        }
        if worker.invocation.options["workjet.health-probe"] != "v1",
           Self.requiresWebResearch(worker),
           !availableSkillIDs.contains(WorkerSkillCatalog.webResearchID) {
            throw WorkjetCLIError(
                code: "skill_runtime_unavailable",
                message: "Web Research ist aktiviert, aber weder Codex Live Search über eine Workjet-Gateway-Route noch ein lokaler Antigravity-Research-Helper wurde bestätigt.",
                exitCode: .state
            )
        }
        let systemPrompt = Self.preparedLocalSystemPrompt(
            worker: worker,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: configuration.technicalRules ?? ""
        )
        let workspace: LocalWorkspaceContext?
        if repositoryAvailable, worker.invocation.options["workjet.health-probe"] != "v1" {
            let snapshot = try await GitWorkspaceSnapshotPreparer().prepare(from: workingDirectory)
            guard let sourceRoot = snapshot.sourceRepositoryRoot else { throw WorkspaceResultError.repositoryUnsafe }
            let identity = try await GitRepositoryInspector().inspect(root: sourceRoot, expectedRepoID: snapshot.manifest.repoID)
            workspace = LocalWorkspaceContext(
                snapshot: snapshot,
                repositoryIdentity: identity,
                computerID: worker.computerID,
                ownerID: "workjet-worker-\(worker.id.uuidString.lowercased())"
            )
        } else {
            workspace = nil
        }
        return try localRuns.start(
            worker: worker,
            route: route,
            brief: brief,
            systemPrompt: systemPrompt,
            skillIDs: availableSkillIDs.intersection(Set(WorkerSkillCatalog.effectiveSkills(for: worker).map(\.id))),
            workspace: workspace,
            turnTimeoutSeconds: Double(min(max(configuration.turnTimeoutSeconds, 60), 10_800)),
            supervisorExecutable: supervisorExecutable
        )
    }

    static func requiresGreppy(_ worker: Worker) -> Bool {
        WorkerSkillCatalog.effectiveSkills(for: worker).contains { $0.id == WorkerSkillCatalog.greppyID }
    }

    static func requiresWebResearch(_ worker: Worker) -> Bool {
        WorkerSkillCatalog.effectiveSkills(for: worker).contains { $0.id == WorkerSkillCatalog.webResearchID }
    }

    static func preparedLocalSystemPrompt(
        worker: Worker,
        repositoryAvailable: Bool,
        availableSkillIDs: Set<String>,
        technicalRules: String
    ) -> String? {
        guard worker.invocation.options["workjet.health-probe"] != "v1" else { return nil }
        return WorkerSkillCatalog.systemPrompt(
            for: worker,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: technicalRules
        )
    }

    static func availableLocalSkillIDs(
        at directory: URL,
        route: ResolvedProviderRuntimeRoute? = nil,
        runner: any CommandRunning = ProcessCommandRunner(),
        sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Set<String> {
        let environment = localSkillProbeEnvironment(sourceEnvironment)
        var available: Set<String> = []
        if let executable = resolvedExecutable(named: WorkerSkillCatalog.greppyID, environment: environment, currentDirectory: directory) {
          do {
            let result = try await runner.run(CommandSpec(
                executable: executable,
                arguments: ["--version"],
                currentDirectory: directory.path,
                environment: environment,
                timeout: 10,
                stdoutLimit: 4_096,
                stderrLimit: 4_096
            ))
            let output = String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
            guard result.exitCode == 0,
                  !result.stdoutTruncated,
                  !result.stderrTruncated,
                  output.range(of: #"(?:^|[^0-9])v?0\.3\.1(?:[^0-9]|$)"#, options: .regularExpression) != nil else { throw LocalSkillProbeFailure.unavailable }
            let surface = try await runner.run(CommandSpec(
                executable: executable,
                arguments: ["--help"],
                currentDirectory: directory.path,
                environment: environment,
                timeout: 10,
                stdoutLimit: 65_536,
                stderrLimit: 4_096
            ))
            let surfaceOutput = String(decoding: surface.standardOutput + surface.standardError, as: UTF8.self)
            guard surface.exitCode == 0,
                  !surface.stdoutTruncated,
                  !surface.stderrTruncated,
                  ["who-calls", "search-symbol", "bash-smart"].allSatisfy(surfaceOutput.contains) else { throw LocalSkillProbeFailure.unavailable }
            available.insert(WorkerSkillCatalog.greppyID)
          } catch {}
        }
        let gatewayAvailable = route?.candidates.contains(where: { $0.kind == .gatewayPool }) ?? true
        if gatewayAvailable,
           let codex = resolvedExecutable(named: "codex", environment: environment, currentDirectory: directory),
           await executableResponds(codex, arguments: ["--version"], in: directory, environment: environment, runner: runner) {
            available.insert(WorkerSkillCatalog.webResearchID)
        } else if let antigravity = resolvedExecutable(named: "agy", environment: environment, currentDirectory: directory),
                  await executableResponds(antigravity, arguments: ["--version"], in: directory, environment: environment, runner: runner) {
            available.insert(WorkerSkillCatalog.webResearchID)
        }
        return available
    }

    private enum LocalSkillProbeFailure: Error { case unavailable }

    private static func executableResponds(
        _ executable: String,
        arguments: [String],
        in directory: URL,
        environment: [String: String],
        runner: any CommandRunning
    ) async -> Bool {
        do {
            let result = try await runner.run(CommandSpec(
                executable: executable,
                arguments: arguments,
                currentDirectory: directory.path,
                environment: environment,
                timeout: 10,
                stdoutLimit: 4_096,
                stderrLimit: 4_096
            ))
            return result.exitCode == 0 && !result.stdoutTruncated && !result.stderrTruncated
        } catch {
            return false
        }
    }

    static func resolvedExecutable(
        named command: String,
        environment: [String: String],
        currentDirectory: URL
    ) -> String? {
        guard !command.isEmpty, !command.contains("/"), !command.contains("\0") else { return nil }
        let pathValue = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for component in pathValue.split(separator: ":", omittingEmptySubsequences: false) {
            let directory: URL
            if component.isEmpty {
                directory = currentDirectory
            } else {
                let raw = String(component)
                directory = raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw, isDirectory: true)
                    : currentDirectory.appendingPathComponent(raw, isDirectory: true)
            }
            let candidate = directory.appendingPathComponent(command).standardizedFileURL
            var info = stat()
            if stat(candidate.path, &info) == 0,
               (info.st_mode & S_IFMT) == S_IFREG,
               access(candidate.path, X_OK) == 0 {
                return candidate.path
            }
        }
        return nil
    }

    static func localSkillProbeEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]
        var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in source[key].map { (key, $0) } })
        if result["PATH"] == nil { result["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        if result["HOME"] == nil { result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path }
        if result["TMPDIR"] == nil { result["TMPDIR"] = NSTemporaryDirectory() }
        return result
    }

    static func repositoryAvailable(at directory: URL, runner: any CommandRunning = ProcessCommandRunner()) async -> Bool {
        guard directory.path.hasPrefix("/"), !directory.path.contains("\0") else { return false }
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(canonical.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        do {
            let result = try await runner.run(CommandSpec(
                executable: "/usr/bin/git",
                arguments: ["rev-parse", "--is-inside-work-tree"],
                currentDirectory: canonical.path,
                environment: GitRepositoryInspector.gitEnvironment,
                timeout: 10,
                stdoutLimit: 128,
                stderrLimit: 4_096
            ))
            return result.exitCode == 0
                && !result.stdoutTruncated
                && !result.stderrTruncated
                && String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch {
            return false
        }
    }
    public func localEvents(runID: String, after: UInt64) async throws -> RemoteHostResponse? {
        try localRuns.events(runID: runID, after: after)
    }
    public func stopLocal(runID: String) async throws -> RemoteHostResponse? {
        try localRuns.stop(runID: runID)
    }

    public func start(worker: Worker, computer: Computer, brief: Data, ownerID: String) async throws -> RemoteHostResponse {
        try await service.startRemoteWorker(worker, on: computer, input: brief, ownerID: ownerID)
    }
    public func start(worker: Worker, computer: Computer, route: ResolvedProviderRuntimeRoute, brief: Data, ownerID: String) async throws -> RemoteHostResponse {
        if worker.invocation.options["workjet.health-probe"] == "v1" {
            // Health waits for its result in this process, so the in-memory
            // tunnel owner remains alive for the complete probe.
            return try await service.startRemoteWorker(worker, on: computer, route: route, input: brief, ownerID: ownerID)
        }
        return try await startRemoteSupervised(worker: worker, computer: computer, route: route, brief: brief, ownerID: ownerID)
    }

    private func startRemoteSupervised(
        worker: Worker,
        computer: Computer,
        route: ResolvedProviderRuntimeRoute,
        brief: Data,
        ownerID: String
    ) async throws -> RemoteHostResponse {
        let root = paths.stateDirectory.appendingPathComponent("remote-supervisors", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let requestURL = directory.appendingPathComponent("request.json")
        let responseURL = directory.appendingPathComponent("response.json")
        let request = RemoteSupervisorRequest(
            workerID: worker.id,
            computerID: computer.id,
            ownerID: ownerID,
            route: route,
            brief: brief,
            workingDirectory: workingDirectory.path
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(to: requestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

        let process = Process()
        process.executableURL = supervisorExecutable
        process.arguments = ["__remote-supervise", directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = paths.homeDirectory.path
        environment["PATH"] = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw WorkjetCLIError(code: "remote_supervisor_start_failed", message: "Der dauerhafte Remote-Supervisor konnte nicht gestartet werden.", exitCode: .transport)
        }

        // Snapshot preparation may complete a shallow submodule from its
        // caller-side origin (180 s) and the remote import has its own 180 s
        // bound. Do not abandon the supervisor while the host can still
        // legitimately accept the workspace and create an orphaned run.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let handshake = try? JSONDecoder().decode(RemoteSupervisorHandshake.self, from: data) {
                try? FileManager.default.removeItem(at: directory)
                guard handshake.ok,
                      let runID = handshake.runID,
                      let state = handshake.state else {
                    throw WorkjetCLIError(code: "remote_start_failed", message: handshake.error ?? "Der Remote-Supervisor konnte den Worker nicht starten.", exitCode: .transport)
                }
                return RemoteHostResponse(ok: true, runID: runID, state: state, cursor: handshake.cursor ?? 0)
            }
            if !process.isRunning {
                try? FileManager.default.removeItem(at: directory)
                throw WorkjetCLIError(code: "remote_supervisor_failed", message: "Der Remote-Supervisor endete vor der Startbestätigung.", exitCode: .transport)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
        throw WorkjetCLIError(code: "remote_supervisor_timeout", message: "Der Remote-Supervisor hat den Start nicht rechtzeitig bestätigt.", exitCode: .transport)
    }

    /// Hidden CLI entry point. This process owns the in-memory gateway tunnel
    /// for the complete remote run instead of letting `workjet run` tear it
    /// down immediately after printing the run ID.
    public static func superviseRemote(requestDirectory: URL, paths: WorkjetPaths) async throws {
        let requestURL = requestDirectory.appendingPathComponent("request.json")
        let responseURL = requestDirectory.appendingPathComponent("response.json")
        let request = try JSONDecoder().decode(RemoteSupervisorRequest.self, from: Data(contentsOf: requestURL))
        let backing = try LiveWorkjetCLIBacking(
            paths: paths,
            workingDirectory: URL(fileURLWithPath: request.workingDirectory, isDirectory: true)
        )
        guard let worker = backing.configuration.workers.first(where: { $0.id == request.workerID }),
              let computer = backing.configuration.computers.first(where: { $0.id == request.computerID }),
              worker.computerID == computer.id,
              !computer.isLocal else {
            try writeRemoteSupervisorHandshake(
                RemoteSupervisorHandshake(ok: false, error: "Worker oder Remote-Computer ist nicht mehr konfiguriert."),
                to: responseURL
            )
            return
        }
        let response: RemoteHostResponse
        do {
            response = try await backing.service.startRemoteWorker(
                worker,
                on: computer,
                route: request.route,
                input: request.brief,
                ownerID: request.ownerID
            )
        } catch {
            try writeRemoteSupervisorHandshake(
                RemoteSupervisorHandshake(ok: false, error: error.localizedDescription),
                to: responseURL
            )
            return
        }
        guard let runID = response.runID else {
            try writeRemoteSupervisorHandshake(
                RemoteSupervisorHandshake(ok: false, error: "Der Remote-Host lieferte keine Run-ID."),
                to: responseURL
            )
            return
        }
        try writeRemoteSupervisorHandshake(
            RemoteSupervisorHandshake(ok: true, runID: runID, state: response.state, cursor: response.cursor),
            to: responseURL
        )

        var cursor = response.cursor
        var state = response.state
        var consecutiveObservationFailures = 0
        while !state.isTerminal {
            try await Task.sleep(for: .milliseconds(500))
            do {
                let observed = try await backing.service.remoteEvents(on: computer, runID: runID, after: cursor)
                cursor = observed.cursor
                state = observed.state
                consecutiveObservationFailures = 0
            } catch {
                // The supervisor's primary duty is to keep the run-scoped
                // provider relay alive. A transient observational SSH failure
                // must not tear that relay down and kill a healthy worker.
                consecutiveObservationFailures += 1
                if consecutiveObservationFailures >= 120 { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func writeRemoteSupervisorHandshake(_ handshake: RemoteSupervisorHandshake, to url: URL) throws {
        let data = try JSONEncoder().encode(handshake)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func list(computer: Computer, ownerID: String) async throws -> RemoteHostResponse {
        try await service.listRemoteRuns(on: computer, ownerID: ownerID)
    }
    public func events(computer: Computer, runID: String, after: UInt64) async throws -> RemoteHostResponse {
        try await service.remoteEvents(on: computer, runID: runID, after: after)
    }
    public func stop(computer: Computer, runID: String) async throws -> RemoteHostResponse {
        try await service.stopRemoteWorker(on: computer, runID: runID)
    }
    public func importResult(runID: String) async throws -> WorkspaceResultImportReceipt {
        let record = try workspaceRuns.load(runID: runID)
        if record.localWorktreePath != nil || record.localRepositoryPath != nil {
            return try await localRuns.importResult(runID: runID)
        }
        guard let computer = configuration.computers.first(where: { $0.id == record.computerID }), !computer.isLocal else { throw WorkspaceResultError.identityMismatch }
        return try await service.importRemoteWorkspaceResult(on: computer, runID: runID)
    }
    public func mark(runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt {
        let record = try workspaceRuns.load(runID: runID)
        if record.localWorktreePath != nil || record.localRepositoryPath != nil {
            return try localRuns.mark(runID: runID, disposition: disposition)
        }
        guard let computer = configuration.computers.first(where: { $0.id == record.computerID }), !computer.isLocal else { throw WorkspaceResultError.identityMismatch }
        return try await service.markRemoteWorkspace(on: computer, runID: runID, disposition: disposition)
    }
    public func setup(computer: Computer) async throws -> Computer {
        guard !computer.isLocal else {
            throw WorkjetCLIError(code: "computer_setup_local", message: "Der lokale Computer benötigt keine Remote-Einrichtung.", exitCode: .usage)
        }
        let deployed = await service.bootstrapRemotePi(computer)
        guard deployed.deploymentStatus == .installed else {
            throw WorkjetCLIError(code: "computer_setup_failed", message: deployed.deploymentDetail, exitCode: .transport)
        }
        var updated = configuration
        guard let index = updated.computers.firstIndex(where: { $0.id == computer.id }) else {
            throw WorkjetCLIError(code: "computer_not_found", message: "Der Computer ist nicht mehr konfiguriert.", exitCode: .state)
        }
        updated.computers[index] = deployed
        try service.save(updated, handwrittenRulesChanged: false)
        return deployed
    }
}

public struct WorkjetCLIEngine: Sendable {
    private let backing: any WorkjetCLIBacking
    private let readFile: @Sendable (String) throws -> Data

    public init(backing: any WorkjetCLIBacking, readFile: @escaping @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }) {
        self.backing = backing
        self.readFile = readFile
    }

    public func execute(_ command: WorkjetCLICommand) async throws -> WorkjetCLIResponse {
        switch command {
        case .workersList:
            return WorkjetCLIResponse(command: "workers.list", workers: backing.configuration.workers.map { presentation($0, includeInstructions: false) })
        case let .workerDescribe(identifier, _):
            let worker = try resolveWorker(identifier)
            return WorkjetCLIResponse(command: "workers.describe", worker: presentation(worker))
        case let .computerSetup(identifier, _):
            let computer = try resolveComputer(identifier)
            let deployed = try await backing.setup(computer: computer)
            return WorkjetCLIResponse(command: "computers.setup", computer: WorkjetCLIComputer(
                id: deployed.id,
                name: deployed.name,
                state: deployed.deploymentStatus.rawValue,
                detail: deployed.deploymentDetail,
                sidecarVersion: deployed.installedSidecarVersion,
                contentHash: deployed.installedContentHash
            ))
        case let .healthProbeWorkers(identifiers, timeoutSeconds, _):
            let timeout = timeoutSeconds ?? backing.configuration.probeTimeoutSeconds
            let selectedWorkers = try identifiers.isEmpty
                ? backing.configuration.workers
                : identifiers.map(resolveWorker)
            let results = await probeWorkers(selectedWorkers, timeoutSeconds: timeout)
            return WorkjetCLIResponse(
                ok: results.allSatisfy { $0.status == "ready" },
                command: "health",
                health: results,
                checkedAt: ISO8601DateFormatter().string(from: Date())
            )
        case let .run(identifier, brief, _):
            let worker = try resolveWorker(identifier)
            let input: Data
            switch brief {
            case let .inline(value): input = Data(value.utf8)
            case let .file(path):
                do { input = try readFile(path) }
                catch { throw WorkjetCLIError(code: "brief_unreadable", message: "Die Brief-Datei konnte nicht gelesen werden.", exitCode: .state) }
            }
            guard !input.isEmpty else { throw WorkjetCLIError.usage("Der Brief darf nicht leer sein.") }
            let (_, response, _) = try await start(worker: worker, input: input)
            guard let runID = response.runID, !runID.isEmpty else {
                throw WorkjetCLIError(code: "missing_run_id", message: "Der Startdienst hat keine Run-ID geliefert.", exitCode: .rejected)
            }
            return WorkjetCLIResponse(command: "run", worker: presentation(worker), runID: runID, state: response.state.rawValue, cursor: response.cursor)
        case let .events(runID, after, _):
            if let response = try await translateLocalErrors({ try await backing.localEvents(runID: runID, after: after) }) {
                return WorkjetCLIResponse(command: "events", runID: runID, state: response.state.rawValue, cursor: response.cursor, events: response.events.map {
                    WorkjetCLIEvent(sequence: $0.sequence, timestamp: $0.timestamp, kind: $0.kind, text: $0.text, exitCode: $0.exitCode)
                })
            }
            let located = try await locateOwnedRun(runID)
            let response = try await translateRemoteErrors {
                try await backing.events(computer: located.computer, runID: runID, after: after)
            }
            return WorkjetCLIResponse(command: "events", runID: runID, state: response.state.rawValue, cursor: response.cursor, events: response.events.map {
                WorkjetCLIEvent(sequence: $0.sequence, timestamp: $0.timestamp, kind: $0.kind, text: $0.text, exitCode: $0.exitCode)
            })
        case let .stop(runID, _):
            if let response = try await translateLocalErrors({ try await backing.stopLocal(runID: runID) }) {
                return WorkjetCLIResponse(command: "stop", runID: runID, state: response.state.rawValue, cursor: response.cursor)
            }
            let located = try await locateOwnedRun(runID)
            let response = try await translateRemoteErrors {
                try await backing.stop(computer: located.computer, runID: runID)
            }
            return WorkjetCLIResponse(command: "stop", runID: runID, state: response.state.rawValue, cursor: response.cursor)
        case let .resultImport(runID, _):
            let receipt = try await translateWorkspaceErrors { try await backing.importResult(runID: runID) }
            return WorkjetCLIResponse(command: "result.import", runID: runID, state: receipt.terminalState?.rawValue, resultRef: receipt.resultRef, resultOID: receipt.resultCommitOID, lifecycle: receipt.lifecycle.rawValue)
        case let .runsMark(runID, disposition, _):
            let receipt = try await translateWorkspaceErrors { try await backing.mark(runID: runID, disposition: disposition) }
            return WorkjetCLIResponse(command: "runs.mark", runID: runID, state: receipt.terminalState.rawValue, resultRef: receipt.resultRef, resultOID: receipt.resultCommitOID, lifecycle: receipt.lifecycle.rawValue)
        }
    }

    private static let healthToken = "WORKJET_HEALTH_OK"
    private static let healthPrompt = """
    WORKJET HEALTH PROBE V1. This is a real user health ping: hi. Do not inspect or edit files. Do not use tools. Do not spawn subagents. Reply exactly WORKJET_HEALTH_OK and exit.
    """

    private func probeWorkers(_ workers: [Worker], timeoutSeconds: Int) async -> [WorkjetCLIWorkerHealth] {
        let limit = min(max(backing.configuration.providerSlots, 1), max(workers.count, 1))
        return await withTaskGroup(of: (Int, WorkjetCLIWorkerHealth).self, returning: [WorkjetCLIWorkerHealth].self) { group in
            var next = 0
            var results: [(Int, WorkjetCLIWorkerHealth)] = []
            while next < min(limit, workers.count) {
                let index = next
                group.addTask { (index, await probe(worker: workers[index], timeoutSeconds: timeoutSeconds)) }
                next += 1
            }
            while let result = await group.next() {
                results.append(result)
                if next < workers.count {
                    let index = next
                    group.addTask { (index, await probe(worker: workers[index], timeoutSeconds: timeoutSeconds)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func probe(worker: Worker, timeoutSeconds: Int) async -> WorkjetCLIWorkerHealth {
        let startedAt = Date()
        var runID: String?
        // Resolve presentation facts before starting the run. A launch error
        // must not erase a computer that is plainly present in configuration.
        var computerName = backing.configuration.computers
            .first(where: { $0.id == worker.computerID })?.name
            ?? "Nicht konfiguriert"
        var routeName: String?
        do {
            var probeWorker = worker
            probeWorker.invocation.options["workjet.health-probe"] = "v1"
            let (computer, response, resolvedRoute) = try await start(worker: probeWorker, input: Data(Self.healthPrompt.utf8))
            computerName = computer.name
            routeName = resolvedRoute.displayName
            guard let value = response.runID, !value.isEmpty else {
                throw WorkjetCLIError(code: "missing_run_id", message: "Der Startdienst hat keine Run-ID geliefert.", exitCode: .rejected)
            }
            runID = value
            var cursor = response.cursor
            var tokenObserved = false
            var failureDiagnostic: String?
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            while Date() < deadline {
                let current: RemoteHostResponse?
                if computer.isLocal {
                    current = try await translateLocalErrors { try await backing.localEvents(runID: value, after: cursor) }
                } else {
                    current = try await translateRemoteErrors {
                        try await backing.events(computer: computer, runID: value, after: cursor)
                    }
                }
                guard let current else {
                    throw WorkjetCLIError(code: "health_run_missing", message: "Der Healthcheck-Run ist nicht mehr auffindbar.", exitCode: .state)
                }
                tokenObserved = tokenObserved || current.events.contains {
                    $0.kind == "stdout" && ($0.text?.contains(Self.healthToken) == true)
                }
                for event in current.events where event.text?.contains(Self.healthToken) != true {
                    guard event.kind != "started", event.kind != "stopped" else { continue }
                    guard let text = Self.healthDiagnostic(event.text) else { continue }
                    if event.kind == "stdout" || event.kind == "provider-error" || failureDiagnostic == nil {
                        failureDiagnostic = text
                    }
                }
                cursor = max(cursor, current.cursor)
                if current.state.isTerminal {
                    let ready = current.state == .completed && tokenObserved
                    let providerFailure = failureDiagnostic.map(Self.isProviderDiagnostic) == true
                    return healthResult(
                        worker: worker,
                        computerName: computerName,
                        providerRoute: routeName,
                        status: ready ? "ready" : "failed",
                        startedAt: startedAt,
                        runID: value,
                        tokenObserved: tokenObserved,
                        error: ready ? nil : (providerFailure ? "provider_unavailable" : "health_response_invalid"),
                        message: ready ? nil : (failureDiagnostic ?? "Der Worker endete mit \(current.state.rawValue), ohne das erwartete Antworttoken zu bestätigen.")
                    )
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if computer.isLocal {
                _ = try? await backing.stopLocal(runID: value)
            } else {
                _ = try? await backing.stop(computer: computer, runID: value)
            }
            return healthResult(worker: worker, computerName: computerName, providerRoute: routeName, status: "timeout", startedAt: startedAt, runID: value, tokenObserved: tokenObserved, error: "health_timeout", message: "Der Worker antwortete nicht innerhalb von \(timeoutSeconds) Sekunden.")
        } catch let error as WorkjetCLIError {
            return healthResult(worker: worker, computerName: computerName, providerRoute: routeName, status: "failed", startedAt: startedAt, runID: runID, tokenObserved: false, error: error.code, message: error.message)
        } catch {
            return healthResult(worker: worker, computerName: computerName, providerRoute: routeName, status: "failed", startedAt: startedAt, runID: runID, tokenObserved: false, error: "health_internal_error", message: error.localizedDescription)
        }
    }

    private static func healthDiagnostic(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(512))
    }

    private static func isProviderDiagnostic(_ message: String) -> Bool {
        let value = message.lowercased()
        return ["http 401", "http 403", "authenticate", "authentication", "usage limit", "quota", "billing cycle", "rate limit"].contains { value.contains($0) }
    }

    private func healthResult(
        worker: Worker,
        computerName: String,
        providerRoute: String?,
        status: String,
        startedAt: Date,
        runID: String?,
        tokenObserved: Bool,
        error: String?,
        message: String?
    ) -> WorkjetCLIWorkerHealth {
        WorkjetCLIWorkerHealth(
            workerID: worker.id,
            workerName: worker.name,
            model: worker.model,
            computerName: computerName,
            providerRoute: providerRoute,
            status: status,
            latencyMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            runID: runID,
            responseTokenObserved: tokenObserved,
            error: error,
            message: message
        )
    }

    private func start(worker: Worker, input: Data) async throws -> (Computer, RemoteHostResponse, ResolvedProviderRuntimeRoute) {
        guard let computer = backing.configuration.computers.first(where: { $0.id == worker.computerID }) else {
            throw WorkjetCLIError(code: "computer_not_found", message: "Der Ziel-Computer des Workers ist nicht konfiguriert.", exitCode: .state)
        }
        guard computer.isLocal || (computer.deploymentStatus == .installed && computer.installedSidecarVersion == PiSidecarRuntime.version) else {
            throw WorkjetCLIError(code: "computer_not_ready", message: "Der Ziel-Computer ist nicht vollständig eingerichtet.", exitCode: .state)
        }
        if computer.isLocal {
            let route = try resolveProviderRoute(worker: worker, target: .local)
            let response = try await translateLocalErrors { try await backing.startLocal(worker: worker, route: route, brief: input) }
            return (computer, response, route)
        }
        let route = try resolveProviderRoute(worker: worker, target: .remote)
        let response = try await translateRemoteErrors {
            try await backing.start(worker: worker, computer: computer, route: route, brief: input, ownerID: ownerID(worker.id))
        }
        return (computer, response, route)
    }

    private func resolveWorker(_ identifier: String) throws -> Worker {
        if let id = UUID(uuidString: identifier), let worker = backing.configuration.workers.first(where: { $0.id == id }) { return worker }
        let matches = backing.configuration.workers.filter { $0.name == identifier }
        guard !matches.isEmpty else {
            throw WorkjetCLIError(code: "worker_not_found", message: "Kein Worker mit dieser UUID oder diesem exakten Namen gefunden.", exitCode: .notFound)
        }
        guard matches.count == 1 else {
            throw WorkjetCLIError(code: "worker_ambiguous", message: "Mehrere Worker haben diesen exakten Namen; verwende die UUID.", exitCode: .ambiguous)
        }
        return matches[0]
    }

    private func resolveComputer(_ identifier: String) throws -> Computer {
        if let id = UUID(uuidString: identifier), let computer = backing.configuration.computers.first(where: { $0.id == id }) { return computer }
        let matches = backing.configuration.computers.filter { $0.name == identifier }
        guard !matches.isEmpty else {
            throw WorkjetCLIError(code: "computer_not_found", message: "Kein Computer mit dieser UUID oder diesem exakten Namen gefunden.", exitCode: .notFound)
        }
        guard matches.count == 1 else {
            throw WorkjetCLIError(code: "computer_ambiguous", message: "Mehrere Computer haben diesen exakten Namen; verwende die UUID.", exitCode: .ambiguous)
        }
        return matches[0]
    }

    private func resolveProviderRoute(worker: Worker, target: ProviderRuntimeTarget) throws -> ResolvedProviderRuntimeRoute {
        do { return try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: backing.configuration.providers, target: target) }
        catch {
            throw WorkjetCLIError(code: "provider_route_unavailable", message: error.localizedDescription, exitCode: .state)
        }
    }

    private func locateOwnedRun(_ runID: String) async throws -> (computer: Computer, descriptor: RemoteHostRunDescriptor) {
        var found: [(Computer, RemoteHostRunDescriptor)] = []
        var attempted = 0
        var failures: [Error] = []
        for computer in backing.configuration.computers where !computer.isLocal && computer.deploymentStatus == .installed && computer.installedSidecarVersion == PiSidecarRuntime.version {
            let owners = backing.configuration.workers.filter { $0.computerID == computer.id }.map { ownerID($0.id) }
            for owner in owners {
                attempted += 1
                let response: RemoteHostResponse
                do { response = try await backing.list(computer: computer, ownerID: owner) }
                catch { failures.append(error); continue }
                found += response.runs.filter { $0.runID == runID && $0.ownerID == owner }.map { (computer, $0) }
            }
        }
        if found.isEmpty, attempted > 0, failures.count == attempted {
            throw WorkjetCLIError(code: "remote_transport", message: "Kein eingerichteter Remote-Computer war erreichbar.", exitCode: .transport)
        }
        guard found.count == 1, let match = found.first else {
            let code = found.isEmpty ? "run_not_found" : "run_ambiguous"
            let exit: WorkjetCLIExitCode = found.isEmpty ? .notFound : .ambiguous
            throw WorkjetCLIError(code: code, message: found.isEmpty ? "Der Run wurde auf keinem eingerichteten Computer gefunden." : "Die Run-ID ist auf mehreren Computern vorhanden.", exitCode: exit)
        }
        let ownedIDs = Set(backing.configuration.workers.map { ownerID($0.id) })
        guard let owner = match.1.ownerID, ownedIDs.contains(owner) else {
            throw WorkjetCLIError(code: "run_not_owned", message: "Der Run gehört keinem konfigurierten Workjet-Worker.", exitCode: .rejected)
        }
        return (match.0, match.1)
    }

    private func presentation(_ worker: Worker, includeInstructions: Bool = true) -> WorkjetCLIWorker {
        let computer = backing.configuration.computers.first(where: { $0.id == worker.computerID })
        return WorkjetCLIWorker(id: worker.id, name: worker.name, harness: worker.harness.rawValue, model: worker.model, reasoning: worker.reasoningEffort?.rawValue, computerID: worker.computerID, computerName: computer?.name ?? "Unbekannt", remote: computer?.isLocal == false, instructions: includeInstructions && !worker.instructions.isEmpty ? worker.instructions : nil)
    }

    private func ownerID(_ workerID: UUID) -> String {
        "workjet-worker-\(workerID.uuidString.lowercased())"
    }

    private func translateRemoteErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as WorkjetCLIError { throw error }
        catch let error as RemoteHostProtocolError {
            switch error {
            case .transport:
                throw WorkjetCLIError(code: "remote_transport", message: error.localizedDescription, exitCode: .transport)
            case .computerNotInstalled:
                throw WorkjetCLIError(code: "computer_not_ready", message: error.localizedDescription, exitCode: .state)
            default:
                throw WorkjetCLIError(code: "remote_rejected", message: error.localizedDescription, exitCode: .rejected)
            }
        } catch {
            throw WorkjetCLIError(code: "remote_failed", message: error.localizedDescription, exitCode: .rejected)
        }
    }

    private func translateWorkspaceErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as WorkjetCLIError { throw error }
        catch let error as WorkspaceResultError {
            let notFound = error == .recordNotFound
            let state = error == .localPersistenceAfterRemoteCleanup
            throw WorkjetCLIError(code: state ? "workspace_partial" : (notFound ? "run_not_found" : "workspace_rejected"), message: error.localizedDescription, exitCode: state ? .state : (notFound ? .notFound : .rejected))
        } catch let error as RemoteHostProtocolError {
            if case .transport = error { throw WorkjetCLIError(code: "remote_transport", message: error.localizedDescription, exitCode: .transport) }
            throw WorkjetCLIError(code: "remote_rejected", message: error.localizedDescription, exitCode: .rejected)
        } catch {
            throw WorkjetCLIError(code: "workspace_failed", message: error.localizedDescription, exitCode: .rejected)
        }
    }

    private func translateLocalErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as WorkjetCLIError { throw error }
        catch let error as StopError {
            throw WorkjetCLIError(code: "local_stop_rejected", message: error.localizedDescription, exitCode: .rejected)
        } catch {
            throw WorkjetCLIError(code: "local_run_failed", message: error.localizedDescription, exitCode: .rejected)
        }
    }
}

// MARK: - Safe local CLI run service

public struct LocalWorkspaceContext: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var repositoryIdentity: GitRepositoryIdentity
    public var computerID: UUID
    public var ownerID: String

    public init(snapshot: WorkspaceSnapshot, repositoryIdentity: GitRepositoryIdentity, computerID: UUID, ownerID: String) {
        self.snapshot = snapshot
        self.repositoryIdentity = repositoryIdentity
        self.computerID = computerID
        self.ownerID = ownerID
    }
}

public struct LocalRunService: Sendable {
    private struct LaunchSpec: Codable {
        var executable: String
        var arguments: [String]
        var workerID: UUID
        var workerName: String
        var model: String
        var reasoning: String?
        var speed: String
        var harness: Harness
        var route: ResolvedProviderRuntimeRoute
        var systemPrompt: String?
        var skillIDs: [String]
        var currentDirectory: String?
        var workspaceRepoID: String?
        var snapshotCommitOID: String?
        var turnTimeoutSeconds: Double?
    }

    private struct Snapshot: Codable {
        var schemaVersion = 1
        var sequence: UInt64
        var state: String
        var heartbeatAt: String
        var model: String?
        var reasoning: String?
        var speed: String?
        var providerRoute: String?
    }

    private struct RecordedProcessIdentity: Codable {
        var pid: Int32
        var executablePath: String
        var startToken: String
    }

    public let paths: WorkjetPaths
    public let processProbe: any ProcessProbing
    public let credentials: any CredentialStoring
    public let gatewayCredentials: any CredentialStoring

    public init(
        paths: WorkjetPaths,
        processProbe: any ProcessProbing = SystemProcessProbe(),
        credentials: any CredentialStoring = PrivateFileCredentialStore(),
        gatewayCredentials: any CredentialStoring = CLIProxyGatewayCredentialStore()
    ) {
        self.paths = paths
        self.processProbe = processProbe
        self.credentials = credentials
        self.gatewayCredentials = gatewayCredentials
    }

    public func start(worker: Worker, brief: Data, supervisorExecutable: URL) throws -> RemoteHostResponse {
        let route = ResolvedProviderRuntimeRoute(displayName: "Ohne Anbieter", candidates: [
            ProviderRuntimeCandidate(kind: .directAccount, providerID: nil, modelProvider: nil, displayName: "Ohne Anbieter", endpoint: "http://127.0.0.1", authentication: .none, credentialReference: nil)
        ])
        return try start(worker: worker, route: route, brief: brief, systemPrompt: nil, skillIDs: [], supervisorExecutable: supervisorExecutable)
    }

    public func start(worker: Worker, route: ResolvedProviderRuntimeRoute, brief: Data, systemPrompt: String? = nil, skillIDs: Set<String> = [], workspace: LocalWorkspaceContext? = nil, turnTimeoutSeconds: Double = 3_600, supervisorExecutable: URL) throws -> RemoteHostResponse {
        guard let briefText = String(data: brief, encoding: .utf8), !briefText.isEmpty else {
            throw WorkjetCLIError(code: "brief_invalid", message: "Der lokale Brief muss gültiger, nicht leerer UTF-8-Text sein.", exitCode: .usage)
        }
        guard HarnessAdapterRegistry.supportsLocalExecution(worker.harness) else {
            throw WorkjetCLIError(code: "harness_unsupported", message: "Dieses Harness besitzt noch keine verifizierte lokale One-Shot-Schnittstelle.", exitCode: .state)
        }
        let executable = try validatedExecutable(worker.invocation.executable, purpose: "Worker-Harness")
        let placeholders = worker.invocation.arguments.indices.filter { worker.invocation.arguments[$0] == "<WORKJET_BRIEF>" }
        guard placeholders.count == 1 else {
            throw WorkjetCLIError(code: "brief_contract_invalid", message: "Der lokale Worker muss genau einen eigenen <WORKJET_BRIEF>-Argumentplatzhalter besitzen.", exitCode: .state)
        }
        if let issue = HarnessAdapterRegistry.localInvocationIssue(harness: worker.harness, invocation: worker.invocation) {
            throw WorkjetCLIError(code: "harness_contract_invalid", message: issue, exitCode: .state)
        }
        if let systemPrompt {
            guard worker.harness == .claudeCode,
                  !systemPrompt.isEmpty,
                  systemPrompt.utf8.count <= 65_536,
                  !systemPrompt.contains("\0") else {
                throw WorkjetCLIError(code: "system_prompt_invalid", message: "Der Harness-System-Prompt ist für diesen Worker ungültig oder nicht unterstützt.", exitCode: .state)
            }
            guard HarnessAdapterRegistry.allowedTools(in: worker.invocation)?.contains("Bash") == true else {
                throw WorkjetCLIError(code: "skill_tool_missing", message: "Ein aktivierter Workjet-Skill benötigt Bash, aber das Claude-Code-Tool Bash ist für diesen Worker nicht freigegeben.", exitCode: .state)
            }
        }
        var arguments = worker.invocation.arguments
        arguments[placeholders[0]] = briefText
        let supervisor = try validatedExecutable(supervisorExecutable.path, purpose: "Workjet-Supervisor")
        var supervisorEnvironment: [String: String] = [:]
        for (index, candidate) in route.candidates.enumerated() {
            guard let reference = candidate.credentialReference else { continue }
            guard let secret = try credentialData(reference: reference), !secret.isEmpty else {
                throw WorkjetCLIError(code: "provider_credential_missing", message: ProviderRuntimeRouteError.credentialMissing(candidate.displayName).localizedDescription, exitCode: .state)
            }
            supervisorEnvironment[Self.supervisorSecretKey(index)] = secret.base64EncodedString()
        }
        let runID = "local-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ""))-\(UUID().uuidString.lowercased())"
        let directory = paths.runsDirectory.appendingPathComponent(runID, isDirectory: true)
        try createPrivateDirectory(paths.runsDirectory)
        try createPrivateDirectory(paths.runIndexDirectory)
        try createPrivateDirectory(directory)
        let currentDirectory: URL?
        if let workspace {
            currentDirectory = try materializeWorkspace(workspace, runID: runID, runDirectory: directory)
        } else {
            currentDirectory = nil
        }
        let normalizedTimeout = min(max(turnTimeoutSeconds, 1), 10_800)
        let spec = LaunchSpec(
            executable: executable.path,
            arguments: arguments,
            workerID: worker.id,
            workerName: worker.name,
            model: worker.model,
            reasoning: worker.reasoningEffort?.rawValue,
            speed: worker.invocation.options["fastMode"] == "true" ? RunSpeed.fast.rawValue : RunSpeed.normal.rawValue,
            harness: worker.harness,
            route: route,
            systemPrompt: systemPrompt,
            skillIDs: skillIDs.sorted(),
            currentDirectory: currentDirectory?.path,
            workspaceRepoID: workspace?.snapshot.manifest.repoID,
            snapshotCommitOID: workspace?.snapshot.manifest.snapshotCommitOID,
            turnTimeoutSeconds: normalizedTimeout
        )
        try AtomicFile.write(try JSONEncoder().encode(spec), to: directory.appendingPathComponent("launch.json"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((worker.id.uuidString.lowercased() + "\n").utf8), to: directory.appendingPathComponent("worker-id"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((executable.path + "\n").utf8), to: directory.appendingPathComponent("worker"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((directory.path + "\n").utf8), to: paths.runIndexDirectory.appendingPathComponent(runID), directoryMode: 0o700, fileMode: 0o600)
        try spawnDetached(executable: supervisor.path, arguments: ["__local-supervise", directory.path], additionalEnvironment: supervisorEnvironment)

        // Detached supervisors can be delayed by a busy host even though the
        // launch is healthy. Keep the handshake bounded, but allow enough time
        // for the child to publish its identity under normal system pressure.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path) {
                return RemoteHostResponse(ok: true, runID: runID, state: .running, cursor: 1)
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("rc").path) {
                let detail = (try? readEvents(directory).last(where: { $0.kind == "provider-error" })?.text)
                    ?? "Der lokale Worker konnte nicht sicher gestartet werden."
                throw WorkjetCLIError(code: "provider_runtime_unavailable", message: detail, exitCode: .state)
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw WorkjetCLIError(code: "local_start_failed", message: "Der lokale Worker konnte nicht sicher gestartet werden.", exitCode: .state)
    }

    public func events(runID: String, after: UInt64) throws -> RemoteHostResponse? {
        guard let directory = ownedRunDirectory(runID) else { return nil }
        let events = try readEvents(directory).filter { $0.sequence > after }
        let state = try readSnapshot(directory)?.state ?? (FileManager.default.fileExists(atPath: directory.appendingPathComponent("rc").path) ? "completed" : "unknown")
        return RemoteHostResponse(ok: true, runID: runID, state: RemoteHostRunState(rawValue: state) ?? .unknown, cursor: events.last?.sequence ?? after, events: events)
    }

    public func stop(runID: String) throws -> RemoteHostResponse? {
        guard let directory = ownedRunDirectory(runID) else { return nil }
        let store = RunTelemetryStore(paths: paths, processProbe: processProbe)
        guard let record = store.scan(workers: []).first(where: { $0.sourceRunID == runID }) else { return nil }
        guard let active = record.activeRun else {
            if record.state == .completed { throw StopError.runAlreadyFinished }
            throw StopError.pidMismatch
        }
        try store.stop(active)
        return RemoteHostResponse(ok: true, runID: runID, state: .stopped, cursor: try readSnapshot(directory)?.sequence ?? 0)
    }

    public func importResult(runID: String, importer: LocalWorkspaceResultImporter = LocalWorkspaceResultImporter()) async throws -> WorkspaceResultImportReceipt {
        var record = try RemoteWorkspaceRunStore(paths: paths).load(runID: runID)
        guard record.localWorktreePath != nil, record.localRepositoryPath != nil else { throw WorkspaceResultError.identityMismatch }
        guard record.lifecycle != .integrated, record.lifecycle != .abandoned else { throw WorkspaceResultError.dispositionConflict }
        let directory = try requiredOwnedRunDirectory(runID)
        let snapshot = try readSnapshot(directory)
        guard let terminalState = snapshot.flatMap({ RemoteHostRunState(rawValue: $0.state) }), terminalState.isTerminal else {
            throw WorkspaceResultError.runNotTerminal
        }
        let manifestData = try SecureFile.readRegularOwnedFile(at: directory.appendingPathComponent("result-manifest.json"), maximumBytes: 4_096)
        let bundle = try SecureFile.readRegularOwnedFile(at: directory.appendingPathComponent("result.bundle"), maximumBytes: LocalWorkspaceResultImporter.maximumBundleBytes)
        guard let manifest = try? JSONDecoder().decode(WorkspaceResultManifest.self, from: manifestData) else { throw WorkspaceResultError.resultMalformed }
        let receipt = try await importer.importResult(WorkspaceResult(manifest: manifest, bundle: bundle), for: record, temporaryRoot: paths.remoteWorkspaceImportsDirectory)
        record.lifecycle = .imported
        record.resultRef = receipt.resultRef
        record.resultCommitOID = receipt.resultCommitOID
        record.terminalState = terminalState
        try RemoteWorkspaceRunStore(paths: paths).save(record)
        return receipt
    }

    public func mark(runID: String, disposition: RemoteWorkspaceDisposition) throws -> WorkspaceLifecycleReceipt {
        let store = RemoteWorkspaceRunStore(paths: paths)
        var record = try store.load(runID: runID)
        guard record.localWorktreePath != nil, record.localRepositoryPath != nil else { throw WorkspaceResultError.identityMismatch }
        let target: RemoteWorkspaceLifecycle = disposition == .integrated ? .integrated : .abandoned
        if record.lifecycle == .integrated || record.lifecycle == .abandoned {
            guard record.lifecycle == target, let terminal = record.terminalState else { throw WorkspaceResultError.dispositionConflict }
            return WorkspaceLifecycleReceipt(runID: runID, lifecycle: target, resultRef: record.resultRef, resultCommitOID: record.resultCommitOID, terminalState: terminal)
        }
        let directory = try requiredOwnedRunDirectory(runID)
        guard let state = try readSnapshot(directory).flatMap({ RemoteHostRunState(rawValue: $0.state) }), state.isTerminal else {
            throw WorkspaceResultError.runNotTerminal
        }
        if disposition == .integrated {
            guard record.lifecycle == .imported,
                  record.resultRef == "refs/workjet/\(runID)",
                  record.resultCommitOID.map(GitRepositoryInspector.validOID) == true else {
                throw WorkspaceResultError.integratedBeforeImport
            }
        }
        try cleanupLocalWorktree(record)
        record.lifecycle = target
        record.terminalState = state
        try store.save(record)
        return WorkspaceLifecycleReceipt(runID: runID, lifecycle: target, resultRef: record.resultRef, resultCommitOID: record.resultCommitOID, terminalState: state)
    }

    public func supervise(runDirectory: URL) throws {
        let directory = runDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == paths.runsDirectory.standardizedFileURL,
              isOwnedDirectory(directory) else { throw LocalStateError.insecurePath(directory.path) }
        let specData = try SecureFile.readRegularOwnedFile(at: directory.appendingPathComponent("launch.json"), maximumBytes: 1_048_576)
        let spec = try JSONDecoder().decode(LaunchSpec.self, from: specData)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("launch.json"))
        let executable = try validatedExecutable(spec.executable, purpose: "Worker-Harness")
        guard !spec.arguments.contains("<WORKJET_BRIEF>") else {
            throw WorkjetCLIError(code: "brief_contract_invalid", message: "Der Brief-Platzhalter wurde nicht ersetzt.", exitCode: .state)
        }

        var finalExitCode: Int32 = 1
        var sequence: UInt64 = 0
        for (candidateIndex, candidate) in spec.route.candidates.enumerated() {
            let environment: [String: String]
            do {
                environment = try runtimeEnvironment(candidate: candidate, candidateIndex: candidateIndex, spec: spec)
            } catch {
                finalExitCode = 78
                sequence += 1
                try appendEvent(RemoteHostEvent(
                    sequence: sequence,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    kind: "provider-error",
                    text: "\(candidate.displayName): \(error.localizedDescription)",
                    exitCode: finalExitCode
                ), directory: directory)
                if candidateIndex + 1 < spec.route.candidates.count { continue }
                break
            }
            let spawned = try spawnSuspended(
                executable: executable.path,
                arguments: effectiveArguments(spec, candidate: candidate),
                environment: environment,
                currentDirectory: spec.currentDirectory
            )
            let pid = spawned.pid
        let deadline = Date().addingTimeInterval(2)
        var identity: ProcessIdentity?
        repeat {
            identity = processProbe.identity(for: pid)
            if identity == nil { Thread.sleep(forTimeInterval: 0.01) }
        } while identity == nil && Date() < deadline
        guard let identity else {
            kill(pid, SIGKILL)
            throw LocalStateError.io("Die Prozessidentität konnte nicht bestätigt werden.")
        }
        let started = Date(timeIntervalSince1970: Double(identity.startToken) ?? Date().timeIntervalSince1970)
        let recordedIdentity = RecordedProcessIdentity(pid: identity.pid, executablePath: identity.executablePath, startToken: identity.startToken)
        try AtomicFile.write(try JSONEncoder().encode(recordedIdentity), to: directory.appendingPathComponent("process-identity.json"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((ISO8601DateFormatter().string(from: started) + "\n").utf8), to: directory.appendingPathComponent("started-at"), directoryMode: 0o700, fileMode: 0o600)
        sequence += 1
        try appendEvent(RemoteHostEvent(sequence: sequence, timestamp: ISO8601DateFormatter().string(from: Date()), kind: "lifecycle", text: "started"), directory: directory)
        try writeSnapshot(Snapshot(sequence: sequence, state: "running", heartbeatAt: ISO8601DateFormatter().string(from: Date()), model: spec.model, reasoning: spec.reasoning, speed: spec.speed, providerRoute: candidate.displayName), directory: directory)
        // The PID is the start() handshake. Publish it only after identity,
        // start time, lifecycle event, and effective run metadata are durable.
        try AtomicFile.write(Data("\(pid)\n".utf8), to: directory.appendingPathComponent("pid"), directoryMode: 0o700, fileMode: 0o600)
        guard kill(pid, SIGCONT) == 0 else { throw LocalStateError.io("Der lokale Worker konnte nicht fortgesetzt werden.") }
        var waitStatus: Int32 = 0
        var diagnostic = Data()
        let turnDeadline = Date().addingTimeInterval(spec.turnTimeoutSeconds ?? 3_600)
        var timedOut = false
        var terminationSentAt: Date?
        while waitpid(pid, &waitStatus, WNOHANG) == 0 {
            try drainEvents(spawned.stdout, kind: "stdout", sequence: &sequence, directory: directory)
            try drainEvents(spawned.stderr, kind: "stderr", sequence: &sequence, directory: directory, diagnostic: &diagnostic)
            if !timedOut, Date() >= turnDeadline {
                timedOut = true
                finalExitCode = 124
                sequence += 1
                try appendEvent(RemoteHostEvent(
                    sequence: sequence,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    kind: "timeout",
                    text: "worker turn timed out after \(spec.turnTimeoutSeconds ?? 3_600) seconds",
                    exitCode: 124
                ), directory: directory)
                _ = kill(-pid, SIGTERM)
                terminationSentAt = Date()
            } else if timedOut, let terminationSentAt, Date().timeIntervalSince(terminationSentAt) >= 2.5 {
                _ = kill(-pid, SIGKILL)
            }
            try writeSnapshot(Snapshot(sequence: sequence, state: "running", heartbeatAt: ISO8601DateFormatter().string(from: Date()), model: spec.model, reasoning: spec.reasoning, speed: spec.speed, providerRoute: candidate.displayName), directory: directory)
            Thread.sleep(forTimeInterval: 0.05)
        }
        try drainEvents(spawned.stdout, kind: "stdout", sequence: &sequence, directory: directory)
        try drainEvents(spawned.stderr, kind: "stderr", sequence: &sequence, directory: directory, diagnostic: &diagnostic)
        close(spawned.stdout)
        close(spawned.stderr)
        let observedExitCode: Int32 = (waitStatus & 0x7f) == 0 ? ((waitStatus >> 8) & 0xff) : 128 + (waitStatus & 0x7f)
        let exitCode: Int32 = timedOut ? 124 : observedExitCode
        finalExitCode = exitCode
        if !timedOut, exitCode != 0, candidateIndex + 1 < spec.route.candidates.count,
           ProviderRuntimeFailureClass.classify(exitCode: exitCode, diagnostic: String(decoding: diagnostic, as: UTF8.self)) == .retryable {
            continue
        }
        break
        }
        var finalState = finalExitCode == 0 ? "completed" : "failed"
        if spec.currentDirectory != nil {
            do {
                try captureLocalWorkspaceResult(spec: spec, runID: directory.lastPathComponent, terminalState: RemoteHostRunState(rawValue: finalState) ?? .failed, runDirectory: directory)
            } catch {
                finalExitCode = 1
                finalState = "error"
                sequence += 1
                try appendEvent(RemoteHostEvent(sequence: sequence, timestamp: ISO8601DateFormatter().string(from: Date()), kind: "result-error", text: error.localizedDescription, exitCode: finalExitCode), directory: directory)
            }
        }
        sequence += 1
        try appendEvent(RemoteHostEvent(sequence: sequence, timestamp: ISO8601DateFormatter().string(from: Date()), kind: "lifecycle", text: finalState, exitCode: finalExitCode), directory: directory)
        try AtomicFile.write(Data("\(finalExitCode)\n".utf8), to: directory.appendingPathComponent("rc"), directoryMode: 0o700, fileMode: 0o600)
        try writeSnapshot(Snapshot(sequence: sequence, state: finalState, heartbeatAt: ISO8601DateFormatter().string(from: Date()), model: spec.model, reasoning: spec.reasoning, speed: spec.speed, providerRoute: spec.route.displayName), directory: directory)
    }

    private func materializeWorkspace(_ context: LocalWorkspaceContext, runID: String, runDirectory: URL) throws -> URL {
        let snapshot = context.snapshot
        let submodulePaths = snapshot.manifest.submodules.map(\.path)
        let submoduleRefs = snapshot.manifest.submodules.map(\.bundleRef)
        guard let sourceRoot = snapshot.sourceRepositoryRoot,
              snapshot.manifest.schemaVersion == (snapshot.manifest.submodules.isEmpty ? 1 : 2),
              snapshot.manifest.submodules.count <= 256,
              Set(submodulePaths).count == submodulePaths.count,
              Set(submoduleRefs).count == submoduleRefs.count,
              GitRepositoryInspector.validDigest(snapshot.manifest.repoID),
              GitRepositoryInspector.validOID(snapshot.manifest.snapshotCommitOID),
              snapshot.manifest.byteSize > 0,
              snapshot.manifest.byteSize <= GitWorkspaceSnapshotPreparer.maximumBundleBytes,
              snapshot.bundle.count == snapshot.manifest.byteSize,
              GitRepositoryInspector.sha256(snapshot.bundle) == snapshot.manifest.bundleSHA256 else {
            throw WorkspaceResultError.resultMismatch
        }
        try createPrivateDirectory(paths.localWorkspaceRepositoriesDirectory)
        try createPrivateDirectory(paths.localWorktreesDirectory)
        let repository = paths.localWorkspaceRepositoriesDirectory.appendingPathComponent("\(snapshot.manifest.repoID).git", isDirectory: true).standardizedFileURL
        if !FileManager.default.fileExists(atPath: repository.path) {
            try createPrivateDirectory(repository)
            _ = try runGit(["init", "--bare", repository.path], cwd: paths.localWorkspaceRepositoriesDirectory)
        }
        try requireOwnedDirectory(repository, beneath: paths.localWorkspaceRepositoriesDirectory)
        let repoWorktrees = paths.localWorktreesDirectory.appendingPathComponent(snapshot.manifest.repoID, isDirectory: true).standardizedFileURL
        try createPrivateDirectory(repoWorktrees)
        try requireOwnedDirectory(repoWorktrees, beneath: paths.localWorktreesDirectory)
        let worktree = repoWorktrees.appendingPathComponent(runID, isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: worktree.path) else { throw WorkspaceResultError.repositoryUnsafe }

        let bundle = runDirectory.appendingPathComponent("snapshot.bundle")
        try AtomicFile.write(snapshot.bundle, to: bundle, directoryMode: 0o700, fileMode: 0o600)
        let heads = try runGit(["bundle", "list-heads", bundle.path], cwd: sourceRoot)
        let advertisedHeads = Dictionary(uniqueKeysWithValues: heads.split(whereSeparator: \Character.isNewline).compactMap { line -> (String, String)? in
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            return fields.count == 2 ? (fields[1], fields[0]) : nil
        })
        guard let advertisedRef = advertisedHeads.first(where: { $0.value == snapshot.manifest.snapshotCommitOID && $0.key.hasPrefix("refs/workjet/input-") })?.key else {
            throw WorkspaceResultError.resultMismatch
        }
        guard snapshot.manifest.submodules.allSatisfy({ submodule in
            advertisedHeads[submodule.bundleRef] == submodule.commitOID
                && safeGitlinkPath(submodule.path)
                && GitRepositoryInspector.validOID(submodule.commitOID)
                && submodule.bundleRef.hasPrefix("refs/workjet/submodules/")
        }) else { throw WorkspaceResultError.resultMismatch }
        let snapshotRef = "refs/workjet/snapshots/\(runID)"
        var fetchArguments = ["--git-dir=\(repository.path)", "fetch", "--no-tags", bundle.path, "\(advertisedRef):\(snapshotRef)"]
        for (index, submodule) in snapshot.manifest.submodules.enumerated() {
            fetchArguments.append("\(submodule.bundleRef):refs/workjet/submodules/\(runID)/\(index)")
        }
        _ = try runGit(fetchArguments, cwd: paths.stateDirectory)
        let expectedGitlinks = Dictionary(uniqueKeysWithValues: snapshot.manifest.submodules.map { ($0.path, $0.commitOID) })
        guard try snapshotGitlinks(repository: repository, commitOID: snapshot.manifest.snapshotCommitOID) == expectedGitlinks else {
            throw WorkspaceResultError.resultMismatch
        }
        _ = try runGit(["--git-dir=\(repository.path)", "worktree", "add", "--detach", worktree.path, snapshot.manifest.snapshotCommitOID], cwd: paths.stateDirectory)
        try requireOwnedDirectory(worktree, beneath: repoWorktrees)
        do {
            try materializePinnedSubmodules(expectedGitlinks, repository: repository, worktree: worktree)
        } catch {
            try? removePinnedSubmodules(expectedGitlinks, repository: repository, worktree: worktree)
            _ = try? runGit(["--git-dir=\(repository.path)", "worktree", "remove", "--force", worktree.path], cwd: paths.stateDirectory)
            throw error
        }
        try? FileManager.default.removeItem(at: bundle)

        let record = RemoteWorkspaceRunRecord(
            runID: runID,
            sourceRepositoryRoot: sourceRoot.path,
            computerID: context.computerID,
            ownerID: context.ownerID,
            repoID: snapshot.manifest.repoID,
            snapshotCommitOID: snapshot.manifest.snapshotCommitOID,
            repositoryIdentity: context.repositoryIdentity,
            localWorktreePath: worktree.path,
            localRepositoryPath: repository.path
        )
        try RemoteWorkspaceRunStore(paths: paths).save(record)
        return worktree
    }

    private func captureLocalWorkspaceResult(spec: LaunchSpec, runID: String, terminalState: RemoteHostRunState, runDirectory: URL) throws {
        guard let worktreePath = spec.currentDirectory,
              let repoID = spec.workspaceRepoID,
              let snapshotOID = spec.snapshotCommitOID,
              GitRepositoryInspector.validDigest(repoID),
              GitRepositoryInspector.validOID(snapshotOID) else { throw WorkspaceResultError.invalidRecord }
        let repository = paths.localWorkspaceRepositoriesDirectory.appendingPathComponent("\(repoID).git", isDirectory: true).standardizedFileURL
        let repoWorktrees = paths.localWorktreesDirectory.appendingPathComponent(repoID, isDirectory: true).standardizedFileURL
        let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL
        guard worktree == repoWorktrees.appendingPathComponent(runID, isDirectory: true).standardizedFileURL else { throw WorkspaceResultError.repositoryUnsafe }
        try requireOwnedDirectory(repository, beneath: paths.localWorkspaceRepositoriesDirectory)
        try requireOwnedDirectory(worktree, beneath: repoWorktrees)
        let expectedGitlinks = try snapshotGitlinks(repository: repository, commitOID: snapshotOID)
        let currentIndexGitlinks = try stagedGitlinks(runGit(["ls-files", "--stage", "-z"], cwd: worktree))
        guard currentIndexGitlinks == expectedGitlinks else { throw WorkspaceResultError.submoduleChanged("gitlink") }
        try validatePinnedSubmodules(expectedGitlinks, repository: repository, worktree: worktree)
        _ = try runGit(["add", "-A", "--", "."], cwd: worktree)
        let staged = try runGit(["ls-files", "--stage", "-z"], cwd: worktree)
        guard try stagedGitlinks(staged) == expectedGitlinks,
              !staged.split(separator: "\0").contains(where: { $0.hasPrefix("120000 ") }) else {
            throw WorkspaceResultError.repositoryUnsafe
        }
        let tree = try runGit(["write-tree"], cwd: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitRepositoryInspector.validOID(tree) else { throw WorkspaceResultError.importFailed }
        let resultOID = try runGit(["commit-tree", tree, "-p", snapshotOID], cwd: worktree, input: Data("Workjet local result \(runID)\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitRepositoryInspector.validOID(resultOID) else { throw WorkspaceResultError.importFailed }
        let resultRef = "refs/workjet/results/\(runID)"
        _ = try runGit(["--git-dir=\(repository.path)", "update-ref", resultRef, resultOID], cwd: paths.stateDirectory)
        let bundleURL = runDirectory.appendingPathComponent("result.bundle")
        _ = try runGit(["--git-dir=\(repository.path)", "bundle", "create", bundleURL.path, resultRef], cwd: paths.stateDirectory)
        let bundle = try SecureFile.readRegularOwnedFile(at: bundleURL, maximumBytes: LocalWorkspaceResultImporter.maximumBundleBytes)
        let manifest = WorkspaceResultManifest(
            runID: runID,
            repoID: repoID,
            snapshotCommitOID: snapshotOID,
            resultCommitOID: resultOID,
            bundleSHA256: GitRepositoryInspector.sha256(bundle),
            byteSize: bundle.count,
            terminalState: terminalState
        )
        try AtomicFile.write(try JSONEncoder().encode(manifest), to: runDirectory.appendingPathComponent("result-manifest.json"), directoryMode: 0o700, fileMode: 0o600)
    }

    private func cleanupLocalWorktree(_ record: RemoteWorkspaceRunRecord) throws {
        guard let worktreePath = record.localWorktreePath, let repositoryPath = record.localRepositoryPath else { throw WorkspaceResultError.invalidRecord }
        let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL
        let expectedRepository = paths.localWorkspaceRepositoriesDirectory.appendingPathComponent("\(record.repoID).git", isDirectory: true).standardizedFileURL
        let repoWorktrees = paths.localWorktreesDirectory.appendingPathComponent(record.repoID, isDirectory: true).standardizedFileURL
        let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL
        let expectedWorktree = repoWorktrees.appendingPathComponent(record.runID, isDirectory: true).standardizedFileURL
        guard repository == expectedRepository, worktree == expectedWorktree else { throw WorkspaceResultError.repositoryUnsafe }
        try requireOwnedDirectory(repository, beneath: paths.localWorkspaceRepositoriesDirectory)
        try requireOwnedDirectory(repoWorktrees, beneath: paths.localWorktreesDirectory)
        if FileManager.default.fileExists(atPath: worktree.path) {
            try requireOwnedDirectory(worktree, beneath: repoWorktrees)
            let gitlinks = try snapshotGitlinks(repository: repository, commitOID: record.snapshotCommitOID)
            try removePinnedSubmodules(gitlinks, repository: repository, worktree: worktree)
            _ = try runGit(["--git-dir=\(repository.path)", "worktree", "remove", "--force", worktree.path], cwd: paths.stateDirectory)
            guard !FileManager.default.fileExists(atPath: worktree.path) else { throw WorkspaceResultError.repositoryUnsafe }
        }
    }

    private func safeGitlinkPath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && !value.hasPrefix("/") && !value.contains("\0")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private func snapshotGitlinks(repository: URL, commitOID: String) throws -> [String: String] {
        let listing = try runGit(["--git-dir=\(repository.path)", "ls-tree", "-r", "-z", "--full-tree", commitOID], cwd: paths.stateDirectory)
        var result: [String: String] = [:]
        for entry in listing.split(separator: "\0") {
            let fields = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw WorkspaceResultError.repositoryUnsafe }
            let metadata = fields[0].split(separator: " ")
            guard metadata.count == 3 else { throw WorkspaceResultError.repositoryUnsafe }
            if metadata[0] == "160000" {
                let path = String(fields[1]), oid = String(metadata[2])
                guard metadata[1] == "commit", safeGitlinkPath(path), GitRepositoryInspector.validOID(oid), result[path] == nil else {
                    throw WorkspaceResultError.repositoryUnsafe
                }
                result[path] = oid
            } else if metadata[0] == "120000" {
                throw WorkspaceResultError.repositoryUnsafe
            }
        }
        return result
    }

    private func stagedGitlinks(_ listing: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in listing.split(separator: "\0") where entry.hasPrefix("160000 ") {
            let fields = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let metadata = fields.first?.split(separator: " ") ?? []
            guard fields.count == 2, metadata.count == 3, metadata[0] == "160000", metadata[2] == "0" else {
                throw WorkspaceResultError.repositoryUnsafe
            }
            let path = String(fields[1]), oid = String(metadata[1])
            guard safeGitlinkPath(path), GitRepositoryInspector.validOID(oid), result[path] == nil else {
                throw WorkspaceResultError.repositoryUnsafe
            }
            result[path] = oid
        }
        return result
    }

    private func materializePinnedSubmodules(_ gitlinks: [String: String], repository: URL, worktree: URL) throws {
        for path in gitlinks.keys.sorted() {
            guard let oid = gitlinks[path], safeGitlinkPath(path) else { throw WorkspaceResultError.repositoryUnsafe }
            let destination = worktree.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            guard destination.path.hasPrefix(worktree.path + "/") else { throw WorkspaceResultError.repositoryUnsafe }
            if FileManager.default.fileExists(atPath: destination.path) {
                let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
                guard contents.isEmpty else { throw WorkspaceResultError.repositoryUnsafe }
                try FileManager.default.removeItem(at: destination)
            }
            _ = try runGit(["--git-dir=\(repository.path)", "worktree", "add", "--detach", destination.path, oid], cwd: paths.stateDirectory)
            try requireOwnedDirectory(destination, beneath: worktree)
            let head = try runGit(["rev-parse", "--verify", "HEAD^{commit}"], cwd: destination).trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == oid else { throw WorkspaceResultError.repositoryUnsafe }
        }
    }

    private func validatePinnedSubmodules(_ gitlinks: [String: String], repository: URL, worktree: URL) throws {
        for path in gitlinks.keys.sorted() {
            guard let oid = gitlinks[path], safeGitlinkPath(path) else { throw WorkspaceResultError.repositoryUnsafe }
            let submodule = worktree.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            guard submodule.path.hasPrefix(worktree.path + "/") else { throw WorkspaceResultError.repositoryUnsafe }
            try requireOwnedDirectory(submodule, beneath: worktree)
            var gitFileInfo = stat()
            guard lstat(submodule.appendingPathComponent(".git").path, &gitFileInfo) == 0,
                  (gitFileInfo.st_mode & S_IFMT) == S_IFREG, gitFileInfo.st_uid == geteuid() else {
                throw WorkspaceResultError.submoduleChanged(path)
            }
            let gitDirectoryText = try runGit(["rev-parse", "--absolute-git-dir"], cwd: submodule).trimmingCharacters(in: .whitespacesAndNewlines)
            let gitDirectory = URL(fileURLWithPath: gitDirectoryText, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let worktreeMetadataRoot = repository.appendingPathComponent("worktrees", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard gitDirectory.path.hasPrefix(worktreeMetadataRoot.path + "/") else { throw WorkspaceResultError.submoduleChanged(path) }
            try requireOwnedDirectory(gitDirectory, beneath: worktreeMetadataRoot)
            let head = try runGit(["rev-parse", "--verify", "HEAD^{commit}"], cwd: submodule).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: submodule)
            guard head == oid, status.isEmpty else { throw WorkspaceResultError.submoduleChanged(path) }
        }
    }

    private func removePinnedSubmodules(_ gitlinks: [String: String], repository: URL, worktree: URL) throws {
        for path in gitlinks.keys.sorted().reversed() {
            guard safeGitlinkPath(path) else { throw WorkspaceResultError.repositoryUnsafe }
            let submodule = worktree.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            guard submodule.path.hasPrefix(worktree.path + "/") else { throw WorkspaceResultError.repositoryUnsafe }
            if FileManager.default.fileExists(atPath: submodule.path) {
                try requireOwnedDirectory(submodule, beneath: worktree)
                _ = try runGit(["--git-dir=\(repository.path)", "worktree", "remove", "--force", submodule.path], cwd: paths.stateDirectory)
                guard !FileManager.default.fileExists(atPath: submodule.path) else { throw WorkspaceResultError.repositoryUnsafe }
            }
        }
    }

    private func requireOwnedDirectory(_ directory: URL, beneath parent: URL) throws {
        let value = directory.standardizedFileURL
        let root = parent.standardizedFileURL
        guard value.deletingLastPathComponent() == root || value.path.hasPrefix(root.path + "/") else { throw WorkspaceResultError.repositoryUnsafe }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedValue = value.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedValue.deletingLastPathComponent() == resolvedRoot || resolvedValue.path.hasPrefix(resolvedRoot.path + "/") else {
            throw WorkspaceResultError.repositoryUnsafe
        }
        let relativeComponents = value.path.dropFirst(root.path.count)
            .split(separator: "/", omittingEmptySubsequences: true)
        var candidates = [root]
        var candidate = root
        for component in relativeComponents {
            candidate.appendPathComponent(String(component), isDirectory: true)
            candidates.append(candidate)
        }
        for candidate in candidates {
            var info = stat()
            guard lstat(candidate.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else { throw WorkspaceResultError.repositoryUnsafe }
        }
    }

    @discardableResult
    private func runGit(_ arguments: [String], cwd: URL, input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = GitRepositoryInspector.gitEnvironment
        environment["GIT_AUTHOR_NAME"] = "Workjet Result"
        environment["GIT_AUTHOR_EMAIL"] = "result@workjet.invalid"
        environment["GIT_COMMITTER_NAME"] = "Workjet Result"
        environment["GIT_COMMITTER_EMAIL"] = "result@workjet.invalid"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard output.count <= 16 * 1_024 * 1_024, diagnostic.count <= 1_048_576,
              process.terminationStatus == 0 else { throw WorkspaceResultError.importFailed }
        return String(decoding: output, as: UTF8.self)
    }

    private func validatedExecutable(_ rawPath: String, purpose: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw WorkjetCLIError(code: "executable_invalid", message: "\(purpose): Der Pfad muss absolut sein (konfiguriert: \(rawPath)).", exitCode: .state)
        }
        // Homebrew and most harness installers expose stable symlinks in bin/.
        // Validate and launch the canonical target so a legitimate symlink is
        // neither rejected nor ambiguously reported as a non-regular file.
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var info = stat()
        let forbidden = ["sh", "bash", "zsh", "dash", "fish", "eval"]
        guard stat(url.path, &info) == 0 else {
            throw WorkjetCLIError(code: "executable_invalid", message: "\(purpose): Ausführbare Datei nicht gefunden (\(url.path)).", exitCode: .state)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw WorkjetCLIError(code: "executable_invalid", message: "\(purpose): Ziel ist keine reguläre Datei (\(url.path)).", exitCode: .state)
        }
        guard access(url.path, X_OK) == 0 else {
            throw WorkjetCLIError(code: "executable_invalid", message: "\(purpose): Datei ist nicht ausführbar (\(url.path)).", exitCode: .state)
        }
        guard !forbidden.contains(url.lastPathComponent) else {
            throw WorkjetCLIError(code: "executable_invalid", message: "\(purpose): Eine Shell darf nicht direkt als Harness konfiguriert werden (\(url.path)).", exitCode: .state)
        }
        return url
    }

    private func effectiveArguments(_ spec: LaunchSpec, candidate: ProviderRuntimeCandidate) -> [String] {
        var arguments = spec.arguments
        switch spec.harness {
        case .claudeCode:
            if let systemPrompt = spec.systemPrompt {
                arguments += ["--append-system-prompt", systemPrompt]
            }
            if !containsOption("--model", in: arguments) { arguments += ["--model", spec.model] }
            if let reasoning = spec.reasoning, !containsOption("--effort", in: arguments) {
                arguments += ["--effort", reasoning]
            }
            if spec.speed == RunSpeed.fast.rawValue {
                // `fastMode` is a documented Claude Code setting; passing it
                // through --settings makes speed effective for this one run
                // without mutating the user's global Claude configuration.
                arguments += ["--settings", #"{"fastMode":true,"fastModePerSessionOptIn":true}"#]
            }
        case .codexCLI:
            if spec.skillIDs.contains(WorkerSkillCatalog.webResearchID), !arguments.contains("--search") {
                arguments.insert("--search", at: 0)
            }
            if spec.skillIDs.contains(WorkerSkillCatalog.webResearchID), candidate.kind == .gatewayPool,
               let execIndex = arguments.firstIndex(of: "exec") {
                arguments.insert(contentsOf: Self.workjetCodexProviderArguments(endpoint: candidate.endpoint), at: execIndex)
            }
            if !containsOption("--model", short: "-m", in: arguments) { arguments += ["--model", spec.model] }
            if let reasoning = spec.reasoning, ["low", "medium", "high", "xhigh"].contains(reasoning) {
                arguments += ["-c", "model_reasoning_effort=\"\(reasoning)\""]
            }
        case .openCode:
            if !containsOption("--model", short: "-m", in: arguments) { arguments += ["--model", spec.model] }
            if let reasoning = spec.reasoning, !containsOption("--variant", in: arguments) {
                arguments += ["--variant", reasoning]
            }
        case .piSidecar, .cursorAgent, .grokCLI:
            break // rejected before launch by localInvocationIssue
        }
        return arguments
    }

    private static func workjetCodexProviderArguments(endpoint: String) -> [String] {
        let endpoint = webResearchBaseURL(endpoint)
        return [
            "-c", #"model_provider="workjet""#,
            "-c", #"model_providers.workjet.name="Workjet Web Research""#,
            "-c", #"model_providers.workjet.base_url="\#(endpoint)""#,
            "-c", #"model_providers.workjet.env_key="WORKJET_WEB_RESEARCH_API_KEY""#,
            "-c", #"model_providers.workjet.wire_api="responses""#,
            "-c", "model_providers.workjet.requires_openai_auth=false",
            "-c", "model_providers.workjet.supports_websockets=false",
            "-c", "model_providers.workjet.supports_standalone_web_search=true",
        ]
    }

    private static func webResearchBaseURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { components.path = "/v1" }
        return components.url?.absoluteString ?? raw
    }

    private func containsOption(_ long: String, short: String? = nil, in arguments: [String]) -> Bool {
        arguments.contains(long)
            || arguments.contains(where: { $0.hasPrefix(long + "=") })
            || short.map { arguments.contains($0) } == true
    }

    private func runtimeEnvironment(candidate: ProviderRuntimeCandidate, candidateIndex: Int, spec: LaunchSpec) throws -> [String: String] {
        var result = baseEnvironment()
        result["WORKJET_MODEL"] = spec.model
        result["WORKJET_REASONING"] = spec.reasoning ?? "automatic"
        result["WORKJET_SPEED"] = spec.speed
        result["WORKJET_PROVIDER_ROUTE"] = candidate.displayName
        result["WORKJET_PROVIDER_ENDPOINT"] = candidate.endpoint
        let secret: String?
        if let reference = candidate.credentialReference {
            let prefetched = ProcessInfo.processInfo.environment[Self.supervisorSecretKey(candidateIndex)]
                .flatMap { Data(base64Encoded: $0) }
            let resolvedData = try prefetched ?? credentialData(reference: reference)
            guard let data = resolvedData,
                  let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw ProviderRuntimeRouteError.credentialMissing(candidate.displayName)
            }
            secret = value
        } else {
            secret = nil
        }
        switch spec.harness {
        case .claudeCode, .piSidecar, .cursorAgent:
            result["ANTHROPIC_BASE_URL"] = candidate.endpoint
            if candidate.authentication == .apiKeyHeader { result["ANTHROPIC_API_KEY"] = secret }
            else if candidate.authentication == .bearerToken { result["ANTHROPIC_AUTH_TOKEN"] = secret }
        case .codexCLI, .openCode:
            result["OPENAI_BASE_URL"] = candidate.endpoint
            if candidate.authentication != .none { result["OPENAI_API_KEY"] = secret }
        case .grokCLI:
            result["XAI_BASE_URL"] = candidate.endpoint
            if candidate.authentication != .none { result["XAI_API_KEY"] = secret }
        }
        if spec.skillIDs.contains(WorkerSkillCatalog.webResearchID) {
            if candidate.kind == .gatewayPool {
                result["WORKJET_WEB_RESEARCH_BASE_URL"] = Self.webResearchBaseURL(candidate.endpoint)
                if candidate.authentication != .none { result["WORKJET_WEB_RESEARCH_API_KEY"] = secret }
                result["WORKJET_WEB_RESEARCH_BACKEND"] = "codex"
            } else if Self.localExecutable(named: "agy", environment: result) != nil {
                result["WORKJET_WEB_RESEARCH_BACKEND"] = "antigravity"
            } else {
                throw WorkjetCLIError(code: "skill_runtime_unavailable", message: "Für Web Research ist kein verifizierter Laufzeit-Backend verfügbar.", exitCode: .state)
            }
        }
        if spec.skillIDs.contains(WorkerSkillCatalog.greppyID) {
            result["GREPPY_STORE_DIR"] = paths.stateDirectory.appendingPathComponent("greppy", isDirectory: true).path
        }
        return result
    }

    private static func localExecutable(named command: String, environment: [String: String]) -> String? {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return LiveWorkjetCLIBacking.resolvedExecutable(named: command, environment: environment, currentDirectory: current)
    }

    func credentialData(reference: String) throws -> Data? {
        let credentialStore: any CredentialStoring = reference == CLIProxyGatewayCredentialStore.reference
            ? gatewayCredentials
            : credentials
        return try credentialStore.read(reference: reference)
    }

    private static func supervisorSecretKey(_ candidateIndex: Int) -> String {
        "WORKJET_SUPERVISOR_SECRET_\(candidateIndex)"
    }

    private func baseEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]
        var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in source[key].map { (key, $0) } })
        if result["PATH"] == nil { result["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        if result["HOME"] == nil { result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path }
        if result["TMPDIR"] == nil { result["TMPDIR"] = NSTemporaryDirectory() }
        return result
    }

    private func spawnDetached(executable: String, arguments: [String], additionalEnvironment: [String: String] = [:]) throws {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw LocalStateError.io("Startattribute konnten nicht erstellt werden.") }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LocalStateError.io("Startkanäle konnten nicht erstellt werden.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = [executable] + arguments
        let environment = baseEnvironment().merging(additionalEnvironment) { _, provided in provided }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let result = argv.withCStringArray { pointers in
            environment.withCStringArray { environmentPointers in
                var pid: pid_t = 0
                return posix_spawn(&pid, executable, &actions, &attributes, pointers, environmentPointers)
            }
        }
        guard result == 0 else { throw LocalStateError.io(String(cString: strerror(result))) }
    }

    private struct SpawnedProcess {
        var pid: pid_t
        var stdout: Int32
        var stderr: Int32
    }

    private func spawnSuspended(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?) throws -> SpawnedProcess {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw LocalStateError.io("Startattribute konnten nicht erstellt werden.") }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LocalStateError.io("Startkanäle konnten nicht erstellt werden.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let currentDirectory {
            guard currentDirectory.hasPrefix("/"), !currentDirectory.contains("\0"),
                  posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) == 0 else {
                throw LocalStateError.insecurePath(currentDirectory)
            }
        }
        var stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw LocalStateError.io("Ausgabekanal konnte nicht erstellt werden.") }
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw LocalStateError.io("Fehlerkanal konnte nicht erstellt werden.")
        }
        defer { close(stdoutPipe[1]); close(stderrPipe[1]) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[1])
        let argv = [executable] + arguments
        let environmentValues = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var child: pid_t = 0
        let result = argv.withCStringArray { pointers in
            environmentValues.withCStringArray { environmentPointers in
                posix_spawn(&child, executable, &actions, &attributes, pointers, environmentPointers)
            }
        }
        guard result == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw LocalStateError.io(String(cString: strerror(result)))
        }
        _ = fcntl(stdoutPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK)
        return SpawnedProcess(pid: child, stdout: stdoutPipe[0], stderr: stderrPipe[0])
    }

    private func drainEvents(
        _ descriptor: Int32,
        kind: String,
        sequence: inout UInt64,
        directory: URL,
        diagnostic: inout Data
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                if diagnostic.count + chunk.count > 65_536 {
                    diagnostic.removeFirst(min(diagnostic.count, diagnostic.count + chunk.count - 65_536))
                }
                diagnostic.append(chunk)
                sequence += 1
                try appendEvent(RemoteHostEvent(
                    sequence: sequence,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    kind: kind,
                    text: String(decoding: chunk, as: UTF8.self)
                ), directory: directory)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func drainEvents(_ descriptor: Int32, kind: String, sequence: inout UInt64, directory: URL) throws {
        var ignored = Data()
        try drainEvents(descriptor, kind: kind, sequence: &sequence, directory: directory, diagnostic: &ignored)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else { throw LocalStateError.insecurePath(url.path) }
        _ = chmod(url.path, 0o700)
        guard lstat(url.path, &info) == 0, (info.st_mode & 0o077) == 0 else { throw LocalStateError.insecurePath(url.path) }
    }

    private func ownedRunDirectory(_ runID: String) -> URL? {
        guard runID.hasPrefix("local-"), LocalWorkspaceResultImporter.safeRunID(runID) else { return nil }
        let directory = paths.runsDirectory.appendingPathComponent(runID, isDirectory: true).standardizedFileURL
        return directory.deletingLastPathComponent() == paths.runsDirectory.standardizedFileURL && isOwnedDirectory(directory) ? directory : nil
    }

    private func requiredOwnedRunDirectory(_ runID: String) throws -> URL {
        guard let directory = ownedRunDirectory(runID) else { throw WorkspaceResultError.recordNotFound }
        return directory
    }

    private func readSnapshot(_ directory: URL) throws -> Snapshot? {
        let url = directory.appendingPathComponent("run-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: SecureFile.readRegularOwnedFile(at: url, maximumBytes: 4_096))
    }

    private func writeSnapshot(_ snapshot: Snapshot, directory: URL) throws {
        try AtomicFile.write(try JSONEncoder().encode(snapshot), to: directory.appendingPathComponent("run-state.json"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((snapshot.heartbeatAt + "\n").utf8), to: directory.appendingPathComponent("heartbeat"), directoryMode: 0o700, fileMode: 0o600)
    }

    private func readEvents(_ directory: URL) throws -> [RemoteHostEvent] {
        let url = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try SecureFile.readRegularOwnedFile(at: url, maximumBytes: 262_144)
        return data.split(separator: 0x0a).compactMap { try? JSONDecoder().decode(RemoteHostEvent.self, from: Data($0)) }
    }

    private func appendEvent(_ event: RemoteHostEvent, directory: URL) throws {
        var events = try readEvents(directory)
        events.append(event)
        if events.count > 64 { events.removeFirst(events.count - 64) }
        let encoder = JSONEncoder()
        var data = Data()
        for item in events {
            data.append(try encoder.encode(item)); data.append(0x0a)
        }
        while data.count > 262_144, events.count > 1 {
            events.removeFirst(); data.removeAll(keepingCapacity: true)
            for item in events { data.append(try encoder.encode(item)); data.append(0x0a) }
        }
        try AtomicFile.write(data, to: directory.appendingPathComponent("events.jsonl"), directoryMode: 0o700, fileMode: 0o600)
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
    }
}

private extension Array where Element == String {
    func withCStringArray<Result>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
        let strings: [UnsafeMutablePointer<CChar>] = map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var pointers = strings.map { Optional($0) } + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
