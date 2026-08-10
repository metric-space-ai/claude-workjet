import Foundation

public enum HarnessInvocationProtocol: String, Codable, Equatable, Sendable {
    case claudePrompt
    case piTurnNDJSON
    case codexExec
    case agentClientProtocol
    case openCodeRun
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
            return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .piSidecar:
            return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .codexCLI:
            return [.low, .medium, .high, .xhigh]
        case .openCode:
            return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .cursorAgent, .grokCLI:
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
        HarnessAdapterDescriptor(id: "claude-code", displayName: "Claude Code", harness: .claudeCode, invocationProtocol: .claudePrompt, defaultInvocation: WorkerInvocation(executable: "claude", arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])),
        HarnessAdapterDescriptor(id: "pi-code", displayName: "Pi Code", harness: .piSidecar, invocationProtocol: .piTurnNDJSON, defaultInvocation: WorkerInvocation(executable: "node")),
        HarnessAdapterDescriptor(id: "codex-cli", displayName: "Codex CLI", harness: .codexCLI, invocationProtocol: .codexExec, defaultInvocation: WorkerInvocation(executable: "codex", arguments: ["exec", "--json", "<WORKJET_BRIEF>"])),
        HarnessAdapterDescriptor(id: "cursor-agent", displayName: "Cursor Agent", harness: .cursorAgent, invocationProtocol: .agentClientProtocol, defaultInvocation: WorkerInvocation(executable: "cursor-agent", arguments: ["acp"])),
        HarnessAdapterDescriptor(id: "opencode", displayName: "OpenCode", harness: .openCode, invocationProtocol: .openCodeRun, defaultInvocation: WorkerInvocation(executable: "opencode", arguments: ["run", "--format", "json", "<WORKJET_BRIEF>"])),
        HarnessAdapterDescriptor(id: "grok-cli", displayName: "Grok CLI", harness: .grokCLI, invocationProtocol: .agentClientProtocol, defaultInvocation: WorkerInvocation(executable: "grok", arguments: ["agent", "stdio"]))
    ]

    /// Harnesses with a verified local, non-interactive one-shot contract.
    /// Pi is intentionally absent until LocalRunService speaks the bundled
    /// sidecar's NDJSON protocol instead of treating it as an argv program.
    public static let local: [HarnessAdapterDescriptor] = all.filter {
        switch $0.harness {
        case .claudeCode, .codexCLI, .openCode: true
        case .piSidecar, .cursorAgent, .grokCLI: false
        }
    }

    public static func supportsLocalExecution(_ harness: Harness) -> Bool {
        local.contains(where: { $0.harness == harness })
    }

    /// Resolves the lifecycle-probed executable instead of persisting a PATH
    /// lookup that LocalRunService cannot verify later.
    public static func defaultLocalInvocation(for harness: Harness) -> WorkerInvocation? {
        guard supportsLocalExecution(harness) else { return nil }
        let driver = lifecycleDriver(for: harness)
        guard let executable = FileSystemHarnessBinaryLocator().firstExecutable(in: driver.binaryCandidates) else { return nil }
        var invocation = descriptor(for: harness).defaultInvocation
        invocation.executable = executable
        return invocation
    }

    public static func localInvocationIssue(harness: Harness, invocation: WorkerInvocation) -> String? {
        guard supportsLocalExecution(harness) else {
            return "Dieses Harness besitzt noch keine verifizierte lokale One-Shot-Schnittstelle."
        }
        let expanded = (invocation.executable as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: expanded) else {
            return "Die lokale ausführbare Datei muss als vorhandener absoluter Pfad gewählt werden."
        }
        let placeholderCount = invocation.arguments.filter { $0 == "<WORKJET_BRIEF>" }.count
        guard placeholderCount == 1 else {
            return "Der lokale Aufruf benötigt genau einen eigenen <WORKJET_BRIEF>-Argumentplatzhalter."
        }
        switch harness {
        case .claudeCode:
            guard invocation.arguments.contains("-p") || invocation.arguments.contains("--print") else {
                return "Claude Code muss als nicht interaktiver Print-Aufruf (-p) konfiguriert sein."
            }
            guard let toolsIndex = invocation.arguments.firstIndex(of: "--allowedTools"),
                  invocation.arguments.indices.contains(toolsIndex + 1),
                  !invocation.arguments[toolsIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Claude Code benötigt für den headless Workjet-Lauf eine explizite, nicht leere --allowedTools-Liste."
            }
        case .codexCLI:
            guard let execIndex = invocation.arguments.firstIndex(of: "exec"),
                  execIndex < invocation.arguments.firstIndex(of: "<WORKJET_BRIEF>")! else {
                return "Codex CLI muss über den verifizierten One-Shot-Aufruf „codex exec“ gestartet werden; globale Optionen wie --search müssen davor stehen."
            }
        case .openCode:
            guard invocation.arguments.first == "run" else {
                return "OpenCode muss über den verifizierten One-Shot-Aufruf „opencode run“ gestartet werden."
            }
        case .piSidecar, .cursorAgent, .grokCLI:
            return "Dieses Harness besitzt noch keine verifizierte lokale One-Shot-Schnittstelle."
        }
        return nil
    }

    public static func allowedTools(in invocation: WorkerInvocation) -> [String]? {
        guard let index = invocation.arguments.firstIndex(of: "--allowedTools"),
              invocation.arguments.indices.contains(index + 1) else { return nil }
        let tools = invocation.arguments[index + 1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return tools.isEmpty ? nil : tools
    }

    public static func descriptor(for harness: Harness) -> HarnessAdapterDescriptor {
        // `all` is intentionally exhaustive and verified by tests. The fallback
        // remains deterministic for corrupt future enum migrations.
        all.first(where: { $0.harness == harness }) ?? all[0]
    }

    /// Static invocation metadata and lifecycle truth are deliberately kept
    /// separate. Callers must run this driver before presenting a harness as
    /// usable; a non-empty `defaultInvocation.executable` is not readiness.
    public static func lifecycleDriver(for harness: Harness) -> any HarnessLifecycleDriving {
        HarnessLifecycleRegistry.driver(for: harness)
    }
}

