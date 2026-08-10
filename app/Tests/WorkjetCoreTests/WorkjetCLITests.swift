import Foundation
import Darwin
import XCTest
@testable import WorkjetCore

final class WorkjetCLITests: XCTestCase {
    private final class Credentials: CredentialStoring, @unchecked Sendable {
        var values: [String: Data]
        private(set) var reads: [String] = []

        init(_ values: [String: Data]) { self.values = values }

        func read(reference: String) throws -> Data? {
            reads.append(reference)
            return values[reference]
        }

        func write(_ secret: Data, reference: String) throws { values[reference] = secret }
        func delete(reference: String) throws { values[reference] = nil }
    }

    private var builtWorkjetCLI: URL {
        Bundle(for: WorkjetCLITests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("workjet")
    }

    private final class Backing: WorkjetCLIBacking, @unchecked Sendable {
        let configuration: WorkjetConfiguration
        private let lock = NSLock()
        private(set) var starts: [(UUID, UUID, Data, String)] = []
        private(set) var startedWorkers: [Worker] = []
        private(set) var remoteRoutes: [ResolvedProviderRuntimeRoute] = []
        private(set) var eventCalls: [(UUID, String, UInt64)] = []
        private(set) var stopCalls: [(UUID, String)] = []
        private(set) var listCalls: [(UUID, String)] = []
        private(set) var localStarts: [(UUID, Data)] = []
        var localRunID: String? = "local-run"
        var localProbeOutput = "WORKJET_HEALTH_OK"
        var localProbeState: RemoteHostRunState = .completed
        var listedRuns: [UUID: [RemoteHostRunDescriptor]] = [:]
        var importReceipt: WorkspaceResultImportReceipt?
        var markReceipt: WorkspaceLifecycleReceipt?
        var workspaceError: WorkspaceResultError?

        init(configuration: WorkjetConfiguration) { self.configuration = configuration }

        func startLocal(worker: Worker, brief: Data) async throws -> RemoteHostResponse {
            lock.withLock { localStarts.append((worker.id, brief)) }
            return RemoteHostResponse(ok: true, runID: localRunID, state: .running, cursor: 1)
        }

        func localEvents(runID: String, after: UInt64) async throws -> RemoteHostResponse? {
            guard runID == localRunID else { return nil }
            return RemoteHostResponse(ok: true, runID: runID, state: localProbeState, cursor: after + 2, events: [
                RemoteHostEvent(sequence: after + 1, timestamp: "2026-08-08T10:00:00Z", kind: "stdout", text: localProbeOutput),
                RemoteHostEvent(sequence: after + 2, timestamp: "2026-08-08T10:00:01Z", kind: "lifecycle", text: localProbeState.rawValue, exitCode: localProbeState == .completed ? 0 : 1)
            ])
        }

        func start(worker: Worker, computer: Computer, brief: Data, ownerID: String) async throws -> RemoteHostResponse {
            lock.withLock {
                starts.append((worker.id, computer.id, brief, ownerID))
                startedWorkers.append(worker)
            }
            return RemoteHostResponse(ok: true, runID: "run-new", state: .starting, cursor: 0)
        }

        func start(worker: Worker, computer: Computer, route: ResolvedProviderRuntimeRoute, brief: Data, ownerID: String) async throws -> RemoteHostResponse {
            lock.withLock { remoteRoutes.append(route) }
            return try await start(worker: worker, computer: computer, brief: brief, ownerID: ownerID)
        }

        func list(computer: Computer, ownerID: String) async throws -> RemoteHostResponse {
            lock.withLock {
                listCalls.append((computer.id, ownerID))
                return RemoteHostResponse(ok: true, runs: (listedRuns[computer.id] ?? []).filter { $0.ownerID == ownerID })
            }
        }

        func events(computer: Computer, runID: String, after: UInt64) async throws -> RemoteHostResponse {
            lock.withLock { eventCalls.append((computer.id, runID, after)) }
            return RemoteHostResponse(ok: true, runID: runID, state: .running, cursor: after + 1, events: [
                RemoteHostEvent(sequence: after + 1, timestamp: "2026-08-04T10:00:00Z", kind: "stdout", text: "ok")
            ])
        }

        func stop(computer: Computer, runID: String) async throws -> RemoteHostResponse {
            lock.withLock { stopCalls.append((computer.id, runID)) }
            return RemoteHostResponse(ok: true, runID: runID, state: .stopped, cursor: 9)
        }

        func importResult(runID: String) async throws -> WorkspaceResultImportReceipt {
            if let workspaceError { throw workspaceError }
            return try XCTUnwrap(importReceipt)
        }

        func mark(runID: String, disposition: RemoteWorkspaceDisposition) async throws -> WorkspaceLifecycleReceipt {
            if let workspaceError { throw workspaceError }
            return try XCTUnwrap(markReceipt)
        }

        func recordedStarts() -> [(UUID, UUID, Data, String)] { lock.withLock { starts } }
        func recordedStartedWorkers() -> [Worker] { lock.withLock { startedWorkers } }
        func recordedRemoteRoutes() -> [ResolvedProviderRuntimeRoute] { lock.withLock { remoteRoutes } }
        func recordedEvents() -> [(UUID, String, UInt64)] { lock.withLock { eventCalls } }
        func recordedStops() -> [(UUID, String)] { lock.withLock { stopCalls } }
        func recordedLists() -> [(UUID, String)] { lock.withLock { listCalls } }
        func setListedRuns(_ value: [RemoteHostRunDescriptor], computerID: UUID) { lock.withLock { listedRuns[computerID] = value } }
    }

    private let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let workerID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!

    func testParserCoversCommandsAndRejectsInvalidBriefCombinations() throws {
        XCTAssertEqual(
            try WorkjetCLIParser.parse(["computers", "setup", "gpu3-a4500", "--json"]),
            .computerSetup(identifier: "gpu3-a4500", json: true)
        )
        XCTAssertEqual(try WorkjetCLIParser.parse(["workers", "list", "--json"]), .workersList(json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["workers", "describe", "Reviewer", "--json"]), .workerDescribe(identifier: "Reviewer", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["health", "--probe-workers", "--timeout", "30", "--json"]), .healthProbeWorkers(identifiers: [], timeoutSeconds: 30, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["health", "--probe-workers", "--worker", "Reviewer", "--json"]), .healthProbeWorkers(identifiers: ["Reviewer"], timeoutSeconds: nil, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["run", "Reviewer", "--brief", "review", "--json"]), .run(identifier: "Reviewer", brief: .inline("review"), json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["events", "run-1", "--after", "8", "--json"]), .events(runID: "run-1", after: 8, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["stop", "run-1", "--json"]), .stop(runID: "run-1", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["result", "import", "run-1", "--json"]), .resultImport(runID: "run-1", json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["runs", "mark", "run-1", "integrated", "--json"]), .runsMark(runID: "run-1", disposition: .integrated, json: true))
        XCTAssertEqual(try WorkjetCLIParser.parse(["runs", "mark", "run-1", "abandoned"]), .runsMark(runID: "run-1", disposition: .abandoned, json: false))

        XCTAssertThrowsError(try WorkjetCLIParser.parse(["run", "Reviewer", "--brief", "a", "--brief-file", "b", "--json"])) { error in
            XCTAssertEqual((error as? WorkjetCLIError)?.code, "usage")
            XCTAssertEqual((error as? WorkjetCLIError)?.exitCode, .usage)
        }
        XCTAssertThrowsError(try WorkjetCLIParser.parse(["events", "run-1", "--after", "-1", "--json"]))
        XCTAssertThrowsError(try WorkjetCLIParser.parse(["health", "--json"]))
        XCTAssertThrowsError(try WorkjetCLIParser.parse(["health", "--probe-workers", "--timeout", "2", "--json"]))
    }

    func testHealthProbeStartsWorkerAndRequiresExactResponseToken() async throws {
        var worker = Worker(id: workerID, name: "Probe", harness: .claudeCode, model: "gpt", computerID: localID, invocation: WorkerInvocation(executable: "/usr/bin/true", arguments: ["<WORKJET_BRIEF>"]))
        let provider = fixtureProvider(.openAI)
        worker.providerID = provider.id
        let backing = Backing(configuration: configuration(remoteWorkers: [], extraWorkers: [worker], providers: [provider]))
        let engine = WorkjetCLIEngine(backing: backing)

        let ready = try await engine.execute(.healthProbeWorkers(identifiers: [], timeoutSeconds: 5, json: true))
        XCTAssertTrue(ready.ok)
        XCTAssertNotNil(ready.checkedAt)
        XCTAssertEqual(ready.health?.first?.status, "ready")
        XCTAssertEqual(ready.health?.first?.responseTokenObserved, true)
        XCTAssertTrue(String(decoding: try XCTUnwrap(backing.localStarts.first?.1), as: UTF8.self).contains("WORKJET HEALTH PROBE V1"))

        backing.localProbeOutput = "hello"
        let failed = try await engine.execute(.healthProbeWorkers(identifiers: [], timeoutSeconds: 5, json: true))
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.health?.first?.status, "failed")
        XCTAssertEqual(failed.health?.first?.error, "health_response_invalid")

        backing.localProbeOutput = "Failed to authenticate. HTTP 403 usage limit reached for this billing cycle."
        backing.localProbeState = .failed
        let providerFailed = try await engine.execute(.healthProbeWorkers(identifiers: [], timeoutSeconds: 5, json: true))
        XCTAssertEqual(providerFailed.health?.first?.error, "provider_unavailable")
        XCTAssertTrue(providerFailed.health?.first?.message?.contains("HTTP 403") == true)
    }

