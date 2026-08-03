import Darwin
import XCTest
@testable import WorkjetCore

final class DefaultsAndLogicTests: XCTestCase {
    func testDefaultsMatchRepositoryAndHaveNoFabricatedCapacity() {
        let config = WorkjetDefaults.configuration()
        XCTAssertEqual(config.computers, [WorkjetDefaults.localComputer])
        XCTAssertEqual(config.selectedComputerID, WorkjetDefaults.localID)
        XCTAssertEqual(config.workers.map(\.name), ["Completion Engine", "Reviewer", "UI/UX-Experte", "Bulk Worker"])
        XCTAssertEqual(config.workers.map(\.invocation.executable), ["~/.local/bin/claude-sol", "~/.local/bin/claude-kimi", "~/.local/bin/claude-kimi", "~/.local/bin/claude-minimax"])
        XCTAssertTrue(config.workers.allSatisfy { $0.capacity.fraction == nil })
    }

    func testCapacityAndPureLogic() {
        XCTAssertEqual(CapacityStatus.measured(used: 25, limit: 100, unit: "requests", rateLimited: false).fraction, 0.25)
        XCTAssertNil(CapacityStatus.measured(used: 110, limit: 100, unit: "requests", rateLimited: false).fraction)
        XCTAssertEqual(CapacityStatus.unavailable(reason: "none").level, .unavailable)
        XCTAssertEqual(WorkerFilter.filtered(WorkjetDefaults.configuration().workers, query: "review", computerID: WorkjetDefaults.localID).map(\.name), ["Reviewer"])
        XCTAssertEqual(DurationFormatter.string(for: 3725), "1h 2m")
    }

    func testWorkerDraftPersistsInvocation() {
        let providerID = UUID()
        var draft = WorkerDraft(); draft.name = "Reviewer"; draft.model = "k3[1m]"; draft.computerID = WorkjetDefaults.localID; draft.providerID = providerID
        XCTAssertFalse(draft.isValid)
        draft.executable = "~/.local/bin/claude-kimi"; draft.arguments = "-p\n<WORKJET_BRIEF>"; draft.capabilities = "Review\nTests"
        let worker = draft.applied(to: nil)
        XCTAssertEqual(worker?.invocation.arguments, ["-p", "<WORKJET_BRIEF>"])
        XCTAssertEqual(worker?.invocation.capabilities, ["Review", "Tests"])
        XCTAssertEqual(WorkerDraft(worker: worker).providerID, providerID)
    }
}

final class ConfigurationStoreTests: XCTestCase {
    func testVersionedRoundTripAndSecureModes() throws {
        let root = try temporaryDirectory(); let file = root.appendingPathComponent("support/Workjet/config.v1.json")
        let store = JSONConfigurationStore(fileURL: file); let expected = WorkjetDefaults.configuration(); try store.save(expected)
        XCTAssertEqual(try store.load(), expected)
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(file.deletingLastPathComponent().path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testCorruptAndUnsupportedConfigurationAreNotOverwritten() throws {
        let root = try temporaryDirectory(); let file = root.appendingPathComponent("config.v1.json"); let original = Data("{not-json".utf8); try original.write(to: file)
        let store = JSONConfigurationStore(fileURL: file); XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: file), original)
        try Data("{\"version\":2}".utf8).write(to: file)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? LocalStateError, .unsupportedConfiguration(2)) }
    }

    func testProductionBootstrapUsesInjectedRootsOnly() throws {
        let root = try temporaryDirectory()
        let paths = WorkjetPaths(homeDirectory: root, applicationSupportDirectory: root.appendingPathComponent("support"), stateDirectory: root.appendingPathComponent("state"))
        let bootstrap = WorkjetBootstrap.live(paths: paths)
        XCTAssertEqual(bootstrap.configuration.selectedComputerID, WorkjetDefaults.localID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configurationFile.path))
        let prompt = try Data(contentsOf: paths.promptFile)
        XCTAssertNotNil(try ManagedPrompt.parse(prompt).body)
        XCTAssertTrue(bootstrap.messages.isEmpty)
    }
}