public enum RemoteHarnessAdapterError: LocalizedError, Equatable {
    case unsupportedHarness(String)
    case invalidModel
    case invalidInput(String)
    case workspaceRequired

    public var errorDescription: String? {
        switch self {
        case let .unsupportedHarness(value): return "Remote-Harness wird nicht unterstützt: \(value)."
        case .invalidModel: return "Das Remote-Harness benötigt eine gültige Modell-ID."
        case let .invalidInput(detail): return "Remote-Harness-Eingabe ist ungültig: \(detail)"
        case .workspaceRequired: return "Dieses Remote-Harness benötigt einen vorbereiteten Git-Workspace."
        }
    }
}

public struct RemoteHarnessLaunch: Codable, Equatable, Sendable {
    public var harnessID: String
    public var model: String
    public var reasoning: String?
    public var sandbox: Bool
    public var inputBase64: String
    /// A real harness system-prompt appendix. Never merge these bytes into the
    /// user brief; only harness adapters with a verified system-prompt API may
    /// populate this field.
    public var systemPromptBase64: String?
    public var allowedTools: [String]?
    public var options: [String: String]
    public var workspace: RemoteWorkspaceDescriptor?
    /// A narrowly-scoped, read-only liveness probe. The remote host accepts
    /// this only with Workjet's exact fixed health prompt and no workspace.
    public var healthProbe: Bool?
    /// Opt-in additive web capability. The host validates the matching Codex
    /// dependency and injects only the already selected gateway credential.
    public var webResearch: Bool?
    /// Opt-in managed Greppy runtime. The host gives it a Workjet-owned cache
    /// so unrelated user-level Greppy state cannot break a worker launch.
    public var greppy: Bool?

