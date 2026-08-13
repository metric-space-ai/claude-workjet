import XCTest
@testable import WorkjetCore

final class CodexCapacityTests: XCTestCase {
    private actor Runner: CommandRunning {
        let result: CommandResult
        private(set) var commands: [CommandSpec] = []
        init(output: Data) { result = CommandResult(exitCode: 0, standardOutput: output) }
        func run(_ command: CommandSpec) async throws -> CommandResult { commands.append(command); return result }
    }

    func testParsesAccountBoundSubscriptionWindows() throws {
        let output = Data("""
        {"id":1,"result":{"userAgent":"Codex"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":2,"result":{"account":{"type":"chatgpt","email":"owner@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
        {"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1787211754},"secondary":null,"planType":"pro"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1787211754},"secondary":null,"planType":"pro","rateLimitReachedType":null},"codex_fast":{"limitId":"codex_fast","limitName":"Fast","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1787211754},"secondary":null,"planType":"pro","rateLimitReachedType":null}}}}
        """.utf8)

        let snapshot = try XCTUnwrap(CodexAppServerCapacityReader.parse(output, observedAt: Date()))

        XCTAssertEqual(snapshot.accountEmail, "owner@example.com")
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.capacity.quotaCompactValue, "20%")
        XCTAssertNil(snapshot.capacity.rateCompactValue)
        XCTAssertEqual(snapshot.capacity.signals.map(\.label), ["Woche", "5 Stunden"])
        XCTAssertTrue(snapshot.capacity.detail.contains("Codex app-server"))
        XCTAssertEqual(snapshot.capacity(matchingAccountLabel: " OWNER@example.com "), snapshot.capacity)
        XCTAssertNil(snapshot.capacity(matchingAccountLabel: "other@example.com"), "A local Codex session must never donate its quota to another CLIProxy account.")
    }

    func testRejectsMissingIdentityAndAmbiguousPayloads() {
        XCTAssertNil(CodexAppServerCapacityReader.parse(Data(#"{"id":3,"result":{"rateLimitsByLimitId":{}}}"#.utf8)))
        XCTAssertNil(CodexAppServerCapacityReader.parse(Data(#"{"id":2,"result":{"account":{"email":"owner@example.com"}}}"#.utf8)))
    }

    func testReaderUsesFixedLocalAppServerCommandAndParsesResult() async throws {
        let output = Data("""
        {"id":2,"result":{"account":{"email":"owner@example.com","planType":"pro"}}}
        {"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1787211754}}}}
        """.utf8)
        let runner = Runner(output: output)
        let reader = CodexAppServerCapacityReader(runner: runner, executableCandidates: ["/usr/bin/true"])

        let snapshot = await reader.read()
        XCTAssertEqual(snapshot?.accountEmail, "owner@example.com")
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].executable, "/bin/sh")
        XCTAssertEqual(commands[0].arguments.last, "/usr/bin/true")
        XCTAssertEqual(commands[0].currentDirectory, NSTemporaryDirectory())
        XCTAssertTrue(commands[0].arguments[1].contains("sleep 3"), "The app-server must remain open long enough for the asynchronous rate-limit reply.")
        XCTAssertFalse(commands[0].arguments[1].contains("owner@example.com"))
    }
}
