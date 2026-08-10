import Foundation
import XCTest
@testable import WorkjetCore

final class ProviderRuntimeRouteTests: XCTestCase {
    private let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testMissingDeletedAndEmptyRoutesAreHardFailures() {
        let worker = Worker(name: "Completion", harness: .claudeCode, model: "gpt-5.6-sol", computerID: localID)
        XCTAssertThrowsError(try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [], target: .local)) {
            XCTAssertEqual($0 as? ProviderRuntimeRouteError, .routeMissing)
        }

        var deleted = worker
        deleted.providerID = UUID()
        XCTAssertThrowsError(try ProviderRuntimeRouteResolver.resolve(worker: deleted, providers: [], target: .local)) {
            XCTAssertEqual($0 as? ProviderRuntimeRouteError, .accountMissing)
        }

        var emptyPool = worker
        emptyPool.providerPool = .openAI
        XCTAssertThrowsError(try ProviderRuntimeRouteResolver.resolve(worker: emptyPool, providers: [], target: .local)) {
            XCTAssertEqual($0 as? ProviderRuntimeRouteError, .poolEmpty(.openAI))
        }
    }

    func testExactDirectAccountAndDeterministicDirectPoolStayDistinct() throws {
        let first = Provider(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, name: "B", kind: .directAPI, endpoint: "https://api.openai.com/v1", authentication: .bearerToken, modelProvider: .openAI, credentialReference: "secret-b", routingPriority: 1)
        let second = Provider(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, name: "A", kind: .directAPI, endpoint: "https://api.openai.com/v1", authentication: .bearerToken, modelProvider: .openAI, credentialReference: "secret-a", routingPriority: 0)
        var worker = Worker(name: "Completion", harness: .claudeCode, model: "gpt-5.6-sol", computerID: localID)
        worker.providerID = first.id
        let exact = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [second, first], target: .local)
        XCTAssertEqual(exact.candidates.map(\.providerID), [first.id])

        worker.providerPool = .openAI
        worker.providerID = nil
        let pool = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [first, second], target: .local)
        XCTAssertEqual(pool.candidates.map(\.providerID), [second.id, first.id])
    }

    func testGatewayOAuthAccountsCollapseToOneHonestGatewayPool() throws {
        let shared = CLIProxyGatewayCredentialStore.reference
        let accounts = ["one@example.com", "two@example.com"].map {
            Provider(name: $0, kind: .cliProxyAPI, endpoint: "http://127.0.0.1:8317/v1", authentication: .bearerToken, modelProvider: .kimi, accountLabel: $0, credentialReference: shared)
        }
        var worker = Worker(name: "Reviewer", harness: .claudeCode, model: "Kimi K3", computerID: localID)
        worker.providerPool = .kimi
        let route = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: accounts, target: .local)
        XCTAssertEqual(route.candidates.count, 1)
        XCTAssertEqual(route.candidates[0].kind, .gatewayPool)
        XCTAssertNil(route.candidates[0].providerID)
        XCTAssertEqual(route.candidates[0].displayName, "Kimi Gateway-Pool")
    }

    func testSelectingOneOAuthRecordStillExposesOnlyTheHonestGatewayPoolContract() throws {
        let selected = Provider(
            name: "OpenAI Privat",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317/v1",
            authentication: .bearerToken,
            modelProvider: .openAI,
            accountLabel: "private@example.test",
            externalCredentialID: "codex-private.json",
            credentialReference: CLIProxyGatewayCredentialStore.reference
        )
        var worker = Worker(name: "Completion", harness: .claudeCode, model: "gpt-5.6-sol", computerID: localID)
        worker.providerID = selected.id

        let route = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [selected], target: .local)

        XCTAssertEqual(route.displayName, "OpenAI Gateway-Pool")
        XCTAssertEqual(route.candidates.count, 1)
        XCTAssertEqual(route.candidates[0].kind, .gatewayPool)
        XCTAssertNil(route.candidates[0].providerID, "Workjet cannot prove request-specific OAuth account pinning")
        XCTAssertFalse(route.candidates[0].displayName.contains("Privat"))
        XCTAssertFalse(route.candidates[0].displayName.contains("private@example.test"))
    }

    func testCustomCompatibleEndpointRemainsAnExactDirectRoute() throws {
        let provider = Provider(
            name: "Internal OpenAI-compatible",
            kind: .directAPI,
            endpoint: "https://models.example.test/openai/v1",
            authentication: .bearerToken,
            modelProvider: .zAI,
            credentialReference: "custom-endpoint-key"
        )
        var worker = Worker(name: "Custom", harness: .codexCLI, model: "glm-5.2", computerID: localID)
        worker.providerID = provider.id

        let route = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [provider], target: .local)

        XCTAssertEqual(route.candidates.map(\.providerID), [provider.id])
        XCTAssertEqual(route.candidates.first?.kind, .directAccount)
        XCTAssertEqual(route.candidates.first?.endpoint, "https://models.example.test/openai/v1")
        XCTAssertEqual(route.candidates.first?.authentication, .bearerToken)
        XCTAssertEqual(route.candidates.first?.credentialReference, "custom-endpoint-key")
    }

    func testOfficialZAIEndpointMatchesTheSelectedHarnessProtocol() throws {
        let provider = Provider(name: "Z.ai", kind: .directAPI, endpoint: "https://api.z.ai/api/paas/v4", authentication: .bearerToken, modelProvider: .zAI, credentialReference: "zai-key")
        var claude = Worker(name: "GLM Claude", harness: .claudeCode, model: "glm-5.2", computerID: localID)
        claude.providerID = provider.id
        var codex = claude
        codex.harness = .codexCLI

        let claudeRoute = try ProviderRuntimeRouteResolver.resolve(worker: claude, providers: [provider], target: .local)
        let codexRoute = try ProviderRuntimeRouteResolver.resolve(worker: codex, providers: [provider], target: .local)

        XCTAssertEqual(claudeRoute.candidates.first?.endpoint, "https://api.z.ai/api/anthropic")
        XCTAssertEqual(codexRoute.candidates.first?.endpoint, "https://api.z.ai/api/coding/paas/v4")
    }

    func testRemoteRouteUsesSameExactNonSecretMetadataAsLocal() throws {
        let provider = Provider(name: "OpenAI", kind: .directAPI, endpoint: "https://api.openai.com/v1", authentication: .none, modelProvider: .openAI)
        var worker = Worker(name: "Remote", harness: .claudeCode, model: "gpt-5.6-sol", computerID: UUID())
        worker.providerID = provider.id
        let local = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [provider], target: .local)
        let remote = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [provider], target: .remote)
        XCTAssertEqual(remote, local)
        XCTAssertEqual(remote.candidates.map(\.providerID), [provider.id])
    }

    func testRemotePolicyRequiresSecureRelayForCLIProxyGatewayPool() throws {
        let account = Provider(name: "Kimi", kind: .cliProxyAPI, endpoint: "http://127.0.0.1:8317/v1", authentication: .bearerToken, modelProvider: .kimi, credentialReference: CLIProxyGatewayCredentialStore.reference)
        var worker = Worker(name: "Remote Reviewer", harness: .claudeCode, model: "Kimi K3", computerID: UUID())
        worker.providerID = account.id
        let route = try ProviderRuntimeRouteResolver.resolve(worker: worker, providers: [account], target: .remote)
        XCTAssertEqual(route.candidates.first?.kind, .gatewayPool)
        XCTAssertNoThrow(try RemoteProviderRoutePolicy.validate(route))
        XCTAssertTrue(RemoteProviderRoutePolicy.requiresGatewayRelay(route))
    }

    func testOnlyClassifiedProviderFailuresAdvanceAPool() {
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: "HTTP 429 rate limit"), .retryable)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: #"{\"type\":\"authentication_error\"}"#), .retryable)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: #"{\"type\":\"rate_limit_error\"}"#), .retryable)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: "insufficient_quota"), .retryable)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: "connection refused"), .taskFailure)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: "network timeout"), .taskFailure)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: "HTTP 503"), .taskFailure)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 1, diagnostic: "test covers 429 handling"), .taskFailure)
        XCTAssertEqual(ProviderRuntimeFailureClass.classify(exitCode: 2, diagnostic: "tests failed"), .taskFailure)
    }

    func testLaunchMetadataContainsReferencesButNeverCredentialBytes() throws {
        let sentinel = "WORKJET-SECRET-SENTINEL"
        let candidate = ProviderRuntimeCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .openAI, displayName: "Account", endpoint: "https://api.openai.com/v1", authentication: .bearerToken, credentialReference: "provider-reference")
        let data = try JSONEncoder().encode(ResolvedProviderRuntimeRoute(displayName: "Account", candidates: [candidate]))
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("provider-reference"))
        XCTAssertFalse(encoded.contains(sentinel))
    }
}
