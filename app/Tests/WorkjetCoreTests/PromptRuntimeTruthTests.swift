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
            "`workjet workers describe <exakter-name-oder-uuid> --json`",
            "`workjet run <exakter-name-oder-uuid> --brief-file <pfad> --json`",
            "`workjet events <run-id> --after <exklusive-sequenz> --json`",
            "`workjet stop <run-id> --json`"
        ]
        for command in advertised { XCTAssertTrue(prompt.contains(command), "Fehlender CLI-Vertrag: \(command)") }

        XCTAssertEqual(try WorkjetCLIParser.parse(["workers", "list", "--json"]), .workersList(json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["workers", "describe", "Reviewer", "--json"]), .workerDescribe(identifier: "Reviewer", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["run", "Reviewer", "--brief-file", "/tmp/brief.md", "--json"]), .run(identifier: "Reviewer", brief: .file("/tmp/brief.md"), json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["events", "run-1", "--after", "7", "--json"]), .events(runID: "run-1", after: 7, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["stop", "run-1", "--json"]), .stop(runID: "run-1", json: true))

        XCTAssertTrue(prompt.contains("App-Fakt; nicht direkt ausführen"))
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
        XCTAssertTrue(prompt.contains("Remote startbar sind Claude Code, Pi Code, Codex CLI und OpenCode."))
        XCTAssertTrue(prompt.contains("Cursor Agent und Grok CLI sind ausschließlich prüf- und installierbar, nicht remote startbar."))
        XCTAssertTrue(prompt.contains("keine t3code-Interoperabilität"))
        XCTAssertTrue(prompt.contains("keinen WebSocket-Stream"))
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

    func testDefaultTechnicalRulesContainNoDirectInvocationOrAutomaticWorkerDegradation() {
        let rules = WorkjetDefaults.configuration().technicalRules ?? ""
        XCTAssertTrue(rules.contains("workjet run <exakter-name-oder-uuid> --brief-file <pfad> --json"))
        XCTAssertTrue(rules.contains("Ein Wechsel auf einen anderen Worker geschieht niemals automatisch."))
        XCTAssertFalse(rules.contains("~/.local/bin/claude-"))
        XCTAssertFalse(rules.contains("/usr/bin/ssh"))
        XCTAssertFalse(rules.contains("Fable erzeugt"))
        XCTAssertFalse(rules.contains("Eine Degradation auf einen anderen Worker"))
    }
}
