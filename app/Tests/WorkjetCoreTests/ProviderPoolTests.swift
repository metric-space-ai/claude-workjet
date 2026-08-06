import XCTest
@testable import WorkjetCore

final class ProviderPoolTests: XCTestCase {
    func testTwoAccountsOfSameProviderRemainDistinct() {
        let first = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            name: "OpenAI Privat",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .openAI,
            routingPriority: 0
        )
        let second = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            name: "OpenAI Arbeit",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .openAI,
            routingPriority: 1
        )

        let pool = ProviderPool(provider: .openAI, accounts: [second, first])

        XCTAssertEqual(pool.accountIDs, [first.id, second.id])
        XCTAssertNotEqual(first.credentialReference, second.credentialReference)
    }

    func testLegacySingleProviderConfigurationMigratesWithoutLosingRoute() throws {
        let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let provider = Provider(
            id: providerID,
            name: "Bestehender Zugang",
            kind: .directAPI,
            endpoint: "https://example.test/v1",
            modelProvider: .zAI,
            modelIDs: ["glm-5.2"]
        )
        let worker = Worker(
            name: "Reviewer",
            harness: .claudeCode,
            model: "glm-5.2",
            computerID: WorkjetDefaults.localID,
            providerID: providerID
        )
        let original = WorkjetConfiguration(
            workers: [worker],
            computers: [WorkjetDefaults.localComputer],
            providers: [provider],
            selectedComputerID: WorkjetDefaults.localID,
            skillRules: "Rules"
        )
        let encoded = try JSONEncoder().encode(original)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        providers[0].removeValue(forKey: "routingPriority")
        root["providers"] = providers
        var workers = try XCTUnwrap(root["workers"] as? [[String: Any]])
        workers[0].removeValue(forKey: "providerPool")
        root["workers"] = workers

        let migrated = try JSONDecoder().decode(
            WorkjetConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertEqual(migrated.providers[0].id, providerID)
        XCTAssertEqual(migrated.providers[0].name, "Bestehender Zugang")
        XCTAssertEqual(migrated.providers[0].routingPriority, 0)
        XCTAssertEqual(migrated.workers[0].providerRoute, .account(providerID))
    }

    func testPoolOrderIsDeterministicAndVisibleByPriorityThenName() {
        let a = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            name: "Abo B",
            kind: .directAPI,
            endpoint: "b",
            modelProvider: .miniMax,
            routingPriority: 1
        )
        let b = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            name: "Abo A",
            kind: .directAPI,
            endpoint: "a",
            modelProvider: .miniMax,
            routingPriority: 1
        )
        let primary = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            name: "Primär",
            kind: .directAPI,
            endpoint: "primary",
            modelProvider: .miniMax,
            routingPriority: 0
        )

        XCTAssertEqual(
            ProviderPool(provider: .miniMax, accounts: [a, primary, b]).accounts.map(\.name),
            ["Primär", "Abo A", "Abo B"]
        )
    }

    func testPoolCapacityOnlyAggregatesCompatibleEvidence() {
        let first = Provider(
            name: "Eins",
            kind: .directAPI,
            endpoint: "one",
            modelProvider: .zAI,
            capacity: .measured(used: 20, limit: 100, unit: "requests", rateLimited: false)
        )
        let second = Provider(
            name: "Zwei",
            kind: .directAPI,
            endpoint: "two",
            modelProvider: .zAI,
            capacity: .measured(used: 30, limit: 100, unit: "requests", rateLimited: true)
        )
        let measured = ProviderPool(provider: .zAI, accounts: [first, second]).capacity
        XCTAssertEqual(measured.fraction, 0.25)
        XCTAssertEqual(measured.rateLimited, true)

        var unknown = second
        unknown.capacity = .unavailable(reason: "Keine Daten")
        let unavailable = ProviderPool(provider: .zAI, accounts: [first, unknown]).capacity
        XCTAssertNil(unavailable.fraction)
        XCTAssertNotNil(unavailable.reason)

        var differentUnit = second
        differentUnit.capacity = .measured(used: 1, limit: 10, unit: "tokens", rateLimited: false)
        XCTAssertNil(ProviderPool(provider: .zAI, accounts: [first, differentUnit]).capacity.fraction)
    }

    func testWorkerDraftPersistsExplicitPoolInsteadOfImplicitAccount() {
        var draft = WorkerDraft()
        draft.name = "Bulk"
        draft.model = "MiniMax-M3"
        draft.instructions = "Klare Massenarbeit"
        draft.computerID = WorkjetDefaults.localID
        draft.providerRoute = .pool(.miniMax)

        let worker = draft.applied(to: nil)

        XCTAssertEqual(worker?.providerRoute, .pool(.miniMax))
        XCTAssertNil(worker?.providerID)
    }
}