final class ManagedPromptTests: XCTestCase {
    func testRendererIsDeterministicAndTruthful() {
        let config = WorkjetDefaults.configuration(); let body = ManagedPrompt.workerBody(configuration: config)
        XCTAssertEqual(body, ManagedPrompt.workerBody(configuration: config)); let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Fable (Claude Code) bleibt der einzige Orchestrator")); XCTAssertTrue(text.contains("genau einen deklarierten Worker"))
        for worker in config.workers { XCTAssertTrue(text.contains(worker.id.uuidString.lowercased())); XCTAssertTrue(text.contains(worker.invocation.executable)); XCTAssertTrue(text.contains(worker.model)) }
        var hostile = config; hostile.workers[0].instructions = ManagedPrompt.endMarker
        XCTAssertNoThrow(try ManagedPrompt.parse(ManagedPrompt.block(body: ManagedPrompt.workerBody(configuration: hostile))))

        let provider = Provider(name: "CLI Route", kind: .cliProxy, endpoint: "http://127.0.0.1:8317", credentialReference: "must-not-render")
        var routed = config; routed.providers = [provider]; routed.workers[0].providerID = provider.id
        let routedText = String(decoding: ManagedPrompt.workerBody(configuration: routed), as: UTF8.self)
        XCTAssertTrue(routedText.contains(provider.id.uuidString.lowercased()))
        XCTAssertTrue(routedText.contains("CLIProxy OAuth/Abo"))
        XCTAssertFalse(routedText.contains("must-not-render"))
        routed.providers = []
        let unavailable = String(decoding: ManagedPrompt.workerBody(configuration: routed), as: UTF8.self)
        XCTAssertTrue(unavailable.contains("gelöscht oder nicht verfügbar"))
        XCTAssertTrue(unavailable.contains(provider.id.uuidString.lowercased()))
    }

    func testAppendReplaceAndHandwrittenEdit() throws {
        let outside = Data([0x23, 0x20, 0x48, 0x61, 0x6e, 0x64, 0x0a, 0x0a, 0x58])
        let appended = try ManagedPrompt.replacingManagedBlock(in: outside, body: Data("one".utf8)); XCTAssertTrue(appended.starts(with: outside))
        let first = try ManagedPrompt.parse(appended); let replaced = try ManagedPrompt.replacingManagedBlock(in: appended, body: Data("two".utf8)); let second = try ManagedPrompt.parse(replaced)
        XCTAssertEqual(first.prefix, second.prefix); XCTAssertEqual(first.suffix, second.suffix); XCTAssertEqual(second.body, Data("two".utf8))
        let edited = try ManagedPrompt.replacingHandwrittenContent(in: replaced, rules: "new rules", body: Data("two".utf8))
        XCTAssertEqual(try ManagedPrompt.handwrittenContent(from: edited), "new rules"); XCTAssertEqual(try ManagedPrompt.parse(edited).body, Data("two".utf8))
    }

