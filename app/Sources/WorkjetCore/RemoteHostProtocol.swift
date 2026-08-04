import Foundation

public enum RemoteHostOperation: String, Codable, Sendable {
    case probe, start, events, stop
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

public struct RemoteHostRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var operation: RemoteHostOperation
    public var runID: String?
    public var afterSequence: UInt64?
    public var launch: RemoteHarnessLaunch?

    public init(operation: RemoteHostOperation, runID: String? = nil, afterSequence: UInt64? = nil, launch: RemoteHarnessLaunch? = nil) {
        self.protocolVersion = 1
        self.operation = operation
        self.runID = runID
        self.afterSequence = afterSequence
        self.launch = launch
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

    public init(protocolVersion: Int = 1, ok: Bool, hostVersion: String? = nil, error: String? = nil, runID: String? = nil, state: RemoteHostRunState = .unknown, cursor: UInt64 = 0, oldestSequence: UInt64? = nil, heartbeatAt: String? = nil, events: [RemoteHostEvent] = [], capabilities: [String] = []) {
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
        case .computerNotInstalled: return "Der Remote-Computer hat keine bestätigte Workjet-Host-Runtime."
        case let .transport(detail): return "Remote-Transport fehlgeschlagen: \(detail)"
        case .truncatedResponse: return "Die Remote-Host-Antwort wurde wegen ihrer Größe verworfen."
        case .malformedResponse: return "Die Remote-Host-Antwort ist kein gültiges Workjet-Protokollobjekt."
        case let .incompatibleProtocol(version): return "Remote-Host-Protokollversion \(version) wird nicht unterstützt."
        case let .rejected(detail): return "Remote-Host hat den Aufruf abgelehnt: \(detail)"
        case let .missingCapability(capability): return "Remote-Host unterstützt die erforderliche Fähigkeit nicht: \(capability)."
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

    public init(runID: String?, state: RemoteHostRunState, cursor: UInt64, events: [RemoteHostEvent], heartbeatAt: Date?, lastError: String?) {
        self.runID = runID
        self.state = state
        self.cursor = cursor
        self.events = events
        self.heartbeatAt = heartbeatAt
        self.lastError = lastError
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
        let command = try RemoteCommandBuilder.command(
            for: computer,
            tailscaleExecutable: tailscale,
            remoteExecutable: "node",
            remoteArguments: [".local/lib/workjet/current/workjet-host.mjs"],
            standardInput: payload,
            timeout: request.operation == .events ? 15 : 30
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
        guard response.protocolVersion == 1 else { throw RemoteHostProtocolError.incompatibleProtocol(response.protocolVersion) }
        guard response.ok else { throw RemoteHostProtocolError.rejected(response.error ?? "Unbekannter Fehler") }
        return response
    }

    public func probe() async throws -> RemoteHostResponse { try await call(RemoteHostRequest(operation: .probe)) }

    public func start(worker: Worker, input: Data, registry: RemoteHarnessAdapterRegistry = .init()) async throws -> RemoteHostResponse {
        let launch = try registry.launch(worker: worker, computer: computer, input: input)
        return try await call(RemoteHostRequest(operation: .start, launch: launch))
    }

    public func events(runID: String, after sequence: UInt64) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .events, runID: runID, afterSequence: sequence))
    }

    public func stop(runID: String) async throws -> RemoteHostResponse {
        try await call(RemoteHostRequest(operation: .stop, runID: runID))
    }
}
