import Foundation

public enum Harness: String, CaseIterable, Codable, Equatable, Sendable {
    case claudeCode = "Claude Code"
    case piSidecar = "Pi Sidecar"
}

public enum ComputerTransport: String, CaseIterable, Codable, Equatable, Sendable {
    case local = "Lokal"
    case tailscale = "Tailscale"
    case ssh = "SSH"
}

public struct Computer: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: ComputerTransport
    public var host: String
    public var user: String
    public var port: Int
    public var sandboxEnabled: Bool
    public var pinnedSidecarVersion: String
    public var telemetryEnabled: Bool

    public init(id: UUID = UUID(), name: String, transport: ComputerTransport, host: String = "", user: String = "", port: Int = 22, sandboxEnabled: Bool = true, pinnedSidecarVersion: String = "", telemetryEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.transport = transport
        self.host = host
        self.user = user
        self.port = port
        self.sandboxEnabled = sandboxEnabled
        self.pinnedSidecarVersion = pinnedSidecarVersion
        self.telemetryEnabled = telemetryEnabled
    }

    public var isLocal: Bool { transport == .local }
}

public enum CapacityStatus: Equatable, Codable, Sendable {
    case measured(used: Double, limit: Double, unit: String, rateLimited: Bool)
    case userConfigured(used: Double, limit: Double, unit: String, rateLimited: Bool)
    case unavailable(reason: String)

    public var fraction: Double? {
        switch self {
        case let .measured(used, limit, _, _), let .userConfigured(used, limit, _, _):
            guard used >= 0, limit > 0, used <= limit else { return nil }
            return used / limit
        case .unavailable:
            return nil
        }
    }

    public var rateLimited: Bool? {
        switch self {
        case let .measured(_, _, _, value), let .userConfigured(_, _, _, value): return value
        case .unavailable: return nil
        }
    }

    public var reason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }

    public enum Level: Equatable, Sendable { case ok, warning, critical, unavailable }
    public var level: Level {
        guard let fraction else { return .unavailable }
        if rateLimited == true || fraction >= 0.9 { return .critical }
        if fraction >= 0.7 { return .warning }
        return .ok
    }
}

public struct WorkerInvocation: Equatable, Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var capabilities: [String]

    public init(executable: String, arguments: [String] = [], capabilities: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.capabilities = capabilities
    }
}

public struct Worker: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var harness: Harness
    public var model: String
    public var instructions: String
    public var computerID: UUID
    public var invocation: WorkerInvocation
    public var capacity: CapacityStatus

    public init(id: UUID = UUID(), name: String, harness: Harness, model: String, instructions: String = "", computerID: UUID, invocation: WorkerInvocation = WorkerInvocation(executable: ""), capacity: CapacityStatus = .unavailable(reason: "Keine kompatiblen Nutzungsdaten verfügbar.")) {
        self.id = id
        self.name = name
        self.harness = harness
        self.model = model
        self.instructions = instructions
        self.computerID = computerID
        self.invocation = invocation
        self.capacity = capacity
    }
}

public enum RunState: String, Equatable, Sendable { case running, completed, interrupted, malformed }
public enum HarnessDelivery: String, Equatable, Sendable {
    case live = "live"
    case postHoc = "post-hoc"
    case unavailable = "nicht verfügbar"
}

public struct ProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var executablePath: String
    public var startToken: String
    public init(pid: Int32, executablePath: String, startToken: String) {
        self.pid = pid
        self.executablePath = executablePath
        self.startToken = startToken
    }
}

public struct ActiveRun: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sourceRunID: String
    public var workerID: UUID?
    public var workerName: String
    public var workerModel: String?
    public var activity: String
    public var startedAt: Date
    public var observedAt: Date
    public var lastHeartbeat: Date?
    public var delivery: HarnessDelivery
    public var pid: Int32
    public var processIdentity: ProcessIdentity
    public var runDirectory: URL
    public var indexFile: URL?

    public init(id: UUID = UUID(), sourceRunID: String, workerID: UUID?, workerName: String, workerModel: String?, activity: String, startedAt: Date, observedAt: Date, lastHeartbeat: Date?, delivery: HarnessDelivery, pid: Int32, processIdentity: ProcessIdentity, runDirectory: URL, indexFile: URL?) {
        self.id = id
        self.sourceRunID = sourceRunID
        self.workerID = workerID
        self.workerName = workerName
        self.workerModel = workerModel
        self.activity = activity
        self.startedAt = startedAt
        self.observedAt = observedAt
        self.lastHeartbeat = lastHeartbeat
        self.delivery = delivery
        self.pid = pid
        self.processIdentity = processIdentity
        self.runDirectory = runDirectory
        self.indexFile = indexFile
    }

    public var observedDuration: TimeInterval { max(observedAt.timeIntervalSince(startedAt), 0) }
}

