import Foundation

/// Editable draft for the worker editor. Validation is pure and testable.
public struct WorkerDraft: Equatable {
    public var name: String
    public var harness: Harness
    public var model: String
    public var instructions: String
    public var computerID: UUID?
    public var executable: String
    public var arguments: String
    public var capabilities: String

    public init(worker: Worker? = nil) {
        self.name = worker?.name ?? ""
        self.harness = worker?.harness ?? .claudeCode
        self.model = worker?.model ?? ""
        self.instructions = worker?.instructions ?? ""
        self.computerID = worker?.computerID
        self.executable = worker?.invocation.executable ?? ""
        self.arguments = worker?.invocation.arguments.joined(separator: "\n") ?? ""
        self.capabilities = worker?.invocation.capabilities.joined(separator: "\n") ?? ""
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && computerID != nil
            && !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Applies the draft to an existing worker or creates a new one.
    public func applied(to worker: Worker?) -> Worker? {
        guard isValid, let computerID else { return nil }
        var result = worker ?? Worker(
            name: "",
            harness: harness,
            model: "",
            computerID: computerID
        )
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.harness = harness
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.instructions = instructions
        result.computerID = computerID
        result.invocation = WorkerInvocation(
            executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            capabilities: capabilities.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        return result
    }
}

/// Editable draft for the computer setup editor (Tailscale or SSH).
public struct ComputerDraft: Equatable {
    public var name: String
    public var transport: ComputerTransport
    public var host: String
    public var user: String
    public var port: Int
    public var sandboxEnabled: Bool
    public var pinnedSidecarVersion: String
    public var telemetryEnabled: Bool

    public init(computer: Computer? = nil) {
        self.name = computer?.name ?? ""
        let transport = computer?.transport ?? .tailscale
        self.transport = transport == .local ? .tailscale : transport
        self.host = computer?.host ?? ""
        self.user = computer?.user ?? ""
        self.port = computer?.port ?? 22
        self.sandboxEnabled = computer?.sandboxEnabled ?? true
        self.pinnedSidecarVersion = computer?.pinnedSidecarVersion ?? ""
        self.telemetryEnabled = computer?.telemetryEnabled ?? false
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    public func applied(to computer: Computer?) -> Computer? {
        guard isValid else { return nil }
        var result = computer ?? Computer(name: "", transport: transport)
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.transport = transport
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        result.port = port
        result.sandboxEnabled = sandboxEnabled
        result.pinnedSidecarVersion = pinnedSidecarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        result.telemetryEnabled = telemetryEnabled
        return result
    }
}