    func testConcurrentSynchronizationUsesStableLockAndPreservesManagedHash() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("AGENTS.md")
        let store = ManagedPromptStore(fileURL: file)
        var first = WorkjetDefaults.configuration(); first.workers[0].name = "Writer One"
        var second = WorkjetDefaults.configuration(); second.workers[0].name = "Writer Two"
        try store.synchronize(first, handwrittenChanged: false)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "prompt-writers", attributes: .concurrent)
        let lock = NSLock()
        var errors: [Error] = []
        for configuration in [first, second] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { try store.synchronize(configuration, handwrittenChanged: false) }
                catch { lock.lock(); errors.append(error); lock.unlock() }
            }
        }
        group.wait()
        XCTAssertTrue(errors.isEmpty)
        let data = try Data(contentsOf: file)
        let parsed = try ManagedPrompt.parse(data)
        let body = try XCTUnwrap(parsed.body)
        XCTAssertTrue(body == ManagedPrompt.workerBody(configuration: first) || body == ManagedPrompt.workerBody(configuration: second))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
    }

    func testMismatchMalformedDuplicateAndSymlinkRefused() throws {
        let valid = ManagedPrompt.block(body: Data("body".utf8)); var tampered = valid
        let bodyOffset = String(decoding: valid, as: UTF8.self).firstIndex(of: "\n")!.utf16Offset(in: String(decoding: valid, as: UTF8.self)) + 1; tampered[bodyOffset] = 0x58
        XCTAssertThrowsError(try ManagedPrompt.parse(tampered)) { XCTAssertEqual($0 as? LocalStateError, .promptHashMismatch) }
        var duplicate = valid; duplicate.append(Data("\n".utf8)); duplicate.append(valid); XCTAssertThrowsError(try ManagedPrompt.parse(duplicate))
        XCTAssertThrowsError(try ManagedPrompt.parse(Data("<!-- WORKJET MANAGED WORKERS BEGIN v1 sha256=x -->".utf8)))
        let root = try temporaryDirectory(); let target = root.appendingPathComponent("target"); try valid.write(to: target); let link = root.appendingPathComponent("AGENTS.md"); XCTAssertEqual(symlink(target.path, link.path), 0)
        XCTAssertThrowsError(try ManagedPromptStore(fileURL: link).loadHandwrittenRules())
        let safeTarget = root.appendingPathComponent("safe-AGENTS.md")
        let lockStore = ManagedPromptStore(fileURL: safeTarget)
        let attackerLock = root.appendingPathComponent("attacker-lock"); try Data().write(to: attackerLock)
        XCTAssertEqual(symlink(attackerLock.path, lockStore.lockURL.path), 0)
        XCTAssertThrowsError(try lockStore.synchronize(WorkjetDefaults.configuration(), handwrittenChanged: false))
    }
}

