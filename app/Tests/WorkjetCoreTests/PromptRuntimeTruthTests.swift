import Foundation
import XCTest
@testable import WorkjetCore

final class PromptRuntimeTruthTests: XCTestCase {
    func testStaticSkillIsExactlyTheGenericVisibleLoader() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let skillURL = repositoryRoot.appendingPathComponent("skills/workjet/SKILL.md")
        let staticSkill = try String(contentsOf: skillURL, encoding: .utf8)

        XCTAssertEqual(staticSkill, WorkjetActivationStore.loader)
        XCTAssertFalse(staticSkill.contains("Sol"))
        XCTAssertFalse(staticSkill.contains("MiniMax"))
        XCTAssertFalse(staticSkill.contains("Kimi"))
        XCTAssertFalse(staticSkill.contains("routing rules"))
    }

    func testEveryAdvertisedWorkerExecutionCommandMatchesTheRuntimeParser() throws {
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: WorkjetDefaults.configuration()), as: UTF8.self)
        let advertised = [
            "`workjet workers list --json`",
            "`workjet workers describe <uuid-oder-exakter-name> --json`",
            "`workjet health --probe-workers --json`",
            "`workjet run <uuid-oder-exakter-name> --brief-file <pfad> --json`",
            "`workjet events <run-id> --after <exklusive-sequenz> --json`",
            "`workjet stop <run-id> --json`",
            "`workjet result import <run-id> --json`",
            "`workjet runs mark <run-id> integrated --json`",
            "`workjet runs mark <run-id> abandoned --json`"
        ]
        for command in advertised { XCTAssertTrue(prompt.contains(command), "Fehlender CLI-Vertrag: \(command)") }

        XCTAssertEqual(try WorkjetCLIParser.parse(["workers", "list", "--json"]), .workersList(json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["workers", "describe", "Reviewer", "--json"]), .workerDescribe(identifier: "Reviewer", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["health", "--probe-workers", "--json"]), .healthProbeWorkers(identifiers: [], timeoutSeconds: nil, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["run", "Reviewer", "--brief-file", "/tmp/brief.md", "--json"]), .run(identifier: "Reviewer", brief: .file("/tmp/brief.md"), json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["events", "run-1", "--after", "7", "--json"]), .events(runID: "run-1", after: 7, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["stop", "run-1", "--json"]), .stop(runID: "run-1", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["result", "import", "run-1", "--json"]), .resultImport(runID: "run-1", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["runs", "mark", "run-1", "integrated", "--json"]), .runsMark(runID: "run-1", disposition: .integrated, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["runs", "mark", "run-1", "abandoned", "--json"]), .runsMark(runID: "run-1", disposition: .abandoned, json: true))

        XCTAssertTrue(prompt.contains("This is polling, never streaming."))
        XCTAssertTrue(prompt.contains("exclusive sequence cursor"))
        XCTAssertTrue(prompt.contains("Self-review may proceed, and explicitly defer independent review."))
        XCTAssertTrue(prompt.contains("Do not inspect or diagnose the native `Claude Code-credentials` keychain entry"))
        XCTAssertTrue(prompt.contains("do not ask the user to run `claude /login`"))
        XCTAssertTrue(prompt.contains("Read health failures literally"))
        XCTAssertTrue(prompt.contains("require the JSON `checkedAt` value"))
        XCTAssertTrue(prompt.contains("Do not replace mixed results with a blanket summary"))
        XCTAssertTrue(prompt.contains("App-Fakt; nicht direkt ausführen"))
        XCTAssertTrue(prompt.contains("Workjet-owned isolated worktrees"))
        XCTAssertFalse(prompt.contains("A local run uses the checkout from which `workjet run` was invoked"))
        XCTAssertTrue(prompt.contains("Repository-backed local and remote runs use Workjet-owned isolated worktrees"))
        XCTAssertTrue(prompt.contains("initialized non-recursive Git submodules are available offline at their pinned commits and must remain unchanged"))
        XCTAssertFalse(prompt.contains("local runs use the invoking checkout"))
        XCTAssertFalse(prompt.contains("Fable erzeugt den aktuellen `CtoxTurnRequest`"))
        XCTAssertFalse(prompt.contains("/usr/bin/ssh"))
        XCTAssertFalse(prompt.contains("NDJSON-Zeile"))
    }

    func testRemoteHarnessPromptMatchesTheRuntimeRegistry() {
        let registry = RemoteHarnessAdapterRegistry()
        let expected: [Harness: Bool] = [
            .claudeCode: true,
            .piSidecar: true,
            .codexCLI: true,
            .openCode: true,
            .cursorAgent: false,
            .grokCLI: false
        ]
        for (harness, supported) in expected {
            XCTAssertEqual(registry.supports(harness), supported, "Remote-Aussage driftet für \(harness.rawValue)")
        }

        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: WorkjetDefaults.configuration()), as: UTF8.self)
        XCTAssertTrue(prompt.contains("verified remotely startable harness set is Claude Code, Pi Code, Codex CLI, and OpenCode"))
        XCTAssertTrue(prompt.contains("Cursor Agent and Grok CLI are inspect/install only"))
        XCTAssertTrue(prompt.contains("Do not infer that every Workjet worker is a headless Claude Code process"))
    }

    func testProviderPoolTextMatchesDirectFallbackAndSharedGatewayRuntime() throws {
        let first = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            name: "Direct A",
            kind: .directAPI,
            endpoint: "https://api.openai.com/v1",
            modelProvider: .openAI,
            credentialReference: "direct-a",
            routingPriority: 0
        )
        let second = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            name: "Direct B",
            kind: .directAPI,
            endpoint: "https://api.openai.com/v1",
            modelProvider: .openAI,
            credentialReference: "direct-b",
            routingPriority: 1
        )
        var directConfiguration = WorkjetDefaults.configuration()
        directConfiguration.providers = [second, first]
        directConfiguration.workers[0].providerPool = .openAI

        let directRoute = try ProviderRuntimeRouteResolver.resolve(
            worker: directConfiguration.workers[0],
            providers: directConfiguration.providers,
            target: .local
        )
        XCTAssertEqual(directRoute.candidates.map(\.providerID), [first.id, second.id])
        let directPrompt = ManagedPrompt.generatedWorkerConfiguration(for: directConfiguration.workers[0], configuration: directConfiguration)
        XCTAssertTrue(directPrompt.contains("deterministische Reihenfolge"))
        XCTAssertTrue(directPrompt.contains("Auth-, Quota- oder Rate-Limit-Fehler"))
        XCTAssertTrue(directPrompt.contains("Task-, Transport-, Timeout- und generische Serverfehler wechseln den Zugang nicht"))

        let gatewayAccounts = ["one@example.com", "two@example.com"].map {
            Provider(
                name: $0,
                kind: .cliProxyAPI,
                endpoint: "http://127.0.0.1:8317/v1",
                modelProvider: .kimi,
                accountLabel: $0,
                credentialReference: CLIProxyGatewayCredentialStore.reference
            )
        }
        var gatewayConfiguration = WorkjetDefaults.configuration()
        gatewayConfiguration.providers = gatewayAccounts
        gatewayConfiguration.workers[1].providerPool = .kimi
        let gatewayRoute = try ProviderRuntimeRouteResolver.resolve(
            worker: gatewayConfiguration.workers[1],
            providers: gatewayConfiguration.providers,
            target: .local
        )
        XCTAssertEqual(gatewayRoute.candidates.count, 1)
        XCTAssertEqual(gatewayRoute.candidates.first?.kind, .gatewayPool)
        XCTAssertNil(gatewayRoute.candidates.first?.providerID)
        let gatewayPrompt = ManagedPrompt.generatedWorkerConfiguration(for: gatewayConfiguration.workers[1], configuration: gatewayConfiguration)
        XCTAssertTrue(gatewayPrompt.contains("gemeinsamen CLIProxy-Gateway-Pool"))
        XCTAssertTrue(gatewayPrompt.contains("keinen einzelnen OAuth-Account pro Anfrage festlegen"))
    }

    func testRemotePiPromptDescribesRealRelayAndEphemeralSecretBoundary() {
        let remote = Computer(
            name: "gpu",
            transport: .tailscale,
            host: "gpu.tailnet.ts.net",
            user: "workjet",
            sandboxEnabled: true,
            deploymentStatus: .installed,
            installedContentHash: "sha256:fixture",
            installedSidecarVersion: PiSidecarRuntime.version,
            tailscaleExecutablePath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            bubblewrapExecutablePath: "/usr/bin/bwrap"
        )
        var configuration = WorkjetDefaults.configuration()
        configuration.computers.append(remote)
        configuration.workers[0].harness = .piSidecar
        configuration.workers[0].computerID = remote.id

        let prompt = ManagedPrompt.generatedWorkerConfiguration(for: configuration.workers[0], configuration: configuration)
        XCTAssertTrue(prompt.contains("pro Lauf einen Loopback-Relay"))
        XCTAssertTrue(prompt.contains("verschlüsselte Request-/Monitor-Pipe"))
        XCTAssertTrue(prompt.contains("OAuth-Dateien, OAuth-Tokens, Keychain-Inhalte und Run-Secrets werden weder kopiert"))
        XCTAssertTrue(prompt.contains("Fable verwendet ausschließlich die Workjet-CLI"))
        XCTAssertFalse(prompt.contains("Remote-Echtmodell-Inferenz ist ohne separaten Loopback-Relay nicht verfügbar"))
        XCTAssertFalse(prompt.contains("Faux-/Offline-Turns"))
        XCTAssertFalse(prompt.contains("NDJSON-Zeile"))
        XCTAssertFalse(prompt.contains("/usr/bin/ssh"))
    }

    func testDefaultRoutingContractIsVisibleAndMatchesTheDeclaredWorkerBoundaries() throws {
        let configuration = WorkjetDefaults.configuration()
        let rules = configuration.skillRules
        for required in [
            "Claude/Fable is the sole Workjet orchestrator",
            "decomposition, routing, synthesis, integration, cleanup, and final verification",
            "reports and completion receipts are claims, never proof",
            "Small bounded work may be done directly",
            "Route clear difficult production work to Sol",
            "same bounded discovery brief to Prototype A, B, and C",
            "never silently substitute another worker when one panel member is unavailable",
            "byte-for-byte equivalent apart from unavoidable transport metadata",
            "Inspect all three artifacts, then write a new consolidated production brief",
            "never pass one prototype through as the solution",
            "Send the consolidated work to Sol",
            "greenfield UI/UX and explicitly assigned visual implementation to Kimi UI/UX",
            "cybersecurity and independent adversarial review to Kimi Cyber & Review",
            "Existing frontend adaptation and frontend-to-backend wiring default to Sol",
            "disjoint, counted, fixed-schema repetitive slices",
            "independently sample its output",
            "Use Terra as the default for standalone current online research requiring primary sources and direct links",
            "Terra never receives repository editing or shell/code work",
            "A different worker with an effective Web Research toggle may use bounded live search and page opening inside its normal assignment",
            "hard file whitelist",
            "forbidden files and non-goals",
            "exact acceptance commands",
            "required artifacts",
            "a stop/escape hatch",
            "no-subagents",
            "fixed completion report",
            "independently inspect actual artifacts, scope, diff, code, and tests"
        ] {
            XCTAssertTrue(rules.contains(required), "Missing routing contract text: \(required)")
        }

        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: configuration), as: UTF8.self)
        for modelName in try XCTUnwrap(configuration.modelPrompts).keys {
            XCTAssertTrue(prompt.contains("#### Modellregeln · \(modelName)"), "Missing visible model prompt: \(modelName)")
        }
        XCTAssertTrue(prompt.contains("- Harness: Codex CLI"))
        XCTAssertTrue(prompt.contains("- Argumente: [`--search`, `-a`, `never`, `-s`, `read-only`, `exec`, `--ignore-user-config`, `--skip-git-repo-check`, `--ephemeral`, `<WORKJET_BRIEF>`]"))
        XCTAssertTrue(prompt.contains("Greppy: deaktiviert (Worker-Override)"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("objectively the best"))
    }

    func testLegacyTerraOnlyRoutingMigratesToTheAdditivePerWorkerWebContract() {
        let legacy = "Owner text. Give Terra only current online research requiring primary sources and direct links through its verified Codex native-web-search harness; Terra never receives repository editing or shell/code work. More owner text."
        let migrated = LegacyPromptMigration.correctingKnownSkillDefaults(in: legacy)

        XCTAssertTrue(migrated.contains("Owner text."))
        XCTAssertTrue(migrated.contains("More owner text."))
        XCTAssertTrue(migrated.contains("A different worker with an effective Web Research toggle"))
        XCTAssertFalse(migrated.contains("Give Terra only current online research"))

        let numbered = LegacyPromptMigration.correctingKnownSkillDefaults(in: "7. Use `Web Research · Terra` only for current online research. Require primary sources and direct links; it must never touch local files or code.")
        XCTAssertTrue(numbered.contains("A normal worker whose Web Research toggle is effective may also search and open pages"))
    }

    func testDefaultTechnicalRulesContainNoDirectInvocationOrAutomaticWorkerDegradation() {
        let rules = WorkjetDefaults.configuration().technicalRules ?? ""
        XCTAssertTrue(rules.contains("workjet run <uuid-oder-exakter-name> --brief-file <pfad> --json"))
        XCTAssertTrue(rules.contains("never silently substitute another worker"))
        XCTAssertTrue(rules.contains("only that Workjet health output as the authority"))
        XCTAssertFalse(rules.contains("~/.local/bin/claude-"))
        XCTAssertFalse(rules.contains("/usr/bin/ssh"))
        XCTAssertFalse(rules.contains("Fable erzeugt"))
        XCTAssertFalse(rules.contains("Eine Degradation auf einen anderen Worker"))
    }
}
