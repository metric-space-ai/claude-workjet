import CryptoKit
import Foundation

public enum RemoteHostOperation: String, Codable, Sendable {
    case probe, start, events, stop
    case relayLost = "relay-lost"
    case harnessInspect = "harness-inspect"
    case harnessInstall = "harness-install"
    case harnessUpdate = "harness-update"
    case harnessRemove = "harness-remove"
    case managedSkillInspect = "managed-skill-inspect"
    case managedSkillInstall = "managed-skill-install"
    case workspaceFinalize = "workspace-finalize"

    public var harnessAction: RemoteHarnessMaintenanceAction? {
        switch self {
        case .harnessInspect: return .inspect
        case .harnessInstall: return .install
        case .harnessUpdate: return .update
        case .harnessRemove: return .remove
        case .probe, .start, .events, .stop, .relayLost, .managedSkillInspect, .managedSkillInstall, .workspaceFinalize: return nil
        }
    }
}

public enum RemoteManagedSkillMaintenanceAction: String, Codable, Equatable, Sendable {
    case inspect, install

    public var operation: RemoteHostOperation {
        switch self {
        case .inspect: return .managedSkillInspect
        case .install: return .managedSkillInstall
        }
    }
}

public enum RemoteHarnessMaintenanceAction: String, Codable, Equatable, Sendable {
    case inspect, install, update, remove

    public var operation: RemoteHostOperation {
        switch self {
        case .inspect: return .harnessInspect
        case .install: return .harnessInstall
        case .update: return .harnessUpdate
        case .remove: return .harnessRemove
        }
    }
}

public enum RemoteHarnessLifecycleState: String, Codable, Equatable, Sendable {
    case installed, missing, broken, unavailable
}

public enum RemoteWorkspaceDisposition: String, Codable, Equatable, Sendable {
    case integrated, abandoned
}

public struct RemoteWorkspaceResultRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var ownerID: String
    public var repoID: String
    public var snapshotCommitOID: String

    public init(schemaVersion: Int = 1, runID: String, ownerID: String, repoID: String, snapshotCommitOID: String) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.ownerID = ownerID
        self.repoID = repoID
        self.snapshotCommitOID = snapshotCommitOID
    }
}

/// A server-observed lifecycle result. The client supplies only `harnessID` and
/// the typed operation; executable paths and argument vectors never cross the
/// protocol boundary.
public struct RemoteHarnessLifecycleResult: Codable, Equatable, Sendable {
    public var harnessID: String
    public var action: RemoteHarnessMaintenanceAction
    public var state: RemoteHarnessLifecycleState
    public var version: String?
    public var detail: String?

    public init(harnessID: String, action: RemoteHarnessMaintenanceAction, state: RemoteHarnessLifecycleState, version: String? = nil, detail: String? = nil) {
        self.harnessID = harnessID
        self.action = action
        self.state = state
        self.version = version
        self.detail = detail
    }
}

/// Server-observed state for a catalog skill. As with harness lifecycle, the
/// wire request contains only a catalog ID and a typed action.
public struct RemoteManagedSkillLifecycleResult: Codable, Equatable, Sendable {
    public var skillID: String
    public var action: RemoteManagedSkillMaintenanceAction
    public var state: RemoteHarnessLifecycleState
    public var version: String?
    public var detail: String?

    public init(skillID: String, action: RemoteManagedSkillMaintenanceAction, state: RemoteHarnessLifecycleState, version: String? = nil, detail: String? = nil) {
        self.skillID = skillID
        self.action = action
        self.state = state
        self.version = version
        self.detail = detail
    }
}

public enum RemoteHostProtocolVersion {
    public static let current = 2
    public static let supported = 1...2
}

public enum RemoteHostRunState: String, Codable, Equatable, Sendable {
    case unknown, starting, running, completed, failed, stopped, error

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped, .error: return true
        case .unknown, .starting, .running: return false
        }
    }
}

public struct RemoteHostEvent: Codable, Equatable, Sendable, Identifiable {
    public var sequence: UInt64
    public var timestamp: String
    public var kind: String
    public var text: String?
    public var exitCode: Int32?
    public var id: UInt64 { sequence }

    public init(sequence: UInt64, timestamp: String, kind: String, text: String? = nil, exitCode: Int32? = nil) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.exitCode = exitCode
    }
}