final class RunTelemetryTests: XCTestCase {
    private final class Probe: ProcessProbing, @unchecked Sendable {
        var identities: [Int32: ProcessIdentity] = [:]; var terminated: [Int32] = []
        func identity(for pid: Int32) -> ProcessIdentity? { identities[pid] }
        func sendTERM(to pid: Int32) throws { terminated.append(pid); identities[pid] = nil }
    }
    private final class Fixture {
        let root: URL; let index: URL; let runs: URL; let probe = Probe(); lazy var store = RunTelemetryStore(paths: WorkjetPaths(homeDirectory: root, stateDirectory: root), processProbe: probe)
        init() throws { root = try temporaryDirectory(); index = root.appendingPathComponent("run-index"); runs = root.appendingPathComponent("runs"); try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true) }
        func make(_ id: String, _ pid: Int32, _ worker: String, terminal: String? = nil) throws -> URL {
            let run = runs.appendingPathComponent(id); try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true); try Data(run.path.utf8).write(to: index.appendingPathComponent(id)); try Data("\(pid)\n".utf8).write(to: run.appendingPathComponent("pid")); try Data(worker.utf8).write(to: run.appendingPathComponent("worker")); try Data("2026-08-03T09:00:00Z\n".utf8).write(to: run.appendingPathComponent("started-at")); FileManager.default.createFile(atPath: run.appendingPathComponent("heartbeat").path, contents: Data()); if let terminal { FileManager.default.createFile(atPath: run.appendingPathComponent(terminal).path, contents: Data()) }; return run
        }
    }
    private func identity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, executablePath: "/usr/bin/worker", startToken: "start-\(pid)") }

    func testRunningCompletedDeadUnknownMalformedAndDeliveryFixtures() throws {
        let f = try Fixture(); let run = try f.make("running", 100, "claude-sol"); try Data("safe title".utf8).write(to: run.appendingPathComponent("title")); FileManager.default.createFile(atPath: run.appendingPathComponent("stream-json").path, contents: Data()); f.probe.identities[100] = identity(100)
        _ = try f.make("completed", 101, "claude-sol", terminal: "exit-code"); _ = try f.make("dead", 102, "claude-sol"); _ = try f.make("unknown", 103, "mystery-wrapper"); f.probe.identities[103] = identity(103)
        let malformed = f.runs.appendingPathComponent("malformed"); try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true); try Data(malformed.path.utf8).write(to: f.index.appendingPathComponent("malformed"))
        let records = f.store.scan(workers: WorkjetDefaults.configuration().workers)
        let running = records.first { $0.sourceRunID == "running" }; XCTAssertEqual(running?.state, .running); XCTAssertEqual(running?.activeRun?.delivery, .live); XCTAssertEqual(running?.activeRun?.activity, "safe title"); XCTAssertNotNil(running?.activeRun?.lastHeartbeat)
        XCTAssertEqual(records.first { $0.sourceRunID == "completed" }?.state, .completed); XCTAssertEqual(records.first { $0.sourceRunID == "dead" }?.state, .interrupted); XCTAssertEqual(records.first { $0.sourceRunID == "malformed" }?.state, .malformed)
        let unknown = records.first { $0.sourceRunID == "unknown" }; XCTAssertEqual(unknown?.state, .running); XCTAssertTrue(unknown?.activeRun?.workerName.contains("mystery-wrapper") == true); XCTAssertNil(unknown?.activeRun?.workerModel)
    }

    func testPiIsPostHocAndStopChecksPIDIdentity() throws {
        let f = try Fixture(); var pi = WorkjetDefaults.configuration().workers[0]; pi.harness = .piSidecar; pi.invocation.executable = "pi-worker"
        let piRun = try f.make("pi", 104, "pi-worker"); FileManager.default.createFile(atPath: piRun.appendingPathComponent("response-events.jsonl").path, contents: Data()); f.probe.identities[104] = identity(104)
        XCTAssertEqual(f.store.scan(workers: [pi]).first?.activeRun?.delivery, .postHoc)
        _ = try f.make("stop", 105, "claude-sol"); f.probe.identities[105] = identity(105); let active = try XCTUnwrap(f.store.scan(workers: WorkjetDefaults.configuration().workers).first { $0.sourceRunID == "stop" }?.activeRun)
        f.probe.identities[105] = ProcessIdentity(pid: 105, executablePath: "/other", startToken: "reused"); XCTAssertThrowsError(try f.store.stop(active)) { XCTAssertEqual($0 as? StopError, .pidMismatch) }; XCTAssertTrue(f.probe.terminated.isEmpty)
        f.probe.identities[105] = identity(105); try f.store.stop(active); XCTAssertEqual(f.probe.terminated, [105])
    }
}

final class CLIProxyTests: XCTestCase {
    private final class Client: HTTPClient, @unchecked Sendable { var responses: [HTTPResponse] = []; var requests: [URLRequest] = []; func request(_ request: URLRequest) async throws -> HTTPResponse { requests.append(request); if responses.isEmpty { throw URLError(.cannotConnectToHost) }; return responses.removeFirst() } }
    private final class Credentials: CredentialStoring, @unchecked Sendable { var values: [String: Data] = [:]; func read(reference: String) throws -> Data? { values[reference] }; func write(_ secret: Data, reference: String) throws { values[reference] = secret }; func delete(reference: String) throws { values[reference] = nil } }

    func testUnsafeUsageDisabledAndDistinctStates() async {
        let unsafeClient = Client(); let unsafe = await CLIProxyInspector(client: unsafeClient, credentials: Credentials()).inspect(CLIProxyConfiguration(endpoint: "http://192.168.1.5:8317")); XCTAssertEqual(unsafe.state, .unsafeEndpoint); XCTAssertTrue(unsafeClient.requests.isEmpty)
        let disabledClient = Client(); disabledClient.responses = [HTTPResponse(statusCode: 200, data: Data())]; let disabled = await CLIProxyInspector(client: disabledClient, credentials: Credentials()).inspect(CLIProxyConfiguration()); XCTAssertEqual(disabled.state, .usageDisabled); XCTAssertEqual(disabledClient.requests.count, 1)
        let authClient = Client(); authClient.responses = [HTTPResponse(statusCode: 401, data: Data())]; let auth = await CLIProxyInspector(client: authClient, credentials: Credentials()).inspect(CLIProxyConfiguration()); XCTAssertEqual(auth.state, .authRequired)
        let missingRouteClient = Client(); missingRouteClient.responses = [HTTPResponse(statusCode: 404, data: Data())]; let missingRoute = await CLIProxyInspector(client: missingRouteClient, credentials: Credentials()).inspect(CLIProxyConfiguration()); XCTAssertEqual(missingRoute.state, .offline); XCTAssertTrue(missingRoute.detail.contains("/v1/models"))
        let managementClient = Client(); managementClient.responses = [HTTPResponse(statusCode: 200, data: Data())]; var config = CLIProxyConfiguration(); config.usageStatisticsEnabled = true; let management = await CLIProxyInspector(client: managementClient, credentials: Credentials()).inspect(config); XCTAssertEqual(management.state, .managementUnavailable)
    }

