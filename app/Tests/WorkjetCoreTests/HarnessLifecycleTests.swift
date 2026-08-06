import XCTest
@testable import WorkjetCore

final class HarnessLifecycleTests: XCTestCase {
    private struct Locator: HarnessBinaryLocating, Sendable {
        var executable: String?
        var packageManagers: Set<String> = []

        func firstExecutable(in candidates: [String]) -> String? {
            if let executable, candidates.contains(executable) { return executable }
            return candidates.first(where: packageManagers.contains)
        }
    }

    private actor Runner: CommandRunning {
        enum Reply: Sendable {
            case result(CommandResult)
            case failure(CommandRunError)
        }

        private var replies: [Reply]
        private var commands: [CommandSpec] = []

        init(_ replies: [Reply]) { self.replies = replies }

        func run(_ command: CommandSpec) async throws -> CommandResult {
            commands.append(command)
            guard !replies.isEmpty else { throw CommandRunError.launch("unexpected command") }
            switch replies.removeFirst() {
            case let .result(result): return result
            case let .failure(error): throw error
            }
        }

        func recordedCommands() -> [CommandSpec] { commands }
    }

    private func success(_ output: String) -> Runner.Reply {
        .result(CommandResult(exitCode: 0, standardOutput: Data(output.utf8)))
    }

