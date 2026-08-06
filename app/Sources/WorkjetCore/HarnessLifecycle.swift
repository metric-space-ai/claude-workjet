import Foundation

public enum HarnessLifecycleStatus: Equatable, Sendable {
    case missing
    case installed(executable: String)
    case version(executable: String, value: String)
    case updateUnknown(executable: String, version: String?)
    case broken(executable: String?, detail: String)

    public var executable: String? {
        switch self {
        case .missing: return nil
        case let .installed(executable), let .version(executable, _), let .updateUnknown(executable, _): return executable
        case let .broken(executable, _): return executable
        }
    }

    public var detectedVersion: String? {
        switch self {
        case let .version(_, value): return value
        case let .updateUnknown(_, version): return version
        case .missing, .installed, .broken: return nil
        }
    }
}

public enum HarnessCapability: String, Equatable, Sendable {
    case claudePrompt
    case codexExec
    case cursorACP
    case grokACP
    case openCodeRun
    case piBundledRuntime
}

public enum HarnessDeploymentAssessment: Equatable, Sendable {
    case notEvaluated
    case capable
    case broken(String)
}

public struct HarnessDeploymentReadiness: Equatable, Sendable {
    public var local: HarnessDeploymentAssessment
    public var remote: HarnessDeploymentAssessment

    public init(local: HarnessDeploymentAssessment, remote: HarnessDeploymentAssessment) {
        self.local = local
        self.remote = remote
    }
}

public struct HarnessDiscovery: Equatable, Sendable {
    public var harness: Harness
    public var status: HarnessLifecycleStatus

    public init(harness: Harness, status: HarnessLifecycleStatus) {
        self.harness = harness
        self.status = status
    }
}

public struct HarnessDoctorReport: Equatable, Sendable {
    public var discovery: HarnessDiscovery
    public var capabilities: Set<HarnessCapability>
    public var deployment: HarnessDeploymentReadiness

    public init(discovery: HarnessDiscovery, capabilities: Set<HarnessCapability>, deployment: HarnessDeploymentReadiness) {
        self.discovery = discovery
        self.capabilities = capabilities
        self.deployment = deployment
    }
}

public enum HarnessMaintenanceOperation: String, Equatable, Sendable {
    case install
    case update
    case remove
}

public enum HarnessInstallationChannel: String, Equatable, Sendable {
    case npm
    case bun
    case pnpm
    case vitePlus
    case homebrew
    case native
}

public struct HarnessMaintenancePlan: Equatable, Sendable {
    public var operation: HarnessMaintenanceOperation
    public var channel: HarnessInstallationChannel
    public var executable: String
    public var arguments: [String]

    public init(operation: HarnessMaintenanceOperation, channel: HarnessInstallationChannel, executable: String, arguments: [String]) {
        self.operation = operation
        self.channel = channel
        self.executable = executable
        self.arguments = arguments
    }
}

public enum HarnessMaintenancePlanAvailability: Equatable, Sendable {
    case supported(HarnessMaintenancePlan)
    case unsupported(String)
}

public protocol HarnessBinaryLocating: Sendable {
    func firstExecutable(in candidates: [String]) -> String?
}

public struct FileSystemHarnessBinaryLocator: HarnessBinaryLocating, Sendable {
    public init() {}

    public func firstExecutable(in candidates: [String]) -> String? {
        candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}

public protocol HarnessLifecycleDriving: Sendable {
    var harness: Harness { get }
    var binaryCandidates: [String] { get }
    func discover(locator: any HarnessBinaryLocating, runner: any CommandRunning) async -> HarnessDiscovery
    func doctor(locator: any HarnessBinaryLocating, runner: any CommandRunning) async -> HarnessDoctorReport
    func installPlan(locator: any HarnessBinaryLocating) -> HarnessMaintenancePlanAvailability
    func updatePlan(for discovery: HarnessDiscovery) -> HarnessMaintenancePlanAvailability
    func removePlan(for discovery: HarnessDiscovery) -> HarnessMaintenancePlanAvailability
}

public extension HarnessLifecycleDriving {
    func discover(runner: any CommandRunning = ProcessCommandRunner()) async -> HarnessDiscovery {
        await discover(locator: FileSystemHarnessBinaryLocator(), runner: runner)
    }