    func testCurrentExecutableResolutionDoesNotDependOnRelativeArgvZero() throws {
        let executable = try LiveWorkjetCLIBacking.currentExecutableURL()
        XCTAssertTrue(executable.path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    }

    func testLocalRunReadsGatewayCredentialFromGatewayStoreAndDirectCredentialFromConfiguredStore() throws {
        let keychain = Credentials(["provider-direct": Data("direct-secret".utf8)])
        let gateway = Credentials([CLIProxyGatewayCredentialStore.reference: Data("gateway-secret".utf8)])
        let service = LocalRunService(paths: .live, credentials: keychain, gatewayCredentials: gateway)

        XCTAssertEqual(
            try service.credentialData(reference: CLIProxyGatewayCredentialStore.reference),
            Data("gateway-secret".utf8)
        )
        XCTAssertEqual(try service.credentialData(reference: "provider-direct"), Data("direct-secret".utf8))
        XCTAssertEqual(gateway.reads, [CLIProxyGatewayCredentialStore.reference])
        XCTAssertEqual(keychain.reads, ["provider-direct"])
    }

    func testListDescribeAndExactNameAmbiguityHaveStableContract() async throws {
        var configuration = configuration(remoteWorkers: [
            Worker(id: workerID, name: "Reviewer", harness: .piSidecar, model: "Kimi K3", reasoningEffort: .high, computerID: remoteID),
            Worker(name: "Reviewer", harness: .claudeCode, model: "Kimi K3", computerID: remoteID)
        ])
        let backing = Backing(configuration: configuration)
        let engine = WorkjetCLIEngine(backing: backing)

        let listed = try await engine.execute(.workersList(json: true))
        XCTAssertEqual(listed.command, "workers.list")
        XCTAssertEqual(listed.workers?.count, 2)
        XCTAssertEqual(listed.workers?.first?.computerName, "gpu")

        let described = try await engine.execute(.workerDescribe(identifier: workerID.uuidString, json: true))
        XCTAssertEqual(described.worker?.id, workerID)
        XCTAssertEqual(described.worker?.reasoning, "high")

        do {
            _ = try await engine.execute(.workerDescribe(identifier: "Reviewer", json: true))
            XCTFail("expected ambiguity")
        } catch let error as WorkjetCLIError {
            XCTAssertEqual(error.code, "worker_ambiguous")
            XCTAssertEqual(error.exitCode, .ambiguous)
        }

        configuration.workers.removeAll()
        _ = configuration // keep the fixture visibly value-based
        let encoded = try JSONEncoder().encode(WorkjetCLIErrorResponse(error: "worker_ambiguous", message: "Mehrdeutig"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "worker_ambiguous")
    }

    func testRemoteStartUsesResolvedProviderRouteWhileEventsAndStopRemainAuthoritative() async throws {
        var worker = Worker(id: workerID, name: "Remote", harness: .piSidecar, model: "Kimi K3", reasoningEffort: .high, computerID: remoteID)
        worker.providerPool = .kimi
        worker.invocation.options["fastMode"] = "true"
        let backing = Backing(configuration: configuration(remoteWorkers: [worker], providers: [fixtureProvider(.kimi)]))
        let owner = "workjet-worker-\(workerID.uuidString.lowercased())"
        backing.setListedRuns([RemoteHostRunDescriptor(runID: "run-new", state: .running, cursor: 7, ownerID: owner)], computerID: remoteID)
        let engine = WorkjetCLIEngine(backing: backing)

        let started = try await engine.execute(.run(identifier: workerID.uuidString, brief: .inline("do it"), json: true))
        XCTAssertEqual(started.runID, "run-new")
        XCTAssertEqual(backing.recordedStarts().count, 1)
        let deliveredWorker = try XCTUnwrap(backing.recordedStartedWorkers().first)
        XCTAssertEqual(deliveredWorker.model, "Kimi K3")
        XCTAssertEqual(deliveredWorker.reasoningEffort, .high)
        XCTAssertEqual(deliveredWorker.invocation.options["fastMode"], "true")
        let remoteLaunch = try RemoteHarnessAdapterRegistry().launch(worker: deliveredWorker, computer: backing.configuration.computers.first(where: { $0.id == remoteID })!, input: Data(#"{"files":[]}"#.utf8))
        XCTAssertEqual(remoteLaunch.model, "Kimi K3")
        XCTAssertEqual(remoteLaunch.reasoning, "high")
        XCTAssertEqual(remoteLaunch.options["fastMode"], "true")
        let route = try XCTUnwrap(backing.recordedRemoteRoutes().first)
        XCTAssertEqual(route.candidates.count, 1)
        XCTAssertEqual(route.candidates.first?.modelProvider, .kimi)
        XCTAssertEqual(route.candidates.first?.kind, .directAccount)
        XCTAssertTrue(route.candidates.first?.credentialReference?.hasPrefix("provider-") == true)

        let events = try await engine.execute(.events(runID: "run-new", after: 7, json: true))
        XCTAssertEqual(events.cursor, 8)
        XCTAssertEqual(events.events?.first?.sequence, 8)
        XCTAssertEqual(backing.recordedEvents().first?.2, 7)
        XCTAssertEqual(backing.recordedLists().first?.1, owner)

        let stopped = try await engine.execute(.stop(runID: "run-new", json: true))
        XCTAssertEqual(stopped.state, "stopped")
        XCTAssertEqual(backing.recordedStops().first?.1, "run-new")
    }

    func testLocalRunRoutesOnlyToLocalServiceAndForeignRemoteRunIsRejected() async throws {
        var local = Worker(id: workerID, name: "Local", harness: .claudeCode, model: "gpt", computerID: localID, invocation: WorkerInvocation(executable: "/usr/bin/true", arguments: ["<WORKJET_BRIEF>"]))
        let provider = fixtureProvider(.openAI)
        local.providerID = provider.id
        let localBacking = Backing(configuration: configuration(remoteWorkers: [], extraWorkers: [local], providers: [provider]))
        let started = try await WorkjetCLIEngine(backing: localBacking).execute(.run(identifier: "Local", brief: .inline("x"), json: true))
        XCTAssertEqual(started.runID, "local-run")
        XCTAssertEqual(localBacking.localStarts.first?.0, workerID)
        XCTAssertEqual(localBacking.localStarts.first?.1, Data("x".utf8))
        XCTAssertTrue(localBacking.recordedStarts().isEmpty)

        let remote = Worker(id: workerID, name: "Remote", harness: .piSidecar, model: "Kimi", computerID: remoteID)
        let remoteBacking = Backing(configuration: configuration(remoteWorkers: [remote]))
        remoteBacking.setListedRuns([RemoteHostRunDescriptor(runID: "foreign", state: .running, ownerID: "someone-else")], computerID: remoteID)
        do {
            _ = try await WorkjetCLIEngine(backing: remoteBacking).execute(.stop(runID: "foreign", json: true))
            XCTFail("expected ownership rejection")
        } catch let error as WorkjetCLIError {
            XCTAssertEqual(error.code, "run_not_found")
            XCTAssertEqual(error.exitCode, .notFound)
            XCTAssertTrue(remoteBacking.recordedStops().isEmpty)
        }
    }

    func testRealLocalServiceValidatesExecutablePlaceholderAndPersistsMetadataAndStopIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-local-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state", isDirectory: true))
        let cli = builtWorkjetCLI
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), "Das fokussierte Test-Build muss die echte Workjet-CLI enthalten.")
        let service = LocalRunService(paths: paths)

        var invalid = Worker(id: workerID, name: "Invalid", harness: .claudeCode, model: "gpt", computerID: localID)
        invalid.invocation = WorkerInvocation(executable: "relative-tool", arguments: ["<WORKJET_BRIEF>"])
        XCTAssertThrowsError(try service.start(worker: invalid, brief: Data("x".utf8), supervisorExecutable: cli)) {
            XCTAssertEqual(($0 as? WorkjetCLIError)?.code, "executable_invalid")
        }
        invalid.invocation = WorkerInvocation(executable: "/usr/bin/true", arguments: [])
        XCTAssertThrowsError(try service.start(worker: invalid, brief: Data("x".utf8), supervisorExecutable: cli)) {
            XCTAssertEqual(($0 as? WorkjetCLIError)?.code, "brief_contract_invalid")
        }
        invalid.invocation = WorkerInvocation(executable: "/bin/sh", arguments: ["-c", "<WORKJET_BRIEF>"])
        XCTAssertThrowsError(try service.start(worker: invalid, brief: Data("true".utf8), supervisorExecutable: cli)) {
            XCTAssertEqual(($0 as? WorkjetCLIError)?.code, "executable_invalid")
        }

        var short = Worker(id: UUID(), name: "Short Local", harness: .claudeCode, model: "fixture", computerID: localID)
        short.invocation = WorkerInvocation(executable: "/usr/bin/true", arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])
        let shortResponse = try service.start(worker: short, brief: Data("ignored".utf8), supervisorExecutable: cli)
        let shortRunID = try XCTUnwrap(shortResponse.runID)
        let shortRC = paths.runsDirectory.appendingPathComponent(shortRunID).appendingPathComponent("rc")
        let shortDeadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: shortRC.path), Date() < shortDeadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(try service.events(runID: shortRunID, after: 0)?.state, .completed)