public struct RunRecord: Equatable, Sendable {
    public var sourceRunID: String
    public var state: RunState
    public var activeRun: ActiveRun?
    public var diagnostic: String?
    public init(sourceRunID: String, state: RunState, activeRun: ActiveRun? = nil, diagnostic: String? = nil) {
        self.sourceRunID = sourceRunID
        self.state = state
        self.activeRun = activeRun
        self.diagnostic = diagnostic
    }
}

public enum ProviderKind: String, CaseIterable, Codable, Equatable, Sendable {
    case cliProxy = "CLIProxy OAuth/Abo"
    case oauthSubscription = "OAuth/Abo"
    case apiKey = "Direkter API-Key"
}

public enum ProviderStatus: String, Codable, Equatable, Sendable {
    case connected = "Verbunden"
    case degraded = "Eingeschränkt"
    case offline = "Offline"
}

public struct Provider: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var endpoint: String
    public var status: ProviderStatus
    public var capacity: CapacityStatus
    public var credentialReference: String?
    public var loginExecutable: String?
    public var loginArguments: [String]

    public init(id: UUID = UUID(), name: String, kind: ProviderKind, endpoint: String, status: ProviderStatus = .offline, capacity: CapacityStatus = .unavailable(reason: "Keine kompatiblen Nutzungsdaten verfügbar."), credentialReference: String? = nil, loginExecutable: String? = nil, loginArguments: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.status = status
        self.capacity = capacity
        self.credentialReference = credentialReference
        self.loginExecutable = loginExecutable
        self.loginArguments = loginArguments
    }
}

public enum CLIProxyConnectionState: String, Codable, Equatable, Sendable {
    case reachable = "Erreichbar"
    case authRequired = "Inferenz-Authentifizierung erforderlich"
    case unsafeEndpoint = "Unsicherer Endpunkt"
    case managementUnavailable = "Management nicht verfügbar"
    case usageDisabled = "Nutzungsstatistik deaktiviert"
    case offline = "Offline"
}

public struct CLIProxyConfiguration: Equatable, Codable, Sendable {
    public var endpoint: String
    public var inferenceCredentialReference: String?
    public var managementCredentialReference: String?
    public var usageStatisticsEnabled: Bool
    public init(endpoint: String = "http://127.0.0.1:8317", inferenceCredentialReference: String? = nil, managementCredentialReference: String? = nil, usageStatisticsEnabled: Bool = false) {
        self.endpoint = endpoint
        self.inferenceCredentialReference = inferenceCredentialReference
        self.managementCredentialReference = managementCredentialReference
        self.usageStatisticsEnabled = usageStatisticsEnabled
    }
}

public struct CLIProxyStatus: Equatable, Sendable {
    public var endpoint: String
    public var state: CLIProxyConnectionState
    public var detail: String
    public var capacity: CapacityStatus
    public init(endpoint: String, state: CLIProxyConnectionState, detail: String, capacity: CapacityStatus) {
        self.endpoint = endpoint
        self.state = state
        self.detail = detail
        self.capacity = capacity
    }
}

public enum SkillActivation: String, CaseIterable, Codable, Equatable, Sendable {
    case skillOnly = "Skill (/workjet)"
    case global = "Global"
}

public struct WorkjetConfiguration: Equatable, Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var workers: [Worker]
    public var computers: [Computer]
    public var providers: [Provider]
    public var selectedComputerID: UUID
    public var skillRules: String
    public var skillActivation: SkillActivation
    public var injectWorkerDeclarations: Bool
    public var telemetryClaudeCodeEvents: Bool
    public var telemetrySidecarEvents: Bool
    public var telemetryRetentionDays: Int
    public var providerSlots: Int
    public var probeTimeoutSeconds: Int
    public var turnTimeoutSeconds: Int
    public var degradationAllowed: Bool
    public var cliProxy: CLIProxyConfiguration

    public init(version: Int = currentVersion, workers: [Worker], computers: [Computer], providers: [Provider], selectedComputerID: UUID, skillRules: String, skillActivation: SkillActivation = .skillOnly, injectWorkerDeclarations: Bool = true, telemetryClaudeCodeEvents: Bool = true, telemetrySidecarEvents: Bool = true, telemetryRetentionDays: Int = 14, providerSlots: Int = 3, probeTimeoutSeconds: Int = 20, turnTimeoutSeconds: Int = 900, degradationAllowed: Bool = true, cliProxy: CLIProxyConfiguration = CLIProxyConfiguration()) {
        self.version = version
        self.workers = workers
        self.computers = computers
        self.providers = providers
        self.selectedComputerID = selectedComputerID
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
        self.cliProxy = cliProxy
    }
}
