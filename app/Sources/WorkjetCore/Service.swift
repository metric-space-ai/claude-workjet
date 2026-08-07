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
            for worker in workers {
                let harnessID = HarnessAdapterRegistry.descriptor(for: worker.harness).id
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

            let managedSkills = workers.flatMap(WorkerSkillCatalog.effectiveSkills(for:))
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
        if result.state == .missing {
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
            invocation: WorkerInvocation(executable: launch.harnessID, options: launch.options)
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
        try validateKnownHosts(computer.knownHostsPath)
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
            throw RemoteGatewayTunnelError.startFailed
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
            throw RemoteGatewayTunnelError.allocationUnconfirmed
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        let lease = RemoteGatewayTunnelLease(remotePort: remotePort, processIdentity: identity)
        lock.withLock { tunnels[lease.id] = ManagedTunnel(lease: lease, process: process, runID: nil) }
        return lease
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

    private func validateKnownHosts(_ path: String) throws {
        guard path.hasPrefix("/") else { throw RemoteGatewayTunnelError.missingKnownHosts }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
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
    private let persistenceBlock: Error?

    public init(configurationStore: any ConfigurationStoring, promptStore: any PromptSynchronizing, telemetryStore: any RunTelemetryReading, cliProxyInspector: CLIProxyInspector, providerInspector: ProviderInspector? = nil, credentialStore: any CredentialStoring, tailscaleDiscovery: TailscaleDeviceDiscovery = TailscaleDeviceDiscovery(), remoteBootstrap: RemotePiBootstrap = RemotePiBootstrap(), cliProxyAccounts: CLIProxyAccountAuthenticator? = nil, learningStore: AdHocLearningStore? = nil, workjetActivationStore: WorkjetActivationStore? = nil, harnessLifecycle: HarnessLifecycleCoordinator = HarnessLifecycleCoordinator(), remoteProvisioning: RemoteWorkerProvisioningCoordinator = RemoteWorkerProvisioningCoordinator(), gatewayTunnels: any RemoteGatewayTunnelManaging = RemoteGatewayTunnelManager(), workspaceSnapshots: any WorkspaceSnapshotPreparing = GitWorkspaceSnapshotPreparer(), workspaceRuns: RemoteWorkspaceRunStore = RemoteWorkspaceRunStore(), workspaceResultImporter: LocalWorkspaceResultImporter = LocalWorkspaceResultImporter(), persistenceBlock: Error? = nil) {
        self.configurationStore = configurationStore
        self.promptStore = promptStore
        self.telemetryStore = telemetryStore
        self.cliProxyInspector = cliProxyInspector
        self.providerInspector = providerInspector ?? ProviderInspector(credentials: credentialStore)
        self.gatewayProviderInspector = ProviderInspector(credentials: CLIProxyGatewayCredentialStore())
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
            return await gatewayProviderInspector.inspect(provider)
        }
        return await providerInspector.inspect(provider)
    }
    public func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount {
        try await cliProxyAccounts.authenticate(provider, credentialReference: credentialReference)
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
        let technicalRules = try configurationStore.load()?.technicalRules ?? ""
        let snapshot: WorkspaceSnapshot?
        if worker.harness == .piSidecar {
            snapshot = nil // Pi keeps its explicit in-memory turn request contract.
        } else {
            guard [.claudeCode, .codexCLI, .openCode].contains(worker.harness) else {
                throw RemoteHarnessAdapterError.unsupportedHarness(worker.harness.rawValue)
            }
            snapshot = try await workspaceSnapshots.prepare(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
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
            if tunnel != nil, !probe.capabilities.contains("gateway-relay-v1") {
                throw RemoteHostProtocolError.missingCapability("gateway-relay-v1")
            }
            var workspace: RemoteWorkspaceDescriptor?
            var launchInput = input
            if let snapshot {
                guard probe.capabilities.contains("workspace-git-v1") else {
                    throw RemoteHostProtocolError.missingCapability("workspace-git-v1")
                }
                workspace = try await client.importWorkspace(snapshot, verifiedCapabilities: probe.capabilities)
                // Skill instructions describe repository tools, so they are
                // injected only after this exact snapshot is safely present on
                // the host and the verified probe confirmed each target tool.
                launchInput = Self.preparedRemoteTaskInput(
                    worker: worker,
                    input: input,
                    workspaceImported: true,
                    verifiedCapabilities: probe.capabilities,
                    technicalRules: technicalRules
                )
            }
            let response = try await client.start(worker: worker, input: launchInput, providerExecution: execution, ownerID: ownerID, workspace: workspace, verifiedCapabilities: probe.capabilities)
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

    static func preparedRemoteTaskInput(
        worker: Worker,
        input: Data,
        workspaceImported: Bool,
        verifiedCapabilities: [String],
        technicalRules: String
    ) -> Data {
        WorkerSkillCatalog.taskInput(
            for: worker,
            input: input,
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
        var response = try await client.list(ownerID: ownerID)
        for index in response.runs.indices {
            let descriptor = response.runs[index]
            if descriptor.state.isTerminal {
                gatewayTunnels.close(runID: descriptor.runID)
            } else if descriptor.relayID != nil,
                      (!gatewayTunnels.hasTunnel(for: descriptor.runID) || !gatewayTunnels.isAlive(runID: descriptor.runID)) {
                let lost = try await client.relayLost(runID: descriptor.runID)
                response.runs[index].state = lost.state
                response.runs[index].cursor = lost.cursor
                gatewayTunnels.close(runID: descriptor.runID)
            }
        }
        return response
    }
    public func adoptRemoteRun(on computer: Computer, runID: String, ownerID: String) async throws -> RemoteHostResponse {
        let client = RemoteHostClient(computer: computer)
        let listed = try await client.list(ownerID: ownerID)
        if let descriptor = listed.runs.first(where: { $0.runID == runID }),
           descriptor.relayID != nil,
           !gatewayTunnels.hasTunnel(for: runID) {
            return try await client.relayLost(runID: runID)
        }
        return try await client.adopt(runID: runID, ownerID: ownerID)
    }
    public func remoteEvents(on computer: Computer, runID: String, after sequence: UInt64) async throws -> RemoteHostResponse {
        let client = RemoteHostClient(computer: computer)
        let tunnelKnown = gatewayTunnels.hasTunnel(for: runID)
        let relayRequired: Bool
        if tunnelKnown {
            relayRequired = true
        } else {
            relayRequired = try await client.list().runs.first(where: { $0.runID == runID })?.relayID != nil
        }
        if relayRequired, (!tunnelKnown || !gatewayTunnels.isAlive(runID: runID)) {
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
        harnessLifecycle: HarnessLifecycleCoordinator = HarnessLifecycleCoordinator()
    ) -> WorkjetBootstrap {
        let configStore = JSONConfigurationStore(fileURL: paths.configurationFile)
        let promptStore = ManagedPromptStore(fileURL: paths.promptFile)
        let learningStore = AdHocLearningStore(fileURL: paths.learningsFile)
        let credentials = KeychainCredentialStore()
        var messages: [String] = []
        var block: Error?
        var configuration: WorkjetConfiguration
        var isFirstLaunch = false
        var configurationWasMigrated = false
        do {
            if let loaded = try configStore.load() {
                configuration = normalized(loaded)
                configurationWasMigrated = configuration != loaded
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
        let service = LocalWorkjetService(configurationStore: configStore, promptStore: promptStore, telemetryStore: RunTelemetryStore(paths: paths), cliProxyInspector: CLIProxyInspector(credentials: credentials), credentialStore: credentials, learningStore: learningStore, workjetActivationStore: WorkjetActivationStore(paths: paths), harnessLifecycle: harnessLifecycle, workspaceRuns: RemoteWorkspaceRunStore(paths: paths), persistenceBlock: block)
        let bootstrapMustPersist = isFirstLaunch
            || configurationWasMigrated
            || importedExternalIdentityChanged
            || handwrittenChanged
        if block == nil, bootstrapMustPersist {
            do { try service.save(configuration, handwrittenRulesChanged: handwrittenChanged) }
            catch { messages.append(error.localizedDescription) }
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
        value.skillRules = LegacyPromptMigration.removingKnownProgressBoardDefault(from: value.skillRules)
        for worker in value.workers {
            let name = ModelPromptCatalog.canonicalName(for: worker.model)
            if prompts[name] == nil, let defaultPrompt = ModelPromptCatalog.defaults[name] {
                prompts[name] = defaultPrompt
            }
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
        let legacyDetail = "Verbunden. Dieser Zugang kann von mehreren Workern verwendet werden."
        for index in configuration.providers.indices {
            guard configuration.providers[index].kind.isLocalGateway,
                  configuration.providers[index].modelProvider?.usesWebLogin == true,
                  configuration.providers[index].status == .degraded,
                  configuration.providers[index].statusDetail == legacyDetail else { continue }
            configuration.providers[index].status = .connected
            configuration.providers[index].statusDetail = "Verbunden."
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

public struct WorkjetCLIEvent: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var timestamp: String
    public var kind: String
    public var text: String?
    public var exitCode: Int32?
}

public struct WorkjetCLIResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var command: String
    public var workers: [WorkjetCLIWorker]?
    public var worker: WorkjetCLIWorker?
    public var runID: String?
    public var state: String?
    public var cursor: UInt64?
    public var events: [WorkjetCLIEvent]?
    public var resultRef: String?
    public var resultOID: String?
    public var lifecycle: String?

    public init(ok: Bool = true, command: String, workers: [WorkjetCLIWorker]? = nil, worker: WorkjetCLIWorker? = nil, runID: String? = nil, state: String? = nil, cursor: UInt64? = nil, events: [WorkjetCLIEvent]? = nil, resultRef: String? = nil, resultOID: String? = nil, lifecycle: String? = nil) {
        self.ok = ok
        self.command = command
        self.workers = workers
        self.worker = worker
        self.runID = runID
        self.state = state
        self.cursor = cursor
        self.events = events
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
}

public struct LiveWorkjetCLIBacking: WorkjetCLIBacking, @unchecked Sendable {
    public let configuration: WorkjetConfiguration
    private let service: any WorkjetService
    private let localRuns: LocalRunService
    private let workspaceRuns: RemoteWorkspaceRunStore

    public init(paths: WorkjetPaths = .live) throws {
        let bootstrap = WorkjetBootstrap.live(paths: paths)
        guard bootstrap.messages.isEmpty else {
            throw WorkjetCLIError(code: "state_load_failed", message: bootstrap.messages.joined(separator: " "), exitCode: .state)
        }
        configuration = bootstrap.configuration
        service = bootstrap.service
        localRuns = LocalRunService(paths: paths)
        workspaceRuns = RemoteWorkspaceRunStore(paths: paths)
    }

    public func startLocal(worker: Worker, brief: Data) async throws -> RemoteHostResponse {
        let route = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: configuration.providers, target: .local)
        return try await startLocal(worker: worker, route: route, brief: brief)
    }
    public func startLocal(worker: Worker, route: ResolvedProviderRuntimeRoute, brief: Data) async throws -> RemoteHostResponse {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let repositoryAvailable = await Self.repositoryAvailable(at: currentDirectory)
        let availableSkillIDs = repositoryAvailable
            ? await Self.availableLocalSkillIDs(at: currentDirectory)
            : []
        let taskInput = Self.preparedLocalTaskInput(
            worker: worker,
            brief: brief,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: configuration.technicalRules ?? ""
        )
        return try localRuns.start(worker: worker, route: route, brief: taskInput, supervisorExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    }

    static func preparedLocalTaskInput(
        worker: Worker,
        brief: Data,
        repositoryAvailable: Bool,
        availableSkillIDs: Set<String>,
        technicalRules: String
    ) -> Data {
        WorkerSkillCatalog.taskInput(
            for: worker,
            input: brief,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: technicalRules
        )
    }

    static func availableLocalSkillIDs(
        at directory: URL,
        runner: any CommandRunning = ProcessCommandRunner(),
        sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Set<String> {
        let environment = localSkillProbeEnvironment(sourceEnvironment)
        guard let executable = resolvedExecutable(
            named: WorkerSkillCatalog.greppyID,
            environment: environment,
            currentDirectory: directory
        ) else { return [] }
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
            guard result.exitCode == 0, !result.stdoutTruncated, !result.stderrTruncated else { return [] }
            return [WorkerSkillCatalog.greppyID]
        } catch {
            return []
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
        try await service.startRemoteWorker(worker, on: computer, route: route, input: brief, ownerID: ownerID)
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
        guard let computer = configuration.computers.first(where: { $0.id == record.computerID }), !computer.isLocal else { throw WorkspaceResultError.identityMismatch }
        return try await service.importRemoteWorkspaceResult(on: computer, runID: runID)
    }
    public func mark(runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt {
        let record = try workspaceRuns.load(runID: runID)
        guard let computer = configuration.computers.first(where: { $0.id == record.computerID }), !computer.isLocal else { throw WorkspaceResultError.identityMismatch }
        return try await service.markRemoteWorkspace(on: computer, runID: runID, disposition: disposition)
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
        case let .run(identifier, brief, _):
            let worker = try resolveWorker(identifier)
            guard let computer = backing.configuration.computers.first(where: { $0.id == worker.computerID }) else {
                throw WorkjetCLIError(code: "computer_not_found", message: "Der Ziel-Computer des Workers ist nicht konfiguriert.", exitCode: .state)
            }
            guard computer.isLocal || (computer.deploymentStatus == .installed && computer.installedSidecarVersion == PiSidecarRuntime.version) else {
                throw WorkjetCLIError(code: "computer_not_ready", message: "Der Ziel-Computer ist nicht vollständig eingerichtet.", exitCode: .state)
            }
            let input: Data
            switch brief {
            case let .inline(value): input = Data(value.utf8)
            case let .file(path):
                do { input = try readFile(path) }
                catch { throw WorkjetCLIError(code: "brief_unreadable", message: "Die Brief-Datei konnte nicht gelesen werden.", exitCode: .state) }
            }
            guard !input.isEmpty else { throw WorkjetCLIError.usage("Der Brief darf nicht leer sein.") }
            let response: RemoteHostResponse
            if computer.isLocal {
                let route = try resolveProviderRoute(worker: worker, target: .local)
                response = try await translateLocalErrors { try await backing.startLocal(worker: worker, route: route, brief: input) }
            } else {
                let route = try resolveProviderRoute(worker: worker, target: .remote)
                response = try await translateRemoteErrors {
                    try await backing.start(worker: worker, computer: computer, route: route, brief: input, ownerID: ownerID(worker.id))
                }
            }
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

    public init(paths: WorkjetPaths, processProbe: any ProcessProbing = SystemProcessProbe(), credentials: any CredentialStoring = KeychainCredentialStore()) {
        self.paths = paths
        self.processProbe = processProbe
        self.credentials = credentials
    }

    public func start(worker: Worker, brief: Data, supervisorExecutable: URL) throws -> RemoteHostResponse {
        let route = ResolvedProviderRuntimeRoute(displayName: "Ohne Anbieter", candidates: [
            ProviderRuntimeCandidate(kind: .directAccount, providerID: nil, modelProvider: nil, displayName: "Ohne Anbieter", endpoint: "http://127.0.0.1", authentication: .none, credentialReference: nil)
        ])
        return try start(worker: worker, route: route, brief: brief, supervisorExecutable: supervisorExecutable)
    }

    public func start(worker: Worker, route: ResolvedProviderRuntimeRoute, brief: Data, supervisorExecutable: URL) throws -> RemoteHostResponse {
        guard let briefText = String(data: brief, encoding: .utf8), !briefText.isEmpty else {
            throw WorkjetCLIError(code: "brief_invalid", message: "Der lokale Brief muss gültiger, nicht leerer UTF-8-Text sein.", exitCode: .usage)
        }
        guard HarnessAdapterRegistry.supportsLocalExecution(worker.harness) else {
            throw WorkjetCLIError(code: "harness_unsupported", message: "Dieses Harness besitzt noch keine verifizierte lokale One-Shot-Schnittstelle.", exitCode: .state)
        }
        let executable = try validatedExecutable(worker.invocation.executable)
        let placeholders = worker.invocation.arguments.indices.filter { worker.invocation.arguments[$0] == "<WORKJET_BRIEF>" }
        guard placeholders.count == 1 else {
            throw WorkjetCLIError(code: "brief_contract_invalid", message: "Der lokale Worker muss genau einen eigenen <WORKJET_BRIEF>-Argumentplatzhalter besitzen.", exitCode: .state)
        }
        if let issue = HarnessAdapterRegistry.localInvocationIssue(harness: worker.harness, invocation: worker.invocation) {
            throw WorkjetCLIError(code: "harness_contract_invalid", message: issue, exitCode: .state)
        }
        var arguments = worker.invocation.arguments
        arguments[placeholders[0]] = briefText
        let supervisor = try validatedExecutable(supervisorExecutable.path)
        let runID = "local-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ""))-\(UUID().uuidString.lowercased())"
        let directory = paths.runsDirectory.appendingPathComponent(runID, isDirectory: true)
        try createPrivateDirectory(paths.runsDirectory)
        try createPrivateDirectory(paths.runIndexDirectory)
        try createPrivateDirectory(directory)
        let spec = LaunchSpec(
            executable: executable.path,
            arguments: arguments,
            workerID: worker.id,
            workerName: worker.name,
            model: worker.model,
            reasoning: worker.reasoningEffort?.rawValue,
            speed: worker.invocation.options["fastMode"] == "true" ? RunSpeed.fast.rawValue : RunSpeed.normal.rawValue,
            harness: worker.harness,
            route: route
        )
        try AtomicFile.write(try JSONEncoder().encode(spec), to: directory.appendingPathComponent("launch.json"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((worker.id.uuidString.lowercased() + "\n").utf8), to: directory.appendingPathComponent("worker-id"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((executable.path + "\n").utf8), to: directory.appendingPathComponent("worker"), directoryMode: 0o700, fileMode: 0o600)
        try AtomicFile.write(Data((directory.path + "\n").utf8), to: paths.runIndexDirectory.appendingPathComponent(runID), directoryMode: 0o700, fileMode: 0o600)
        try spawnDetached(executable: supervisor.path, arguments: ["__local-supervise", directory.path])

        // Detached supervisors can be delayed by a busy host even though the
        // launch is healthy. Keep the handshake bounded, but allow enough time
        // for the child to publish its identity under normal system pressure.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path) {
                return RemoteHostResponse(ok: true, runID: runID, state: .running, cursor: 1)
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("rc").path) { break }
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

    public func supervise(runDirectory: URL) throws {
        let directory = runDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == paths.runsDirectory.standardizedFileURL,
              isOwnedDirectory(directory) else { throw LocalStateError.insecurePath(directory.path) }
        let specData = try SecureFile.readRegularOwnedFile(at: directory.appendingPathComponent("launch.json"), maximumBytes: 1_048_576)
        let spec = try JSONDecoder().decode(LaunchSpec.self, from: specData)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("launch.json"))
        let executable = try validatedExecutable(spec.executable)
        guard !spec.arguments.contains("<WORKJET_BRIEF>") else {
            throw WorkjetCLIError(code: "brief_contract_invalid", message: "Der Brief-Platzhalter wurde nicht ersetzt.", exitCode: .state)
        }

        var finalExitCode: Int32 = 1
        var sequence: UInt64 = 0
        for (candidateIndex, candidate) in spec.route.candidates.enumerated() {
            let environment: [String: String]
            do {
                environment = try runtimeEnvironment(candidate: candidate, spec: spec)
            } catch {
                finalExitCode = 78
                if candidateIndex + 1 < spec.route.candidates.count { continue }
                break
            }
            let spawned = try spawnSuspended(executable: executable.path, arguments: effectiveArguments(spec), environment: environment)
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
        while waitpid(pid, &waitStatus, WNOHANG) == 0 {
            drain(spawned.stderr, into: &diagnostic)
            try writeSnapshot(Snapshot(sequence: sequence, state: "running", heartbeatAt: ISO8601DateFormatter().string(from: Date()), model: spec.model, reasoning: spec.reasoning, speed: spec.speed, providerRoute: candidate.displayName), directory: directory)
            Thread.sleep(forTimeInterval: 0.25)
        }
        drain(spawned.stderr, into: &diagnostic)
        close(spawned.stderr)
        let exitCode: Int32 = (waitStatus & 0x7f) == 0 ? ((waitStatus >> 8) & 0xff) : 128 + (waitStatus & 0x7f)
        finalExitCode = exitCode
        if exitCode != 0, candidateIndex + 1 < spec.route.candidates.count,
           ProviderRuntimeFailureClass.classify(exitCode: exitCode, diagnostic: String(decoding: diagnostic, as: UTF8.self)) == .retryable {
            continue
        }
        break
        }
        sequence += 1
        let finalState = finalExitCode == 0 ? "completed" : "failed"
        try appendEvent(RemoteHostEvent(sequence: sequence, timestamp: ISO8601DateFormatter().string(from: Date()), kind: "lifecycle", text: finalState, exitCode: finalExitCode), directory: directory)
        try AtomicFile.write(Data("\(finalExitCode)\n".utf8), to: directory.appendingPathComponent("rc"), directoryMode: 0o700, fileMode: 0o600)
        try writeSnapshot(Snapshot(sequence: sequence, state: finalState, heartbeatAt: ISO8601DateFormatter().string(from: Date()), model: spec.model, reasoning: spec.reasoning, speed: spec.speed, providerRoute: spec.route.displayName), directory: directory)
    }

    private func validatedExecutable(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw WorkjetCLIError(code: "executable_invalid", message: "Die lokale ausführbare Datei muss als absoluter Pfad konfiguriert sein.", exitCode: .state)
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var info = stat()
        let forbidden = ["sh", "bash", "zsh", "dash", "fish", "eval"]
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(url.path, X_OK) == 0,
              !forbidden.contains(url.lastPathComponent) else {
            throw WorkjetCLIError(code: "executable_invalid", message: "Die lokale ausführbare Datei fehlt, ist nicht regulär oder nicht ausführbar.", exitCode: .state)
        }
        return url
    }

    private func effectiveArguments(_ spec: LaunchSpec) -> [String] {
        var arguments = spec.arguments
        switch spec.harness {
        case .claudeCode:
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

    private func containsOption(_ long: String, short: String? = nil, in arguments: [String]) -> Bool {
        arguments.contains(long)
            || arguments.contains(where: { $0.hasPrefix(long + "=") })
            || short.map { arguments.contains($0) } == true
    }

    private func runtimeEnvironment(candidate: ProviderRuntimeCandidate, spec: LaunchSpec) throws -> [String: String] {
        var result = baseEnvironment()
        result["WORKJET_MODEL"] = spec.model
        result["WORKJET_REASONING"] = spec.reasoning ?? "automatic"
        result["WORKJET_SPEED"] = spec.speed
        result["WORKJET_PROVIDER_ROUTE"] = candidate.displayName
        result["WORKJET_PROVIDER_ENDPOINT"] = candidate.endpoint
        let secret: String?
        if let reference = candidate.credentialReference {
            guard let data = try credentials.read(reference: reference),
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
        return result
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

    private func spawnDetached(executable: String, arguments: [String]) throws {
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
        let environment = baseEnvironment().map { "\($0.key)=\($0.value)" }.sorted()
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
        var stderr: Int32
    }

    private func spawnSuspended(executable: String, arguments: [String], environment: [String: String]) throws -> SpawnedProcess {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw LocalStateError.io("Startattribute konnten nicht erstellt werden.") }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LocalStateError.io("Startkanäle konnten nicht erstellt werden.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stderrPipe) == 0 else { throw LocalStateError.io("Fehlerkanal konnte nicht erstellt werden.") }
        defer { close(stderrPipe[1]) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
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
            close(stderrPipe[0])
            throw LocalStateError.io(String(cString: strerror(result)))
        }
        _ = fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK)
        return SpawnedProcess(pid: child, stderr: stderrPipe[0])
    }

    private func drain(_ descriptor: Int32, into data: inout Data) {
        guard data.count < 65_536 else { return }
        var buffer = [UInt8](repeating: 0, count: min(4_096, 65_536 - data.count))
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else { break }
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func ownedRunDirectory(_ runID: String) -> URL? {
        guard runID.hasPrefix("local-"), !runID.contains("/"), !runID.contains("..") else { return nil }
        let directory = paths.runsDirectory.appendingPathComponent(runID, isDirectory: true).standardizedFileURL
        return isOwnedDirectory(directory) ? directory : nil
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