    func doctor(runner: any CommandRunning = ProcessCommandRunner()) async -> HarnessDoctorReport {
        await doctor(locator: FileSystemHarnessBinaryLocator(), runner: runner)
    }

    func installPlan() -> HarnessMaintenancePlanAvailability {
        installPlan(locator: FileSystemHarnessBinaryLocator())
    }
}

public enum HarnessLifecycleRegistry {
    public static let all: [any HarnessLifecycleDriving] = Harness.allCases.map { HarnessLifecycleDriver(harness: $0) }

    public static func driver(for harness: Harness) -> any HarnessLifecycleDriving {
        HarnessLifecycleDriver(harness: harness)
    }
}

public struct HarnessLifecycleDriver: HarnessLifecycleDriving, Sendable {
    public let harness: Harness

    public init(harness: Harness) {
        self.harness = harness
    }

    public var binaryCandidates: [String] { definition.binaryCandidates }

    public func discover(locator: any HarnessBinaryLocating, runner: any CommandRunning) async -> HarnessDiscovery {
        if harness == .piSidecar {
            return HarnessDiscovery(
                harness: harness,
                status: .version(executable: "bundled://pi-code", value: PiSidecarRuntime.version)
            )
        }
        guard let located = locator.firstExecutable(in: definition.binaryCandidates),
              definition.binaryCandidates.contains(located),
              located.hasPrefix("/") else {
            return HarnessDiscovery(harness: harness, status: .missing)
        }
        let executable = located
        let result: CommandResult
        do {
            result = try await runner.run(probe(executable: executable, arguments: definition.versionArguments))
        } catch {
            return HarnessDiscovery(harness: harness, status: .broken(executable: executable, detail: "Die Installation konnte nicht geprüft werden."))
        }
        guard !result.stdoutTruncated, !result.stderrTruncated else {
            return HarnessDiscovery(harness: harness, status: .broken(executable: executable, detail: "Die Installation lieferte bei der Prüfung zu viele Daten."))
        }
        guard result.exitCode == 0 else {
            return HarnessDiscovery(harness: harness, status: .broken(executable: executable, detail: "Die Installation antwortet nicht wie erwartet. Prüfe oder aktualisiere sie."))
        }
        let text = combinedOutput(result)
        let version = parseVersion(text)
        let hasKnownMaintenance = definition.package != nil || definition.nativeUpdateArguments != nil
        if !hasKnownMaintenance || installationChannel(for: executable) == nil {
            return HarnessDiscovery(harness: harness, status: .updateUnknown(executable: executable, version: version))
        }
        if let version {
            return HarnessDiscovery(harness: harness, status: .version(executable: executable, value: version))
        }
        return HarnessDiscovery(harness: harness, status: .installed(executable: executable))
    }

    public func doctor(locator: any HarnessBinaryLocating, runner: any CommandRunning) async -> HarnessDoctorReport {
        let discovery = await discover(locator: locator, runner: runner)
        if harness == .piSidecar {
            return HarnessDoctorReport(
                discovery: discovery,
                capabilities: [.piBundledRuntime],
                deployment: HarnessDeploymentReadiness(local: .notEvaluated, remote: .notEvaluated)
            )
        }
        guard let executable = discovery.status.executable else {
            return HarnessDoctorReport(
                discovery: discovery,
                capabilities: [],
                deployment: HarnessDeploymentReadiness(local: .broken("Nicht installiert."), remote: .notEvaluated)
            )
        }
        if case .broken = discovery.status {
            return HarnessDoctorReport(
                discovery: discovery,
                capabilities: [],
                deployment: HarnessDeploymentReadiness(local: .broken("Versionsprüfung fehlgeschlagen."), remote: .notEvaluated)
            )
        }

        let result: CommandResult
        do {
            result = try await runner.run(probe(
                executable: executable,
                arguments: definition.capabilityArguments,
                input: definition.capabilityInput
            ))
        } catch {
            let detail = "Die Installation konnte nicht vollständig geprüft werden."
            let broken = HarnessDiscovery(harness: harness, status: .broken(executable: executable, detail: detail))
            return HarnessDoctorReport(discovery: broken, capabilities: [], deployment: .init(local: .broken(detail), remote: .notEvaluated))
        }
        let capabilityWorks = result.exitCode == 0
            && !result.stdoutTruncated
            && !result.stderrTruncated
            && definition.capabilityVerifier(combinedOutput(result))
        guard capabilityWorks else {
            let detail = "Die Installation ist vorhanden, aber noch nicht einsatzbereit. Prüfe oder aktualisiere sie."
            let broken = HarnessDiscovery(harness: harness, status: .broken(executable: executable, detail: detail))
            return HarnessDoctorReport(discovery: broken, capabilities: [], deployment: .init(local: .broken(detail), remote: .notEvaluated))
        }
        return HarnessDoctorReport(
            discovery: discovery,
            capabilities: [definition.capability],
            deployment: .init(local: .capable, remote: .notEvaluated)
        )
    }