    public init(harnessID: String, model: String, reasoning: String?, sandbox: Bool, input: Data, systemPrompt: String? = nil, allowedTools: [String]? = nil, options: [String: String] = [:], workspace: RemoteWorkspaceDescriptor? = nil, healthProbe: Bool = false, webResearch: Bool = false, greppy: Bool = false) {
        self.harnessID = harnessID
        self.model = model
        self.reasoning = reasoning
        self.sandbox = sandbox
        self.inputBase64 = input.base64EncodedString()
        self.systemPromptBase64 = systemPrompt.map { Data($0.utf8).base64EncodedString() }
        self.allowedTools = allowedTools
        self.options = options
        self.workspace = workspace
        self.healthProbe = healthProbe ? true : nil
        self.webResearch = webResearch ? true : nil
        self.greppy = greppy ? true : nil
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
        // The current remote Codex runner has no verified filesystem sandbox.
        // Never advertise the computer's Pi-only bubblewrap boundary here.
        return RemoteHarnessLaunch(harnessID: id, model: model, reasoning: worker.reasoningEffort?.rawValue, sandbox: false, input: Data(brief.utf8), options: worker.invocation.options)
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
        // The current remote OpenCode runner has no verified filesystem
        // sandbox. Only Pi Code may request the deployed bubblewrap boundary.
        return RemoteHarnessLaunch(harnessID: id, model: model, reasoning: worker.reasoningEffort?.rawValue, sandbox: false, input: Data(brief.utf8), options: worker.invocation.options)
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
        return RemoteHarnessLaunch(harnessID: id, model: worker.model, reasoning: worker.reasoningEffort?.rawValue, sandbox: computer.sandboxEnabled, input: Data(lines[0].utf8), options: worker.invocation.options)
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

    public func launch(worker: Worker, computer: Computer, input: Data, systemPrompt: String? = nil, workspace: RemoteWorkspaceDescriptor? = nil) throws -> RemoteHarnessLaunch {
        var launch: RemoteHarnessLaunch
        switch worker.harness {
        case .claudeCode:
            launch = try ClaudeCodeRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .piSidecar:
            launch = try PiCodeRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .codexCLI:
            launch = try CodexCLIRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .openCode:
            launch = try OpenCodeRemoteAdapter().launch(worker: worker, computer: computer, input: input)
        case .cursorAgent, .grokCLI:
            throw RemoteHarnessAdapterError.unsupportedHarness(worker.harness.rawValue)
        }
        if let systemPrompt {
            let bytes = systemPrompt.utf8
            guard worker.harness == .claudeCode else {
                throw RemoteHarnessAdapterError.invalidInput("Dieses Harness besitzt keine verifizierte System-Prompt-Erweiterung.")
            }
            guard !bytes.isEmpty, bytes.count <= 65_536, !systemPrompt.contains("\0") else {
                throw RemoteHarnessAdapterError.invalidInput("Der Harness-System-Prompt muss nicht leer, frei von NUL-Bytes und höchstens 64 KiB groß sein.")
            }
            launch.systemPromptBase64 = Data(bytes).base64EncodedString()
        }
        if worker.harness == .claudeCode {
            guard let tools = HarnessAdapterRegistry.allowedTools(in: worker.invocation),
                  tools.allSatisfy({ $0.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil }) else {
                throw RemoteHarnessAdapterError.invalidInput("Claude Code benötigt eine gültige explizite --allowedTools-Liste.")
            }
            if systemPrompt != nil, !tools.contains("Bash") {
                throw RemoteHarnessAdapterError.invalidInput("Ein aktivierter Workjet-Skill benötigt das freigegebene Claude-Code-Tool Bash.")
            }
            launch.allowedTools = tools
        }
        let healthProbe = worker.invocation.options["workjet.health-probe"] == "v1"
        launch.healthProbe = healthProbe ? true : nil
        let webResearch = !healthProbe && WorkerSkillCatalog.effectiveSkills(for: worker).contains(where: { $0.id == WorkerSkillCatalog.webResearchID })
        launch.webResearch = webResearch ? true : nil
        let greppy = !healthProbe && WorkerSkillCatalog.effectiveSkills(for: worker).contains(where: { $0.id == WorkerSkillCatalog.greppyID })
        launch.greppy = greppy ? true : nil
        launch.options.removeValue(forKey: "workjet.health-probe")
        if worker.harness == .piSidecar {
            launch.workspace = nil // Preserve Pi Code's explicit in-memory request contract.
        } else if healthProbe {
            launch.workspace = nil
        } else {
            guard let workspace else { throw RemoteHarnessAdapterError.workspaceRequired }
            launch.workspace = workspace
        }
        return launch
    }
}
