import XCTest
@testable import WorkjetCore

final class ZAIUsageTests: XCTestCase {
    func testParsesIndependentCodingPlanWindowsAndTier() throws {
        let payload = Data(#"""
        {
          "data": {
            "level": "lite",
            "limits": [
              {"type":"TIME_LIMIT","number":1,"unit":5,"percentage":0,"currentValue":0,"usage":100,"nextResetTime":1787873130000},
              {"type":"TOKENS_LIMIT","number":1,"unit":6,"percentage":14,"nextResetTime":"2026-08-18T02:05:30Z"},
              {"type":"TOKENS_LIMIT","number":5,"unit":3,"percentage":0}
            ]
          }
        }
        """#.utf8)

        let result = try XCTUnwrap(ProviderInspector.parseZAIUsage(payload, observedAt: Date()))
        XCTAssertEqual(result.capacity.quotaCompactValue, "14%")
        XCTAssertEqual(result.capacity.rateCompactValue, "Lite · dyn.")
        XCTAssertEqual(result.capacity.signals.filter { $0.kind == .quota }.map(\.label), ["Web/MCP · Monat", "Woche", "5 Stunden"])
        XCTAssertTrue(result.summary.contains("Woche 14 % genutzt"))
    }

    func testRejectsUnknownOrInvalidQuotaRows() {
        XCTAssertNil(ProviderInspector.parseZAIUsage(Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","number":2,"unit":7,"percentage":12}]}}"#.utf8)))
        XCTAssertNil(ProviderInspector.parseZAIUsage(Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","number":5,"unit":3,"percentage":101}]}}"#.utf8)))
        XCTAssertNil(ProviderInspector.zAIUsageURL(baseURL: URL(string: "https://example.com/api/anthropic")!))
        XCTAssertEqual(ProviderInspector.zAIUsageURL(baseURL: URL(string: "https://api.z.ai/api/anthropic")!)?.absoluteString, "https://api.z.ai/api/monitor/usage/quota/limit")
    }

    func testZAIProbeDoesNotFailConnectionWhenQuotaPayloadIsUnavailable() async {
        let client = MiniMaxCapacityTests.Client()
        client.responses = [
            HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"glm-5.2","owned_by":"zai"}]}"#.utf8)),
            HTTPResponse(statusCode: 403, data: Data())
        ]
        let credentials = MiniMaxCapacityTests.Credentials()
        let provider = Provider(name: "Z.ai", kind: .directAPI, endpoint: "https://api.z.ai/api/anthropic", modelProvider: .zAI)
        credentials.values[provider.credentialReference!] = Data("secret".utf8)

        let result = await ProviderInspector(client: client, credentials: credentials).inspect(provider)

        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(result.modelIDs, ["glm-5.2"])
        XCTAssertNil(result.capacity.fraction)
        XCTAssertTrue(result.capacity.reason?.contains("nicht gelesen") == true)
    }
}
