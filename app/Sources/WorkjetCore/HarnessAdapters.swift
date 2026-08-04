import Foundation

public enum HarnessInvocationProtocol: String, Codable, Equatable, Sendable {
    case claudePrompt
    case piTurnNDJSON
    case codexAppServer
    case agentClientProtocol
    case openCodeHTTP
}

public struct HarnessOptionChoice: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct HarnessOptionDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var choices: [HarnessOptionChoice]
    public var defaultValue: String

    public init(id: String, label: String, choices: [HarnessOptionChoice], defaultValue: String) {
        self.id = id
        self.label = label
        self.choices = choices
        self.defaultValue = defaultValue
    }
}

public struct HarnessAdapterDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var harness: Harness
    public var invocationProtocol: HarnessInvocationProtocol
    public var defaultInvocation: WorkerInvocation

    public init(id: String, displayName: String, harness: Harness, invocationProtocol: HarnessInvocationProtocol, defaultInvocation: WorkerInvocation) {
        self.id = id
        self.displayName = displayName
        self.harness = harness
        self.invocationProtocol = invocationProtocol
        self.defaultInvocation = defaultInvocation
    }

    public func reasoningEfforts(for model: String) -> [ReasoningEffort] {
        switch harness {
        case .claudeCode:
            return [.low, .medium, .high, .xhigh, .max, .ultra, .ultracode, .ultrathink]
        case .piSidecar:
            return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .codexCLI:
            // app-server negotiates model settings through its protocol. Workjet
            // must not invent unsupported executable flags for that protocol.
            return []
        case .cursorAgent, .openCode, .grokCLI:
            return []
        }
    }

    public func options(for model: String) -> [HarnessOptionDescriptor] {
        guard harness == .claudeCode else { return [] }
        return [HarnessOptionDescriptor(
            id: "fastMode",
            label: "Geschwindigkeit",
            choices: [
                HarnessOptionChoice(id: "false", label: "Standard"),
                HarnessOptionChoice(id: "true", label: "Schnell")
            ],
            defaultValue: "false"
        )]
    }
}

public enum HarnessAdapterRegistry {
    public static let all: [HarnessAdapterDescriptor] = [
        HarnessAdapterDescriptor(id: "claude-code", displayName: "Claude Code", harness: .claudeCode, invocationProtocol: .claudePrompt, defaultInvocation: WorkerInvocation(executable: "claude", arguments: ["-p", "<WORKJET_BRIEF>"])),
        HarnessAdapterDescriptor(id: "pi-code", displayName: "Pi Code", harness: .piSidecar, invocationProtocol: .piTurnNDJSON, defaultInvocation: WorkerInvocation(executable: "node")),
        HarnessAdapterDescriptor(id: "codex-cli", displayName: "Codex CLI", harness: .codexCLI, invocationProtocol: .codexAppServer, defaultInvocation: WorkerInvocation(executable: "codex", arguments: ["app-server"])),
        HarnessAdapterDescriptor(id: "cursor-agent", displayName: "Cursor Agent", harness: .cursorAgent, invocationProtocol: .agentClientProtocol, defaultInvocation: WorkerInvocation(executable: "cursor-agent", arguments: ["acp"])),
        HarnessAdapterDescriptor(id: "opencode", displayName: "OpenCode", harness: .openCode, invocationProtocol: .openCodeHTTP, defaultInvocation: WorkerInvocation(executable: "opencode", arguments: ["serve"])),
        HarnessAdapterDescriptor(id: "grok-cli", displayName: "Grok CLI", harness: .grokCLI, invocationProtocol: .agentClientProtocol, defaultInvocation: WorkerInvocation(executable: "grok", arguments: ["agent", "stdio"]))
    ]

    public static func descriptor(for harness: Harness) -> HarnessAdapterDescriptor {
        // `all` is intentionally exhaustive and verified by tests. The fallback
        // remains deterministic for corrupt future enum migrations.
        all.first(where: { $0.harness == harness }) ?? all[0]
    }
}

public enum RemoteHarnessAdapterError: LocalizedError, Equatable {
    case unsupportedHarness(String)
    case invalidModel
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedHarness(value): return "Remote-Harness wird nicht unterstützt: \(value)."
        case .invalidModel: return "Das Remote-Harness benötigt eine gültige Modell-ID."
        case let .invalidInput(detail): return "Remote-Harness-Eingabe ist ungültig: \(detail)"
        }
    }
}

public struct RemoteHarnessLaunch: Codable, Equatable, Sendable {
    public var harnessID: String
    public var model: String
    public var reasoning: String?
    public var sandbox: Bool
    public var inputBase64: String
    public var options: [String: String]