        var worker = Worker(id: workerID, name: "Real Local", harness: .claudeCode, model: "gpt-5.6-sol", reasoningEffort: .high, computerID: localID)
        worker.invocation = WorkerInvocation(executable: "/usr/bin/yes", arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"], options: ["fastMode": "true"])
        let response = try service.start(worker: worker, brief: Data("bounded fixture".utf8), supervisorExecutable: cli)
        let runID = try XCTUnwrap(response.runID)
        XCTAssertEqual(response.state, .running)

        let deadline = Date().addingTimeInterval(30)
        var active: ActiveRun?
        repeat {
            active = RunTelemetryStore(paths: paths).scan(workers: [worker]).first(where: { $0.sourceRunID == runID })?.activeRun
            if active == nil { Thread.sleep(forTimeInterval: 0.025) }
        } while active == nil && Date() < deadline
        let run = try XCTUnwrap(active)
        XCTAssertEqual(run.workerID, workerID)
        XCTAssertEqual(run.effectiveModel, "gpt-5.6-sol")
        XCTAssertEqual(run.effectiveReasoning, .high)
        XCTAssertEqual(run.effectiveSpeed, .fast)

        let events = try XCTUnwrap(service.events(runID: runID, after: 0))
        XCTAssertEqual(events.events.first?.kind, "lifecycle")
        XCTAssertEqual(events.events.first?.text, "started")
        XCTAssertEqual(try service.stop(runID: runID)?.state, .stopped)

        let rc = run.runDirectory.appendingPathComponent("rc")
        let stopDeadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: rc.path), Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rc.path))
        XCTAssertThrowsError(try service.stop(runID: runID)) {
            XCTAssertEqual($0 as? StopError, .runAlreadyFinished)
        }
    }

    func testLocalHarnessReceivesEffectiveModelReasoningSpeedAndSanitizedEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-launch-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let argumentsFile = root.appendingPathComponent("arguments.txt")
        let environmentFile = root.appendingPathComponent("environment.txt")
        let script = root.appendingPathComponent("fixture-harness")
        let scriptLink = root.appendingPathComponent("fixture-harness-link")
        let body = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsFile.path)'
        env > '\(environmentFile.path)'
        printf '%s\\n' 'fixture-output'
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(at: scriptLink, withDestinationURL: script)

        let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state", isDirectory: true))
        let cli = builtWorkjetCLI
        var worker = Worker(name: "Fixture", harness: .claudeCode, model: "gpt-5.6-sol", reasoningEffort: .high, computerID: localID)
        worker.invocation = WorkerInvocation(executable: scriptLink.path, arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"], options: ["fastMode": "true"])
        let route = ResolvedProviderRuntimeRoute(displayName: "Fixture Account", candidates: [
            ProviderRuntimeCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .openAI, displayName: "Fixture Account", endpoint: "https://api.openai.com/v1", authentication: .none, credentialReference: nil)
        ])
        setenv("WORKJET_SECRET_SENTINEL", "must-not-leak", 1)
        defer { unsetenv("WORKJET_SECRET_SENTINEL") }
        let greppySystemPrompt = "GREPPY SYSTEM PROMPT SENTINEL"
        let response = try LocalRunService(paths: paths).start(worker: worker, route: route, brief: Data("implement".utf8), systemPrompt: greppySystemPrompt, supervisorExecutable: cli)
        let runID = try XCTUnwrap(response.runID)
        let rc = paths.runsDirectory.appendingPathComponent(runID).appendingPathComponent("rc")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: rc.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        XCTAssertTrue(arguments.contains("--model\ngpt-5.6-sol"))
        XCTAssertTrue(arguments.contains("--effort\nhigh"))
        XCTAssertTrue(arguments.contains("--settings\n{\"fastMode\":true,\"fastModePerSessionOptIn\":true}"))
        XCTAssertTrue(arguments.contains("--append-system-prompt\n\(greppySystemPrompt)"))
        XCTAssertTrue(arguments.contains("--allowedTools\nRead,Write,Edit,Grep,Glob,Bash"))
        let environment = try String(contentsOf: environmentFile, encoding: .utf8)
        XCTAssertTrue(environment.contains("WORKJET_MODEL=gpt-5.6-sol"))
        XCTAssertTrue(environment.contains("WORKJET_REASONING=high"))
        XCTAssertTrue(environment.contains("WORKJET_SPEED=fast"))
        XCTAssertTrue(environment.contains("WORKJET_PROVIDER_ROUTE=Fixture Account"))
        XCTAssertFalse(environment.contains("WORKJET_SECRET_SENTINEL"))
        let events = try XCTUnwrap(LocalRunService(paths: paths).events(runID: runID, after: 0))
        XCTAssertTrue(events.events.contains { $0.kind == "stdout" && $0.text?.contains("fixture-output") == true })
    }

    func testDirectCredentialIsPrefetchedBeforeDetachedSupervisorStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-prefetched-credential-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let observed = root.appendingPathComponent("observed.txt")
        let harness = root.appendingPathComponent("fixture-harness")
        let script = """
        #!/bin/sh
        printf '%s' "$ANTHROPIC_API_KEY" > '\(observed.path)'
        """
        try Data(script.utf8).write(to: harness)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.path)

        let credentials = Credentials(["provider-direct": Data("prefetched-value".utf8)])
        let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state", isDirectory: true))
        var worker = Worker(name: "Direct", harness: .claudeCode, model: "fixture", computerID: localID)
        worker.invocation = WorkerInvocation(executable: harness.path, arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])
        let route = ResolvedProviderRuntimeRoute(displayName: "Direct", candidates: [
            ProviderRuntimeCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .miniMax, displayName: "Direct", endpoint: "https://example.test/v1", authentication: .apiKeyHeader, credentialReference: "provider-direct")
        ])
        let response = try LocalRunService(paths: paths, credentials: credentials).start(worker: worker, route: route, brief: Data("probe".utf8), supervisorExecutable: builtWorkjetCLI)
        let runID = try XCTUnwrap(response.runID)
        let rc = paths.runsDirectory.appendingPathComponent(runID).appendingPathComponent("rc")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: rc.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: rc.path))
        XCTAssertEqual(try String(contentsOf: observed, encoding: .utf8), "prefetched-value")
        XCTAssertEqual(credentials.reads, ["provider-direct"], "Nur der autorisierte Elternprozess darf den Zugang lesen.")
    }

    func testWebResearchKeepsClaudeToolsAndInjectsGatewayForCodexHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-web-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let observed = root.appendingPathComponent("observed.txt")
        let harness = root.appendingPathComponent("fixture-harness")
        let script = """
        #!/bin/sh
        printf '%s\n%s\n%s\n%s\n%s\n' "$WORKJET_WEB_RESEARCH_BACKEND" "$WORKJET_WEB_RESEARCH_BASE_URL" "$WORKJET_WEB_RESEARCH_API_KEY" "$GREPPY_STORE_DIR" "$*" > '\(observed.path)'
        """
        try Data(script.utf8).write(to: harness)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.path)

        let gateway = Credentials([CLIProxyGatewayCredentialStore.reference: Data("gateway-secret".utf8)])
        let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state", isDirectory: true))
        var worker = Worker(name: "Research-enabled Grok", harness: .claudeCode, model: "grok-4.5", computerID: localID)
        worker.invocation = WorkerInvocation(executable: harness.path, arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])
        let route = ResolvedProviderRuntimeRoute(displayName: "xAI Gateway", candidates: [
            ProviderRuntimeCandidate(kind: .gatewayPool, providerID: nil, modelProvider: .xAI, displayName: "xAI Gateway", endpoint: "http://127.0.0.1:8317", authentication: .bearerToken, credentialReference: CLIProxyGatewayCredentialStore.reference)
        ])
        let response = try LocalRunService(paths: paths, gatewayCredentials: gateway).start(
            worker: worker,
            route: route,
            brief: Data("research".utf8),
            systemPrompt: "WEB RESEARCH SYSTEM PROMPT",
            skillIDs: [WorkerSkillCatalog.greppyID, WorkerSkillCatalog.webResearchID],
            supervisorExecutable: builtWorkjetCLI
        )
        let runID = try XCTUnwrap(response.runID)
        let rc = paths.runsDirectory.appendingPathComponent(runID).appendingPathComponent("rc")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: rc.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }

        let value = try String(contentsOf: observed, encoding: .utf8)
        XCTAssertTrue(value.hasPrefix("codex\nhttp://127.0.0.1:8317/v1\ngateway-secret\n\(paths.stateDirectory.appendingPathComponent("greppy").path)\n"))
        XCTAssertTrue(value.contains("--allowedTools Read,Write,Edit,Grep,Glob,Bash"))
        XCTAssertTrue(value.contains("--append-system-prompt WEB RESEARCH SYSTEM PROMPT"))
        XCTAssertEqual(gateway.reads, [CLIProxyGatewayCredentialStore.reference])
    }

    func testLocalDirectPoolRetriesOnlyAnAuthenticatedCapacityFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-provider-pool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trace = root.appendingPathComponent("trace.txt")
        let harness = root.appendingPathComponent("fixture-provider-harness")
        let body = """
        #!/bin/sh
        printf '%s\n' "$WORKJET_PROVIDER_ROUTE" >> '\(trace.path)'
        sleep 1
        if [ "$WORKJET_PROVIDER_ROUTE" = "Primary" ]; then
          if printf '%s\n' "$*" | grep -q 'rate'; then
            printf '%s\n' 'HTTP 429 rate limit exceeded' >&2
          else
            printf '%s\n' 'HTTP 503 task-owned integration failed' >&2
          fi
          exit 1
        fi
        exit 0
        """
        try Data(body.utf8).write(to: harness)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.path)

        let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state", isDirectory: true))
        let supervisor = builtWorkjetCLI
        var worker = Worker(name: "Pool", harness: .claudeCode, model: "fixture", computerID: localID)
        worker.invocation = WorkerInvocation(executable: harness.path, arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])
        let route = ResolvedProviderRuntimeRoute(displayName: "Direct Pool", candidates: [
            ProviderRuntimeCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .openAI, displayName: "Primary", endpoint: "https://primary.example.test/v1", authentication: .none, credentialReference: nil),
            ProviderRuntimeCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .openAI, displayName: "Reserve", endpoint: "https://reserve.example.test/v1", authentication: .none, credentialReference: nil)
        ])

        func run(_ brief: String) throws {
            let response = try LocalRunService(paths: paths).start(worker: worker, route: route, brief: Data(brief.utf8), supervisorExecutable: supervisor)
            let runID = try XCTUnwrap(response.runID)
            let rc = paths.runsDirectory.appendingPathComponent(runID).appendingPathComponent("rc")
            let deadline = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: rc.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: rc.path))
        }

        try run("rate")
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init), ["Primary", "Reserve"])

        try Data().write(to: trace)
        try run("task")
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init), ["Primary"])
    }

    func testCodexAndOpenCodeUseVerifiedOneShotArgvWithoutPaidTurns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-local-one-shot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = builtWorkjetCLI

        for (harness, baseArguments, expected) in [
            (Harness.codexCLI, ["exec", "--json", "<WORKJET_BRIEF>"], ["exec", "--json", "implement", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=\"high\""]),
            (Harness.openCode, ["run", "--format", "json", "<WORKJET_BRIEF>"], ["run", "--format", "json", "implement", "--model", "openai/gpt-5.6-sol", "--variant", "high"])
        ] {
            let suffix = harness == .codexCLI ? "codex" : "opencode"
            let output = root.appendingPathComponent("\(suffix)-arguments.txt")
            let executable = root.appendingPathComponent("fixture-\(suffix)")
            let script = """
            #!/bin/sh
            printf '%s\n' "$@" > '\(output.path)'
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            let paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state-\(suffix)", isDirectory: true))
            var worker = Worker(name: suffix, harness: harness, model: harness == .codexCLI ? "gpt-5.6-sol" : "openai/gpt-5.6-sol", reasoningEffort: .high, computerID: localID)
            worker.invocation = WorkerInvocation(executable: executable.path, arguments: baseArguments)
            let response = try LocalRunService(paths: paths).start(worker: worker, brief: Data("implement".utf8), supervisorExecutable: cli)
            let runID = try XCTUnwrap(response.runID)
            let rc = paths.runsDirectory.appendingPathComponent(runID).appendingPathComponent("rc")
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: rc.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: rc.path), "\(harness)")
            let actual = try String(contentsOf: output, encoding: .utf8)
                .split(whereSeparator: \.isNewline).map(String.init)
            XCTAssertEqual(actual, expected, "\(harness)")
        }
    }

    func testUnsupportedLocalHarnessesFailClosedBeforeLaunch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-local-unsupported-\(UUID().uuidString)", isDirectory: true)
        let service = LocalRunService(paths: WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state", isDirectory: true)))
        let cli = URL(fileURLWithPath: "/usr/bin/true")

        for harness in [Harness.piSidecar, .cursorAgent, .grokCLI] {
            var worker = Worker(name: "Unsupported", harness: harness, model: "fixture", computerID: localID)
            worker.invocation = WorkerInvocation(executable: "/usr/bin/true", arguments: ["<WORKJET_BRIEF>"])
            XCTAssertThrowsError(try service.start(worker: worker, brief: Data("brief".utf8), supervisorExecutable: cli)) {
                XCTAssertEqual(($0 as? WorkjetCLIError)?.code, "harness_unsupported", "\(harness)")
            }
        }
    }

    func testResultImportAndExplicitLifecycleCommandsExposeOnlySafeResultIdentity() async throws {
        let backing = Backing(configuration: configuration(remoteWorkers: []))
        let oid = String(repeating: "a", count: 40)
        backing.importReceipt = WorkspaceResultImportReceipt(runID: "run-1", resultRef: "refs/workjet/run-1", resultCommitOID: oid, lifecycle: .imported, terminalState: .completed)
        let engine = WorkjetCLIEngine(backing: backing)
        let imported = try await engine.execute(.resultImport(runID: "run-1", json: true))
        XCTAssertEqual(imported.command, "result.import")
        XCTAssertEqual(imported.resultRef, "refs/workjet/run-1")
        XCTAssertEqual(imported.resultOID, oid)
        XCTAssertEqual(imported.lifecycle, "imported")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(imported), as: UTF8.self).contains("/Users/"))

        backing.markReceipt = WorkspaceLifecycleReceipt(runID: "run-1", lifecycle: .integrated, resultRef: "refs/workjet/run-1", resultCommitOID: oid, terminalState: .completed)
        let integrated = try await engine.execute(.runsMark(runID: "run-1", disposition: .integrated, json: true))
        XCTAssertEqual(integrated.lifecycle, "integrated")
        XCTAssertEqual(integrated.resultRef, "refs/workjet/run-1")

        backing.workspaceError = .integratedBeforeImport
        do {
            _ = try await engine.execute(.runsMark(runID: "run-2", disposition: .integrated, json: true))
            XCTFail("expected integrated-before-import rejection")
        } catch let error as WorkjetCLIError {
            XCTAssertEqual(error.code, "workspace_rejected")
            XCTAssertEqual(error.exitCode, .rejected)
        }
        backing.workspaceError = nil
        backing.markReceipt = WorkspaceLifecycleReceipt(runID: "run-3", lifecycle: .abandoned, terminalState: .failed)
        let abandoned = try await engine.execute(.runsMark(runID: "run-3", disposition: .abandoned, json: true))
        XCTAssertEqual(abandoned.lifecycle, "abandoned")
    }

    private func configuration(remoteWorkers: [Worker], extraWorkers: [Worker] = [], providers: [Provider] = []) -> WorkjetConfiguration {
        var value = WorkjetDefaults.configuration()
        value.computers = [
            Computer(id: localID, name: "Local", transport: .local),
            Computer(id: remoteID, name: "gpu", transport: .tailscale, host: "gpu.tailnet.ts.net", user: "workjet", deploymentStatus: .installed, installedSidecarVersion: PiSidecarRuntime.version)
        ]
        value.workers = remoteWorkers + extraWorkers
        value.providers = providers
        value.selectedComputerID = localID
        return value
    }

    private func fixtureProvider(_ modelProvider: ModelProvider) -> Provider {
        Provider(name: modelProvider.rawValue, kind: .directAPI, endpoint: modelProvider.defaultEndpoint ?? "https://example.invalid/v1", authentication: .none, modelProvider: modelProvider, status: .connected)
    }
}