    public func installPlan(locator: any HarnessBinaryLocating) -> HarnessMaintenancePlanAvailability {
        guard let package = definition.package else {
            return .unsupported("Diese Installation muss außerhalb von Workjet eingerichtet werden.")
        }
        // More than one installed manager would make an automatic choice a guess.
        let managers = PackageManagerDefinition.all.compactMap { manager -> (PackageManagerDefinition, String)? in
            guard let located = locator.firstExecutable(in: manager.candidates),
                  manager.candidates.contains(located), located.hasPrefix("/") else { return nil }
            return (manager, located)
        }
        guard managers.count == 1, let (manager, executable) = managers.first else {
            return .unsupported(managers.isEmpty ? "Die automatische Installation ist auf diesem Computer nicht verfügbar." : "Wähle zuerst eine eindeutige vorhandene Installation aus.")
        }
        return .supported(plan(operation: .install, channel: manager.channel, executable: executable, arguments: manager.install(package)))
    }

    public func updatePlan(for discovery: HarnessDiscovery) -> HarnessMaintenancePlanAvailability {
        maintenancePlan(.update, discovery: discovery)
    }

    public func removePlan(for discovery: HarnessDiscovery) -> HarnessMaintenancePlanAvailability {
        maintenancePlan(.remove, discovery: discovery)
    }

    private func maintenancePlan(_ operation: HarnessMaintenanceOperation, discovery: HarnessDiscovery) -> HarnessMaintenancePlanAvailability {
        guard discovery.harness == harness, let executable = discovery.status.executable, !executable.hasPrefix("bundled://") else {
            return .unsupported("Die Installation wurde noch nicht erkannt.")
        }
        guard let channel = installationChannel(for: executable) else {
            return .unsupported("Diese Installation kann nicht automatisch verwaltet werden.")
        }
        if channel == .native {
            guard operation == .update, let nativeArguments = definition.nativeUpdateArguments else {
                return .unsupported("Diese Aktion ist für die vorhandene Installation nicht verfügbar.")
            }
            return .supported(plan(operation: operation, channel: channel, executable: executable, arguments: nativeArguments))
        }
        guard let package = definition.package, let manager = PackageManagerDefinition.definition(for: channel) else {
            return .unsupported("Diese Installation kann nicht automatisch verwaltet werden.")
        }
        let managerExecutable = manager.executable(forBinaryAt: executable)
        let arguments = operation == .update ? manager.update(package) : manager.remove(package)
        return .supported(plan(operation: operation, channel: channel, executable: managerExecutable, arguments: arguments))
    }

    private func plan(operation: HarnessMaintenanceOperation, channel: HarnessInstallationChannel, executable: String, arguments: [String]) -> HarnessMaintenancePlan {
        HarnessMaintenancePlan(operation: operation, channel: channel, executable: executable, arguments: arguments)
    }

    private func probe(executable: String, arguments: [String], input: Data = Data()) -> CommandSpec {
        CommandSpec(executable: executable, arguments: arguments, standardInput: input, timeout: 5, stdoutLimit: 65_536, stderrLimit: 32_768)
    }