/// Non-secret execution facts accepted and persisted by the remote host.
///
/// Every value is optional because old host journals remain readable and the
/// app must never fill missing evidence from a worker's later configuration.
/// `workerID` is derived only from Workjet's deterministic owner ID unless a
/// future client supplies the same identity explicitly. `workerName` requires
/// an explicit start-time value; the host never guesses it.
public struct RemoteRunMetadata: Codable, Equatable, Sendable {
    public var workerID: UUID?
    public var workerName: String?
    public var harnessID: String?
    public var model: String?
    public var reasoning: String?
    public var speed: String?
    public var providerRoute: String?
    public var providerAccountLabel: String?
    public var startedAt: String?
    public var workspaceRepoID: String?
    public var workspaceCommitOID: String?
    public var workspaceRunID: String?

    public init(
        workerID: UUID? = nil,
        workerName: String? = nil,
        harnessID: String? = nil,
        model: String? = nil,
        reasoning: String? = nil,
        speed: String? = nil,
        providerRoute: String? = nil,
        providerAccountLabel: String? = nil,
        startedAt: String? = nil,
        workspaceRepoID: String? = nil,
        workspaceCommitOID: String? = nil,
        workspaceRunID: String? = nil
    ) {
        self.workerID = workerID
        self.workerName = workerName
        self.harnessID = harnessID
        self.model = model
        self.reasoning = reasoning
        self.speed = speed
        self.providerRoute = providerRoute
        self.providerAccountLabel = providerAccountLabel
        self.startedAt = startedAt
        self.workspaceRepoID = workspaceRepoID
        self.workspaceCommitOID = workspaceCommitOID
        self.workspaceRunID = workspaceRunID
    }
}

/// Provider execution data is carried only inside the encrypted remote request.
/// The host strips `secret` before persisting any launch metadata.
public struct RemoteProviderExecutionCandidate: Codable, Equatable, Sendable {
    public var kind: ProviderRuntimeCandidate.Kind
    public var providerID: UUID?
    public var modelProvider: ModelProvider?
    public var displayName: String
    public var endpoint: String
    public var authentication: ProviderAuthentication
    public var secret: String?
    public var relay: RemoteGatewayRelay?

    public init(kind: ProviderRuntimeCandidate.Kind, providerID: UUID?, modelProvider: ModelProvider?, displayName: String, endpoint: String, authentication: ProviderAuthentication, secret: String?, relay: RemoteGatewayRelay? = nil) {
        self.kind = kind
        self.providerID = providerID
        self.modelProvider = modelProvider
        self.displayName = displayName
        self.endpoint = endpoint
        self.authentication = authentication
        self.secret = secret
        self.relay = relay
    }
}

public struct RemoteGatewayRelay: Codable, Equatable, Sendable {
    public var id: UUID
    public var remotePort: Int
    public init(id: UUID, remotePort: Int) {
        self.id = id
        self.remotePort = remotePort
    }
}

public struct RemoteGatewayTunnelLease: Equatable, Sendable {
    public var id: UUID
    public var remotePort: Int
    public var processIdentity: ProcessIdentity
    public init(id: UUID = UUID(), remotePort: Int, processIdentity: ProcessIdentity) {
        self.id = id
        self.remotePort = remotePort
        self.processIdentity = processIdentity
    }
}

public protocol RemoteGatewayTunnelManaging: Sendable {
    func open(for computer: Computer) async throws -> RemoteGatewayTunnelLease
    func bind(_ lease: RemoteGatewayTunnelLease, to runID: String)
    func close(leaseID: UUID)
    func close(runID: String)
    func hasTunnel(for runID: String) -> Bool
    func isAlive(runID: String) -> Bool
}

public enum RemoteGatewayTunnelError: LocalizedError, Equatable, Sendable {
    case missingKnownHosts
    case invalidKnownHosts
    case startFailed(String)
    case allocationUnconfirmed(String)
    public var errorDescription: String? {
        switch self {
        case .missingKnownHosts, .invalidKnownHosts: return "Bestätige zuerst die Identität dieses Computers."
        case let .startFailed(detail), let .allocationUnconfirmed(detail):
            return "Der sichere Anbieter-Tunnel konnte nicht eingerichtet werden: \(detail)"
        }
    }
}

