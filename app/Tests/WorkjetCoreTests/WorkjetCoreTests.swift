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
        draft.selectHarness(.piSidecar)
        XCTAssertEqual(draft.executable, "node")
        XCTAssertNotEqual(draft.executable, "~/.local/bin/claude-sol")
        XCTAssertTrue(draft.arguments.isEmpty)
        draft.selectHarness(.claudeCode)
        XCTAssertEqual(draft.executable, "~/.local/bin/claude-sol")
        XCTAssertEqual(draft.arguments, "-p\n<WORKJET_BRIEF>")
    }

    func testBootstrapNormalizesSkillOnlyAndDispatcherBounds() {
        var config = WorkjetDefaults.configuration()
        config.skillActivation = .global
        config.providerSlots = 9
        config.probeTimeoutSeconds = 1
        config.turnTimeoutSeconds = 99_999
        config.injectWorkerDeclarations = false
        let normalized = WorkjetBootstrap.normalized(config)
        XCTAssertEqual(normalized.skillActivation, .skillOnly)
        XCTAssertTrue(normalized.injectWorkerDeclarations)
        XCTAssertEqual(normalized.providerSlots, 3)
        XCTAssertEqual(normalized.probeTimeoutSeconds, 5)
        XCTAssertEqual(normalized.turnTimeoutSeconds, 10_800)
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
        XCTAssertTrue(text.contains("höchstens 3 parallele Aufrufe je Provider"))
        XCTAssertTrue(text.contains("Probe-Timeout 120 s"))
        XCTAssertTrue(text.contains("Turn-Timeout 5400 s"))
        for worker in config.workers { XCTAssertTrue(text.contains(worker.id.uuidString.lowercased())); XCTAssertTrue(text.contains(worker.invocation.executable)); XCTAssertTrue(text.contains(worker.model)) }
        var hostile = config; hostile.workers[0].instructions = ManagedPrompt.endMarker
        XCTAssertNoThrow(try ManagedPrompt.parse(ManagedPrompt.block(body: ManagedPrompt.workerBody(configuration: hostile))))

        let provider = Provider(name: "CLI Route", kind: .cliProxy, endpoint: "http://127.0.0.1:8317", credentialReference: "must-not-render")
        var routed = config; routed.providers = [provider]; routed.workers[0].providerID = provider.id
        let routedText = String(decoding: ManagedPrompt.workerBody(configuration: routed), as: UTF8.self)
        XCTAssertTrue(routedText.contains("CLI Route"))
        XCTAssertTrue(routedText.contains("CLIProxyAPI"))
        XCTAssertFalse(routedText.contains("must-not-render"))
        routed.providers = []
        let unavailable = String(decoding: ManagedPrompt.workerBody(configuration: routed), as: UTF8.self)
        XCTAssertTrue(unavailable.contains("gelöscht oder nicht verfügbar"))
        XCTAssertTrue(unavailable.contains(provider.id.uuidString.lowercased()))
    }

    func testMultilineInstructionsMentionsAndReasoningRenderExactlyOnce() throws {
        var config = WorkjetDefaults.configuration()
        config.workers[0].name = "Kimi-K3"
        config.workers[0].instructions = "Erste Zeile\n\n- Markdown bleibt\nArbeite mit @UI-UX-Experte."
        config.workers[0].reasoningEffort = .xhigh
        XCTAssertEqual(config.workers[0].mentionTag, "@Kimi-K3")
        XCTAssertEqual(config.workers[2].mentionTag, "@UI-UX-Experte")
        let text = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertTrue(text.contains("### @Kimi-K3 — Kimi-K3"))
        XCTAssertTrue(text.contains("Erste Zeile\n\n- Markdown bleibt\nArbeite mit @UI-UX-Experte."))
        XCTAssertEqual(text.components(separatedBy: "Erste Zeile").count - 1, 1)
        XCTAssertTrue(text.contains("Reasoning: `xhigh`"))
        XCTAssertTrue(text.contains("Fable muss den konfigurierten Effort `xhigh`"))
        XCTAssertTrue(ManagedPrompt.unresolvedMentions(in: config.workers[0].instructions, workers: config.workers).isEmpty)
        XCTAssertEqual(ManagedPrompt.unresolvedMentions(in: "Frage @Missing und @Missing", workers: config.workers), ["@Missing"])
    }

    func testReasoningCodableDraftAndLegacyDecode() throws {
        var worker = WorkjetDefaults.configuration().workers[0]
        worker.reasoningEffort = .ultra
        let encoded = try JSONEncoder().encode(worker)
        XCTAssertEqual(try JSONDecoder().decode(Worker.self, from: encoded).reasoningEffort, .ultra)
        var draft = WorkerDraft(worker: worker)
        draft.reasoningEffort = .max
        XCTAssertEqual(draft.applied(to: worker)?.reasoningEffort, .max)
        let legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var legacy = legacyObject
        legacy.removeValue(forKey: "reasoningEffort")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(Worker.self, from: legacyData).reasoningEffort)
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
    private func identity(_ pid: Int32, start: String = "1785747600.000000") -> ProcessIdentity { ProcessIdentity(pid: pid, executablePath: "/usr/bin/worker", startToken: start) }

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

    func testReusedPIDWithLaterProcessStartIsInterrupted() throws {
        let f = try Fixture()
        _ = try f.make("old-run", 691, "claude-sol")
        f.probe.identities[691] = identity(691, start: "1785920400.000000")
        let record = try XCTUnwrap(f.store.scan(workers: WorkjetDefaults.configuration().workers).first { $0.sourceRunID == "old-run" })
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertNil(record.activeRun)
        XCTAssertTrue(record.diagnostic?.contains("später gestarteten Prozess") == true)
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

    func testProviderBackwardsCodableAndEndpointPolicies() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\",\"kind\":\"Direkter API-Key\",\"endpoint\":\"https://api.example.test\",\"status\":\"Nicht geprüft\",\"capacity\":{\"unavailable\":{\"reason\":\"n/a\"}},\"loginArguments\":[]}".utf8)
        let provider = try JSONDecoder().decode(Provider.self, from: legacy)
        XCTAssertEqual(provider.kind, .directAPI)
        XCTAssertEqual(provider.modelIDs, [])
        XCTAssertEqual(provider.credentialReference, Provider.credentialReference(for: id))
        XCTAssertEqual(ProviderEndpointValidator.validate("https://api.example.test", kind: .directAPI), .valid(URL(string: "https://api.example.test")!))
        if case .valid = ProviderEndpointValidator.validate("http://127.0.0.1:9000", kind: .directAPI) {} else { XCTFail("Loopback development endpoint should be allowed") }
        if case .invalid = ProviderEndpointValidator.validate("http://api.example.test", kind: .directAPI) {} else { XCTFail("Remote direct HTTP must be rejected") }
        if case .valid = ProviderEndpointValidator.validate("http://localhost:8317", kind: .cliProxyAPI) {} else { XCTFail("Loopback gateway should be allowed") }
        if case .invalid = ProviderEndpointValidator.validate("https://gateway.example.test", kind: .cliProxyRust) {} else { XCTFail("Remote gateway must be rejected") }
        if case .invalid = ProviderEndpointValidator.validate("https://user:secret@api.example.test", kind: .directAPI) {} else { XCTFail("URL credentials must be rejected") }
    }

    func testProviderProbeSendsBearerOnlyWhenExplicitlyCalledAndDiscoversModels() async {
        let client = Client()
        client.responses = [HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"gpt-5.6-sol"},{"id":"claude-sonnet-5"},{"id":"gpt-5.6-sol"}]}"#.utf8))]
        let credentials = Credentials()
        let provider = Provider(name: "Direct", kind: .directAPI, endpoint: "https://api.example.test")
        credentials.values[provider.credentialReference!] = Data("top-secret".utf8)
        XCTAssertTrue(client.requests.isEmpty)
        let result = await ProviderInspector(client: client, credentials: credentials).inspect(provider)
        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(result.modelIDs, ["gpt-5.6-sol", "claude-sonnet-5"])
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].url?.path, "/v1/models")
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
        XCTAssertFalse(result.detail.contains("top-secret"))
        XCTAssertEqual(WorkerModelSuggestions.values(providerID: provider.id, providers: [Provider(id: provider.id, name: provider.name, kind: provider.kind, endpoint: provider.endpoint, modelIDs: result.modelIDs)]).prefix(2), result.modelIDs.prefix(2))
    }

    func testGatewayProbeDoesNotSubstituteKindsAndParsesCompatibleModels() async {
        for kind in [ProviderKind.cliProxyAPI, .cliProxyRust] {
            let client = Client()
            client.responses = [HTTPResponse(statusCode: 200, data: Data(#"{"data":[{"id":"gateway-model"}]}"#.utf8))]
            let result = await ProviderInspector(client: client, credentials: Credentials()).inspect(Provider(name: kind.rawValue, kind: kind, endpoint: "http://127.0.0.1:8317"))
            XCTAssertEqual(result.status, .connected)
            XCTAssertEqual(result.modelIDs, ["gateway-model"])
            XCTAssertTrue(result.detail.contains("lokalen Gateway"))
        }
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

final class TailscaleDeviceTests: XCTestCase {
    private actor Runner: CommandRunning {
        var result: CommandResult
        var commands: [CommandSpec] = []
        init(_ result: CommandResult) { self.result = result }
        func run(_ command: CommandSpec) async throws -> CommandResult { commands.append(command); return result }
        func recorded() -> [CommandSpec] { commands }
    }
    private struct Locator: TailscaleLocating { var path: String?; func executablePath() -> String? { path } }

    private var statusJSON: Data {
        Data(#"{"BackendState":"Running","Self":{"ID":"self-id","HostName":"mac"},"Peer":{"node-off":{"ID":"off-id","HostName":"zeta","DNSName":"zeta.tailnet.ts.net.","TailscaleIPs":["fd7a::2","100.64.0.2"],"Online":false,"OS":"linux"},"node-on":{"ID":"on-id","HostName":"alpha","DNSName":"alpha.tailnet.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true,"OS":"linux"},"duplicate-self":{"ID":"self-id","HostName":"mac"}}}"#.utf8)
    }

    func testParserExcludesSelfTrimsDNSSelectsIPv4AndOrdersOnlineFirst() throws {
        let devices = try TailscaleDeviceParser.parse(statusJSON)
        XCTAssertEqual(devices.map(\.id), ["on-id", "off-id"])
        XCTAssertEqual(devices[0].dnsName, "alpha.tailnet.ts.net")
        XCTAssertEqual(devices[1].ipv4, "100.64.0.2")
        XCTAssertTrue(devices[0].online)
        XCTAssertFalse(devices[1].online)
    }

    func testDiscoveryUsesAllowlistedExecutableAndReportsErrors() async throws {
        let runner = Runner(CommandResult(exitCode: 0, standardOutput: statusJSON))
        let devices = try await TailscaleDeviceDiscovery(runner: runner, locator: Locator(path: "/usr/bin/tailscale")).discover()
        XCTAssertEqual(devices.count, 2)
        let commands = await runner.recorded()
        XCTAssertEqual(commands.first?.executable, "/usr/bin/tailscale")
        XCTAssertEqual(commands.first?.arguments, ["status", "--json"])
        XCTAssertEqual(commands.first?.stdoutLimit, 1_048_576)

        do {
            _ = try await TailscaleDeviceDiscovery(runner: runner, locator: Locator(path: "/tmp/tailscale")).discover()
            XCTFail("Expected unavailable executable")
        } catch { XCTAssertEqual(error as? TailscaleDeviceError, .unavailable) }
        XCTAssertThrowsError(try TailscaleDeviceParser.parse(Data(#"{"BackendState":"Stopped","Peer":{}}"#.utf8))) {
            XCTAssertEqual($0 as? TailscaleDeviceError, .notConnected("Stopped"))
        }
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
        CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=/usr/bin/bwrap\n".utf8))
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
        let unavailable = CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=missing\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=/usr/bin/bwrap\n".utf8))
        let runner = Runner([unavailable])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertTrue(result.deploymentDetail.contains("Node >=20"))
        XCTAssertNil(result.lastSuccessfulPreflightAt)
        XCTAssertNil(result.installedContentHash)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
    }

    func testSandboxEnabledPreflightBlocksWithoutBubblewrapAndDoesNotInstall() async {
        let noBubblewrap = CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=missing\n".utf8))
        let runner = Runner([noBubblewrap])
        let result = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(result.deploymentStatus, .blocked)
        XCTAssertTrue(result.deploymentDetail.contains("kein ausführbares Linux-`bwrap`"))
        XCTAssertTrue(result.deploymentDetail.contains("niemals stillschweigend ohne OS-Sandbox"))
        XCTAssertNil(result.bubblewrapExecutablePath)
        XCTAssertNil(result.installedContentHash)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(String(decoding: commands[0].standardInput, as: UTF8.self).contains("WORKJET_BWRAP"))
    }

    func testGeneratedSandboxInvocationAndRunnerUseExactBubblewrapBoundary() async {
        let runner = Runner([successfulPreflight])
        let installed = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(sshComputer())
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertEqual(installed.bubblewrapExecutablePath, "/usr/bin/bwrap")

        var config = WorkjetDefaults.configuration()
        var worker = config.workers[0]
        worker.harness = .piSidecar
        worker.computerID = installed.id
        config.workers = [worker]
        config.computers.append(installed)
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertTrue(prompt.contains("workjet-pi-turn.mjs' '--sandbox'"))
        XCTAssertTrue(prompt.contains("aktiviert `--sandbox` ausdrücklich"))
        XCTAssertTrue(prompt.contains("projizierten In-Memory-Snapshot"))
        XCTAssertTrue(prompt.contains("read-only Host-Dateisystem"))

        let source = RemotePiBootstrap.turnRunnerSource
        for token in ["--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--ro-bind", "--bind", "--proc", "--dev"] {
            XCTAssertTrue(source.contains("\"\(token)\""), "missing \(token)")
        }
        XCTAssertTrue(source.contains("daemon = spawn(sandboxExecutable, sandboxArguments"))
        XCTAssertFalse(source.contains("--unshare-net"))
        XCTAssertTrue(source.contains("no verified bubblewrap executable is recorded"))
    }

    func testSandboxDisabledInvocationIsExplicitlyUnsandboxed() async {
        var computer = sshComputer()
        computer.sandboxEnabled = false
        let runner = Runner([CommandResult(exitCode: 0, standardOutput: Data("WORKJET_OS=Linux\nWORKJET_ARCH=aarch64\nWORKJET_HOME_WRITABLE=1\nWORKJET_SH=1\nWORKJET_NODE=v20.18.0\nWORKJET_SHA=sha256sum\nWORKJET_BWRAP=missing\n".utf8))])
        let installed = await RemotePiBootstrap(runner: runner, files: Files(), tailscaleLocator: Locator(path: nil)).deploy(computer)
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertNil(installed.bubblewrapExecutablePath)
        var config = WorkjetDefaults.configuration()
        var worker = config.workers[0]; worker.harness = .piSidecar; worker.computerID = installed.id
        config.workers = [worker]; config.computers.append(installed)
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: config), as: UTF8.self)
        XCTAssertFalse(prompt.contains("workjet-pi-turn.mjs' '--sandbox'"))
        XCTAssertTrue(prompt.contains("OS-Sandbox ist deaktiviert"))
        XCTAssertTrue(prompt.contains("keine zusätzliche Betriebssystem-Dateisystemgrenze"))
    }

    func testSuccessfulContentAddressedDeploymentAndStatusRoundTrip() async throws {
        let runner = Runner([successfulPreflight])
        let files = Files(); files.values["/audit/ctox-pi-sidecar.mjs"] = Data("audited sidecar".utf8); files.values["/private/workjet-known-hosts"] = Data("host key".utf8)
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let installed = await RemotePiBootstrap(runner: runner, files: files, tailscaleLocator: Locator(path: nil), now: { date }).deploy(sshComputer())
        XCTAssertEqual(installed.deploymentStatus, .installed)
        XCTAssertEqual(installed.installedSidecarVersion, "0.80.2")
        XCTAssertEqual(installed.bubblewrapExecutablePath, "/usr/bin/bwrap")
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
        XCTAssertTrue(prompt.contains("lokalen Keychain"))
        XCTAssertTrue(prompt.contains("CtoxTurnRequest"))
        XCTAssertTrue(prompt.contains("post-hoc"))
        XCTAssertTrue(prompt.contains("Loopback-Relay nicht verfügbar"))
        XCTAssertTrue(prompt.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(prompt.contains("--sandbox"))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("env: cleanEnvironment"))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("spawn(sandboxExecutable"))
        XCTAssertFalse(RemotePiBootstrap.turnRunnerSource.contains("process.env.API"))
    }
}

final class ProcessCommandRunnerTests: XCTestCase {
    func testEarlyChildExitDuringLargeStdinReturnsControlledFailureWithoutSIGPIPEOrHang() async {
        let payload = Data(repeating: 0x41, count: 16 * 1_024 * 1_024)
        let command = CommandSpec(executable: "/bin/sh", arguments: ["-c", "exit 0"], standardInput: payload, timeout: 2)
        let started = Date()
        do {
            _ = try await ProcessCommandRunner().run(command)
            XCTFail("Expected closed stdin to be reported")
        } catch {
            XCTAssertEqual(error as? CommandRunError, .standardInputClosed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

@MainActor final class ViewModelTests: XCTestCase {
    private final class Service: WorkjetService, @unchecked Sendable {
        var saves: [(WorkjetConfiguration, Bool)] = []
        var proxyStatus: CLIProxyStatus?
        var providerProbe = ProviderProbeResult(status: .unverified, detail: "test")
        var credentials: [String: Data] = [:]
        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws { saves.append((configuration, handwrittenRulesChanged)) }
        func runs(workers: [Worker]) -> [RunRecord] { [] }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            proxyStatus ?? CLIProxyStatus(endpoint: configuration.endpoint, state: .offline, detail: "test", capacity: .unavailable(reason: "test"))
        }
        func inspectProvider(_ provider: Provider) async -> ProviderProbeResult { providerProbe }
        func storeCredential(_ secret: Data, reference: String) throws { credentials[reference] = secret }
        func hasCredential(reference: String) -> Bool { credentials[reference] != nil }
    }
    func testSelectionIsExclusiveAndDebouncedChangesCoalesceOnExplicitFlush() async {
        let service = Service(); let model = WorkjetViewModel(configuration: PreviewData.configuration(), service: service, persistenceDelay: 60); model.toggleComputerSelection(PreviewData.devbox.id); XCTAssertEqual(model.selectedComputerID, PreviewData.devbox.id); model.toggleComputerSelection(PreviewData.devbox.id); XCTAssertEqual(model.selectedComputerID, PreviewData.devbox.id)
        model.providerSlots = 2; model.telemetryRetentionDays = 30; model.cliProxyConfiguration.usageStatisticsEnabled = true; model.skillRules = "n"; model.skillRules = "new rules"; model.addProvider(Provider(name: "API", kind: .apiKey, endpoint: "https://example.test"))
        XCTAssertTrue(service.saves.isEmpty)
        await model.flushPersistence()
        XCTAssertEqual(service.saves.count, 1)
        XCTAssertEqual(service.saves.first?.1, true)
        XCTAssertEqual(service.saves.first?.0.skillRules, "new rules")
        XCTAssertEqual(service.saves.first?.0.providers.count, 2)
    }

    func testTelemetryDefaultsAndMaskingKeepAutomaticActiveRuns() {
        let defaults = WorkjetDefaults.configuration()
        let model = WorkjetViewModel(configuration: defaults, service: Service(), persistenceDelay: 60)
        XCTAssertTrue(model.telemetryClaudeCodeEvents)
        XCTAssertTrue(model.telemetrySidecarEvents)
        XCTAssertFalse(Computer(name: "remote", transport: .ssh).telemetryEnabled)

        let localClaude = defaults.workers[0]
        let remoteComputer = Computer(name: "pi", transport: .ssh, telemetryEnabled: false)
        var remotePi = defaults.workers[1]
        remotePi.harness = .piSidecar
        remotePi.computerID = remoteComputer.id
        let claudeRun = activeRun(worker: localClaude, activity: "Claude liest Dateien", delivery: .live, pid: 300)
        let piRun = activeRun(worker: remotePi, activity: "Pi bearbeitet Snapshot", delivery: .postHoc, pid: 301)

        let claudeMasked = WorkjetViewModel.applyingTelemetryPolicy(to: [claudeRun], workers: [localClaude], computers: defaults.computers, claudeEventsEnabled: false, sidecarEventsEnabled: true)
        XCTAssertEqual(claudeMasked.count, 1)
        XCTAssertEqual(claudeMasked[0].activity, "läuft")
        XCTAssertEqual(claudeMasked[0].delivery, .unavailable)

        let remoteMasked = WorkjetViewModel.applyingTelemetryPolicy(to: [piRun], workers: [remotePi], computers: [remoteComputer], claudeEventsEnabled: true, sidecarEventsEnabled: true)
        XCTAssertEqual(remoteMasked.count, 1)
        XCTAssertEqual(remoteMasked[0].activity, "läuft")
        XCTAssertEqual(remoteMasked[0].delivery, .unavailable)

        var enabledComputer = remoteComputer; enabledComputer.telemetryEnabled = true
        let remoteVisible = WorkjetViewModel.applyingTelemetryPolicy(to: [piRun], workers: [remotePi], computers: [enabledComputer], claudeEventsEnabled: true, sidecarEventsEnabled: true)
        XCTAssertEqual(remoteVisible[0].activity, "Pi bearbeitet Snapshot")
        XCTAssertEqual(remoteVisible[0].delivery, .postHoc)

        let piGloballyMasked = WorkjetViewModel.applyingTelemetryPolicy(to: [piRun], workers: [remotePi], computers: [enabledComputer], claudeEventsEnabled: true, sidecarEventsEnabled: false)
        XCTAssertEqual(piGloballyMasked[0].activity, "läuft")
        XCTAssertEqual(piGloballyMasked[0].delivery, .unavailable)
    }

    func testProviderConnectionTestStoresSecretModelsAndStatus() async {
        var config = WorkjetDefaults.configuration()
        let provider = Provider(name: "CLI", kind: .cliProxyAPI, endpoint: "http://127.0.0.1:8317")
        config.providers = [provider]
        config.workers[0].providerID = provider.id
        let service = Service()
        service.providerProbe = ProviderProbeResult(status: .connected, detail: "verbunden", modelIDs: ["gateway-model"])
        let model = WorkjetViewModel(configuration: config, service: service, persistenceDelay: 60)
        await model.testProvider(id: provider.id, secret: "secret")
        let updated = try! XCTUnwrap(model.providers.first)
        XCTAssertEqual(updated.status, .connected)
        XCTAssertEqual(updated.statusDetail, "verbunden")
        XCTAssertEqual(updated.modelIDs, ["gateway-model"])
        XCTAssertEqual(service.credentials[Provider.credentialReference(for: provider.id)], Data("secret".utf8))
        XCTAssertTrue(model.providerAccessStored.contains(provider.id))
        XCTAssertEqual(model.providerPresentation(for: updated).tone, .connected)
        XCTAssertEqual(WorkerModelSuggestions.values(providerID: provider.id, providers: model.providers).first, "gateway-model")
    }

    func testUnprobedProviderDefaultsToNeutralInsteadOfOffline() {
        let provider = Provider(name: "New", kind: .apiKey, endpoint: "https://example.test")
        XCTAssertEqual(provider.status, .unverified)
        let model = WorkjetViewModel(configuration: WorkjetDefaults.configuration(), service: Service(), persistenceDelay: 60)
        let presentation = model.providerPresentation(for: provider)
        XCTAssertEqual(presentation.state, ProviderStatus.unverified.rawValue)
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertNil(presentation.capacity.fraction)
    }

    private func activeRun(worker: Worker, activity: String, delivery: HarnessDelivery, pid: Int32) -> ActiveRun {
        ActiveRun(
            sourceRunID: "run-\(pid)",
            workerID: worker.id,
            workerName: worker.name,
            workerModel: worker.model,
            activity: activity,
            startedAt: Date(timeIntervalSince1970: 1_000),
            observedAt: Date(timeIntervalSince1970: 1_100),
            lastHeartbeat: Date(timeIntervalSince1970: 1_090),
            delivery: delivery,
            pid: pid,
            processIdentity: ProcessIdentity(pid: pid, executablePath: "/usr/bin/worker", startToken: "start-\(pid)"),
            runDirectory: URL(fileURLWithPath: "/tmp/run-\(pid)"),
            indexFile: nil
        )
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkjetTests-\(UUID().uuidString)", isDirectory: true); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}
