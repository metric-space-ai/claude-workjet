import Foundation

public enum Harness: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case claudeCode = "Claude Code"
    case piSidecar = "Pi Code"
    case codexCLI = "Codex CLI"
    case cursorAgent = "Cursor Agent"
    case openCode = "OpenCode"
    case grokCLI = "Grok CLI"

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "Claude Code": self = .claudeCode
        case "Pi Code", "Pi Sidecar": self = .piSidecar
        case "Codex", "Codex CLI": self = .codexCLI
        case "Cursor", "Cursor Agent": self = .cursorAgent
        case "OpenCode", "Open Code": self = .openCode
        case "Grok", "Grok CLI": self = .grokCLI
        default:
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Unbekanntes Harness: \(value)")
        }
    }
}

public enum ReasoningEffort: String, CaseIterable, Codable, Equatable, Sendable {
    case low, medium, high, xhigh, max, ultra, ultracode, ultrathink

    public var label: String { rawValue }
}

public enum RunSpeed: String, Codable, Equatable, Sendable {
    case fast
    case normal
}

public enum ComputerTransport: String, CaseIterable, Codable, Equatable, Sendable {
    case local = "Lokal"
    case tailscale = "Tailscale"
    case ssh = "SSH"
}

public enum PiSidecarRuntime {
    public static let version = "0.80.2"
}

public enum DeploymentStatus: String, Codable, Equatable, Sendable {
    case notConfigured = "Nicht eingerichtet"
    case checking = "Wird geprüft"
    case blocked = "Blockiert"
    case installed = "Installiert"
    case failed = "Fehlgeschlagen"
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
    public var sidecarBundlePath: String
    public var deploymentStatus: DeploymentStatus
    public var deploymentDetail: String
    public var installedContentHash: String?
    public var installedSidecarVersion: String?
    public var knownHostsPath: String
    public var identityFilePath: String
    public var tailscaleExecutablePath: String?
    public var bubblewrapExecutablePath: String?
    public var lastSuccessfulPreflightAt: Date?
    public var lastSuccessfulDeploymentAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        transport: ComputerTransport,
        host: String = "",
        user: String = "",
        port: Int = 22,
        sandboxEnabled: Bool = true,
        pinnedSidecarVersion: String = PiSidecarRuntime.version,
        telemetryEnabled: Bool = false,
        sidecarBundlePath: String = "",
        deploymentStatus: DeploymentStatus = .notConfigured,
        deploymentDetail: String = "Noch nicht geprüft.",
        installedContentHash: String? = nil,
        installedSidecarVersion: String? = nil,
        knownHostsPath: String = "",
        identityFilePath: String = "",
        tailscaleExecutablePath: String? = nil,
        bubblewrapExecutablePath: String? = nil,
        lastSuccessfulPreflightAt: Date? = nil,
        lastSuccessfulDeploymentAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.host = host
        self.user = user
        self.port = port
        self.sandboxEnabled = sandboxEnabled
        self.pinnedSidecarVersion = pinnedSidecarVersion.isEmpty ? PiSidecarRuntime.version : pinnedSidecarVersion
        self.telemetryEnabled = telemetryEnabled
        self.sidecarBundlePath = sidecarBundlePath
        self.deploymentStatus = deploymentStatus
        self.deploymentDetail = deploymentDetail
        self.installedContentHash = installedContentHash
        self.installedSidecarVersion = installedSidecarVersion
        self.knownHostsPath = knownHostsPath
        self.identityFilePath = identityFilePath
        self.tailscaleExecutablePath = tailscaleExecutablePath
        self.bubblewrapExecutablePath = bubblewrapExecutablePath
        self.lastSuccessfulPreflightAt = lastSuccessfulPreflightAt
        self.lastSuccessfulDeploymentAt = lastSuccessfulDeploymentAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, transport, host, user, port, sandboxEnabled, pinnedSidecarVersion, telemetryEnabled
        case sidecarBundlePath, deploymentStatus, deploymentDetail, installedContentHash, installedSidecarVersion
        case knownHostsPath, identityFilePath, tailscaleExecutablePath, bubblewrapExecutablePath, lastSuccessfulPreflightAt, lastSuccessfulDeploymentAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        transport = try values.decode(ComputerTransport.self, forKey: .transport)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        sandboxEnabled = try values.decodeIfPresent(Bool.self, forKey: .sandboxEnabled) ?? true
        pinnedSidecarVersion = try values.decodeIfPresent(String.self, forKey: .pinnedSidecarVersion) ?? PiSidecarRuntime.version
        if pinnedSidecarVersion.isEmpty { pinnedSidecarVersion = PiSidecarRuntime.version }
        telemetryEnabled = try values.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? false
        sidecarBundlePath = try values.decodeIfPresent(String.self, forKey: .sidecarBundlePath) ?? ""
        deploymentStatus = try values.decodeIfPresent(DeploymentStatus.self, forKey: .deploymentStatus) ?? .notConfigured
        deploymentDetail = try values.decodeIfPresent(String.self, forKey: .deploymentDetail) ?? "Noch nicht geprüft."
        installedContentHash = try values.decodeIfPresent(String.self, forKey: .installedContentHash)
        installedSidecarVersion = try values.decodeIfPresent(String.self, forKey: .installedSidecarVersion)
        knownHostsPath = try values.decodeIfPresent(String.self, forKey: .knownHostsPath) ?? ""
        identityFilePath = try values.decodeIfPresent(String.self, forKey: .identityFilePath) ?? ""
        tailscaleExecutablePath = try values.decodeIfPresent(String.self, forKey: .tailscaleExecutablePath)
        bubblewrapExecutablePath = try values.decodeIfPresent(String.self, forKey: .bubblewrapExecutablePath)
        lastSuccessfulPreflightAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessfulPreflightAt)
        lastSuccessfulDeploymentAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessfulDeploymentAt)
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
    /// Harness-specific selections whose IDs come from `HarnessAdapterRegistry`.
    /// Unknown legacy selections remain readable, but drafts only persist options
    /// exposed by the currently selected adapter.
    public var options: [String: String]

    public init(executable: String, arguments: [String] = [], capabilities: [String] = [], options: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.capabilities = capabilities
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case executable, arguments, capabilities, options }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        executable = try values.decodeIfPresent(String.self, forKey: .executable) ?? ""
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        options = try values.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }
}