public enum RemoteGatewayTunnelCommandBuilder {
    public static func knownHostsPath(for computer: Computer) -> String {
        computer.usesManagedTailscaleSSH
            ? TailscaleSSHKnownHosts.path
            : computer.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func command(for computer: Computer) throws -> CommandSpec {
        try RemoteCommandBuilder.validate(computer)
        if computer.usesManagedTailscaleSSH, computer.port != 22 {
            throw RemotePiBootstrapError.tailscaleSSHRequiresPort22
        }
        let knownHosts = knownHostsPath(for: computer)
        guard knownHosts.hasPrefix("/") else { throw RemoteGatewayTunnelError.missingKnownHosts }
        var arguments = [
            "-v",
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes",
            "-o", try RemoteCommandBuilder.knownHostsOption(for: knownHosts),
            "-o", "ForwardAgent=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4"
        ]
        if computer.usesManagedTailscaleSSH {
            arguments += ["-o", "IdentitiesOnly=yes", "-o", "IdentityFile=none"]
        } else {
            arguments += try RemoteCommandBuilder.identityArguments(for: computer)
        }
        arguments += [
            "-p", String(computer.port),
            "-l", computer.user,
            "-R", "127.0.0.1:0:127.0.0.1:8317",
            "-T", "-N", "--", computer.host
        ]
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            timeout: 15,
            stdoutLimit: 0,
            stderrLimit: 65_536
        )
    }
}

public struct RemoteProviderExecution: Codable, Equatable, Sendable {
    public var displayName: String
    public var candidates: [RemoteProviderExecutionCandidate]

    public init(displayName: String, candidates: [RemoteProviderExecutionCandidate]) {
        self.displayName = displayName
        self.candidates = candidates
    }
}

public struct RemoteHostRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var operation: RemoteHostOperation
    public var runID: String?
    public var afterSequence: UInt64?
    public var launch: RemoteHarnessLaunch?
    public var ownerID: String?
    public var harnessID: String?
    public var skillID: String?
    public var providerExecution: RemoteProviderExecution?
    /// Optional start-time display name. The host accepts it only together
    /// with Workjet's deterministic owner identity and persists it as evidence.
    public var workerName: String?
    /// Worker turn deadline. Probe deadlines remain a separate client-side
    /// contract and health probes may omit this value.
    public var turnTimeoutSeconds: Int?
    public var workspaceDisposition: RemoteWorkspaceDisposition?
    /// v2 operations that older exhaustive app adapters must not be forced to
    /// understand. Encoding emits this value as the actual wire `operation`.
    public var wireOperation: String?

    public init(operation: RemoteHostOperation, runID: String? = nil, afterSequence: UInt64? = nil, launch: RemoteHarnessLaunch? = nil, ownerID: String? = nil, harnessID: String? = nil, skillID: String? = nil, providerExecution: RemoteProviderExecution? = nil, workerName: String? = nil, turnTimeoutSeconds: Int? = nil, workspaceDisposition: RemoteWorkspaceDisposition? = nil, protocolVersion: Int = RemoteHostProtocolVersion.current, wireOperation: String? = nil) {
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.runID = runID
        self.afterSequence = afterSequence
        self.launch = launch
        self.ownerID = ownerID
        self.harnessID = harnessID
        self.skillID = skillID
        self.providerExecution = providerExecution
        self.workerName = workerName
        self.turnTimeoutSeconds = turnTimeoutSeconds
        self.workspaceDisposition = workspaceDisposition
        self.wireOperation = wireOperation
    }

    public init(harnessID: String, action: RemoteHarnessMaintenanceAction) {
        self.init(operation: action.operation, harnessID: harnessID)
    }

    public init(skillID: String, action: RemoteManagedSkillMaintenanceAction) {
        self.init(operation: action.operation, skillID: skillID)
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, operation, runID, afterSequence, launch, ownerID, harnessID, skillID, providerExecution, workerName, turnTimeoutSeconds, workspaceDisposition }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        let wire = try values.decode(String.self, forKey: .operation)
        wireOperation = ["list", "adopt"].contains(wire) ? wire : nil
        operation = RemoteHostOperation(rawValue: wire) ?? (wire == "adopt" ? .events : .probe)
        runID = try values.decodeIfPresent(String.self, forKey: .runID)
        afterSequence = try values.decodeIfPresent(UInt64.self, forKey: .afterSequence)
        launch = try values.decodeIfPresent(RemoteHarnessLaunch.self, forKey: .launch)
        ownerID = try values.decodeIfPresent(String.self, forKey: .ownerID)
        harnessID = try values.decodeIfPresent(String.self, forKey: .harnessID)
        skillID = try values.decodeIfPresent(String.self, forKey: .skillID)
        providerExecution = try values.decodeIfPresent(RemoteProviderExecution.self, forKey: .providerExecution)
        workerName = try values.decodeIfPresent(String.self, forKey: .workerName)
        turnTimeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .turnTimeoutSeconds)
        workspaceDisposition = try values.decodeIfPresent(RemoteWorkspaceDisposition.self, forKey: .workspaceDisposition)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(wireOperation ?? operation.rawValue, forKey: .operation)
        try values.encodeIfPresent(runID, forKey: .runID)
        try values.encodeIfPresent(afterSequence, forKey: .afterSequence)
        try values.encodeIfPresent(launch, forKey: .launch)
        try values.encodeIfPresent(ownerID, forKey: .ownerID)
        try values.encodeIfPresent(harnessID, forKey: .harnessID)
        try values.encodeIfPresent(skillID, forKey: .skillID)
        try values.encodeIfPresent(providerExecution, forKey: .providerExecution)
        try values.encodeIfPresent(workerName, forKey: .workerName)
        try values.encodeIfPresent(turnTimeoutSeconds, forKey: .turnTimeoutSeconds)
        try values.encodeIfPresent(workspaceDisposition, forKey: .workspaceDisposition)
    }
}