    public init(harnessID: String, model: String, reasoning: String?, sandbox: Bool, input: Data, options: [String: String] = [:]) {
        self.harnessID = harnessID
        self.model = model
        self.reasoning = reasoning
        self.sandbox = sandbox
        self.inputBase64 = input.base64EncodedString()
        self.options = options
    }
}

public protocol RemoteHarnessAdapting: Sendable {
    var id: String { get }
    func launch(worker: Worker, computer: Computer, input: Data) throws -> RemoteHarnessLaunch
}

public struct ClaudeCodeRemoteAdapter: RemoteHarnessAdapting, Sendable {
    public let id = "claude-code"
    public init() {}

    public func launch(worker: Worker, computer: Computer, input: Data) throws -> RemoteHarnessLaunch {
        let model = worker.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw RemoteHarnessAdapterError.invalidModel }
        let brief = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, brief.utf8.count <= 1_048_576 else {
            throw RemoteHarnessAdapterError.invalidInput("Claude Code erwartet einen nicht leeren Brief bis 1 MiB.")
        }
        return RemoteHarnessLaunch(harnessID: id, model: model, reasoning: worker.reasoningEffort?.rawValue, sandbox: false, input: Data(brief.utf8), options: worker.invocation.options)
    }
}

public struct CodexCLIRemoteAdapter: RemoteHarnessAdapting, Sendable {
    public let id = "codex-cli"
    public init() {}

    public func launch(worker: Worker, computer: Computer, input: Data) throws -> RemoteHarnessLaunch {
        let model = worker.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw RemoteHarnessAdapterError.invalidModel }
        guard !brief.isEmpty, brief.utf8.count <= 1_048_576 else {
            throw RemoteHarnessAdapterError.invalidInput("Codex CLI erwartet einen nicht leeren Brief bis 1 MiB.")
        }
        return RemoteHarnessLaunch(harnessID: id, model: model, reasoning: worker.reasoningEffort?.rawValue, sandbox: computer.sandboxEnabled, input: Data(brief.utf8), options: worker.invocation.options)
    }
}

public struct OpenCodeRemoteAdapter: RemoteHarnessAdapting, Sendable {
    public let id = "opencode"
    public init() {}

    public func launch(worker: Worker, computer: Computer, input: Data) throws -> RemoteHarnessLaunch {
        let model = worker.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw RemoteHarnessAdapterError.invalidModel }
        // OpenCode's verified one-shot interface accepts the message as an
        // argv value. Stay below conservative Linux per-argument limits.
        guard !brief.isEmpty, brief.utf8.count <= 32_768 else {
            throw RemoteHarnessAdapterError.invalidInput("OpenCode erwartet einen nicht leeren Brief bis 32 KiB.")
        }
        return RemoteHarnessLaunch(harnessID: id, model: model, reasoning: worker.reasoningEffort?.rawValue, sandbox: computer.sandboxEnabled, input: Data(brief.utf8), options: worker.invocation.options)
    }
}

public struct PiCodeRemoteAdapter: RemoteHarnessAdapting, Sendable {
    public let id = "pi-code"
    public init() {}

    public func launch(worker: Worker, computer: Computer, input: Data) throws -> RemoteHarnessLaunch {
        let lines = String(decoding: input, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.count == 1, input.count <= 1_048_576,
              (try? JSONSerialization.jsonObject(with: Data(lines[0].utf8))) != nil else {
            throw RemoteHarnessAdapterError.invalidInput("Pi Code erwartet genau einen CtoxTurnRequest als NDJSON-Zeile bis 1 MiB.")
        }
        return RemoteHarnessLaunch(harnessID: id, model: worker.model, reasoning: worker.reasoningEffort?.rawValue, sandbox: computer.sandboxEnabled, input: Data(lines[0].utf8))
    }
}

public struct RemoteHarnessAdapterRegistry: Sendable {
    public init() {}

    public func supports(_ harness: Harness) -> Bool {
        switch harness {
        case .claudeCode, .piSidecar, .codexCLI, .openCode: return true
        case .cursorAgent, .grokCLI: return false
        }
    }

    public func launch(worker: Worker, computer: Computer, input: Data) throws -> RemoteHarnessLaunch {
        switch worker.harness {
        case .claudeCode:
            return try ClaudeCodeRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .piSidecar:
            return try PiCodeRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .codexCLI:
            return try CodexCLIRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .openCode:
            return try OpenCodeRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .cursorAgent, .grokCLI:
            throw RemoteHarnessAdapterError.unsupportedHarness(worker.harness.rawValue)
        }
    }
}
