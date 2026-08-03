import Foundation

/// Harness a worker runs on. Harness is a secondary property of a worker;
/// the role/persona name is the primary identity.
public enum Harness: String, CaseIterable, Codable, Equatable {
    case claudeCode = "Claude Code"
    case piSidecar = "Pi Sidecar"
}

public enum ComputerTransport: String, CaseIterable, Codable, Equatable {
    case local = "Lokal"
    case tailscale = "Tailscale"
    case ssh = "SSH"
}

/// A machine workers can run on. `Local` is always present; further
/// computers are reached via Tailscale or SSH.
public struct Computer: Identifiable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var transport: ComputerTransport
    public var host: String
    public var user: String
    public var port: Int
    public var sandboxEnabled: Bool
    public var pinnedSidecarVersion: String
    public var telemetryEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        transport: ComputerTransport,
        host: String = "",
        user: String = "",
        port: Int = 22,
        sandboxEnabled: Bool = true,
        pinnedSidecarVersion: String = "",
        telemetryEnabled: Bool = false
    ) {
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

/// Compact quota/rate state shown as tiny indicators in worker rows.
/// Exact quota details live in Settings.
public struct QuotaStatus: Equatable, Codable {
    public var usedPercent: Double
    public var rateLimited: Bool

    public init(usedPercent: Double, rateLimited: Bool) {
        self.usedPercent = min(max(usedPercent, 0), 1)
        self.rateLimited = rateLimited
    }

    public enum Level: Equatable {
        case ok, warning, critical
    }

    public var level: Level {
        switch usedPercent {
        case ..<0.7: return .ok
        case ..<0.9: return .warning
        default: return .critical
        }
    }
}

/// A worker is a role/persona (e.g. Completion Engine, Reviewer,
/// UI/UX-Experte, Bulk Worker). Model and harness are secondary.
public struct Worker: Identifiable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var harness: Harness
    public var model: String
    public var instructions: String
    public var computerID: UUID
    public var quota: QuotaStatus

    public init(
        id: UUID = UUID(),
        name: String,
        harness: Harness,
        model: String,
        instructions: String = "",
        computerID: UUID,
        quota: QuotaStatus = QuotaStatus(usedPercent: 0, rateLimited: false)
    ) {
        self.id = id
        self.name = name
        self.harness = harness
        self.model = model
        self.instructions = instructions
        self.computerID = computerID
        self.quota = quota
    }
}

/// A currently running worker shown in the pinned "Aktiv" area.
public struct ActiveRun: Identifiable, Equatable {
    public var id: UUID
    public var workerID: UUID
    public var workerName: String
    public var activity: String
    public var startedAt: Date

    public init(id: UUID = UUID(), workerID: UUID, workerName: String, activity: String, startedAt: Date) {
        self.id = id
        self.workerID = workerID
        self.workerName = workerName
        self.activity = activity
        self.startedAt = startedAt
    }
}

public enum ProviderKind: String, CaseIterable, Codable, Equatable {
    case cliProxy = "CLIProxy"
    case oauthSubscription = "OAuth/Abo"
    case apiKey = "API-Key"
}

public enum ProviderStatus: String, Codable, Equatable {
    case connected = "Verbunden"
    case degraded = "Eingeschränkt"
    case offline = "Offline"
}

/// A model-access provider (OAuth/subscription or API key). CLIProxy is
/// tracked separately as the local bridge for ChatGPT OAuth.
public struct Provider: Identifiable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var endpoint: String
    public var status: ProviderStatus
    public var quota: QuotaStatus

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        endpoint: String,
        status: ProviderStatus,
        quota: QuotaStatus = QuotaStatus(usedPercent: 0, rateLimited: false)
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.status = status
        self.quota = quota
    }
}

/// Status of the local CLIProxy bridge (ChatGPT OAuth → Anthropic API).
public struct CLIProxyStatus: Equatable, Codable {
    public var endpoint: String
    public var status: ProviderStatus
    public var account: String

    public init(endpoint: String, status: ProviderStatus, account: String) {
        self.endpoint = endpoint
        self.status = status
        self.account = account
    }
}

public enum SkillActivation: String, CaseIterable, Codable, Equatable {
    case skillOnly = "Skill (/workjet)"
    case global = "Global"
}