public struct Worker: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var harness: Harness
    public var model: String
    public var instructions: String
    public var reasoningEffort: ReasoningEffort?
    public var computerID: UUID
    /// Stable access route. A missing/deleted provider remains unavailable and is never replaced implicitly.
    public var providerID: UUID?
    /// Explicitly selects the deterministic pool of all configured accounts for
    /// one provider. This is mutually exclusive with `providerID`.
    public var providerPool: ModelProvider?
    /// Sparse catalog overrides. Missing IDs use the current catalog default;
    /// unknown IDs are retained for forward/backward compatibility.
    public var skillOverrides: [String: Bool]
    public var invocation: WorkerInvocation
    public var capacity: CapacityStatus

    public init(id: UUID = UUID(), name: String, harness: Harness, model: String, instructions: String = "", reasoningEffort: ReasoningEffort? = nil, computerID: UUID, providerID: UUID? = nil, providerPool: ModelProvider? = nil, skillOverrides: [String: Bool] = [:], invocation: WorkerInvocation = WorkerInvocation(executable: ""), capacity: CapacityStatus = .unavailable(reason: "Keine kompatiblen Nutzungsdaten verfügbar.")) {
        self.id = id
        self.name = name
        self.harness = harness
        self.model = model
        self.instructions = instructions
        self.reasoningEffort = reasoningEffort
        self.computerID = computerID
        self.providerID = providerPool == nil ? providerID : nil
        self.providerPool = providerPool
        self.skillOverrides = skillOverrides
        self.invocation = invocation
        self.capacity = capacity
    }

    public var providerRoute: ProviderRoute? {
        get {
            if let providerPool { return .pool(providerPool) }
            if let providerID { return .account(providerID) }
            return nil
        }
        set {
            switch newValue {
            case let .account(id): providerID = id; providerPool = nil
            case let .pool(provider): providerID = nil; providerPool = provider
            case nil: providerID = nil; providerPool = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, harness, model, instructions, reasoningEffort, computerID
        case providerID, providerPool, skillOverrides, invocation, capacity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        harness = try values.decode(Harness.self, forKey: .harness)
        model = try values.decode(String.self, forKey: .model)
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        reasoningEffort = try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        computerID = try values.decode(UUID.self, forKey: .computerID)
        providerPool = try values.decodeIfPresent(ModelProvider.self, forKey: .providerPool)
        providerID = providerPool == nil ? try values.decodeIfPresent(UUID.self, forKey: .providerID) : nil
        skillOverrides = try values.decodeIfPresent([String: Bool].self, forKey: .skillOverrides) ?? [:]
        invocation = try values.decodeIfPresent(WorkerInvocation.self, forKey: .invocation) ?? WorkerInvocation(executable: "")
        capacity = try values.decodeIfPresent(CapacityStatus.self, forKey: .capacity) ?? .unavailable(reason: "Keine kompatiblen Nutzungsdaten verfügbar.")
    }

    public var mentionTag: String {
        let scalars = name.unicodeScalars
        var result = ""
        var pendingSeparator = false
        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                if pendingSeparator && !result.isEmpty && !result.hasSuffix("-") { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return "@" + (result.isEmpty ? "Worker" : result)
    }
}

public enum WorkerOperationalState: String, Equatable, Sendable {
    case active
    case ready
    case unverified
    case degraded
    case unavailable
}

public struct WorkerOperationalStatus: Equatable, Sendable {
    public var state: WorkerOperationalState
    public var label: String
    public var detail: String

    public init(state: WorkerOperationalState, label: String, detail: String) {
        self.state = state
        self.label = label
        self.detail = detail
    }
}

/// A concrete recovery exposed next to a worker that cannot currently run.
/// The UI must never leave an authentication/configuration error without a
/// direct route to the corresponding provider action.
public enum WorkerProviderRecovery: Equatable, Sendable {
    case connect(ModelProvider)
    case reauthenticate(accountID: UUID, provider: ModelProvider)
    case configure(ModelProvider?)
}

public enum ProviderRoute: Equatable, Codable, Sendable {
    case account(UUID)
    case pool(ModelProvider)
}

public enum ProviderRuntimeTarget: Equatable, Sendable { case local, remote }

public enum ProviderRuntimeRouteError: LocalizedError, Equatable, Sendable {
    case routeMissing
    case accountMissing
    case poolEmpty(ModelProvider)
    case endpointInvalid(String)
    case credentialMissing(String)
    case remoteGatewayUnavailable
    /// Kept for decoding/source compatibility; secure remote routes no longer
    /// produce this error.
    case remoteProfileUnavailable

    public var errorDescription: String? {
        switch self {
        case .routeMissing: return "Wähle für diesen Worker einen Anbieterzugang."
        case .accountMissing: return "Der gewählte Anbieterzugang existiert nicht mehr."
        case let .poolEmpty(provider): return "Für \(provider.rawValue) ist kein Zugang konfiguriert."
        case .endpointInvalid: return "Der Anbieter-Endpunkt ist ungültig."
        case .credentialMissing: return "Für den Anbieterzugang fehlt die sichere Zugangsdaten-Referenz."
        case .remoteGatewayUnavailable: return "CLIProxy-Zugänge sind auf diesem Computer noch nicht verfügbar. Wähle einen direkten API-Zugang."
        case .remoteProfileUnavailable: return "Der Remote-Anbieterzugang ist nicht verfügbar."
        }
    }
}

public enum RemoteProviderRoutePolicy {
    public static func validate(_ route: ResolvedProviderRuntimeRoute) throws {
        guard !route.candidates.isEmpty else { throw ProviderRuntimeRouteError.routeMissing }
    }

    public static func requiresGatewayRelay(_ route: ResolvedProviderRuntimeRoute) -> Bool {
        route.candidates.contains(where: { $0.kind == .gatewayPool })
    }
}

public struct ProviderRuntimeCandidate: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable { case directAccount, gatewayPool }
    public var kind: Kind
    public var providerID: UUID?
    public var modelProvider: ModelProvider?
    public var displayName: String
    public var endpoint: String
    public var authentication: ProviderAuthentication
    public var credentialReference: String?

    public init(kind: Kind, providerID: UUID?, modelProvider: ModelProvider?, displayName: String, endpoint: String, authentication: ProviderAuthentication, credentialReference: String?) {
        self.kind = kind
        self.providerID = providerID
        self.modelProvider = modelProvider
        self.displayName = displayName
        self.endpoint = endpoint
        self.authentication = authentication
        self.credentialReference = credentialReference
    }
}

public struct ResolvedProviderRuntimeRoute: Codable, Equatable, Sendable {
    public var displayName: String
    public var candidates: [ProviderRuntimeCandidate]
    public init(displayName: String, candidates: [ProviderRuntimeCandidate]) {
        self.displayName = displayName
        self.candidates = candidates
    }
}

public enum ProviderRuntimeRouteResolver {
    public static func resolve(worker: Worker, providers: [Provider], target: ProviderRuntimeTarget) throws -> ResolvedProviderRuntimeRoute {
        let selected: [Provider]
        let poolProvider: ModelProvider?
        switch worker.providerRoute {
        case let .account(id):
            guard let provider = providers.first(where: { $0.id == id }) else { throw ProviderRuntimeRouteError.accountMissing }
            selected = [provider]
            poolProvider = nil
        case let .pool(modelProvider):
            selected = Provider.deterministicPool(providers, for: modelProvider)
            guard !selected.isEmpty else { throw ProviderRuntimeRouteError.poolEmpty(modelProvider) }
            poolProvider = modelProvider
        case nil:
            throw ProviderRuntimeRouteError.routeMissing
        }

        var candidates: [ProviderRuntimeCandidate] = []
        var emittedGateways = Set<ModelProvider>()
        for provider in selected {
            guard case let .valid(baseURL) = ProviderEndpointValidator.validate(provider.endpoint, kind: provider.kind) else {
                throw ProviderRuntimeRouteError.endpointInvalid(provider.name)
            }
            if provider.kind.isLocalGateway {
                let modelProvider = provider.modelProvider ?? ModelProvider.inferred(from: worker.model)
                if let modelProvider, !emittedGateways.insert(modelProvider).inserted { continue }
                let reference = provider.credentialReference ?? CLIProxyGatewayCredentialStore.reference
                candidates.append(ProviderRuntimeCandidate(
                    kind: .gatewayPool,
                    providerID: nil,
                    modelProvider: modelProvider,
                    displayName: "\(modelProvider?.rawValue ?? provider.name) Gateway-Pool",
                    endpoint: baseURL.absoluteString,
                    authentication: provider.authentication,
                    credentialReference: provider.authentication == .none ? nil : reference
                ))
            } else {
                if provider.authentication != .none, provider.credentialReference == nil {
                    throw ProviderRuntimeRouteError.credentialMissing(provider.name)
                }
                candidates.append(ProviderRuntimeCandidate(
                    kind: .directAccount,
                    providerID: provider.id,
                    modelProvider: provider.modelProvider,
                    displayName: provider.accountLabel ?? provider.name,
                    endpoint: baseURL.absoluteString,
                    authentication: provider.authentication,
                    credentialReference: provider.credentialReference
                ))
            }
        }
        guard !candidates.isEmpty else {
            if let poolProvider { throw ProviderRuntimeRouteError.poolEmpty(poolProvider) }
            throw ProviderRuntimeRouteError.accountMissing
        }
        let name = candidates.count == 1 ? candidates[0].displayName : "\(poolProvider?.rawValue ?? "Anbieter") Pool"
        return ResolvedProviderRuntimeRoute(displayName: name, candidates: candidates)
    }
}

public enum ProviderRuntimeFailureClass: Equatable, Sendable {
    case retryable
    case taskFailure

    public static func classify(exitCode: Int32, diagnostic: String) -> Self {
        guard exitCode != 0 else { return .taskFailure }
        let value = diagnostic.lowercased()
        // A different direct account is tried only when the harness surfaced
        // recognizable provider authentication/capacity evidence. Transport,
        // timeout and generic 5xx text are deliberately excluded: they do not
        // prove that another subscription can answer, and may be emitted by the
        // task itself. CLIProxy owns its own gateway-account retries.
        let exactProviderMarkers = [
            "http 401", "http 403", "http 429",
            "status 401", "status 403", "status 429",
            #"\"status\":401"#, #"\"status\":403"#, #"\"status\":429"#,
            #"\"code\":401"#, #"\"code\":403"#, #"\"code\":429"#,
            "authentication_error", "rate_limit_error", "invalid_api_key", "insufficient_quota", "quota_exceeded",
            "invalid api key", "token expired", "quota exceeded", "quota exhausted",
            "rate limit exceeded", "rate-limit exceeded", "too many requests"
        ]
        return exactProviderMarkers.contains(where: value.contains) ? .retryable : .taskFailure
    }
}

public enum RunState: String, Equatable, Sendable { case running, completed, interrupted, malformed }
public enum WorkjetRuntimeStatus: Equatable, Sendable {
    case ready
    case active(count: Int)
    case attention
}
public enum PromptSyncStatus: Equatable, Sendable {
    case synchronized(Date)
    case pending
    case failed(String)
}
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
    public var effectiveModel: String?
    public var effectiveReasoning: ReasoningEffort?
    public var effectiveSpeed: RunSpeed?
    public var effectiveProviderRoute: String?
    public var activity: String
    public var startedAt: Date
    public var observedAt: Date
    public var lastHeartbeat: Date?
    public var delivery: HarnessDelivery
    public var pid: Int32
    public var processIdentity: ProcessIdentity
    public var runDirectory: URL
    public var indexFile: URL?

    public init(id: UUID = UUID(), sourceRunID: String, workerID: UUID?, workerName: String, workerModel: String?, effectiveModel: String? = nil, effectiveReasoning: ReasoningEffort? = nil, effectiveSpeed: RunSpeed? = nil, effectiveProviderRoute: String? = nil, activity: String, startedAt: Date, observedAt: Date, lastHeartbeat: Date?, delivery: HarnessDelivery, pid: Int32, processIdentity: ProcessIdentity, runDirectory: URL, indexFile: URL?) {
        self.id = id
        self.sourceRunID = sourceRunID
        self.workerID = workerID
        self.workerName = workerName
        self.workerModel = workerModel
        self.effectiveModel = effectiveModel
        self.effectiveReasoning = effectiveReasoning
        self.effectiveSpeed = effectiveSpeed
        self.effectiveProviderRoute = effectiveProviderRoute
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
    case directAPI = "Direkte API"
    case cliProxyAPI = "CLIProxyAPI"
    case cliProxyRust = "CLIProxy (Rust)"

    public var isLocalGateway: Bool { self != .directAPI }

    // Source-compatible aliases for older app code; encoded product names stay current.
    public static var apiKey: ProviderKind { .directAPI }
    public static var cliProxy: ProviderKind { .cliProxyAPI }
    public static var oauthSubscription: ProviderKind { .cliProxyRust }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "Direkte API", "Direkter API-Key": self = .directAPI
        case "CLIProxyAPI", "CLIProxy OAuth/Abo": self = .cliProxyAPI
        case "CLIProxy (Rust)": self = .cliProxyRust
        case "OAuth/Abo": self = .cliProxyAPI
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unbekannter Anbietertyp: \(value)")
        }
    }
}