public struct RemoteHostRunDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var runID: String
    public var state: RemoteHostRunState
    public var cursor: UInt64
    public var oldestSequence: UInt64?
    public var heartbeatAt: String?
    public var ownerID: String?
    /// Non-secret identity of the run-scoped reverse tunnel required by a
    /// gateway-backed run. The gateway token never appears in this descriptor.
    public var relayID: UUID?
    public var metadata: RemoteRunMetadata?
    public var id: String { runID }

    public init(runID: String, state: RemoteHostRunState, cursor: UInt64 = 0, oldestSequence: UInt64? = nil, heartbeatAt: String? = nil, ownerID: String? = nil, relayID: UUID? = nil, metadata: RemoteRunMetadata? = nil) {
        self.runID = runID
        self.state = state
        self.cursor = cursor
        self.oldestSequence = oldestSequence
        self.heartbeatAt = heartbeatAt
        self.ownerID = ownerID
        self.relayID = relayID
        self.metadata = metadata
    }
}

public struct RemoteHostResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var ok: Bool
    public var hostVersion: String?
    public var error: String?
    public var runID: String?
    public var state: RemoteHostRunState
    public var cursor: UInt64
    public var oldestSequence: UInt64?
    /// Run-liveness heartbeat emitted by a host that can actually observe the
    /// child process. A successful RPC is deliberately not treated as one.
    public var heartbeatAt: String?
    public var events: [RemoteHostEvent]
    public var capabilities: [String]
    public var runs: [RemoteHostRunDescriptor]
    /// Present when retention rotated past the requested cursor. The caller may
    /// resume at `oldestSequence - 1`; raw diagnostics before it are unavailable.
    public var gapAfterSequence: UInt64?
    public var harnessResult: RemoteHarnessLifecycleResult?
    public var managedSkillResult: RemoteManagedSkillLifecycleResult?
    public var metadata: RemoteRunMetadata?
    public var workspaceDisposition: RemoteWorkspaceDisposition?

    public init(protocolVersion: Int = RemoteHostProtocolVersion.current, ok: Bool, hostVersion: String? = nil, error: String? = nil, runID: String? = nil, state: RemoteHostRunState = .unknown, cursor: UInt64 = 0, oldestSequence: UInt64? = nil, heartbeatAt: String? = nil, events: [RemoteHostEvent] = [], capabilities: [String] = [], runs: [RemoteHostRunDescriptor] = [], gapAfterSequence: UInt64? = nil, harnessResult: RemoteHarnessLifecycleResult? = nil, managedSkillResult: RemoteManagedSkillLifecycleResult? = nil, metadata: RemoteRunMetadata? = nil, workspaceDisposition: RemoteWorkspaceDisposition? = nil) {
        self.protocolVersion = protocolVersion
        self.ok = ok
        self.hostVersion = hostVersion
        self.error = error
        self.runID = runID
        self.state = state
        self.cursor = cursor
        self.oldestSequence = oldestSequence
        self.heartbeatAt = heartbeatAt
        self.events = events
        self.capabilities = capabilities
        self.runs = runs
        self.gapAfterSequence = gapAfterSequence
        self.harnessResult = harnessResult
        self.managedSkillResult = managedSkillResult
        self.metadata = metadata
        self.workspaceDisposition = workspaceDisposition
    }


    private enum CodingKeys: String, CodingKey {
        case protocolVersion, ok, hostVersion, error, runID, state, cursor, oldestSequence, heartbeatAt, events, capabilities, runs, gapAfterSequence, harnessResult, managedSkillResult, metadata, workspaceDisposition
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        ok = try values.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        hostVersion = try values.decodeIfPresent(String.self, forKey: .hostVersion)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        runID = try values.decodeIfPresent(String.self, forKey: .runID)
        state = try values.decodeIfPresent(RemoteHostRunState.self, forKey: .state) ?? .unknown
        cursor = try values.decodeIfPresent(UInt64.self, forKey: .cursor) ?? 0
        oldestSequence = try values.decodeIfPresent(UInt64.self, forKey: .oldestSequence)
        heartbeatAt = try values.decodeIfPresent(String.self, forKey: .heartbeatAt)
        events = try values.decodeIfPresent([RemoteHostEvent].self, forKey: .events) ?? []
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        runs = try values.decodeIfPresent([RemoteHostRunDescriptor].self, forKey: .runs) ?? []
        gapAfterSequence = try values.decodeIfPresent(UInt64.self, forKey: .gapAfterSequence)
        harnessResult = try values.decodeIfPresent(RemoteHarnessLifecycleResult.self, forKey: .harnessResult)
        managedSkillResult = try values.decodeIfPresent(RemoteManagedSkillLifecycleResult.self, forKey: .managedSkillResult)
        metadata = try values.decodeIfPresent(RemoteRunMetadata.self, forKey: .metadata)
        workspaceDisposition = try values.decodeIfPresent(RemoteWorkspaceDisposition.self, forKey: .workspaceDisposition)
    }
}

