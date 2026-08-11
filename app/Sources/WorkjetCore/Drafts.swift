import Foundation

/// Editable draft for the worker editor. Validation is pure and testable.
public struct WorkerDraft: Equatable {
    public var name: String
    public var harness: Harness
    public var model: String
    public var instructions: String
    public var reasoningEffort: ReasoningEffort?
    public var computerID: UUID?
    public var providerID: UUID?
    public var providerPool: ModelProvider?
    public var skillOverrides: [String: Bool]
    public var executable: String
    public var arguments: String
    public var capabilities: String
    public var harnessOptions: [String: String]

    public init(worker: Worker? = nil) {
        let initialHarness = worker?.harness ?? .claudeCode
        self.name = worker?.name ?? ""
        self.harness = initialHarness
        self.model = worker?.model ?? ""
        self.instructions = worker?.instructions ?? ""
        self.reasoningEffort = worker?.reasoningEffort
        self.computerID = worker?.computerID
        self.providerID = worker?.providerID
        self.providerPool = worker?.providerPool
        self.skillOverrides = worker?.skillOverrides ?? [:]
        self.executable = worker?.invocation.executable ?? Self.defaultExecutable(for: initialHarness)
        self.arguments = worker?.invocation.arguments.joined(separator: "\n") ?? Self.defaultArguments(for: initialHarness)
        self.capabilities = worker?.invocation.capabilities.joined(separator: "\n") ?? ""
        self.harnessOptions = worker?.invocation.options ?? [:]
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

    public func configuredEnabled(for skill: WorkerSkillDescriptor) -> Bool {
        skill.configuredEnabled(overrides: skillOverrides)
    }

    public func effectiveEnabled(for skill: WorkerSkillDescriptor) -> Bool {
        skill.effectiveEnabled(overrides: skillOverrides, harness: harness)
    }

    public mutating func setConfiguredEnabled(_ enabled: Bool, for skill: WorkerSkillDescriptor) {
        WorkerSkillCatalog.setConfiguredEnabled(enabled, skill: skill, overrides: &skillOverrides)
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && computerID != nil
            && !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func defaultExecutable(for harness: Harness) -> String {
        HarnessAdapterRegistry.defaultLocalInvocation(for: harness)?.executable
            ?? HarnessAdapterRegistry.descriptor(for: harness).defaultInvocation.executable
    }

    public static func defaultArguments(for harness: Harness) -> String {
        (HarnessAdapterRegistry.defaultLocalInvocation(for: harness)
            ?? HarnessAdapterRegistry.descriptor(for: harness).defaultInvocation).arguments.joined(separator: "\n")
    }

    public mutating func selectHarness(_ harness: Harness) {
        let previousHarness = self.harness
        let executableWasDefault = executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || executable == Self.defaultExecutable(for: previousHarness)
        let argumentsWereDefault = arguments == Self.defaultArguments(for: previousHarness)
        self.harness = harness
        if executableWasDefault { executable = Self.defaultExecutable(for: harness) }
        if argumentsWereDefault { arguments = Self.defaultArguments(for: harness) }
        let adapter = HarnessAdapterRegistry.descriptor(for: harness)
        let allowedOptions = Set(adapter.options(for: model).map(\.id))
        harnessOptions = harnessOptions.filter { allowedOptions.contains($0.key) }
        if let effort = reasoningEffort, !adapter.reasoningEfforts(for: model).contains(effort) {
            reasoningEffort = nil
        }
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
        result.reasoningEffort = reasoningEffort
        result.computerID = computerID
        result.providerRoute = providerRoute
        result.skillOverrides = skillOverrides
        let adapter = HarnessAdapterRegistry.descriptor(for: harness)
        let allowedOptions = Set(adapter.options(for: result.model).map(\.id))
        result.invocation = WorkerInvocation(
            executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            capabilities: capabilities.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            options: harnessOptions.filter { allowedOptions.contains($0.key) }
        )
        return result
    }
}

/// Editable draft for the computer setup editor (Tailscale or SSH).
public struct ComputerDraft: Equatable {
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
    public var knownHostsPath: String
    public var identityFilePath: String
    public var tailscaleSSHEnabled: Bool

    public init(computer: Computer? = nil) {
        self.id = computer?.id ?? UUID()
        self.name = computer?.name ?? ""
        let transport = computer?.transport ?? .tailscale
        self.transport = transport == .local ? .tailscale : transport
        self.host = computer?.host ?? ""
        self.user = computer?.user ?? ""
        self.port = computer?.port ?? 22
        self.sandboxEnabled = computer?.sandboxEnabled ?? true
        self.pinnedSidecarVersion = PiSidecarRuntime.version
        self.telemetryEnabled = computer?.telemetryEnabled ?? false
        self.sidecarBundlePath = computer?.sidecarBundlePath ?? ""
        self.knownHostsPath = computer?.knownHostsPath ?? ""
        self.identityFilePath = computer?.identityFilePath ?? ""
        // New Tailscale computers use Tailscale SSH. Existing records without
        // the field remain on their proven legacy OpenSSH route until edited.
        self.tailscaleSSHEnabled = computer == nil ? true : (computer?.tailscaleSSHEnabled == true)
    }

    public static func preferredConnectionDefaults(in computers: [Computer], transport: ComputerTransport) -> Computer? {
        computers
            .filter {
                !$0.isLocal
                    && $0.transport == transport
                    && $0.deploymentStatus == .installed
                    && !$0.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .max {
                ($0.lastSuccessfulDeploymentAt ?? .distantPast) < ($1.lastSuccessfulDeploymentAt ?? .distantPast)
            }
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    public var isDeployable: Bool {
        isValid
            && !sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((transport == .tailscale && tailscaleSSHEnabled)
                || !knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public func applied(to computer: Computer?) -> Computer? {
        guard isValid, computer?.isLocal != true else { return nil }
        var result = computer ?? Computer(id: id, name: "", transport: transport)
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.transport = transport
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        result.port = port
        result.sandboxEnabled = sandboxEnabled
        result.pinnedSidecarVersion = PiSidecarRuntime.version
        result.telemetryEnabled = telemetryEnabled
        result.sidecarBundlePath = sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        result.knownHostsPath = knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        result.identityFilePath = identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tailscaleSSHEnabled = transport == .tailscale
            ? (tailscaleSSHEnabled ? true : computer?.tailscaleSSHEnabled)
            : nil
        if let computer {
            let routeChanged = computer.transport != result.transport
                || computer.host != result.host
                || computer.user != result.user
                || computer.port != result.port
                || computer.sandboxEnabled != result.sandboxEnabled
                || computer.sidecarBundlePath != result.sidecarBundlePath
                || computer.knownHostsPath != result.knownHostsPath
                || computer.identityFilePath != result.identityFilePath
                || computer.tailscaleSSHEnabled != result.tailscaleSSHEnabled
            if routeChanged {
                result.deploymentStatus = .notConfigured
                result.deploymentDetail = "Verbindungs- oder Bundle-Konfiguration wurde geändert; erneut prüfen und einrichten."
                result.remoteSetupIssue = nil
                result.installedContentHash = nil
                result.installedSidecarVersion = nil
                result.tailscaleExecutablePath = nil
                result.bubblewrapExecutablePath = nil
                result.lastSuccessfulPreflightAt = nil
                result.lastSuccessfulDeploymentAt = nil
            }
        }
        return result
    }
}