public enum ProviderStatus: String, Codable, Equatable, Sendable {
    case unverified = "Nicht geprüft"
    case connected = "Verbunden"
    case degraded = "Eingeschränkt"
    case offline = "Offline"
}

public enum ProviderAuthentication: String, CaseIterable, Codable, Equatable, Sendable {
    case none = "Ohne Zugang"
    case bearerToken = "Bearer-Token"
    case apiKeyHeader = "API-Key (x-api-key)"
}

public enum ModelProvider: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case kimi = "Kimi"
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case antigravity = "Antigravity"
    case xAI = "xAI"
    case miniMax = "MiniMax"
    case zAI = "Z.ai"

    public var id: String { rawValue }

    public var cliProxyLoginFlag: String? {
        switch self {
        case .kimi: return "-kimi-login"
        case .openAI: return "-codex-login"
        case .anthropic: return "-claude-login"
        case .antigravity: return "-antigravity-login"
        case .xAI: return "-xai-login"
        case .miniMax, .zAI: return nil
        }
    }

    public var defaultEndpoint: String? {
        switch self {
        case .miniMax: return "https://api.minimax.io/anthropic"
        case .zAI: return "https://api.z.ai/api/paas/v4"
        default: return nil
        }
    }

    public var usesWebLogin: Bool { cliProxyLoginFlag != nil }

    public var defaultAuthentication: ProviderAuthentication {
        switch self {
        case .miniMax: return .apiKeyHeader
        default: return .bearerToken
        }
    }

    public var requestedModelSuggestions: [String] {
        switch self {
        case .miniMax: return ["MiniMax-M3", "MiniMax-M2.7"]
        case .zAI: return ["glm-5.2", "glm-5.1", "glm-5"]
        default: return []
        }
    }

    public var modelOwnerAliases: Set<String> {
        switch self {
        case .kimi: return ["kimi", "moonshot", "moonshotai"]
        case .openAI: return ["openai", "codex"]
        case .anthropic: return ["anthropic", "claude"]
        case .antigravity: return ["antigravity", "google", "gemini"]
        case .xAI: return ["xai", "x-ai", "grok"]
        case .miniMax: return ["minimax"]
        case .zAI: return ["zai", "z.ai", "glm"]
        }
    }

    public static func inferred(from modelID: String) -> ModelProvider? {
        let value = modelID.lowercased()
        if value.contains("kimi") || value.hasPrefix("k2") || value.hasPrefix("k3") { return .kimi }
        if value.contains("gpt") || value.contains("codex") { return .openAI }
        if value.contains("claude") || value.contains("opus") || value.contains("sonnet") || value.contains("fable") { return .anthropic }
        if value.contains("gemini") { return .antigravity }
        if value.contains("grok") { return .xAI }
        if value.contains("minimax") { return .miniMax }
        if value.contains("glm") { return .zAI }
        return nil
    }
}