public enum RemoteHostProtocolError: LocalizedError, Equatable {
    case computerNotInstalled
    case transport(String)
    case truncatedResponse
    case malformedResponse
    case incompatibleProtocol(Int)
    case rejected(String)
    case missingCapability(String)

    public var errorDescription: String? {
        switch self {
        case .computerNotInstalled: return "Richte Workjet zuerst auf diesem Computer ein."
        case .transport: return "Verbindung zum Computer fehlgeschlagen. Öffne den Computer, um sie zu prüfen."
        case .truncatedResponse, .malformedResponse:
            return "Aktivitätsdetails konnten nicht aktualisiert werden. Prüfe den Computer."
        case .incompatibleProtocol:
            return "Die Workjet-Komponente auf diesem Computer muss aktualisiert werden."
        case .rejected:
            return "Der Computer hat den Vorgang abgelehnt. Öffne den Computer, um ihn zu prüfen."
        case .missingCapability:
            return "Diese Funktion ist auf dem Computer nicht eingerichtet."
        }
    }
}

public struct RemoteLedgerSnapshot: Equatable, Sendable {
    public var runID: String?
    public var state: RemoteHostRunState
    public var cursor: UInt64
    public var events: [RemoteHostEvent]
    public var heartbeatAt: Date?
    public var lastError: String?
    public var metadata: RemoteRunMetadata?

    public init(runID: String?, state: RemoteHostRunState, cursor: UInt64, events: [RemoteHostEvent], heartbeatAt: Date?, lastError: String?, metadata: RemoteRunMetadata? = nil) {
        self.runID = runID
        self.state = state
        self.cursor = cursor
        self.events = events
        self.heartbeatAt = heartbeatAt
        self.lastError = lastError
        self.metadata = metadata
    }
}

public struct RemoteWorkerRun: Identifiable, Equatable, Sendable {
    public var workerID: UUID
    public var computerID: UUID
    public var runID: String
    public var state: RemoteHostRunState
    public var cursor: UInt64
    public var events: [RemoteHostEvent]
    public var heartbeatAt: Date?
    public var connectionError: String?
    public var metadata: RemoteRunMetadata?
    public var id: String { runID }

