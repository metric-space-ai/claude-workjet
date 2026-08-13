import XCTest
@testable import WorkjetCore

final class HarnessLifecycleIntegrationTests: XCTestCase {
    private struct Locator: HarnessBinaryLocating, Sendable {
        var binary: String?
        var npm: String?

        func firstExecutable(in candidates: [String]) -> String? {
            if let binary, candidates.contains(binary) { return binary }
            if let npm, candidates.contains(npm) { return npm }
            return nil
        }
    }

    private actor Runner: CommandRunning {
        private var results: [Result<CommandResult, CommandRunError>]
        private var commands: [CommandSpec] = []

        init(_ results: [Result<CommandResult, CommandRunError>]) { self.results = results }

        func run(_ command: CommandSpec) async throws -> CommandResult {
            commands.append(command)
            guard !results.isEmpty else { throw CommandRunError.launch("unexpected command") }
            return try results.removeFirst().get()
        }

        func recorded() -> [CommandSpec] { commands }
    }

    private actor InspectionGate {
        private var immediateResults: [HarnessComputerStatus]
        private var continuations: [CheckedContinuation<HarnessComputerStatus, Never>] = []
        private(set) var callCount = 0

        init(immediateResults: [HarnessComputerStatus]) {
            self.immediateResults = immediateResults
        }

        func inspect() async -> HarnessComputerStatus {
            callCount += 1
            if !immediateResults.isEmpty { return immediateResults.removeFirst() }
            return await withCheckedContinuation { continuations.append($0) }
        }

        func resumeNext(with status: HarnessComputerStatus) {
            continuations.removeFirst().resume(returning: status)
        }
    }

    private final class ControlledInspectionService: WorkjetService, @unchecked Sendable {
        let gate: InspectionGate