/// Product/provider metadata. Authentication, health and capacity deliberately
/// do not live here; those belong to concrete `Provider` account instances.
public struct ProviderDefinition: Identifiable, Equatable, Sendable {
    public var id: ModelProvider
    public var displayName: String { id.rawValue }
    public var supportsWebLogin: Bool { id.usesWebLogin }
    public var defaultEndpoint: String? { id.defaultEndpoint }

    public init(id: ModelProvider) { self.id = id }
    public static let all = ModelProvider.allCases.map(ProviderDefinition.init)
}

public enum CLIProxyLoginState: Equatable, Sendable {
    case idle
    case authenticating
    case connected(modelCount: Int)
    case failed(String)
}

public enum ProviderPresentationTone: Equatable, Sendable {
    case neutral
    case connected
    case warning
    case critical
}

public struct ProviderPresentation: Equatable, Sendable {
    public var state: String
    public var detail: String
    public var tone: ProviderPresentationTone
    public var capacity: CapacityStatus

    public init(state: String, detail: String, tone: ProviderPresentationTone, capacity: CapacityStatus) {
        self.state = state
        self.detail = detail
        self.tone = tone
        self.capacity = capacity
    }
}

/// One concrete subscription/account. Multiple values may share the same
/// `modelProvider`; credentials, health and capacity remain account-scoped.
public struct Provider: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var endpoint: String
    public var authentication: ProviderAuthentication
    public var modelProvider: ModelProvider?
    /// Non-secret account identity reported by the provider login (usually an
    /// email address). Tokens and auth JSON never enter Workjet configuration.
    public var accountLabel: String?
    /// Opaque non-secret identifier of the external CLIProxy auth record.
    public var externalCredentialID: String?
    public var modelIDs: [String]
    public var status: ProviderStatus
    public var statusDetail: String
    public var capacity: CapacityStatus
    public var credentialReference: String?
    public var loginExecutable: String?
    public var loginArguments: [String]
    /// Lower values are attempted first when this account participates in its
    /// provider pool. UUID is the stable final tie-breaker.
    public var routingPriority: Int

    public init(id: UUID = UUID(), name: String, kind: ProviderKind, endpoint: String, authentication: ProviderAuthentication = .bearerToken, modelProvider: ModelProvider? = nil, accountLabel: String? = nil, externalCredentialID: String? = nil, modelIDs: [String] = [], status: ProviderStatus = .unverified, statusDetail: String = "Noch nicht geprüft.", capacity: CapacityStatus = .unavailable(reason: "Anbieterstatus und Kapazität wurden noch nicht verifiziert."), credentialReference: String? = nil, loginExecutable: String? = nil, loginArguments: [String] = [], routingPriority: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.authentication = authentication
        self.modelProvider = modelProvider
        self.accountLabel = accountLabel
        self.externalCredentialID = externalCredentialID
        self.modelIDs = Self.normalizedModels(modelIDs)
        self.status = status
        self.statusDetail = statusDetail
        self.capacity = capacity
        self.credentialReference = credentialReference ?? Self.credentialReference(for: id)
        self.loginExecutable = loginExecutable
        self.loginArguments = loginArguments
        self.routingPriority = routingPriority
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, endpoint, authentication, modelProvider, accountLabel, externalCredentialID, modelIDs, status, statusDetail, capacity, credentialReference, loginExecutable, loginArguments, routingPriority
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(ProviderKind.self, forKey: .kind)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        authentication = try values.decodeIfPresent(ProviderAuthentication.self, forKey: .authentication) ?? .bearerToken
        modelProvider = try values.decodeIfPresent(ModelProvider.self, forKey: .modelProvider)
        accountLabel = try values.decodeIfPresent(String.self, forKey: .accountLabel)
        externalCredentialID = try values.decodeIfPresent(String.self, forKey: .externalCredentialID)
        modelIDs = Self.normalizedModels(try values.decodeIfPresent([String].self, forKey: .modelIDs) ?? [])
        status = try values.decodeIfPresent(ProviderStatus.self, forKey: .status) ?? .unverified
        statusDetail = try values.decodeIfPresent(String.self, forKey: .statusDetail) ?? "Noch nicht geprüft."
        capacity = try values.decodeIfPresent(CapacityStatus.self, forKey: .capacity) ?? .unavailable(reason: "Anbieterstatus und Kapazität wurden noch nicht verifiziert.")
        credentialReference = try values.decodeIfPresent(String.self, forKey: .credentialReference) ?? Self.credentialReference(for: id)
        loginExecutable = try values.decodeIfPresent(String.self, forKey: .loginExecutable)
        loginArguments = try values.decodeIfPresent([String].self, forKey: .loginArguments) ?? []
        routingPriority = try values.decodeIfPresent(Int.self, forKey: .routingPriority) ?? 0
    }

    public static func credentialReference(for id: UUID) -> String {
        "provider-\(id.uuidString.lowercased())"
    }

    /// Compact account hint for dense UI. The complete non-secret identity is
    /// retained for matching, while the provider list avoids exposing it at a glance.
    public var compactAccountLabel: String? {
        guard let accountLabel else { return nil }
        let value = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let separator = value.firstIndex(of: "@") else { return value }
        let local = String(value[..<separator])
        let domain = String(value[value.index(after: separator)...])
        let prefix = String(local.prefix(min(2, local.count)))
        return "\(prefix)…@\(domain)"
    }

    public static func normalizedModels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    public static func deterministicPool(_ accounts: [Provider], for provider: ModelProvider) -> [Provider] {
        accounts
            .filter { $0.modelProvider == provider }
            .sorted {
                if $0.routingPriority != $1.routingPriority { return $0.routingPriority < $1.routingPriority }
                let left = $0.name.localizedCaseInsensitiveCompare($1.name)
                if left != .orderedSame { return left == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
}

public typealias ProviderAccount = Provider

public struct ProviderPool: Equatable, Sendable {
    public var provider: ModelProvider
    public var accounts: [Provider]

    public init(provider: ModelProvider, accounts: [Provider]) {
        self.provider = provider
        self.accounts = Provider.deterministicPool(accounts, for: provider)
    }

    public var accountIDs: [UUID] { accounts.map(\.id) }
    public var modelIDs: [String] {
        Provider.normalizedModels(accounts.flatMap(\.modelIDs) + provider.requestedModelSuggestions)
    }

    /// A sum is only valid when every account exposes the same unit and the
    /// same evidence class. Missing or mixed data stays explicitly unknown.
    public var capacity: CapacityStatus {
        guard !accounts.isEmpty else {
            return .unavailable(reason: "Für diesen Anbieter ist kein Zugang im Pool konfiguriert.")
        }
        var used = 0.0
        var limit = 0.0
        var unit: String?
        var rateLimited = false
        var measured: Bool?
        for account in accounts {
            let valueUsed: Double
            let valueLimit: Double
            let valueUnit: String
            let valueRateLimited: Bool
            let valueMeasured: Bool
            switch account.capacity {
            case let .measured(accountUsed, accountLimit, accountUnit, accountRateLimited):
                (valueUsed, valueLimit, valueUnit, valueRateLimited, valueMeasured) = (accountUsed, accountLimit, accountUnit, accountRateLimited, true)
            case let .userConfigured(accountUsed, accountLimit, accountUnit, accountRateLimited):
                (valueUsed, valueLimit, valueUnit, valueRateLimited, valueMeasured) = (accountUsed, accountLimit, accountUnit, accountRateLimited, false)
            case .unavailable:
                return .unavailable(reason: "Mindestens ein Zugang im Pool liefert keine belastbaren Kapazitätsdaten.")
            }
            guard valueUsed >= 0, valueLimit > 0, valueUsed <= valueLimit else {
                return .unavailable(reason: "Mindestens ein Zugang im Pool liefert ungültige Kapazitätsdaten.")
            }
            if let unit, unit != valueUnit {
                return .unavailable(reason: "Kapazitäten mit unterschiedlichen Einheiten werden nicht addiert.")
            }
            if let measured, measured != valueMeasured {
                return .unavailable(reason: "Gemessene und manuell konfigurierte Kapazitäten werden nicht vermischt.")
            }
            unit = valueUnit
            measured = valueMeasured
            used += valueUsed
            limit += valueLimit
            rateLimited = rateLimited || valueRateLimited
        }
        guard let unit, let measured else {
            return .unavailable(reason: "Keine belastbaren Kapazitätsdaten verfügbar.")
        }
        return measured
            ? .measured(used: used, limit: limit, unit: unit, rateLimited: rateLimited)
            : .userConfigured(used: used, limit: limit, unit: unit, rateLimited: rateLimited)
    }
}

public struct ProviderProbeResult: Equatable, Sendable {
    public var status: ProviderStatus
    public var detail: String
    public var modelIDs: [String]
    public var capacity: CapacityStatus

    public init(status: ProviderStatus, detail: String, modelIDs: [String] = [], capacity: CapacityStatus = .unavailable(reason: "Diese Anbieterprobe liefert keine account-spezifische Quote oder Rate.")) {
        self.status = status
        self.detail = detail
        self.modelIDs = Provider.normalizedModels(modelIDs)
        self.capacity = capacity
    }
}

public enum WorkerModelSuggestions {
    public static let defaults = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "claude-sonnet-5", "claude-opus-5", "k3[1m]", "MiniMax-M3"]

    public static func values(providerID: UUID?, providers: [Provider]) -> [String] {
        guard let providerID, let provider = providers.first(where: { $0.id == providerID }) else { return [] }
        let requested = provider.modelProvider?.requestedModelSuggestions ?? []
        return Provider.normalizedModels(provider.modelIDs + requested)
    }

    public static func values(route: ProviderRoute?, providers: [Provider]) -> [String] {
        switch route {
        case let .account(id): return values(providerID: id, providers: providers)
        case let .pool(provider): return ProviderPool(provider: provider, accounts: providers).modelIDs
        case nil: return []
        }
    }
}

public enum ModelPromptCatalog {
    public static let prototypeDiscoveryPrompt = """
    You are one of three discovery panel workers receiving the same discovery brief as the other panel members. Produce a bounded, disposable prototype or evidence-based approach that measures difficulty and improves a later production specification; this is not the final solution. Obey the brief's hard file whitelist and non-goals, use no subagents, and stop rather than widen scope. Report exactly: Approach; Produced prototype/evidence; Commands/results; Difficulty (1-5); Hidden constraints; Failure modes; Decisive tests; Recommended final-brief additions; Unresolved questions. End with the required WORKJET COMPLETION RECEIPT V1; the receipt is a claim for independent verification.
    """

    public static func canonicalName(for model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("kimi") || normalized.contains("k3") { return "Kimi K3" }
        if normalized == "gpt-5.6-sol" || normalized == "gpt-5.6 sol" { return "GPT-5.6 Sol" }
        if normalized == "minimax-m3" || normalized == "minimax m3" { return "MiniMax M3" }
        return model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let defaults: [String: String] = [
        "GPT-5.6 Sol": """
        Use Sol for final production implementation that is difficult and clearly specified. Supply exact scope, hard whitelist, non-goals, acceptance commands, artifacts, and stop conditions. Sol owns existing frontend adaptation and frontend-to-backend wiring; independently verify its diff, code, and tests.
        """,
        "Kimi K3": """
        Use Kimi UI/UX for greenfield or explicitly assigned visual implementation. Use Kimi Cyber & Review for read-oriented cybersecurity or independent adversarial review, requiring confirmed findings to be separated from hypotheses. Existing frontend adaptation and frontend-to-backend wiring remain with Sol.
        """,
        "MiniMax M3": """
        Use MiniMax only for clear, disjoint, counted, fixed-schema repetitive slices. Require coverage counts and explicit outputs, forbid edits to existing files and git use, stop on ambiguity, and independently sample the result afterward.
        """,
        "grok-4.5": prototypeDiscoveryPrompt,
        "gpt-5.6-luna": prototypeDiscoveryPrompt,
        "glm-5.2": prototypeDiscoveryPrompt,
        "gpt-5.6-terra": """
        Use Terra only for current online research with WebSearch and WebFetch. Require primary sources, direct links, careful separation of confirmed and uncertain evidence, no subagents, and no local repository, file, shell, or code work.
        """
    ]

    public static func prompt(for model: String, in prompts: [String: String]) -> String {
        prompts[canonicalName(for: model)] ?? ""
    }
}

public enum CLIProxyConnectionState: String, Codable, Equatable, Sendable {
    case unverified = "Nicht geprüft"
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
    /// Visible, editable instructions written into the Claude Code skill loader.
    /// YAML metadata is generated structurally and contains no operative policy.
    public var skillLoaderInstructions: String?
    /// Model-specific policy, keyed by `ModelPromptCatalog.canonicalName(for:)`.
    /// Optional keeps version-1 configuration files backwards decodable.
    public var modelPrompts: [String: String]?
    /// Visible orchestration-board policy rendered as its own prompt source.
    /// Optional keeps existing version-1 configuration files backwards decodable.
    public var progressBoardRules: String?
    /// Durable lessons from systematic, reproducible Workjet orchestration failures.
    /// Optional keeps version-1 configuration files backwards decodable.
    public var adHocLearnings: String?
    /// Workjet-specific technical instructions. This is user-visible and editable;
    /// the renderer must not add operative instructions outside this field.
    public var technicalRules: String?
    /// One-time migration flag for moving formerly hard-coded worker prompts
    /// into the visible technical-rules section.
    public var transparentWorkerPromptsMigrated: Bool?
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

    public init(version: Int = currentVersion, workers: [Worker], computers: [Computer], providers: [Provider], selectedComputerID: UUID, skillRules: String, skillLoaderInstructions: String? = nil, modelPrompts: [String: String]? = nil, progressBoardRules: String? = nil, adHocLearnings: String? = nil, technicalRules: String? = nil, transparentWorkerPromptsMigrated: Bool? = nil, skillActivation: SkillActivation = .global, injectWorkerDeclarations: Bool = true, telemetryClaudeCodeEvents: Bool = true, telemetrySidecarEvents: Bool = true, telemetryRetentionDays: Int = 14, providerSlots: Int = 3, probeTimeoutSeconds: Int = 120, turnTimeoutSeconds: Int = 5400, degradationAllowed: Bool = true, cliProxy: CLIProxyConfiguration = CLIProxyConfiguration()) {
        self.version = version
        self.workers = workers
        self.computers = computers
        self.providers = providers
        self.selectedComputerID = selectedComputerID
        self.skillRules = skillRules
        self.skillLoaderInstructions = skillLoaderInstructions
        self.modelPrompts = modelPrompts
        self.progressBoardRules = progressBoardRules
        self.adHocLearnings = adHocLearnings
        self.technicalRules = technicalRules
        self.transparentWorkerPromptsMigrated = transparentWorkerPromptsMigrated
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