    func testManagementUsesDistinctCredentialAndParsesCapacity() async {
        let client = Client(); client.responses = [HTTPResponse(statusCode: 200, data: Data()), HTTPResponse(statusCode: 200, data: Data("{\"usage\":{\"used\":25,\"limit\":100,\"window\":\"monthly\",\"identity\":\"account-a\"}}".utf8))]
        let credentials = Credentials(); credentials.values["management"] = Data("mgmt-secret".utf8); credentials.values["inference"] = Data("inference-secret".utf8)
        let status = await CLIProxyInspector(client: client, credentials: credentials).inspect(CLIProxyConfiguration(inferenceCredentialReference: "inference", managementCredentialReference: "management", usageStatisticsEnabled: true))
        XCTAssertEqual(status.state, .reachable); XCTAssertEqual(status.capacity.fraction, 0.25); XCTAssertEqual(client.requests.count, 2); XCTAssertEqual(client.requests[0].url?.path, "/v1/models"); XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer inference-secret"); XCTAssertEqual(client.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer mgmt-secret")

        let aggregateClient = Client(); aggregateClient.responses = [HTTPResponse(statusCode: 200, data: Data()), HTTPResponse(statusCode: 200, data: Data("{\"total_tokens\":9000,\"used\":25,\"limit\":100}".utf8))]
        let aggregate = await CLIProxyInspector(client: aggregateClient, credentials: credentials).inspect(CLIProxyConfiguration(inferenceCredentialReference: "inference", managementCredentialReference: "management", usageStatisticsEnabled: true))
        XCTAssertNil(aggregate.capacity.fraction)
        XCTAssertTrue(aggregate.capacity.reason?.contains("identitäts") == true)
    }
}

final class RemotePiBootstrapTests: XCTestCase {
    private actor Runner: CommandRunning {
        var results: [CommandResult]
        var recorded: [CommandSpec] = []
        init(_ results: [CommandResult]) { self.results = results }
        func run(_ command: CommandSpec) async throws -> CommandResult {
            recorded.append(command)
            return results.isEmpty ? CommandResult(exitCode: 0) : results.removeFirst()
        }
        func commands() -> [CommandSpec] { recorded }
    }