    public init(workerID: UUID, computerID: UUID, snapshot: RemoteLedgerSnapshot, connectionError: String? = nil) throws {
        guard let runID = snapshot.runID, !runID.isEmpty else { throw RemoteRunLedgerError.missingRunID }
        self.workerID = workerID
        self.computerID = computerID
        self.runID = runID
        self.state = snapshot.state
        self.cursor = snapshot.cursor
        self.events = snapshot.events
        self.heartbeatAt = snapshot.heartbeatAt
        self.connectionError = connectionError ?? snapshot.lastError
        self.metadata = snapshot.metadata
    }
}

public protocol RemoteHostCalling: Sendable {
    func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse
}

public struct RemoteHostClient: RemoteHostCalling, Sendable {
    public let computer: Computer
    public let runner: any CommandRunning
    public let tailscaleLocator: any TailscaleLocating

    public init(computer: Computer, runner: any CommandRunning = ProcessCommandRunner(), tailscaleLocator: any TailscaleLocating = AllowlistedTailscaleLocator()) {
        self.computer = computer
        self.runner = runner
        self.tailscaleLocator = tailscaleLocator
    }

    public func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
        guard computer.deploymentStatus == .installed,
              computer.installedSidecarVersion == PiSidecarRuntime.version else {
            throw RemoteHostProtocolError.computerNotInstalled
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0a)
        let tailscale = computer.transport == .tailscale ? (computer.tailscaleExecutablePath ?? tailscaleLocator.executablePath()) : nil
        let timeout: TimeInterval
        switch request.operation {
        case .events: timeout = 15
        case .harnessInstall, .harnessUpdate, .harnessRemove: timeout = 330
        // The remote Greppy install performs a clean, pinned CUDA build and a
        // real runtime probe. Keep the SSH request alive beyond the host-side
        // one-hour build ceiling so the caller receives its typed result.
        case .managedSkillInstall: timeout = 3_900
        default: timeout = 30
        }
        let command = try RemoteCommandBuilder.command(
            for: computer,
            tailscaleExecutable: tailscale,
            remoteExecutable: ".local/lib/workjet/current/workjet-node",
            remoteArguments: [".local/lib/workjet/current/workjet-host.mjs"],
            standardInput: payload,
            timeout: timeout
        )
        let result: CommandResult
        do { result = try await runner.run(command) }
        catch { throw RemoteHostProtocolError.transport(error.localizedDescription) }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw RemoteHostProtocolError.truncatedResponse }
        guard result.exitCode == 0 else {
            let detail = String(decoding: result.standardError.prefix(2_048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteHostProtocolError.transport(detail.isEmpty ? "Exit \(result.exitCode)" : detail)
        }
        let lines = String(decoding: result.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.count == 1,
              let response = try? JSONDecoder().decode(RemoteHostResponse.self, from: Data(lines[0].utf8)) else {
            throw RemoteHostProtocolError.malformedResponse
        }
        guard RemoteHostProtocolVersion.supported.contains(response.protocolVersion) else { throw RemoteHostProtocolError.incompatibleProtocol(response.protocolVersion) }
        guard response.ok else { throw RemoteHostProtocolError.rejected(response.error ?? "Unbekannter Fehler") }
        return response
    }

    public func probe() async throws -> RemoteHostResponse { try await call(RemoteHostRequest(operation: .probe)) }

    public func importWorkspace(_ snapshot: WorkspaceSnapshot, verifiedCapabilities: [String]? = nil) async throws -> RemoteWorkspaceDescriptor {
        guard computer.deploymentStatus == .installed,
              computer.installedSidecarVersion == PiSidecarRuntime.version else {
            throw RemoteHostProtocolError.computerNotInstalled
        }
        let capabilities: [String]
        if let verifiedCapabilities { capabilities = verifiedCapabilities }
        else { capabilities = try await probe().capabilities }
        guard capabilities.contains("workspace-git-v1") else { throw RemoteHostProtocolError.missingCapability("workspace-git-v1") }
        if !snapshot.manifest.submodules.isEmpty, !capabilities.contains("workspace-gitlinks-v1") {
            throw RemoteHostProtocolError.missingCapability("workspace-gitlinks-v1")
        }
        guard snapshot.bundle.count == snapshot.manifest.byteSize,
              snapshot.manifest.byteSize > 0,
              snapshot.manifest.byteSize <= GitWorkspaceSnapshotPreparer.maximumBundleBytes else {
            throw RemoteHostProtocolError.rejected("Ungültige Workspace-Bundle-Größe")
        }
        var input = try JSONEncoder().encode(snapshot.manifest)
        input.append(0x0a)
        input.append(snapshot.bundle)
        let tailscale = computer.transport == .tailscale ? (computer.tailscaleExecutablePath ?? tailscaleLocator.executablePath()) : nil
        let command = try RemoteCommandBuilder.command(
            for: computer,
            tailscaleExecutable: tailscale,
            remoteExecutable: ".local/lib/workjet/current/workjet-node",
            remoteArguments: [".local/lib/workjet/current/workjet-host.mjs", "--workspace-import"],
            standardInput: input,
            timeout: 180
        )
        let result: CommandResult
        do { result = try await runner.run(command) }
        catch { throw RemoteHostProtocolError.transport(error.localizedDescription) }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw RemoteHostProtocolError.truncatedResponse }
        guard result.exitCode == 0 else { throw RemoteHostProtocolError.transport("Workspace-Import fehlgeschlagen") }
        let lines = result.standardOutput.split(whereSeparator: { $0 == 0x0a })
        guard lines.count == 1,
              let response = try? JSONDecoder().decode(RemoteHostResponse.self, from: Data(lines[0])),
              RemoteHostProtocolVersion.supported.contains(response.protocolVersion) else {
            throw RemoteHostProtocolError.malformedResponse
        }
        guard response.ok else { throw RemoteHostProtocolError.rejected(response.error ?? "Workspace-Import abgelehnt") }
        return snapshot.manifest.descriptor
    }

    public func start(worker: Worker, input: Data, systemPrompt: String? = nil, workspace: RemoteWorkspaceDescriptor? = nil, turnTimeoutSeconds: Int = 3_600, registry: RemoteHarnessAdapterRegistry = .init()) async throws -> RemoteHostResponse {
        if worker.harness != .piSidecar {
            let probe = try await probe()
            guard probe.capabilities.contains("workspace-git-v1") else { throw RemoteHostProtocolError.missingCapability("workspace-git-v1") }
        }
        let launch = try registry.launch(worker: worker, computer: computer, input: input, systemPrompt: systemPrompt, workspace: workspace)
        return try await call(RemoteHostRequest(operation: .start, launch: launch, turnTimeoutSeconds: min(max(turnTimeoutSeconds, 60), 10_800)))
    }

    public func start(worker: Worker, input: Data, systemPrompt: String? = nil, providerExecution: RemoteProviderExecution, ownerID: String? = nil, workerName: String? = nil, workspace: RemoteWorkspaceDescriptor? = nil, turnTimeoutSeconds: Int = 3_600, verifiedCapabilities: [String]? = nil, registry: RemoteHarnessAdapterRegistry = .init()) async throws -> RemoteHostResponse {
        if worker.harness != .piSidecar {
            let capabilities: [String]
        if let verifiedCapabilities { capabilities = verifiedCapabilities }
        else { capabilities = try await probe().capabilities }
            guard capabilities.contains("workspace-git-v1") else { throw RemoteHostProtocolError.missingCapability("workspace-git-v1") }
        }
        let launch = try registry.launch(worker: worker, computer: computer, input: input, systemPrompt: systemPrompt, workspace: workspace)
        return try await call(RemoteHostRequest(operation: .start, launch: launch, ownerID: ownerID, providerExecution: providerExecution, workerName: workerName, turnTimeoutSeconds: min(max(turnTimeoutSeconds, 60), 10_800)))
    }

    public func events(runID: String, after sequence: UInt64) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .events, runID: runID, afterSequence: sequence))
    }

    public func stop(runID: String) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .stop, runID: runID))
    }

    public func relayLost(runID: String) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .relayLost, runID: runID))
    }

    public func list(ownerID: String? = nil) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .probe, ownerID: ownerID, wireOperation: "list"))
    }

    public func adopt(runID: String, ownerID: String) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .events, runID: runID, ownerID: ownerID, wireOperation: "adopt"))
    }

    public func exportWorkspaceResult(_ request: RemoteWorkspaceResultRequest, verifiedCapabilities: [String]? = nil) async throws -> WorkspaceResult {
        guard computer.deploymentStatus == .installed,
              computer.installedSidecarVersion == PiSidecarRuntime.version else { throw RemoteHostProtocolError.computerNotInstalled }
        let capabilities: [String]
        if let verifiedCapabilities { capabilities = verifiedCapabilities }
        else { capabilities = try await probe().capabilities }
        guard capabilities.contains("workspace-result-v1") else { throw RemoteHostProtocolError.missingCapability("workspace-result-v1") }
        guard request.schemaVersion == 1, LocalWorkspaceResultImporter.safeRunID(request.runID),
              GitRepositoryInspector.validDigest(request.repoID), GitRepositoryInspector.validOID(request.snapshotCommitOID),
              request.ownerID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw RemoteHostProtocolError.rejected("Ungültige Ergebnis-Anfrage")
        }
        var input = try JSONEncoder().encode(request)
        input.append(0x0a)
        let tailscale = computer.transport == .tailscale ? (computer.tailscaleExecutablePath ?? tailscaleLocator.executablePath()) : nil
        let command = try RemoteCommandBuilder.command(
            for: computer,
            tailscaleExecutable: tailscale,
            remoteExecutable: ".local/lib/workjet/current/workjet-node",
            remoteArguments: [".local/lib/workjet/current/workjet-host.mjs", "--workspace-result"],
            standardInput: input,
            timeout: 180,
            stdoutLimit: LocalWorkspaceResultImporter.maximumBundleBytes + 4097
        )
        let result: CommandResult
        do { result = try await runner.run(command) }
        catch { throw RemoteHostProtocolError.transport(error.localizedDescription) }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw RemoteHostProtocolError.truncatedResponse }
        if result.exitCode != 0 {
            let detail = String(decoding: result.standardError.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 65, detail.range(of: "^[a-z0-9_\\n -]{1,512}$", options: .regularExpression) != nil {
                throw RemoteHostProtocolError.rejected(detail)
            }
            throw RemoteHostProtocolError.transport("Workspace-Ergebnisexport fehlgeschlagen")
        }
        guard let newline = result.standardOutput.firstIndex(of: 0x0a), newline > 1, newline <= 4096 else { throw RemoteHostProtocolError.malformedResponse }
        let manifestData = result.standardOutput.prefix(upTo: newline)
        guard let manifest = try? JSONDecoder().decode(WorkspaceResultManifest.self, from: manifestData) else { throw RemoteHostProtocolError.malformedResponse }
        let bundle = Data(result.standardOutput.suffix(from: result.standardOutput.index(after: newline)))
        guard manifest.schemaVersion == 1, manifest.runID == request.runID, manifest.repoID == request.repoID,
              manifest.snapshotCommitOID == request.snapshotCommitOID, GitRepositoryInspector.validOID(manifest.resultCommitOID),
              manifest.byteSize == bundle.count, manifest.byteSize > 0, manifest.byteSize <= LocalWorkspaceResultImporter.maximumBundleBytes,
              manifest.bundleSHA256 == SHA256.hash(data: bundle).map({ String(format: "%02x", $0) }).joined(),
              manifest.terminalState?.isTerminal == true else { throw RemoteHostProtocolError.malformedResponse }
        return WorkspaceResult(manifest: manifest, bundle: bundle)
    }

    public func finalizeWorkspace(runID: String, ownerID: String, disposition: RemoteWorkspaceDisposition) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .workspaceFinalize, runID: runID, ownerID: ownerID, workspaceDisposition: disposition))
    }

    public func maintain(harnessID: String, action: RemoteHarnessMaintenanceAction) async throws -> RemoteHarnessLifecycleResult {
        let response = try await call(RemoteHostRequest(harnessID: harnessID, action: action))
        guard let result = response.harnessResult else { throw RemoteHostProtocolError.malformedResponse }
        return result
    }

    public func maintain(skillID: String, action: RemoteManagedSkillMaintenanceAction) async throws -> RemoteManagedSkillLifecycleResult {
        let response = try await call(RemoteHostRequest(skillID: skillID, action: action))
        guard let result = response.managedSkillResult else { throw RemoteHostProtocolError.malformedResponse }
        return result
    }
}