    private func installationChannel(for executable: String) -> HarnessInstallationChannel? {
        let normalized = executable.lowercased().replacingOccurrences(of: "\\", with: "/")
        if definition.nativePathFragments.contains(where: normalized.contains) { return .native }
        return packageChannel(for: normalized)
    }

    private var definition: DriverDefinition { DriverDefinition.forHarness(harness) }
}

private struct DriverDefinition: Sendable {
    var binaryCandidates: [String]
    var versionArguments: [String]
    var capabilityArguments: [String]
    var capabilityInput: Data
    var capability: HarnessCapability
    var package: String?
    var nativeUpdateArguments: [String]?
    var nativePathFragments: [String]
    var capabilityVerifier: @Sendable (String) -> Bool

    static func forHarness(_ harness: Harness) -> DriverDefinition {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch harness {
        case .claudeCode:
            return DriverDefinition(
                binaryCandidates: candidates("claude", home: home) + ["\(home)/.local/bin/claude"],
                versionArguments: ["--version"], capabilityArguments: ["--help"], capabilityInput: Data(),
                capability: .claudePrompt, package: "@anthropic-ai/claude-code", nativeUpdateArguments: ["update"],
                nativePathFragments: ["/.local/bin/claude", "/.local/share/claude/"],
                capabilityVerifier: { $0.contains("--print") || $0.contains("-p,") || $0.contains("-p ") }
            )
        case .codexCLI:
            return DriverDefinition(
                binaryCandidates: candidates("codex", home: home), versionArguments: ["--version"],
                capabilityArguments: ["exec", "--help"], capabilityInput: Data(),
                capability: .codexExec, package: "@openai/codex", nativeUpdateArguments: nil, nativePathFragments: [],
                capabilityVerifier: { text in
                    let lower = text.lowercased()
                    return lower.contains("codex exec") && lower.contains("prompt") && lower.contains("--model")
                }
            )
        case .cursorAgent:
            return DriverDefinition(
                binaryCandidates: candidates("cursor-agent", home: home), versionArguments: ["--version"],
                capabilityArguments: ["acp"], capabilityInput: acpInitialize(name: "workjet-cursor-doctor"),
                capability: .cursorACP, package: nil, nativeUpdateArguments: ["update"], nativePathFragments: ["/cursor-agent"],
                capabilityVerifier: acpVerifier
            )
        case .grokCLI:
            return DriverDefinition(
                binaryCandidates: candidates("grok", home: home), versionArguments: ["--version"],
                capabilityArguments: ["agent", "stdio"], capabilityInput: acpInitialize(name: "workjet-grok-doctor"),
                capability: .grokACP, package: nil, nativeUpdateArguments: nil, nativePathFragments: [],
                capabilityVerifier: acpVerifier
            )
        case .openCode:
            return DriverDefinition(
                binaryCandidates: ["\(home)/.opencode/bin/opencode"] + candidates("opencode", home: home),
                versionArguments: ["--version"], capabilityArguments: ["run", "--help"], capabilityInput: Data(),
                capability: .openCodeRun, package: "opencode-ai", nativeUpdateArguments: ["upgrade"],
                nativePathFragments: ["/.opencode/bin/opencode"],
                capabilityVerifier: { text in
                    let lower = text.lowercased()
                    return lower.contains("opencode run") && lower.contains("message") && lower.contains("--model")
                }
            )
        case .piSidecar:
            return DriverDefinition(binaryCandidates: [], versionArguments: [], capabilityArguments: [], capabilityInput: Data(), capability: .piBundledRuntime, package: nil, nativeUpdateArguments: nil, nativePathFragments: [], capabilityVerifier: { _ in true })
        }
    }

    private static func candidates(_ name: String, home: String) -> [String] {
        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.local/share/pnpm/\(name)",
            "\(home)/.npm-global/bin/\(name)"
        ]
    }
}

private struct PackageManagerDefinition: Sendable {
    var channel: HarnessInstallationChannel
    var candidates: [String]
    var install: @Sendable (String) -> [String]
    var update: @Sendable (String) -> [String]
    var remove: @Sendable (String) -> [String]