    func testRegistryCoversEveryHarnessAndMissingIsNotInferredFromInvocationText() async {
        XCTAssertEqual(HarnessLifecycleRegistry.all.map(\.harness), Harness.allCases)

        for harness in Harness.allCases where harness != .piSidecar {
            let driver = HarnessAdapterRegistry.lifecycleDriver(for: harness)
            let runner = Runner([])
            let discovery = await driver.discover(locator: Locator(executable: nil), runner: runner)
            XCTAssertEqual(discovery.status, .missing, "\(harness)")
            let commands = await runner.recordedCommands()
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testPiReportsPinnedBundleWithoutClaimingLocalOrRemoteDeployment() async {
        let driver = HarnessLifecycleRegistry.driver(for: .piSidecar)
        let report = await driver.doctor(locator: Locator(), runner: Runner([]))

        XCTAssertEqual(report.discovery.status, .version(executable: "bundled://pi-code", value: PiSidecarRuntime.version))
        XCTAssertEqual(report.capabilities, [.piBundledRuntime])
        XCTAssertEqual(report.deployment, .init(local: .notEvaluated, remote: .notEvaluated))
        XCTAssertEqual(driver.updatePlan(for: report.discovery), .unsupported("Die Installation wurde noch nicht erkannt."))
    }

    func testEveryExternalDriverClassifiesFailedVersionProbeAsBroken() async throws {
        for harness in Harness.allCases where harness != .piSidecar {
            let driver = HarnessLifecycleRegistry.driver(for: harness)
            let executable = try XCTUnwrap(driver.binaryCandidates.first)
            let runner = Runner([.result(CommandResult(exitCode: 9, standardError: Data("bad version".utf8)))])
            let discovery = await driver.discover(locator: Locator(executable: executable), runner: runner)
            guard case let .broken(path, detail) = discovery.status else {
                return XCTFail("Expected broken for \(harness), got \(discovery.status)")
            }
            XCTAssertEqual(path, executable)
            XCTAssertEqual(detail, "Die Installation antwortet nicht wie erwartet. Prüfe oder aktualisiere sie.")
            XCTAssertFalse(detail.contains("bad version"))
        }
    }

    func testDoctorUsesRealProtocolCapabilityForEveryExternalDriver() async throws {
        let cases: [(Harness, String, String, [String])] = [
            (.claudeCode, "Claude Code 2.1.3", "Usage: claude -p, --print", ["--help"]),
            (.codexCLI, "codex-cli 0.42.0", "Usage: codex exec [OPTIONS] [PROMPT] --model", ["exec", "--help"]),
            (.cursorAgent, "cursor-agent 1.2.3", #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#, ["acp"]),
            (.grokCLI, "grok 1.2.3", #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#, ["agent", "stdio"]),
            (.openCode, "opencode 1.2.3", "opencode run [message] --model", ["run", "--help"])
        ]

        for (harness, versionOutput, capabilityOutput, capabilityArguments) in cases {
            let driver = HarnessLifecycleRegistry.driver(for: harness)
            let executable = try XCTUnwrap(driver.binaryCandidates.first)
            let runner = Runner([success(versionOutput), success(capabilityOutput)])
            let report = await driver.doctor(locator: Locator(executable: executable), runner: runner)
            XCTAssertFalse(report.capabilities.isEmpty, "\(harness): \(report)")
            XCTAssertEqual(report.deployment.local, .capable)
            XCTAssertEqual(report.deployment.remote, .notEvaluated)

            let commands = await runner.recordedCommands()
            XCTAssertEqual(commands.count, 2)
            XCTAssertEqual(commands[1].arguments, capabilityArguments)
            XCTAssertEqual(commands[1].timeout, 5)
            XCTAssertEqual(commands[1].stdoutLimit, 65_536)
            XCTAssertEqual(commands[1].stderrLimit, 32_768)
            XCTAssertTrue(commands.allSatisfy { $0.executable == executable && $0.executable.hasPrefix("/") })
            XCTAssertFalse(commands.flatMap(\.arguments).contains("-c"))

            switch harness {
            case .cursorAgent, .grokCLI:
                XCTAssertFalse(commands[1].standardInput.isEmpty)
                XCTAssertTrue(String(decoding: commands[1].standardInput, as: UTF8.self).contains("\"method\":\"initialize\""))
            case .claudeCode, .codexCLI, .openCode:
                XCTAssertTrue(commands[1].standardInput.isEmpty)
            case .piSidecar:
                XCTFail("Pi is not an external protocol case")
            }
        }
    }

    func testLocalRegistryExposesOnlyVerifiedOneShotHarnesses() {
        XCTAssertEqual(HarnessAdapterRegistry.local.map(\.harness), [.claudeCode, .codexCLI, .openCode])
        XCTAssertFalse(HarnessAdapterRegistry.supportsLocalExecution(.piSidecar))
        XCTAssertFalse(HarnessAdapterRegistry.supportsLocalExecution(.cursorAgent))
        XCTAssertFalse(HarnessAdapterRegistry.supportsLocalExecution(.grokCLI))
    }

    func testOneShotVersionDoesNotMaskMissingRequiredCapability() async throws {
        for harness in [Harness.codexCLI, .cursorAgent, .grokCLI, .openCode] {
            let driver = HarnessLifecycleRegistry.driver(for: harness)
            let executable = try XCTUnwrap(driver.binaryCandidates.first)
            let runner = Runner([success("tool 1.2.3"), success("ordinary one-shot help")])
            let report = await driver.doctor(locator: Locator(executable: executable), runner: runner)
            guard case .broken = report.discovery.status else {
                return XCTFail("\(harness) must be broken without its protocol capability")
            }
            XCTAssertTrue(report.capabilities.isEmpty)
        }
    }

    func testOutputLimitsTimeoutAndTruncationAreFailureBoundaries() async throws {
        let driver = HarnessLifecycleRegistry.driver(for: .claudeCode)
        let executable = try XCTUnwrap(driver.binaryCandidates.first)
        let truncated = Runner([.result(CommandResult(exitCode: 0, standardOutput: Data("2.1.3".utf8), stdoutTruncated: true))])
        let truncatedDiscovery = await driver.discover(locator: Locator(executable: executable), runner: truncated)
        guard case .broken = truncatedDiscovery.status else { return XCTFail("truncation must be broken") }

        let timedOut = Runner([.failure(.timedOut)])
        let timedOutDiscovery = await driver.discover(locator: Locator(executable: executable), runner: timedOut)
        guard case .broken = timedOutDiscovery.status else { return XCTFail("timeout must be broken") }
    }

    func testMaintenancePlansAreArgumentArraysAndNeverShellCommands() async throws {
        let codex = HarnessLifecycleRegistry.driver(for: .codexCLI)
        let binary = try XCTUnwrap(codex.binaryCandidates.first) // /opt/homebrew/bin/codex
        let discovery = HarnessDiscovery(harness: .codexCLI, status: .version(executable: binary, value: "1.2.3"))

        XCTAssertEqual(codex.updatePlan(for: discovery), .supported(.init(
            operation: .update, channel: .homebrew, executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "codex"]
        )))
        XCTAssertEqual(codex.removePlan(for: discovery), .supported(.init(
            operation: .remove, channel: .homebrew, executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "codex"]
        )))

        let npm = "/usr/bin/npm"
        XCTAssertEqual(codex.installPlan(locator: Locator(packageManagers: [npm])), .supported(.init(
            operation: .install, channel: .npm, executable: npm, arguments: ["install", "-g", "@openai/codex@latest"]
        )))

        for availability in [codex.updatePlan(for: discovery), codex.removePlan(for: discovery), codex.installPlan(locator: Locator(packageManagers: [npm]))] {
            guard case let .supported(plan) = availability else { return XCTFail("expected plan") }
            XCTAssertTrue(plan.executable.hasPrefix("/"))
            XCTAssertFalse(plan.arguments.contains("-c"))
            XCTAssertNotEqual(plan.executable, "/bin/sh")
            XCTAssertNotEqual(plan.executable, "/bin/zsh")
        }
    }

    func testUnknownOrInjectedPathsAreUnsupportedInsteadOfGuessed() async {
        let driver = HarnessLifecycleRegistry.driver(for: .codexCLI)
        let injected = "/tmp/codex;touch /tmp/pwned"
        let discovery = await driver.discover(locator: Locator(executable: injected), runner: Runner([success("codex 1.2.3")]))
        XCTAssertEqual(discovery.status, .missing)

        let unknown = HarnessDiscovery(harness: .codexCLI, status: .updateUnknown(executable: "/custom/bin/codex", version: "1.2.3"))
        guard case .unsupported = driver.updatePlan(for: unknown) else { return XCTFail("unknown install channel must not be guessed") }

        let ambiguousManagers = Set(["/usr/bin/npm", "/opt/homebrew/bin/brew"])
        guard case .unsupported = driver.installPlan(locator: Locator(packageManagers: ambiguousManagers)) else {
            return XCTFail("ambiguous install channel must not be guessed")
        }
    }

    func testNativeUpdateChannelsMatchReferenceBehavior() async throws {
        let claude = HarnessLifecycleRegistry.driver(for: .claudeCode)
        let claudeBinary = try XCTUnwrap(claude.binaryCandidates.first(where: { $0.hasSuffix("/.local/bin/claude") }))
        let claudeDiscovery = HarnessDiscovery(harness: .claudeCode, status: .version(executable: claudeBinary, value: "2.1.3"))
        XCTAssertEqual(claude.updatePlan(for: claudeDiscovery), .supported(.init(operation: .update, channel: .native, executable: claudeBinary, arguments: ["update"])))
        guard case .unsupported = claude.removePlan(for: claudeDiscovery) else { return XCTFail("native remove is undocumented") }

        let cursor = HarnessLifecycleRegistry.driver(for: .cursorAgent)
        let cursorBinary = try XCTUnwrap(cursor.binaryCandidates.first)
        let cursorDiscovery = HarnessDiscovery(harness: .cursorAgent, status: .installed(executable: cursorBinary))
        XCTAssertEqual(cursor.updatePlan(for: cursorDiscovery), .supported(.init(operation: .update, channel: .native, executable: cursorBinary, arguments: ["update"])))

        let grok = HarnessLifecycleRegistry.driver(for: .grokCLI)
        let grokBinary = try XCTUnwrap(grok.binaryCandidates.first)
        let probedGrok = await grok.discover(locator: Locator(executable: grokBinary), runner: Runner([success("grok 1.0.0")]))
        XCTAssertEqual(probedGrok.status, .updateUnknown(executable: grokBinary, version: "1.0.0"))
        let grokDiscovery = HarnessDiscovery(harness: .grokCLI, status: .updateUnknown(executable: grokBinary, version: "1.0.0"))
        guard case .unsupported = grok.updatePlan(for: grokDiscovery) else { return XCTFail("Grok is manual-only in the reference") }
    }
}
