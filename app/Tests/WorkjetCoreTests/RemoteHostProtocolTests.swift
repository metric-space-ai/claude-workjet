import CryptoKit
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
        private var listResponse: RemoteHostResponse
        private var adoptResponses: [RemoteHostResponse]
        private var wireOperations: [(String, String?, String?)] = []
        private var startOwnerIDs: [String] = []

        init(start: RemoteHostResponse, events: [RemoteHostResponse], stop: RemoteHostResponse, list: RemoteHostResponse = RemoteHostResponse(ok: true), adopts: [RemoteHostResponse] = []) {
            startResponse = start
            eventResponses = events
            stopResponse = stop
            listResponse = list
            adoptResponses = adopts
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
        func startRemoteWorker(_ worker: Worker, on computer: Computer, input: Data, ownerID: String) async throws -> RemoteHostResponse {
            lock.withLock { startOwnerIDs.append(ownerID) }
            return try await startRemoteWorker(worker, on: computer, input: input)
        }
        func listRemoteRuns(on computer: Computer, ownerID: String?) async throws -> RemoteHostResponse {
            lock.withLock {
                wireOperations.append(("list", nil, ownerID))
                return listResponse
            }
        }
        func adoptRemoteRun(on computer: Computer, runID: String, ownerID: String) async throws -> RemoteHostResponse {
            lock.withLock {
                wireOperations.append(("adopt", runID, ownerID))
                return adoptResponses.removeFirst()
            }
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
        func recordedWireOperations() -> [(String, String?, String?)] { lock.withLock { wireOperations } }
        func recordedStartOwnerIDs() -> [String] { lock.withLock { startOwnerIDs } }
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
        XCTAssertTrue(command.arguments.suffix(2).elementsEqual([".local/lib/workjet/current/workjet-node", ".local/lib/workjet/current/workjet-host.mjs"]))
        let request = try JSONDecoder().decode(RemoteHostRequest.self, from: command.standardInput)
        XCTAssertEqual(request.operation, .events)
        XCTAssertEqual(request.afterSequence, 7)
    }

    func testSecureProviderExecutionRoundTripsOnlyOnStartRequest() throws {
        let sentinel = "secret-transport-only"
        let execution = RemoteProviderExecution(displayName: "Account", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .openAI, displayName: "Account", endpoint: "https://api.openai.com/v1", authentication: .bearerToken, secret: sentinel)
        ])
        let launch = RemoteHarnessLaunch(harnessID: "codex-cli", model: "gpt", reasoning: "high", sandbox: false, input: Data("brief".utf8))
        let request = RemoteHostRequest(operation: .start, launch: launch, ownerID: "owner", providerExecution: execution)
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(RemoteHostRequest.self, from: encoded), request)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(sentinel), "the credential exists only in the encrypted SSH request body")

        let events = try JSONEncoder().encode(RemoteHostRequest(operation: .events, runID: "run-1", afterSequence: 0))
        XCTAssertFalse(String(decoding: events, as: UTF8.self).contains("providerExecution"))
        XCTAssertFalse(String(decoding: events, as: UTF8.self).contains(sentinel))
    }

    func testGatewayTunnelCommandIsStrictRunScopedLoopbackOnlySSH() throws {
        let command = try RemoteGatewayTunnelCommandBuilder.command(for: installedComputer())
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.arguments.contains("UserKnownHostsFile=\"/private/workjet-known-hosts\""))
        XCTAssertTrue(command.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(command.arguments.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(command.arguments.contains("127.0.0.1:0:127.0.0.1:8317"))
        XCTAssertFalse(command.arguments.contains(where: { $0.contains("0.0.0.0") || $0.contains("tailscale serve") || $0.contains("sh -c") }))
        XCTAssertEqual(command.arguments.suffix(4), ["-T", "-N", "--", "remote.tailnet.ts.net"])

        let tailscale = try RemoteGatewayTunnelCommandBuilder.command(for: installedComputer(transport: .tailscale))
        XCTAssertEqual(tailscale.executable, "/usr/bin/ssh", "Tailscale addresses still require strict OpenSSH host-key verification")
        XCTAssertTrue(tailscale.arguments.contains("127.0.0.1:0:127.0.0.1:8317"))
    }

    func testOnlyPiRemoteAdapterCanClaimTheVerifiedBubblewrapSandbox() throws {
        let computer = installedComputer()
        var worker = WorkjetDefaults.configuration().workers[0]
        worker.computerID = computer.id
        worker.model = "model"
        let registry = RemoteHarnessAdapterRegistry()
        let workspace = RemoteWorkspaceDescriptor(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40))

        for harness in [Harness.claudeCode, .codexCLI, .openCode] {
            worker.harness = harness
            let launch = try registry.launch(worker: worker, computer: computer, input: Data("brief".utf8), workspace: workspace)
            XCTAssertFalse(launch.sandbox, "\(harness.rawValue) has no verified remote filesystem sandbox")
        }

        worker.harness = .piSidecar
        let launch = try registry.launch(worker: worker, computer: computer, input: Data("{\"files\":[]}".utf8))
        XCTAssertTrue(launch.sandbox, "Pi Code is the only harness protected by the deployed bubblewrap turn runner")
    }

    func testGatewayTunnelBlocksBeforeSSHWhenPrivateKnownHostsIsUnconfirmed() async {
        var computer = installedComputer()
        computer.knownHostsPath = "/private/workjet-does-not-exist-\(UUID().uuidString)"
        let manager = RemoteGatewayTunnelManager()
        do {
            _ = try await manager.open(for: computer)
            XCTFail("an unconfirmed host key must block before starting the relay")
        } catch let error as RemoteGatewayTunnelError {
            XCTAssertEqual(error, .invalidKnownHosts)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testClientHarnessMaintenanceSendsOnlyTypedIDAndAction() async throws {
        let result = RemoteHarnessLifecycleResult(harnessID: "claude-code", action: .install, state: .installed, version: "2.0")
        let response = RemoteHostResponse(ok: true, harnessResult: result)
        let runner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: try responseLine(response)))
        let client = RemoteHostClient(computer: installedComputer(), runner: runner, tailscaleLocator: Locator(path: nil))

        let received = try await client.maintain(harnessID: "claude-code", action: .install)
        XCTAssertEqual(received, result)
        let commands = await runner.recordedCommands()
        let command = try XCTUnwrap(commands.first)
        let request = try JSONDecoder().decode(RemoteHostRequest.self, from: command.standardInput)
        XCTAssertEqual(request.operation, .harnessInstall)
        XCTAssertEqual(request.harnessID, "claude-code")
        XCTAssertNil(request.launch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: command.standardInput) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocolVersion", "operation", "harnessID"])
    }

    func testClientManagedSkillMaintenanceSendsOnlyTypedIDAndAction() async throws {
        let result = RemoteManagedSkillLifecycleResult(skillID: "greppy", action: .install, state: .installed, version: "1.3.0")
        let response = RemoteHostResponse(ok: true, managedSkillResult: result)
        let runner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: try responseLine(response)))
        let client = RemoteHostClient(computer: installedComputer(), runner: runner, tailscaleLocator: Locator(path: nil))

        let received = try await client.maintain(skillID: "greppy", action: .install)
        XCTAssertEqual(received, result)
        let commands = await runner.recordedCommands()
        let command = try XCTUnwrap(commands.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: command.standardInput) as? [String: Any])
        XCTAssertEqual(object["operation"] as? String, "managed-skill-install")
        XCTAssertEqual(object["skillID"] as? String, "greppy")
        XCTAssertEqual(Set(object.keys), ["protocolVersion", "operation", "skillID"])
        XCTAssertNil(object["url"])
        XCTAssertNil(object["command"])
        XCTAssertNil(object["arguments"])
    }

    func testClientPreservesStructuredUnknownHarnessAndUnavailableAction() async throws {
        let result = RemoteHarnessLifecycleResult(harnessID: "future-harness", action: .remove, state: .unavailable)
        let response = RemoteHostResponse(ok: true, harnessResult: result)
        let runner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: try responseLine(response)))
        let client = RemoteHostClient(computer: installedComputer(), runner: runner, tailscaleLocator: Locator(path: nil))

        let received = try await client.maintain(harnessID: "future-harness", action: .remove)
        XCTAssertEqual(received, result)
    }

    func testRemoteHostAllowsOnlyTheFourTypedLifecycleActions() {
        let source = RemotePiBootstrap.hostRuntimeSource
        XCTAssertTrue(source.contains(#"["harness-inspect", "harness-install", "harness-update", "harness-remove"].includes(request.operation)"#))
        XCTAssertTrue(source.contains(#"path.join(path.dirname(process.execPath), "npm")"#), "the verified Node runtime must use its matching npm before a potentially incompatible system npm")
        XCTAssertTrue(source.contains(#"["managed-skill-inspect", "managed-skill-install"].includes(request.operation)"#))
        XCTAssertTrue(source.contains(#"reject("client commands and URLs are forbidden")"#))
        XCTAssertTrue(source.contains(RemoteManagedSkillArtifact.greppyLinuxX8664URL))
        XCTAssertTrue(source.contains(RemoteManagedSkillArtifact.greppyLinuxX8664SHA256))
        XCTAssertTrue(source.contains(#"reject("unsupported operation")"#))
        XCTAssertFalse(source.contains("harness-execute"))
        XCTAssertFalse(source.contains("harness-command"))
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

    func testRestartAdoptionPreservesAcceptedRemoteMetadataAndAllowsOnlyAccountAdvance() async throws {
        let workerID = UUID()
        let initial = RemoteRunMetadata(
            workerID: workerID,
            workerName: "Reviewer",
            harnessID: "claude-code",
            model: "k3[1m]",
            reasoning: "high",
            speed: "fast",
            providerRoute: "Kimi Pool",
            startedAt: "2026-08-04T10:00:00Z"
        )
        var running = initial
        running.providerAccountLabel = "owner@example.test"
        let host = ScriptedHost([
            .response(RemoteHostResponse(ok: true, runID: "run-metadata", state: .running, metadata: initial)),
            .response(RemoteHostResponse(ok: true, runID: "run-metadata", state: .running, heartbeatAt: "2026-08-04T10:00:01Z", metadata: running))
        ])
        let firstApp = RemoteRunLedger(client: host)
        _ = try await firstApp.start(RemoteHostRequest(operation: .start))
        let firstSnapshot = await firstApp.snapshot()
        XCTAssertEqual(firstSnapshot.metadata, initial)

        let restartedApp = RemoteRunLedger(client: host)
        let adopted = try await restartedApp.adopt(runID: "run-metadata", ownerID: "workjet-worker-\(workerID.uuidString.lowercased())")
        XCTAssertEqual(adopted.metadata, running)
        XCTAssertEqual(adopted.metadata?.workerName, "Reviewer")
        XCTAssertEqual(adopted.metadata?.model, "k3[1m]")
    }

    func testLedgerRejectsRemoteMetadataThatChangesAcceptedLaunchFacts() async throws {
        let accepted = RemoteRunMetadata(harnessID: "claude-code", model: "accepted-model", providerRoute: "Route")
        let changed = RemoteRunMetadata(harnessID: "claude-code", model: "different-model", providerRoute: "Route")
        let host = ScriptedHost([
            .response(RemoteHostResponse(ok: true, runID: "run-tampered", state: .running, metadata: accepted)),
            .response(RemoteHostResponse(ok: true, runID: "run-tampered", state: .running, metadata: changed))
        ])
        let ledger = RemoteRunLedger(client: host)
        _ = try await ledger.start(RemoteHostRequest(operation: .start))

        do {
            _ = try await ledger.replay()
            XCTFail("changed accepted launch facts must not replace restart telemetry")
        } catch {
            XCTAssertEqual(error as? RemoteRunLedgerError, .metadataMismatch("run-tampered"))
        }
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
    func testViewModelDoesNotStartRemoteWorkerFromLocalProviderCredentials() async throws {
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
        XCTAssertNil(started)
        XCTAssertNil(model.remoteRuns[workerID])
        XCTAssertEqual(service.recordedOperations(), [])
        XCTAssertTrue(model.statusMessages.contains(where: { $0.localizedCaseInsensitiveContains("Anbieter") }))
    }

    func testRemoteServiceHostClientDispatchesV2WireOperations() async throws {
        let computer = installedComputer()
        let descriptor = RemoteHostRunDescriptor(runID: "run-bridge", state: .running, ownerID: "owner-bridge")
        let service = RemoteService(
            start: RemoteHostResponse(ok: true),
            events: [],
            stop: RemoteHostResponse(ok: true),
            list: RemoteHostResponse(ok: true, runs: [descriptor]),
            adopts: [RemoteHostResponse(ok: true, runID: "run-bridge", state: .running)]
        )
        let client = RemoteServiceHostClient(service: service, computer: computer)

        let listed = try await client.call(RemoteHostRequest(operation: .probe, ownerID: "owner-bridge", wireOperation: "list"))
        let adopted = try await client.call(RemoteHostRequest(operation: .events, runID: "run-bridge", ownerID: "owner-bridge", wireOperation: "adopt"))

        XCTAssertEqual(listed.runs, [descriptor])
        XCTAssertEqual(adopted.runID, "run-bridge")
        let calls = service.recordedWireOperations()
        XCTAssertEqual(calls.map(\.0), ["list", "adopt"])
        XCTAssertEqual(calls.map(\.1), [nil, "run-bridge"])
        XCTAssertEqual(calls.map(\.2), ["owner-bridge", "owner-bridge"])
        XCTAssertTrue(service.recordedOperations().isEmpty, "wire operations must not degrade to probe/events")
    }

    @MainActor
    func testFreshViewModelListsAndAdoptsOnlyPersistentlyAttributedRun() async throws {
        var computer = installedComputer()
        computer.sandboxEnabled = false
        var configuration = WorkjetDefaults.configuration()
        configuration.computers.append(computer)
        configuration.workers[0].computerID = computer.id
        let worker = configuration.workers[0]
        let ownerID = "workjet-worker-\(worker.id.uuidString.lowercased())"

        let event = RemoteHostEvent(sequence: 1, timestamp: "2026-08-04T10:00:00Z", kind: "stdout", text: "raw diagnostic")
        let heartbeat = ISO8601DateFormatter().string(from: Date())
        let recoveryService = RemoteService(
            start: RemoteHostResponse(ok: true),
            events: [
                RemoteHostResponse(ok: true, runID: "run-owned", state: .running, cursor: 1, oldestSequence: 1, heartbeatAt: heartbeat, events: [event]),
                RemoteHostResponse(ok: true, runID: "run-owned", state: .running, cursor: 1, oldestSequence: 1, heartbeatAt: heartbeat)
            ],
            stop: RemoteHostResponse(ok: true),
            list: RemoteHostResponse(ok: true, runs: [
                RemoteHostRunDescriptor(runID: "run-owned", state: .running, cursor: 1, oldestSequence: 1, heartbeatAt: heartbeat, ownerID: ownerID),
                RemoteHostRunDescriptor(runID: "run-foreign", state: .running, ownerID: "workjet-worker-\(UUID().uuidString.lowercased())"),
                RemoteHostRunDescriptor(runID: "run-unattributed", state: .running, ownerID: nil)
            ]),
            adopts: [RemoteHostResponse(ok: true, runID: "run-owned", state: .running, heartbeatAt: heartbeat)]
        )
        let afterRestart = WorkjetViewModel(configuration: configuration, service: recoveryService, persistenceDelay: 60)

        afterRestart.refreshRemoteTelemetry()
        for _ in 0..<100 where afterRestart.remoteRuns[worker.id]?.cursor != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(afterRestart.remoteRuns.count, 1)
        XCTAssertEqual(afterRestart.remoteRuns[worker.id]?.runID, "run-owned")
        XCTAssertEqual(afterRestart.remoteRuns[worker.id]?.events, [event])
        XCTAssertEqual(
            afterRestart.remoteHostErrors[computer.id],
            "Ein laufender Remote-Worker konnte nicht zugeordnet werden. Öffne den Computer und prüfe die Verbindung."
        )

        afterRestart.refreshRemoteTelemetry()
        for _ in 0..<100 where recoveryService.recordedWireOperations().filter({ $0.0 == "list" }).count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let wireCalls = recoveryService.recordedWireOperations()
        XCTAssertEqual(wireCalls.filter { $0.0 == "adopt" }.count, 1, "refresh must deduplicate an already adopted run")
        XCTAssertEqual(afterRestart.remoteRuns.count, 1, "foreign and unattributable runs must never be assigned heuristically")
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
        let workspace = RemoteWorkspaceDescriptor(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40))

        worker.harness = .codexCLI
        XCTAssertEqual(try registry.launch(worker: worker, computer: computer, input: Data("implement".utf8), workspace: workspace).harnessID, "codex-cli")
        worker.harness = .openCode
        XCTAssertEqual(try registry.launch(worker: worker, computer: computer, input: Data("implement".utf8), workspace: workspace).harnessID, "opencode")
        for harness in [Harness.cursorAgent, .grokCLI] {
            worker.harness = harness
            XCTAssertThrowsError(try registry.launch(worker: worker, computer: computer, input: Data("implement".utf8))) {
                XCTAssertEqual($0 as? RemoteHarnessAdapterError, .unsupportedHarness(harness.rawValue))
            }
        }
    }

    func testWorkspaceResultClientUsesStrictRawBinaryTransportAndRejectsIdentityOrHashMismatch() async throws {
        let request = RemoteWorkspaceResultRequest(
            runID: "run-result-1",
            ownerID: "workjet-worker-00000000-0000-0000-0000-000000000123",
            repoID: String(repeating: "a", count: 64),
            snapshotCommitOID: String(repeating: "b", count: 40)
        )
        let bundle = Data([0, 10, 255, 1, 2, 0, 13])
        let hash = SHA256.hash(data: bundle).map { String(format: "%02x", $0) }.joined()
        let manifest = WorkspaceResultManifest(runID: request.runID, repoID: request.repoID, snapshotCommitOID: request.snapshotCommitOID, resultCommitOID: String(repeating: "c", count: 40), bundleSHA256: hash, byteSize: bundle.count, terminalState: .completed)
        var output = try JSONEncoder().encode(manifest); output.append(0x0a); output.append(bundle)
        let runner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: output))
        let result = try await RemoteHostClient(computer: installedComputer(), runner: runner, tailscaleLocator: Locator(path: nil)).exportWorkspaceResult(request, verifiedCapabilities: ["workspace-result-v1"])
        XCTAssertEqual(result.bundle, bundle)
        let commands = await runner.recordedCommands()
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.arguments.suffix(2).elementsEqual([".local/lib/workjet/current/workjet-host.mjs", "--workspace-result"]))
        XCTAssertGreaterThan(command.stdoutLimit, LocalWorkspaceResultImporter.maximumBundleBytes)
        XCTAssertFalse(String(decoding: command.standardInput, as: UTF8.self).contains("/Users/"))

        var badManifest = manifest; badManifest.bundleSHA256 = String(repeating: "0", count: 64)
        var badOutput = try JSONEncoder().encode(badManifest); badOutput.append(0x0a); badOutput.append(bundle)
        let badRunner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: badOutput))
        do {
            _ = try await RemoteHostClient(computer: installedComputer(), runner: badRunner, tailscaleLocator: Locator(path: nil)).exportWorkspaceResult(request, verifiedCapabilities: ["workspace-result-v1"])
            XCTFail("expected hash rejection")
        } catch { XCTAssertEqual(error as? RemoteHostProtocolError, .malformedResponse) }

        var wrongRun = manifest; wrongRun.runID = "run-other"
        var wrongOutput = try JSONEncoder().encode(wrongRun); wrongOutput.append(0x0a); wrongOutput.append(bundle)
        let wrongRunner = ReplyRunner(CommandResult(exitCode: 0, standardOutput: wrongOutput))
        do {
            _ = try await RemoteHostClient(computer: installedComputer(), runner: wrongRunner, tailscaleLocator: Locator(path: nil)).exportWorkspaceResult(request, verifiedCapabilities: ["workspace-result-v1"])
            XCTFail("expected run identity rejection")
        } catch { XCTAssertEqual(error as? RemoteHostProtocolError, .malformedResponse) }
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
