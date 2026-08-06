import XCTest
import Security
@testable import WorkjetCore

final class MiniMaxCapacityTests: XCTestCase {
    final class Client: HTTPClient, @unchecked Sendable {
        var requests: [URLRequest] = []
        var responses: [HTTPResponse] = []
        func request(_ request: URLRequest) async throws -> HTTPResponse {
            requests.append(request)
            return responses.removeFirst()
        }
    }

    final class Credentials: CredentialStoring, @unchecked Sendable {
        var reads = 0
        var values: [String: Data] = [:]
        var readError: Error?
        func read(reference: String) throws -> Data? {
            reads += 1
            if let readError { throw readError }
            return values[reference]
        }
        func write(_ secret: Data, reference: String) throws { values[reference] = secret }
        func delete(reference: String) throws { values.removeValue(forKey: reference) }
    }

    func testMiniMaxProbeUsesUIAuthenticationForModelsAndBearerForTokenPlan() async {
        let client = Client()
        client.responses = [
            HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"MiniMax-M3"}]}"#.utf8)),
            HTTPResponse(statusCode: 200, data: Data(#"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"MiniMax-M3","current_interval_total_count":1000,"current_interval_usage_count":250,"current_weekly_total_count":2000,"current_weekly_usage_count":1600}]}"#.utf8))
        ]
        let credentials = Credentials()
        let provider = Provider(name: "MiniMax", kind: .directAPI, endpoint: "https://api.minimax.io/anthropic", authentication: .apiKeyHeader, modelProvider: .miniMax)
        credentials.values[provider.credentialReference!] = Data("mini-secret".utf8)

        let result = await ProviderInspector(client: client, credentials: credentials).inspect(provider)

        XCTAssertEqual(result.modelIDs, ["MiniMax-M3"])
        XCTAssertEqual(result.capacity.fraction, 0.8)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "x-api-key"), "mini-secret")
        XCTAssertNil(client.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(client.requests[1].url?.absoluteString, "https://www.minimax.io/v1/token_plan/remains")
        XCTAssertEqual(client.requests[1].httpMethod, "GET")
        XCTAssertEqual(client.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer mini-secret")
        XCTAssertEqual(credentials.reads, 1)
    }

    func testParsesCodingPlanRemainingPercentAndRejectsMediaEntries() {
        let data = Data(#"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"video-01","current_interval_total_count":10,"current_interval_usage_count":10},{"model_name":"general","current_interval_remaining_percent":65,"current_weekly_remaining_percent":20,"weekly_end_time":1786320000000}]}"#.utf8)
        let result = ProviderInspector.parseMiniMaxCapacity(data)
        XCTAssertEqual(result?.capacity.fraction, 0.8)
        XCTAssertTrue(result?.summary.contains("Woche 80 % genutzt") == true)
        XCTAssertTrue(result?.summary.contains("Reset 2026-") == true)
        XCTAssertNotNil(result?.resetAt)
    }

    func testMalformedAmbiguousAndFailedResponsesStayUnavailable() {
        let samples = [
            Data("not json".utf8),
            Data(#"{"base_resp":{"status_code":1},"model_remains":[{"model_name":"general","current_interval_total_count":100,"current_interval_usage_count":10}]}"#.utf8),
            Data(#"{"model_remains":[{"model_name":"general","remaining":75,"total":100}]}"#.utf8),
            Data(#"{"model_remains":[{"model_name":"image-01","current_interval_total_count":100,"current_interval_usage_count":10}]}"#.utf8),
            Data(#"{"model_remains":[{"model_name":"general","current_interval_total_count":100,"current_interval_usage_count":120}]}"#.utf8)
        ]
        for sample in samples { XCTAssertNil(ProviderInspector.parseMiniMaxCapacity(sample)) }
    }

    func testNonMiniMaxProbeDoesNotQueryTokenPlan() async {
        let client = Client()
        client.responses = [HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"custom-model"}]}"#.utf8))]
        let credentials = Credentials()
        let provider = Provider(name: "Custom", kind: .directAPI, endpoint: "https://api.example.test", authentication: .bearerToken)
        credentials.values[provider.credentialReference!] = Data("secret".utf8)
        _ = await ProviderInspector(client: client, credentials: credentials).inspect(provider)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testUnavailableCredentialStopsBeforeNetworkRequest() async {
        let client = Client()
        let credentials = Credentials()
        credentials.readError = CredentialError.keychain(errSecInteractionNotAllowed)
        let provider = Provider(
            name: "MiniMax",
            kind: .directAPI,
            endpoint: "https://api.minimax.io/anthropic",
            authentication: .apiKeyHeader,
            modelProvider: .miniMax,
            credentialReference: "provider-secret"
        )

        let result = await ProviderInspector(client: client, credentials: credentials).inspect(provider)

        XCTAssertEqual(result.status, .offline)
        XCTAssertTrue(result.detail.contains("erneut"))
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(credentials.reads, 1)
    }
}