    private final class Files: OwnedFileReading, @unchecked Sendable {
        var values: [String: Data] = [:]
        var failure: Error?
        func readOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
            if let failure { throw failure }
            return values[url.path] ?? Data("bundle".utf8)
        }
    }

    private struct Locator: TailscaleLocating {
        var path: String?
        func executablePath() -> String? { path }
    }

    private var successfulPreflight: CommandResult {
        CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_SHA=sha256sum\n".utf8))
    }

    private func sshComputer(bundle: String = "/audit/ctox-pi-sidecar.mjs") -> Computer {
        Computer(name: "pi", transport: .ssh, host: "pi.example.test", user: "workjet", port: 2222, sidecarBundlePath: bundle, knownHostsPath: "/private/workjet-known-hosts")
    }

    func testExactSSHArgumentsUseStrictPrivateKnownHostsAndNoUnsafeOption() throws {
        let computer = sshComputer()
        let command = try RemoteCommandBuilder.command(for: computer, tailscaleExecutable: nil, remoteExecutable: "/bin/sh", remoteArguments: ["-s", "--", String(repeating: "a", count: 64)], standardInput: Data("fixed".utf8), timeout: 20)
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(command.arguments, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/private/workjet-known-hosts", "-o", "ClearAllForwardings=yes", "-p", "2222", "-l", "workjet", "--", "pi.example.test", "/bin/sh", "-s", "--", String(repeating: "a", count: 64)])
        XCTAssertFalse(command.arguments.contains { $0.contains("StrictHostKeyChecking=no") || $0.contains("accept-new") })
        XCTAssertFalse(command.arguments.contains("-c"))
    }

    func testTailscaleExecutableMissingDoesNotFallBackToSSH() async {
        let runner = Runner([])
        let files = Files()
        var computer = sshComputer(); computer.transport = .tailscale; computer.knownHostsPath = ""
        let result = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil)).deploy(computer)
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertTrue(result.deploymentDetail.contains("fällt nicht"))
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testInvalidBundleSymlinkAndInjectedWrongOwnerAreRejected() async throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("bundle-real.mjs")
        try Data("audited".utf8).write(to: target)
        let link = root.appendingPathComponent("bundle-link.mjs")
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let runner = Runner([])
        let linked = await RemotePiBootstrap(runner: runner, files: SecureOwnedFileReader(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer(bundle: link.path))
        XCTAssertEqual(linked.deploymentStatus, .failed)
        XCTAssertNil(linked.installedContentHash)

        let wrongOwnerFiles = Files(); wrongOwnerFiles.failure = LocalStateError.wrongOwner("/audit/ctox-pi-sidecar.mjs")
        let wrongOwner = await RemotePiBootstrap(runner: runner, files: wrongOwnerFiles, tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(wrongOwner.deploymentStatus, .failed)
        XCTAssertTrue(wrongOwner.deploymentDetail.contains("falschem Eigentümer"))

        let relative = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer(bundle: "relative-sidecar.mjs"))
        XCTAssertEqual(relative.deploymentStatus, .failed)
        XCTAssertTrue(relative.deploymentDetail.contains("absolut"))
    }

    func testNodePreflightFailureIsBlockedWithoutInstallingAnything() async {
        let unavailable = CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=missing\nWORKJET_SHA=sha256sum\n".utf8))
        let runner = Runner([unavailable])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertTrue(result.deploymentDetail.contains("Node >=20"))
        XCTAssertNil(result.lastSuccessfulPreflightAt)
        XCTAssertNil(result.installedContentHash)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
    }

    func testSuccessfulContentAddressedDeploymentAndStatusRoundTrip() async throws {
        let runner = Runner([successfulPreflight])
        let files = Files(); files.values["/audit/ctox-pi-sidecar.mjs"] = Data("audited sidecar".utf8); files.values["/private/workjet-known-hosts"] = Data("host key".utf8)
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let installed = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil), now: { date }).deploy(sshComputer())
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertEqual(installed.installedSidecarVersion, "0.80.2")
        XCTAssertEqual(installed.installedContentHash?.count, 64)
        XCTAssertEqual(installed.lastSuccessfulPreflightAt, date)
        XCTAssertEqual(installed.lastSuccessfulDeploymentAt, date)

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 6)
        XCTAssertTrue(commands.allSatisfy { $0.executable == "/usr/bin/ssh" })
        XCTAssertTrue(String(decoding: commands[1].standardInput, as: UTF8.self).contains("releases/$hash"))
        XCTAssertTrue(String(decoding: commands[5].standardInput, as: UTF8.self).contains("fs.renameSync(temporary, current)"))
        XCTAssertEqual(commands.filter { $0.arguments.contains("node") }.count, 3)

        let root = try temporaryDirectory(); let store = JSONConfigurationStore(fileURL: root.appendingPathComponent("config.v1.json"))
        var config = WorkjetDefaults.configuration(); config.computers.append(installed); try store.save(config)
        XCTAssertEqual(try store.load()?.computers.last?.installedContentHash, installed.installedContentHash)
        XCTAssertEqual(try store.load()?.computers.last?.deploymentStatus, .installed)
    }

    func testRemoteFailureNeverMarksInstalledAndExplainsHostKeyApproval() async {
        let failure = CommandResult(exitCode: 255, standardError: Data("Host key verification failed".utf8))
        let runner = Runner([successfulPreflight, failure])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .failed)
        XCTAssertNil(result.installedContentHash)
        XCTAssertNil(result.installedSidecarVersion)
        XCTAssertTrue(result.deploymentDetail.contains("außerhalb von Workjet"))
        let commands = await runner.commands()
        XCTAssertFalse(commands.flatMap(\.arguments).contains { $0.contains("accept-new") || $0.contains("StrictHostKeyChecking=no") })
    }

    func testCredentialsNeverAppearInCommandsManifestPromptOrDeploymentPayload() async {
        let secret = "SUPER-SECRET-CREDENTIAL-VALUE"
        let runner = Runner([successfulPreflight])
        let files = Files(); files.values["/audit/ctox-pi-sidecar.mjs"] = Data("audited sidecar".utf8)
        let installed = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        let commands = await runner.commands()
        let transcript = commands.map { $0.executable + $0.arguments.joined(separator: " ") + String(decoding: $0.standardInput, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertFalse(transcript.contains(secret))

        let provider = Provider(name: "Direct", kind: .apiKey, endpoint: "https://user:\(secret)@api.example.test/v1?api_key=\(secret)", credentialReference: secret)
        var config = WorkjetDefaults.configuration(); config.providers = [provider]; config.workers[0].providerID = provider.id; config.workers[0].harness = .piSidecar; config.workers[0].computerID = installed.id; config.computers.append(installed)
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertFalse(prompt.contains(secret))
        XCTAssertTrue(prompt.contains("Geheimnisse bleiben ausschließlich in der lokalen Keychain"))
        XCTAssertTrue(prompt.contains("CtoxTurnRequest"))
        XCTAssertTrue(prompt.contains("post-hoc"))
        XCTAssertTrue(prompt.contains("Loopback-Relay nicht verfügbar"))
        XCTAssertTrue(prompt.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("env: cleanEnvironment"))
        XCTAssertFalse(RemotePiBootstrap.turnRunnerSource.contains("process.env.API"))
    }
}

@MainActor final class ViewModelTests: XCTestCase {
    private final class Service: WorkjetService, @unchecked Sendable { var saves: [(WorkjetConfiguration, Bool)] = []; func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws { saves.append((configuration, handwrittenRulesChanged)) }; func runs(workers: [Worker]) -> [RunRecord] { [] }; func stop(_ run: ActiveRun) throws {}; func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus { CLIProxyStatus(endpoint: configuration.endpoint, state: .offline, detail: "test", capacity: .unavailable(reason: "test")) }; func storeCredential(_ secret: Data, reference: String) throws {} }
    func testSelectionIsExclusiveAndDebouncedChangesCoalesceOnExplicitFlush() async {
        let service = Service(); let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60); model.toggleComputerSelection(PreviewData.devbox.id); XCTAssertEqual(model.selectedComputerID, PreviewData.devbox.id); model.toggleComputerSelection(PreviewData.devbox.id); XCTAssertEqual(model.selectedComputerID, PreviewData.devbox.id)
        model.providerSlots = 4; model.telemetryRetentionDays = 30; model.cliProxyConfiguration.usageStatisticsEnabled = true; model.skillRules = "n"; model.skillRules = "new rules"; model.addProvider(Provider(name: "API", kind: .apiKey, endpoint: "https://example.test"))
        XCTAssertTrue(service.saves.isEmpty)
        await model.flushPersistence()
        XCTAssertEqual(service.saves.count, 1)
        XCTAssertEqual(service.saves.first?.1, true)
        XCTAssertEqual(service.saves.first?.0.skillRules, "new rules")
        XCTAssertEqual(service.saves.first?.0.providers.count, 2)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkjetTests-\(UUID().uuidString)", isDirectory: true); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}