    static var all: [PackageManagerDefinition] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            .init(channel: .npm, candidates: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"], install: { ["install", "-g", "\($0)@latest"] }, update: { ["install", "-g", "\($0)@latest"] }, remove: { ["uninstall", "-g", $0] }),
            .init(channel: .bun, candidates: ["\(home)/.bun/bin/bun"], install: { ["install", "-g", "\($0)@latest"] }, update: { ["install", "-g", "\($0)@latest"] }, remove: { ["remove", "-g", $0] }),
            .init(channel: .pnpm, candidates: ["\(home)/.local/share/pnpm/pnpm", "/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"], install: { ["add", "-g", "\($0)@latest"] }, update: { ["add", "-g", "\($0)@latest"] }, remove: { ["remove", "-g", $0] }),
            .init(channel: .vitePlus, candidates: ["\(home)/.vite-plus/bin/vp"], install: { ["install", "-g", $0] }, update: { ["install", "-g", $0] }, remove: { ["remove", "-g", $0] }),
            .init(channel: .homebrew, candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], install: { ["install", brewFormula($0)] }, update: { ["upgrade", brewFormula($0)] }, remove: { ["uninstall", brewFormula($0)] })
        ]
    }

    static func definition(for channel: HarnessInstallationChannel) -> PackageManagerDefinition? {
        all.first(where: { $0.channel == channel })
    }

    func executable(forBinaryAt binary: String) -> String {
        if binary.hasPrefix("/opt/homebrew/bin/") { return "/opt/homebrew/bin/\(toolName)" }
        if binary.hasPrefix("/usr/local/bin/") { return "/usr/local/bin/\(toolName)" }
        if binary.contains("/.bun/bin/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/bun").path }
        if binary.contains("/.local/share/pnpm/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pnpm/pnpm").path }
        if binary.contains("/.vite-plus/bin/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vite-plus/bin/vp").path }
        if binary.contains("/.npm-global/bin/") { return "/usr/local/bin/npm" }
        return candidates[0]
    }

    private var toolName: String {
        switch channel {
        case .npm: return "npm"
        case .bun: return "bun"
        case .pnpm: return "pnpm"
        case .vitePlus: return "vp"
        case .homebrew: return "brew"
        case .native: return ""
        }
    }

    private static func brewFormula(_ package: String) -> String {
        switch package {
        case "@anthropic-ai/claude-code": return "claude-code"
        case "@openai/codex": return "codex"
        case "opencode-ai": return "anomalyco/tap/opencode"
        default: return package
        }
    }
}

private func packageChannel(for normalized: String) -> HarnessInstallationChannel? {
    if normalized.contains("/.bun/bin/") { return .bun }
    if normalized.contains("/.vite-plus/bin/") { return .vitePlus }
    if normalized.contains("/.local/share/pnpm/") || normalized.contains("/pnpm/global/") { return .pnpm }
    if normalized.contains("/.npm-global/bin/") || normalized.contains("/node_modules/.bin/") || normalized.contains("/lib/node_modules/") { return .npm }
    if normalized.hasPrefix("/opt/homebrew/bin/") || normalized.hasPrefix("/usr/local/bin/") { return .homebrew }
    return nil
}

private func jsonRPCInitialize(name: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"\(name)\",\"title\":\"Workjet Doctor\",\"version\":\"1\"},\"capabilities\":{\"experimentalApi\":true}}}\n".utf8)
}

private func acpInitialize(name: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{},\"clientInfo\":{\"name\":\"\(name)\",\"version\":\"1\"}}}\n".utf8)
}

private let acpVerifier: @Sendable (String) -> Bool = { text in
    let compact = text.filter { !$0.isWhitespace }
    return compact.contains("\"id\":1") && (compact.contains("protocolVersion") || compact.contains("protocol_version"))
}

private func parseVersion(_ text: String) -> String? {
    let pattern = #"(?i)(?:^|[^0-9])v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

private func combinedOutput(_ result: CommandResult) -> String {
    String(decoding: result.standardOutput + Data("\n".utf8) + result.standardError, as: UTF8.self)
}
