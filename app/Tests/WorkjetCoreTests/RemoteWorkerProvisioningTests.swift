import XCTest
@testable import WorkjetCore

final class RemoteWorkerProvisioningTests: XCTestCase {
    private actor Host: RemoteHostCalling {
        private var responses: [RemoteHostResponse]
        private var requests: [RemoteHostRequest] = []

        init(_ responses: [RemoteHostResponse]) { self.responses = responses }

        func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw RemoteHostProtocolError.transport("unexpected request") }
            return responses.removeFirst()
        }

        func recorded() -> [RemoteHostRequest] { requests }
    }

    private final class SavingService: WorkjetService, @unchecked Sendable {
        var provisioningResult: RemoteWorkerProvisioningResult
        var events: [String] = []

        init(provisioningResult: RemoteWorkerProvisioningResult) {
            self.provisioningResult = provisioningResult
        }

        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws { events.append("save") }
        func runs(workers: [Worker]) -> [RunRecord] { [] }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "", capacity: .unavailable(reason: ""))
        }
        func provisionRemoteWorker(_ worker: Worker, on computer: Computer) async -> RemoteWorkerProvisioningResult {
            events.append("provision")
            return provisioningResult
        }
        func storeCredential(_ secret: Data, reference: String) throws {}
    }

    func testMissingHarnessAndDefaultEnabledGreppyAreAutomaticallyInstalledAndVerified() async {
        let computer = remoteComputer()
        let worker = remoteWorker(computerID: computer.id)
        let host = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .missing, detail: "Nicht installiert."),
            harness("claude-code", .install, .installed, version: "2.1.222"),
            harness("claude-code", .inspect, .installed, version: "2.1.222"),
            skill("greppy", .inspect, .missing),
            skill("greppy", .install, .installed, version: "0.3.1"),
            skill("greppy", .inspect, .installed, version: "0.3.1"),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code", "greppy"])
        ])
        let coordinator = RemoteWorkerProvisioningCoordinator(remoteClient: { _ in host })

        let result = await coordinator.provision(worker: worker, on: computer)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.components.map(\.id), ["claude-code", "greppy"])
        XCTAssertEqual(result.components.map(\.state), [.installed, .installed])
        let requests = await host.recorded()
        XCTAssertEqual(requests.map(\.operation), [
            .probe, .harnessInspect, .harnessInstall, .harnessInspect,
            .managedSkillInspect, .managedSkillInstall, .managedSkillInspect, .probe
        ])
        XCTAssertTrue(requests.allSatisfy { $0.launch == nil })
    }

    func testGreppyOverrideFalseSkipsManagedSkillLifecycle() async {
        let computer = remoteComputer()
        var worker = remoteWorker(computerID: computer.id)
        worker.skillOverrides = [WorkerSkillCatalog.greppyID: false]
        let host = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .installed, version: "2.1.222"),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code"])
        ])
        let coordinator = RemoteWorkerProvisioningCoordinator(remoteClient: { _ in host })

        let result = await coordinator.provision(worker: worker, on: computer)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.components.map(\.id), ["claude-code"])
        let requests = await host.recorded()
        XCTAssertFalse(requests.contains { $0.skillID != nil })
    }

    func testWebResearchInstallsCodexHarnessWithoutInventingManagedSkill() async {
        let computer = remoteComputer()
        var worker = remoteWorker(computerID: computer.id)
        worker.skillOverrides = [WorkerSkillCatalog.greppyID: false, WorkerSkillCatalog.webResearchID: true]
        let host = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code"]),
            harness("claude-code", .inspect, .installed, version: "2.1.222"),
            harness("codex-cli", .inspect, .missing),
            harness("codex-cli", .install, .installed, version: "1.0.0"),
            harness("codex-cli", .inspect, .installed, version: "1.0.0"),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code", "codex-cli"])
        ])
        let result = await RemoteWorkerProvisioningCoordinator(remoteClient: { _ in host }).provision(worker: worker, on: computer)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.components.map(\.id), ["claude-code", "codex-cli"])
        let requests = await host.recorded()
        XCTAssertFalse(requests.contains { $0.skillID != nil })
    }

    func testBrokenGreppyInstallationIsRepairedAndReverified() async {
        let computer = remoteComputer()
        let worker = remoteWorker(computerID: computer.id)
        let host = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .installed, version: "2.1.222"),
            skill("greppy", .inspect, .broken, version: "0.3.1", detail: "Falsche Befehlsoberfläche."),
            skill("greppy", .install, .installed, version: "0.3.1"),
            skill("greppy", .inspect, .installed, version: "0.3.1"),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code", "greppy"])
        ])
        let coordinator = RemoteWorkerProvisioningCoordinator(remoteClient: { _ in host })

        let result = await coordinator.provision(worker: worker, on: computer)

        XCTAssertTrue(result.succeeded)
        let requests = await host.recorded()
        XCTAssertEqual(requests.map(\.operation), [
            .probe, .harnessInspect,
            .managedSkillInspect, .managedSkillInstall, .managedSkillInspect, .probe
        ])
    }

    func testSharedHarnessAndDefaultSkillAreDeduplicatedAcrossAssignedWorkers() async {
        let computer = remoteComputer()
        let workers = [remoteWorker(computerID: computer.id), remoteWorker(computerID: computer.id)]
        let host = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .installed, version: "2.1.222"),
            skill("greppy", .inspect, .installed, version: "0.3.1"),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code", "greppy"])
        ])
        let coordinator = RemoteWorkerProvisioningCoordinator(remoteClient: { _ in host })

        let result = await coordinator.provision(workers: workers, on: computer)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.workerIDs.count, 2)
        let requests = await host.recorded()
        XCTAssertEqual(requests.filter { $0.operation == .harnessInspect }.count, 1)
        XCTAssertEqual(requests.filter { $0.operation == .managedSkillInspect }.count, 1)
        XCTAssertEqual(requests.count, 4)
    }

    func testMultipleRemoteComputersKeepProvisioningHostsAndWorkerAssignmentsIsolated() async {
        let first = remoteComputer(name: "gpu3-a4500")
        let second = remoteComputer(name: "gpu4-a4500")
        let firstWorker = remoteWorker(computerID: first.id)
        let secondWorker = remoteWorker(computerID: second.id)
        let firstHost = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .installed),
            skill("greppy", .inspect, .installed),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code", "greppy"])
        ])
        let secondHost = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .installed),
            skill("greppy", .inspect, .installed),
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1", "claude-code", "greppy"])
        ])
        let firstID = first.id
        let coordinator = RemoteWorkerProvisioningCoordinator(remoteClient: { computer in
            computer.id == firstID ? firstHost : secondHost
        })

        async let firstResult = coordinator.provision(worker: firstWorker, on: first)
        async let secondResult = coordinator.provision(worker: secondWorker, on: second)
        let results = await [firstResult, secondResult]
        let firstOperations = await firstHost.recorded().map(\.operation)
        let secondOperations = await secondHost.recorded().map(\.operation)

        XCTAssertEqual(Set(results.map(\.computerID)), Set([first.id, second.id]))
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertEqual(firstOperations, [.probe, .harnessInspect, .managedSkillInspect, .probe])
        XCTAssertEqual(secondOperations, [.probe, .harnessInspect, .managedSkillInspect, .probe])
    }

    func testProvisioningFailureNamesExactComponentAndDetail() async {
        let computer = remoteComputer()
        let worker = remoteWorker(computerID: computer.id)
        let host = Host([
            probe(["harness-lifecycle-v2", "managed-skill-lifecycle-v1"]),
            harness("claude-code", .inspect, .installed, version: "2.1.222"),
            skill("greppy", .inspect, .missing),
            skill("greppy", .install, .broken, detail: "Der Greppy-Download hat nicht die erwartete SHA-256-Prüfsumme. Es wurde nichts aktiviert.")
        ])
        let coordinator = RemoteWorkerProvisioningCoordinator(remoteClient: { _ in host })

        let result = await coordinator.provision(worker: worker, on: computer)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failure?.component.kind, .managedSkill)
        XCTAssertEqual(result.failure?.component.id, "greppy")
        XCTAssertTrue(result.failure?.userVisibleDetail.contains("SHA-256") == true)
    }

    @MainActor
    func testRemoteDurableSaveProvisionsBeforePersistenceAndKeepsFailureOutOfConfiguration() async {
        var configuration = WorkjetDefaults.configuration()
        let computer = remoteComputer()
        configuration.computers.append(computer)
        var worker = remoteWorker(computerID: computer.id)
        configuration.workers = []

        let success = RemoteWorkerProvisioningResult(
            workerIDs: [worker.id],
            computerID: computer.id,
            components: [RemoteProvisioningComponent(kind: .harness, id: "claude-code", state: .installed, version: "2.1.222", detail: "Installiert.")],
            verifiedCapabilities: ["claude-code", "greppy"]
        )
        let service = SavingService(provisioningResult: success)
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)

        let saved = await model.saveWorkerDurably(worker)
        XCTAssertEqual(saved, .succeeded)
        XCTAssertEqual(service.events, ["provision", "save"])
        XCTAssertEqual(model.workers.map(\.id), [worker.id])

        worker.name = "Failed replacement"
        let failedComponent = RemoteProvisioningComponent(kind: .managedSkill, id: "greppy", state: .broken, detail: "Digest stimmt nicht.")
        service.provisioningResult = RemoteWorkerProvisioningResult(workerIDs: [worker.id], computerID: computer.id, components: [failedComponent], failure: RemoteProvisioningFailure(component: failedComponent))
        let failed = await model.saveWorkerDurably(worker)

        guard case let .failed(message) = failed else { return XCTFail("Expected provisioning failure") }
        XCTAssertTrue(message.contains("Skill greppy"))
        XCTAssertEqual(service.events, ["provision", "save", "provision"])
        XCTAssertNotEqual(model.workers.first?.name, "Failed replacement")
        XCTAssertEqual(model.workerProvisioningFailures[worker.id]?.component.id, "greppy")
    }

    private func remoteComputer(name: String = "gpu3-a4500") -> Computer {
        Computer(
            id: UUID(),
            name: name,
            transport: .ssh,
            host: "\(name).example.test",
            user: "workjet",
            deploymentStatus: .installed,
            deploymentDetail: "Eingerichtet.",
            installedSidecarVersion: PiSidecarRuntime.version
        )
    }

    private func remoteWorker(computerID: UUID) -> Worker {
        Worker(
            id: UUID(),
            name: "Remote Completion",
            harness: .claudeCode,
            model: "claude-sonnet-4-5",
            instructions: "Implement the bounded task.",
            computerID: computerID,
            invocation: WorkerInvocation(executable: "claude", arguments: ["-p", "<WORKJET_BRIEF>"])
        )
    }

    private func probe(_ capabilities: [String]) -> RemoteHostResponse {
        RemoteHostResponse(ok: true, capabilities: capabilities)
    }

    private func harness(_ id: String, _ action: RemoteHarnessMaintenanceAction, _ state: RemoteHarnessLifecycleState, version: String? = nil, detail: String? = nil) -> RemoteHostResponse {
        RemoteHostResponse(ok: true, harnessResult: RemoteHarnessLifecycleResult(harnessID: id, action: action, state: state, version: version, detail: detail))
    }

    private func skill(_ id: String, _ action: RemoteManagedSkillMaintenanceAction, _ state: RemoteHarnessLifecycleState, version: String? = nil, detail: String? = nil) -> RemoteHostResponse {
        RemoteHostResponse(ok: true, managedSkillResult: RemoteManagedSkillLifecycleResult(skillID: id, action: action, state: state, version: version, detail: detail))
    }
}