        init(gate: InspectionGate) { self.gate = gate }
        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {}
        func runs(workers: [Worker]) -> [RunRecord] { [] }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "", capacity: .unavailable(reason: ""))
        }
        func inspectHarness(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus {
            await gate.inspect()
        }
        func storeCredential(_ secret: Data, reference: String) throws {}
    }

    private actor RemoteLifecycleHost: RemoteHostCalling {
        private var responses: [Result<RemoteHostResponse, RemoteHostProtocolError>]
        private var requests: [RemoteHostRequest] = []

        init(_ responses: [Result<RemoteHostResponse, RemoteHostProtocolError>]) {
            self.responses = responses
        }

        func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw RemoteHostProtocolError.transport("unexpected") }
            return try responses.removeFirst().get()
        }

        func recorded() -> [RemoteHostRequest] { requests }
    }

    private final class Service: WorkjetService, @unchecked Sendable {
        let response: @Sendable (Harness, Computer) -> HarnessComputerStatus
        init(_ response: HarnessComputerStatus) { self.response = { _, _ in response } }
        init(response: @escaping @Sendable (Harness, Computer) -> HarnessComputerStatus) { self.response = response }
        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {}
        func runs(workers: [Worker]) -> [RunRecord] { [] }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "", capacity: .unavailable(reason: ""))
        }
        func inspectHarness(_ harness: Harness, on computer: Computer) async -> HarnessComputerStatus { response(harness, computer) }
        func performHarnessAction(_ action: HarnessComputerAction, harness: Harness, on computer: Computer) async -> HarnessComputerStatus { response(harness, computer) }
        func storeCredential(_ secret: Data, reference: String) throws {}
    }

    func testMissingHarnessOffersInstallWhenExactlyOneRealManagerExists() async {
        let npm = "/usr/bin/npm"
        let coordinator = HarnessLifecycleCoordinator(runner: Runner([]), locator: Locator(npm: npm))
        let local = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!
        let status = await coordinator.inspect(.codexCLI, on: local)

        XCTAssertEqual(status.state, .missing)
        XCTAssertEqual(status.action, .install)
        XCTAssertEqual(status.action.label, "Installieren")
    }

    func testInstallExecutesFixedArgvWithoutShellAndDoesNotFakeSuccess() async {
        let npm = "/usr/bin/npm"
        let runner = Runner([.success(CommandResult(exitCode: 0))])
        let coordinator = HarnessLifecycleCoordinator(runner: runner, locator: Locator(npm: npm))
        let local = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!

        let status = await coordinator.perform(.install, harness: .codexCLI, on: local)
        XCTAssertEqual(status.state, .missing, "A successful package-manager exit is not readiness; doctor still sees no binary")
        let commands = await runner.recorded()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].executable, npm)
        XCTAssertEqual(commands[0].arguments, ["install", "-g", "@openai/codex@latest"])
        XCTAssertFalse(commands[0].arguments.contains("-c"))
        XCTAssertNotEqual(commands[0].executable, "/bin/sh")
    }

    func testFailedDoctorIsBrokenEvenThoughVersionProbeSucceeded() async throws {
        let driver = HarnessLifecycleRegistry.driver(for: .codexCLI)
        let binary = try XCTUnwrap(driver.binaryCandidates.first)
        let runner = Runner([
            .success(CommandResult(exitCode: 0, standardOutput: Data("codex 1.2.3".utf8))),
            .success(CommandResult(exitCode: 1, standardError: Data("app-server unavailable".utf8)))
        ])
        let coordinator = HarnessLifecycleCoordinator(runner: runner, locator: Locator(binary: binary))
        let local = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!

        let status = await coordinator.inspect(.codexCLI, on: local)
        XCTAssertEqual(status.state, .broken)
        XCTAssertEqual(status.action, .check)
        XCTAssertEqual(status.action.label, "Prüfen")
    }

    func testRemoteInspectUsesV2HarnessIDAndMapsHostActions() async {
        let host = RemoteLifecycleHost([
            .success(RemoteHostResponse(ok: true, capabilities: ["harness-lifecycle-v2"])),
            .success(RemoteHostResponse(ok: true, harnessResult: RemoteHarnessLifecycleResult(harnessID: "codex-cli", action: .inspect, state: .installed, version: "1.2.3")))
        ])
        let coordinator = HarnessLifecycleCoordinator(remoteClient: { _ in host })
        var remote = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!
        remote.id = UUID()
        remote.transport = .ssh
        remote.host = "host.example"
        remote.deploymentStatus = .installed
        remote.installedSidecarVersion = PiSidecarRuntime.version

        let status = await coordinator.inspect(.codexCLI, on: remote)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.version, "1.2.3")
        XCTAssertEqual(status.actions, [.update, .remove])
        let requests = await host.recorded()
        XCTAssertEqual(requests.map(\.operation), [.probe, .harnessInspect])
        XCTAssertEqual(requests.last?.harnessID, "codex-cli")
        XCTAssertNil(requests.last?.launch)
    }

    func testRemoteCapabilityMissingOffersNoMaintenanceAction() async {
        let host = RemoteLifecycleHost([.success(RemoteHostResponse(ok: true, capabilities: ["start"]))])
        let coordinator = HarnessLifecycleCoordinator(remoteClient: { _ in host })
        var remote = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!
        remote.id = UUID(); remote.transport = .ssh; remote.host = "host.example"

        let status = await coordinator.perform(.install, harness: .claudeCode, on: remote)
        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.action, .unavailable)
        XCTAssertTrue(status.actions.isEmpty)
        let requests = await host.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testRemoteFailureDoesNotLeakTransportDetailsIntoUIState() async {
        let host = RemoteLifecycleHost([.failure(.transport("ssh argv / secret stderr"))])
        let coordinator = HarnessLifecycleCoordinator(remoteClient: { _ in host })
        var remote = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!
        remote.id = UUID(); remote.transport = .ssh; remote.host = "host.example"

        let status = await coordinator.inspect(.claudeCode, on: remote)
        XCTAssertEqual(status.state, .broken)
        XCTAssertEqual(status.detail, "Computer nicht erreichbar.")
        XCTAssertFalse(status.detail.contains("stderr"))
    }

    func testRemotePiReportsDeploymentRatherThanPackageMaintenance() async {
        let host = RemoteLifecycleHost([
            .success(RemoteHostResponse(ok: true, capabilities: ["harness-lifecycle-v2"])),
            .success(RemoteHostResponse(ok: true, harnessResult: RemoteHarnessLifecycleResult(harnessID: "pi-code", action: .inspect, state: .installed, version: PiSidecarRuntime.version)))
        ])
        let coordinator = HarnessLifecycleCoordinator(remoteClient: { _ in host })
        var remote = WorkjetDefaults.configuration().computers.first(where: \.isLocal)!
        remote.id = UUID(); remote.transport = .ssh; remote.host = "host.example"

        let status = await coordinator.inspect(.piSidecar, on: remote)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.actions, [.check])
        XCTAssertTrue(status.detail.contains("eingerichtet"))
        XCTAssertFalse(status.detail.contains("Gebündelt"))
    }

    @MainActor
    func testViewModelPublishesCheckingThenUserFacingLifecycleStateAndBlocksReadiness() async {
        let expected = HarnessComputerStatus(state: .missing, detail: "Nicht installiert.", action: .install)
        let service = Service(expected)
        var configuration = WorkjetDefaults.configuration()
        let provider = Provider(name: "Test", kind: .directAPI, endpoint: "https://example.test", authentication: .none, status: .connected, statusDetail: "Verbunden")
        configuration.providers = [provider]
        if !configuration.workers.isEmpty { configuration.workers[0].providerRoute = .account(provider.id) }
        let model = WorkjetViewModel(configuration: configuration, service: service)
        let local = configuration.computers.first(where: \.isLocal)!

        XCTAssertEqual(model.harnessStatus(.claudeCode, on: local.id).state, .unknown)
        await model.inspectHarness(.claudeCode, on: local)
        XCTAssertEqual(model.harnessStatus(.claudeCode, on: local.id), expected)

        if let worker = configuration.workers.first(where: { $0.harness == .claudeCode }) {
            XCTAssertEqual(model.operationalStatus(for: worker).state, .unavailable)
            XCTAssertEqual(model.operationalStatus(for: worker).label, "Harness fehlt")
        }
    }

    @MainActor
    func testCancelledHarnessInspectionRestoresReadyStateAndRejectsLateResult() async throws {
        let installed = HarnessComputerStatus(state: .installed, detail: "Installiert.", action: .check)
        let lateMissing = HarnessComputerStatus(state: .missing, detail: "Nicht installiert.", action: .install)
        let gate = InspectionGate(immediateResults: [installed])
        let service = ControlledInspectionService(gate: gate)
        var configuration = WorkjetDefaults.configuration()
        let provider = Provider(
            name: "Connected",
            kind: .directAPI,
            endpoint: "https://example.test",
            authentication: .none,
            status: .connected,
            statusDetail: "Verbunden"
        )
        configuration.providers = [provider]
        configuration.workers[0].providerRoute = .account(provider.id)
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let local = try XCTUnwrap(configuration.computers.first(where: \.isLocal))
        let worker = configuration.workers[0]

        await model.inspectHarness(.claudeCode, on: local)
        XCTAssertEqual(model.operationalStatus(for: worker).state, .unverified)
        XCTAssertEqual(model.operationalStatus(for: worker).label, "Nicht geprüft")

        let inspection = Task { await model.inspectHarness(.claudeCode, on: local) }
        while await gate.callCount < 2 { await Task.yield() }
        XCTAssertEqual(model.harnessStatus(.claudeCode, on: local.id).state, .checking)
        inspection.cancel()
        await gate.resumeNext(with: lateMissing)
        _ = await inspection.value

        XCTAssertEqual(model.harnessStatus(.claudeCode, on: local.id), installed)
        XCTAssertEqual(model.operationalStatus(for: worker).state, .unverified)
        XCTAssertEqual(model.operationalStatus(for: worker).label, "Nicht geprüft")
        XCTAssertTrue(model.statusMessages.isEmpty)
    }

    @MainActor
    func testPollingStartInspectsEachConfiguredHarnessDependencyOnce() async throws {
        let installed = HarnessComputerStatus(state: .installed, detail: "Installiert.", action: .check)
        let gate = InspectionGate(immediateResults: [installed])
        let service = ControlledInspectionService(gate: gate)
        var configuration = WorkjetDefaults.configuration()
        let provider = Provider(
            name: "Connected",
            kind: .directAPI,
            endpoint: "https://example.test",
            authentication: .bearerToken,
            status: .connected,
            statusDetail: "Verbunden",
            credentialReference: "workjet.tests.connected"
        )
        configuration.providers = [provider]
        for index in configuration.workers.indices {
            configuration.workers[index].providerRoute = .account(provider.id)
        }
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let expectedInspectionCount = Set(configuration.workers.map(\.harness)).count

        model.startPolling()
        while await gate.callCount < expectedInspectionCount {
            await Task.yield()
        }
        model.stopPolling()

        let inspectionCount = await gate.callCount
        XCTAssertEqual(inspectionCount, expectedInspectionCount, "Jede konfigurierte Harness-Abhängigkeit darf genau eine Startprüfung auslösen.")
        XCTAssertTrue(model.workers.allSatisfy { model.operationalStatus(for: $0).state == .unverified })
        XCTAssertTrue(model.statusMessages.isEmpty)
    }

    func testUserFacingActionLabelsAreStable() {
        XCTAssertEqual(HarnessComputerAction.check.label, "Prüfen")
        XCTAssertEqual(HarnessComputerAction.install.label, "Installieren")
        XCTAssertEqual(HarnessComputerAction.update.label, "Aktualisieren")
        XCTAssertEqual(HarnessComputerAction.remove.label, "Entfernen")
    }

    @MainActor
    func testViewModelKeepsHarnessTruthSeparateForEveryComputer() async {
        var configuration = WorkjetDefaults.configuration()
        let local = configuration.computers.first(where: \.isLocal)!
        var remote = local
        remote.id = UUID(); remote.name = "remote"; remote.transport = .ssh; remote.host = "host.example"
        configuration.computers.append(remote)
        let remoteID = remote.id
        let service = Service { harness, computer in
            if computer.id == remoteID {
                return HarnessComputerStatus(state: .installed, detail: "Installiert.", version: "2", action: .update, actions: [.update, .remove])
            }
            return HarnessComputerStatus(state: harness == .claudeCode ? .missing : .broken, detail: "Nicht installiert.", action: .install)
        }
        let model = WorkjetViewModel(configuration: configuration, service: service)

        await model.inspectHarness(.claudeCode, on: local)
        await model.inspectHarness(.claudeCode, on: remote)

        XCTAssertEqual(model.harnessStatus(.claudeCode, on: local.id).state, .missing)
        XCTAssertEqual(model.harnessStatus(.claudeCode, on: remote.id).state, .installed)
        XCTAssertEqual(model.harnessStatus(.claudeCode, on: remote.id).actions, [.update, .remove])
    }
}
