import Foundation
import XCTest
@testable import WorkjetCore

final class RemoteHostProtocolTests: XCTestCase {
    private actor ScriptedHost: RemoteHostCalling {
        enum Step: Sendable {
            case response(RemoteHostResponse)
            case transport(String)
        }

        private var steps: [Step]
        private var requests: [RemoteHostRequest] = []

        init(_ steps: [Step]) { self.steps = steps }

        func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
            requests.append(request)
            guard !steps.isEmpty else { throw RemoteHostProtocolError.transport("no scripted response") }
            switch steps.removeFirst() {
            case let .response(response): return response
            case let .transport(detail): throw RemoteHostProtocolError.transport(detail)
            }
        }

        func recordedRequests() -> [RemoteHostRequest] { requests }
    }

    private actor ReplyRunner: CommandRunning {
        var result: CommandResult
        private var commands: [CommandSpec] = []

        init(_ result: CommandResult) { self.result = result }

        func run(_ command: CommandSpec) async throws -> CommandResult {
            commands.append(command)
            return result
        }

        func recordedCommands() -> [CommandSpec] { commands }
    }

    private struct Locator: TailscaleLocating {
        var path: String?
        func executablePath() -> String? { path }
    }

    private final class RemoteService: WorkjetService, @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [RemoteHostOperation] = []
        private var eventResponses: [RemoteHostResponse]
        private let startResponse: RemoteHostResponse
        private let stopResponse: RemoteHostResponse

        init(start: RemoteHostResponse, events: [RemoteHostResponse], stop: RemoteHostResponse) {
            startResponse = start
            eventResponses = events
            stopResponse = stop
        }

        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {}
        func runs(workers: [Worker]) -> [RunRecord] { [] }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "test", capacity: .unavailable(reason: "test"))
        }
        func storeCredential(_ secret: Data, reference: String) throws {}
        func probeRemoteHost(_ computer: Computer) async throws -> RemoteHostResponse {
            record(.probe)
            return RemoteHostResponse(ok: true, hostVersion: "1", capabilities: ["start", "events-after-exclusive-cursor", "stop", "claude-code"])
        }
        func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data) async throws -> RemoteHostResponse {
            record(.start)
            return startResponse
        }
        func remoteEvents(on computer: Computer, runID: String, after sequence: UInt64) async throws -> RemoteHostResponse {
            lock.withLock {
                operations.append(.events)
                return eventResponses.removeFirst()
            }
        }
        func stopRemoteWorker(on computer: Computer, runID: String) async throws -> RemoteHostResponse {
            record(.stop)
            return stopResponse
        }
        func recordedOperations() -> [RemoteHostOperation] {
            lock.lock(); defer { lock.unlock() }
            return operations
        }
        private func record(_ operation: RemoteHostOperation) {
            lock.lock(); operations.append(operation); lock.unlock()
        }
    }

    private func installedComputer(transport: ComputerTransport = .ssh) -> Computer {
        Computer(
            name: "remote",
            transport: transport,
            host: "remote.tailnet.ts.net",
            user: "workjet",
            deploymentStatus: .installed,
            installedSidecarVersion: PiSidecarRuntime.version,
            knownHostsPath: "/private/workjet-known-hosts",
            tailscaleExecutablePath: transport == .tailscale ? "/usr/bin/tailscale" : nil
        )
    }

    private func responseLine(_ response: RemoteHostResponse) throws -> Data {
        var data = try JSONEncoder().encode(response)
        data.append(0x0a)
        return data
    }

    func testClientUsesRealSSHTransportAndExclusiveCursor() async throws {
        let response = RemoteHostResponse(ok: true, runID: "run-1", state: .running, cursor: 8)
        let runner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: try responseLine(response)))
        let client = RemoteHostClient(computer: installedComputer(), runner: runner, tailscaleLocator: Locator(path: nil))

        let received = try await client.events(runID: "run-1", after: 7)
        XCTAssertEqual(received, response)
        let recordedCommands = await runner.recordedCommands()
        let command = try XCTUnwrap(recordedCommands.first)
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.suffix(2).elementsEqual(["node", ".local/lib/workjet/current/workjet-host.mjs"]))
        let request = try JSONDecoder().decode(RemoteHostRequest.self, from: command.standardInput)
        XCTAssertEqual(request.operation, .events)
        XCTAssertEqual(request.afterSequence, 7)
    }

    func testStartReplayAndStopPreserveAuthoritativeRemoteState() async throws {
        let started = RemoteHostResponse(ok: true, runID: "run-2", state: .starting, cursor: 0)
        let first = RemoteHostEvent(sequence: 1, timestamp: "2026-08-03T10:00:00Z", kind: "started", text: "claude-code")
        let output = RemoteHostEvent(sequence: 2, timestamp: "2026-08-03T10:00:01Z", kind: "stdout", text: "working")
        let replay = RemoteHostResponse(ok: true, runID: "run-2", state: .running, cursor: 2, oldestSequence: 1, events: [first, output])
        let stopped = RemoteHostResponse(ok: true, runID: "run-2", state: .stopped, cursor: 2)
        let host = ScriptedHost([.response(started), .response(replay), .response(stopped)])
        let ledger = RemoteRunLedger(client: host)

        let runID = try await ledger.start(RemoteHostRequest(operation: .start, launch: RemoteHarnessLaunch(harnessID: "claude-code", model: "claude-sonnet-5", reasoning: "high", sandbox: false, input: Data("brief".utf8))))
        XCTAssertEqual(runID, "run-2")
        let replayed = try await ledger.replay()
        XCTAssertEqual(replayed, [first, output])
        let cursor = await ledger.cursor
        XCTAssertEqual(cursor, 2)
        try await ledger.stop()
        let state = await ledger.state
        XCTAssertEqual(state, .stopped)

        let requests = await host.recordedRequests()
        XCTAssertEqual(requests.map(\.operation), [.start, .events, .stop])
        XCTAssertEqual(requests[1].afterSequence, 0)
    }

    func testReconnectRetriesTransportFailureWithoutReplayingCursor() async throws {
        let started = RemoteHostResponse(ok: true, runID: "run-3", state: .starting)
        let event = RemoteHostEvent(sequence: 1, timestamp: "2026-08-03T10:00:00Z", kind: "started")
        let replay = RemoteHostResponse(ok: true, runID: "run-3", state: .running, cursor: 1, oldestSequence: 1, events: [event])
        let host = ScriptedHost([.response(started), .transport("link lost"), .response(replay)])
        let ledger = RemoteRunLedger(client: host)
        _ = try await ledger.start(RemoteHostRequest(operation: .start))
        let supervisor = RemoteConnectionSupervisor(ledger: ledger, policy: .init(attempts: 2, initialDelayMilliseconds: 0))

        let replayed = try await supervisor.reconnectAndReplay()
        XCTAssertEqual(replayed, [event])
        let requests = await host.recordedRequests()
        XCTAssertEqual(requests.dropFirst().map(\.afterSequence), [0, 0])
        let connectionError = await supervisor.connectionError
        XCTAssertNil(connectionError)
    }

    func testReconnectDeduplicatesAlreadyDeliveredPrefixWithoutReplayingIt() async throws {
        let first = RemoteHostEvent(sequence: 1, timestamp: "2026-08-03T10:00:00Z", kind: "started")
        let second = RemoteHostEvent(sequence: 2, timestamp: "2026-08-03T10:00:01Z", kind: "stdout", text: "next")
        let host = ScriptedHost([
            .response(RemoteHostResponse(ok: true, runID: "run-resume", state: .starting)),
            .response(RemoteHostResponse(ok: true, runID: "run-resume", state: .running, cursor: 1, oldestSequence: 1, events: [first])),
            .transport("link lost"),
            .response(RemoteHostResponse(ok: true, runID: "run-resume", state: .running, cursor: 2, oldestSequence: 1, events: [first, second]))
        ])
        let ledger = RemoteRunLedger(client: host)
        _ = try await ledger.start(RemoteHostRequest(operation: .start))
        let initial = try await ledger.replay()
        XCTAssertEqual(initial, [first])
        let supervisor = RemoteConnectionSupervisor(ledger: ledger, policy: .init(attempts: 2, initialDelayMilliseconds: 0))

        let resumed = try await supervisor.reconnectAndReplay()
        let snapshot = await ledger.snapshot()
        let requests = await host.recordedRequests()
        XCTAssertEqual(resumed, [second])
        XCTAssertEqual(snapshot.events, [first, second])
        XCTAssertEqual(requests.suffix(2).map(\.afterSequence), [1, 1])
    }

    func testStaleExplicitHeartbeatRequestsGhostStopAndKeepsTerminalState() async throws {
        let stale = "2026-08-03T10:00:00Z"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-03T10:02:00Z"))
        let host = ScriptedHost([
            .response(RemoteHostResponse(ok: true, runID: "run-ghost", state: .running, heartbeatAt: stale)),
            .response(RemoteHostResponse(ok: true, runID: "run-ghost", state: .running, heartbeatAt: stale)),
            .response(RemoteHostResponse(ok: true, runID: "run-ghost", state: .stopped, heartbeatAt: stale))
        ])
        let ledger = RemoteRunLedger(client: host, now: { now })
        _ = try await ledger.start(RemoteHostRequest(operation: .start))
        let supervisor = RemoteConnectionSupervisor(ledger: ledger, policy: .init(attempts: 1, initialDelayMilliseconds: 0))

        _ = try await supervisor.refreshAndReapGhosts(staleAfter: 45)

        let snapshot = await ledger.snapshot()
        let requests = await host.recordedRequests()
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertEqual(requests.map(\.operation), [.start, .events, .stop])
    }

    @MainActor
    func testViewModelWiresProbeStartEventsAndStopThroughService() async throws {
        let event = RemoteHostEvent(sequence: 1, timestamp: "2026-08-03T10:00:00Z", kind: "started", text: "claude-code")
        let freshHeartbeat = ISO8601DateFormatter().string(from: Date())
        let service = RemoteService(
            start: RemoteHostResponse(ok: true, runID: "run-app", state: .starting),
            events: [RemoteHostResponse(ok: true, runID: "run-app", state: .running, cursor: 1, oldestSequence: 1, heartbeatAt: freshHeartbeat, events: [event])],
            stop: RemoteHostResponse(ok: true, runID: "run-app", state: .stopped, cursor: 1, heartbeatAt: freshHeartbeat)
        )
        var remote = installedComputer()
        remote.sandboxEnabled = false
        var configuration = WorkjetDefaults.configuration()
        configuration.computers.append(remote)
        configuration.workers[0].computerID = remote.id
        let workerID = configuration.workers[0].id
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)

        let started = await model.startRemoteWorker(id: workerID, input: Data("implement".utf8))
        XCTAssertEqual(started?.state, .starting)
        model.refreshRemoteTelemetry()
        for _ in 0..<50 where model.remoteRuns[workerID]?.cursor != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.remoteRuns[workerID]?.events, [event])
        await model.stopRemoteWorker(id: workerID)
        XCTAssertEqual(model.remoteRuns[workerID]?.state, .stopped)
        XCTAssertEqual(service.recordedOperations(), [.probe, .start, .probe, .events, .stop])
    }

    func testSequenceGapBecomesErrorAndIsNotRetried() async throws {
        let started = RemoteHostResponse(ok: true, runID: "run-gap", state: .starting)
        let gap = RemoteHostEvent(sequence: 2, timestamp: "2026-08-03T10:00:00Z", kind: "stdout", text: "missing one")
        let replay = RemoteHostResponse(ok: true, runID: "run-gap", state: .running, cursor: 2, oldestSequence: 2, events: [gap])
        let host = ScriptedHost([.response(started), .response(replay), .transport("must not be consumed")])
        let ledger = RemoteRunLedger(client: host)
        _ = try await ledger.start(RemoteHostRequest(operation: .start))
        let supervisor = RemoteConnectionSupervisor(ledger: ledger, policy: .init(attempts: 3, initialDelayMilliseconds: 0))

        do {
            _ = try await supervisor.reconnectAndReplay()
            XCTFail("Expected sequence gap")
        } catch {
            XCTAssertEqual(error as? RemoteRunLedgerError, .sequenceGap(expected: 1, received: 2))
        }
        let state = await ledger.state
        XCTAssertEqual(state, .error)
        let requests = await host.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testRemoteAdaptersRejectUnimplementedProtocolHarnessesRatherThanFakingRuns() throws {
        let computer = installedComputer()
        var worker = WorkjetDefaults.configuration().workers[0]
        worker.computerID = computer.id
        worker.model = "gpt-5.6-sol"
        let registry = RemoteHarnessAdapterRegistry()

        worker.harness = .codexCLI
        XCTAssertEqual(try registry.launch(worker: worker, computer: computer, input: Data("implement".utf8)).harnessID, "codex-cli")
        worker.harness = .openCode
        XCTAssertEqual(try registry.launch(worker: worker, computer: computer, input: Data("implement".utf8)).harnessID, "opencode")
        for harness in [Harness.cursorAgent, .grokCLI] {
            worker.harness = harness
            XCTAssertThrowsError(try registry.launch(worker: worker, computer: computer, input: Data("implement".utf8))) {
                XCTAssertEqual($0 as? RemoteHarnessAdapterError, .unsupportedHarness(harness.rawValue))
            }
        }
    }

    func testMalformedTruncatedAndRejectedResponsesStayExplicitErrors() async throws {
        let malformed = ReplyRunner(CommandResult(exitCode: 0, standardOutput: Data("not-json\n".utf8)))
        do {
            _ = try await RemoteHostClient(computer: installedComputer(), runner: malformed, tailscaleLocator: Locator(path: nil)).probe()
            XCTFail("Expected malformed response")
        } catch { XCTAssertEqual(error as? RemoteHostProtocolError, .malformedResponse) }

        let truncated = ReplyRunner(CommandResult(exitCode: 0, stdoutTruncated: true))
        do {
            _ = try await RemoteHostClient(computer: installedComputer(), runner: truncated, tailscaleLocator: Locator(path: nil)).probe()
            XCTFail("Expected truncated response")
        } catch { XCTAssertEqual(error as? RemoteHostProtocolError, .truncatedResponse) }

        let rejectedResponse = RemoteHostResponse(ok: false, error: "harness unavailable", state: .error)
        let rejected = ReplyRunner(CommandResult(exitCode: 0, standardOutput: try responseLine(rejectedResponse)))
        do {
            _ = try await RemoteHostClient(computer: installedComputer(), runner: rejected, tailscaleLocator: Locator(path: nil)).probe()
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? RemoteHostProtocolError, .rejected("harness unavailable")) }
    }
}
