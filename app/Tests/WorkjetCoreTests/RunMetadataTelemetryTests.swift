import Darwin
import XCTest
@testable import WorkjetCore

final class RunMetadataTelemetryTests: XCTestCase {
    @MainActor
    func testRemotePresentationUsesAcceptedLaunchEvidenceAndNotWorkerConfiguration() throws {
        let keys = ["WORKJET_UI_TEST_WINDOW", "WORKJET_UI_TEST_SEED", "WORKJET_UI_TEST_REMOTE_RUN"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        keys.forEach { setenv($0, "1", 1) }
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }

        var configuration = WorkjetDefaults.configuration()
        let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        configuration.computers.append(Computer(
            id: remoteID,
            name: "Remote Ready",
            transport: .ssh,
            host: "remote.invalid",
            user: "test",
            deploymentStatus: .installed
        ))
        let index = try XCTUnwrap(configuration.workers.firstIndex(where: { $0.name == "UI/UX-Experte" }))
        configuration.workers[index].computerID = remoteID
        configuration.workers[index].model = "later-configured-model"
        configuration.workers[index].reasoningEffort = .low

        let model = WorkjetViewModel(configuration: configuration)
        let run = try XCTUnwrap(model.activeRunPresentations.first)

        XCTAssertEqual(run.workerName, "UI/UX-Experte")
        XCTAssertEqual(run.computerName, "Remote Ready")
        XCTAssertEqual(run.model, "k3[1m]")
        XCTAssertEqual(run.reasoning, .high)
        XCTAssertEqual(run.speed, .fast)
        XCTAssertEqual(run.providerRoute, "Kimi Testzugang")
        XCTAssertEqual(run.state, "Verbindung unterbrochen")
        XCTAssertNotEqual(run.model, configuration.workers[index].model)
        XCTAssertEqual(run.recoveryComputerID, remoteID)
    }

    func testCanonicalSnapshotReportsCompleteEffectiveMetadata() throws {
        let fixture = try Fixture()
        try fixture.writeSnapshot(model: "gpt-5.6-sol", reasoning: "high", speed: "fast")

        let run = try XCTUnwrap(fixture.scan())

        XCTAssertEqual(run.effectiveModel, "gpt-5.6-sol")
        XCTAssertEqual(run.effectiveReasoning, .high)
        XCTAssertEqual(run.effectiveSpeed, .fast)
    }

    func testMissingEvidenceStaysExplicitlyAbsent() throws {
        let fixture = try Fixture()
        try fixture.writeSnapshot()

        let run = try XCTUnwrap(fixture.scan())

        XCTAssertNil(run.effectiveModel)
        XCTAssertNil(run.effectiveReasoning)
        XCTAssertNil(run.effectiveSpeed)
        XCTAssertNil(run.workerModel)
    }

    func testLegacyJournalWithoutCanonicalSnapshotRemainsReadable() throws {
        let fixture = try Fixture()

        let run = try XCTUnwrap(fixture.scan())

        XCTAssertEqual(run.workerName, fixture.worker.name)
        XCTAssertNil(run.effectiveModel)
        XCTAssertNil(run.effectiveReasoning)
        XCTAssertNil(run.effectiveSpeed)
    }

    func testCurrentWorkerConfigurationNeverOverridesObservedRunMetadata() throws {
        let fixture = try Fixture(workerModel: "new-current-model", workerReasoning: .low)
        try fixture.writeSnapshot(model: "actual-run-model", reasoning: "ultra", speed: "normal")

        let run = try XCTUnwrap(fixture.scan())

        XCTAssertEqual(run.effectiveModel, "actual-run-model")
        XCTAssertEqual(run.effectiveReasoning, .ultra)
        XCTAssertEqual(run.effectiveSpeed, .normal)
        XCTAssertNotEqual(run.effectiveModel, fixture.worker.model)
        XCTAssertNotEqual(run.effectiveReasoning, fixture.worker.reasoningEffort)
    }


    func testRecordedWorkerIDWinsWhenMultipleWorkersShareExecutable() throws {
        let fixture = try Fixture()
        var other = fixture.worker
        other.id = UUID()
        other.name = "Other"
        try Data((other.id.uuidString + "\n").utf8).write(to: fixture.runDirectory.appendingPathComponent("worker-id"))
        try fixture.writeSnapshot(model: "actual")

        let run = RunTelemetryStore(paths: fixture.paths, processProbe: fixture.probe, now: { fixture.now })
            .scan(workers: [fixture.worker, other])
            .first?.activeRun

        XCTAssertEqual(run?.workerID, other.id)
        XCTAssertEqual(run?.workerName, "Other")
    }

    func testRetentionRemovesOnlyOldTerminalAndDeadRunsWithTheirIndexes() throws {
        let fixture = try RetentionFixture()
        let terminal = try fixture.makeRun("terminal", pid: 5101, terminal: true)
        let dead = try fixture.makeRun("dead", pid: 5102)
        try fixture.makeOld(terminal)
        try fixture.makeOld(dead)

        fixture.store.cleanup(retentionDays: 30)
        fixture.store.cleanup(retentionDays: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.index("terminal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.index("dead").path))
    }

    func testRetentionKeepsOldIdentityConfirmedProcessEvenWithTerminalMarker() throws {
        let fixture = try RetentionFixture()
        let startedAt = fixture.now.addingTimeInterval(-90 * 86_400)
        let run = try fixture.makeRun("still-owned", pid: 5201, startedAt: startedAt, terminal: true)
        fixture.probe.processes[5201] = ProcessIdentity(
            pid: 5201,
            executablePath: "/usr/bin/claude",
            startToken: String(startedAt.timeIntervalSince1970)
        )
        try fixture.makeOld(run)

        fixture.store.cleanup(retentionDays: 30)

        XCTAssertTrue(FileManager.default.fileExists(atPath: run.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.index("still-owned").path))
    }

    func testRetentionKeepsFreshAndAmbiguousRuns() throws {
        let fixture = try RetentionFixture()
        let fresh = try fixture.makeRun("fresh", pid: 5301, terminal: true)
        let ambiguous = try fixture.makeRun("ambiguous", pid: 5302)
        try FileManager.default.removeItem(at: ambiguous.appendingPathComponent("started-at"))
        fixture.probe.processes[5302] = ProcessIdentity(pid: 5302, executablePath: "/usr/bin/unknown", startToken: "unknown")
        try fixture.makeOld(ambiguous)

        fixture.store.cleanup(retentionDays: 30)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ambiguous.path))
    }

    func testRetentionRefusesSymlinkTreesAndIndexesOutsideOwnedRunsRoot() throws {
        let fixture = try RetentionFixture()
        let unsafeRun = try fixture.makeRun("unsafe", pid: 5401)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        XCTAssertEqual(symlink(outside.path, unsafeRun.appendingPathComponent("link").path), 0)
        try fixture.makeOld(unsafeRun)

        let outsideIndex = fixture.index("outside-index")
        try Data((outside.path + "\n").utf8).write(to: outsideIndex)
        try FileManager.default.setAttributes([.modificationDate: fixture.oldDate], ofItemAtPath: outsideIndex.path)

        fixture.store.cleanup(retentionDays: 30)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafeRun.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideIndex.path))
    }
}

private final class RetentionFixture {
    final class Probe: ProcessProbing, @unchecked Sendable {
        var processes: [Int32: ProcessIdentity] = [:]
        func identity(for pid: Int32) -> ProcessIdentity? { processes[pid] }
        func sendTERM(to pid: Int32) throws {}
    }

    let root: URL
    let paths: WorkjetPaths
    let probe = Probe()
    let now = Date(timeIntervalSince1970: 1_785_850_000)
    var oldDate: Date { now.addingTimeInterval(-90 * 86_400) }
    lazy var store = RunTelemetryStore(paths: paths, processProbe: probe, now: { [now] in now })

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-retention-\(UUID().uuidString)")
        paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: paths.runsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.runIndexDirectory, withIntermediateDirectories: true)
    }

    func index(_ id: String) -> URL { paths.runIndexDirectory.appendingPathComponent(id) }

    func makeRun(_ id: String, pid: Int32, startedAt: Date? = nil, terminal: Bool = false) throws -> URL {
        let directory = paths.runsDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((directory.path + "\n").utf8).write(to: index(id))
        try Data("\(pid)\n".utf8).write(to: directory.appendingPathComponent("pid"))
        let start = startedAt ?? now
        try Data((ISO8601DateFormatter().string(from: start) + "\n").utf8).write(to: directory.appendingPathComponent("started-at"))
        if terminal { try Data("0\n".utf8).write(to: directory.appendingPathComponent("exit-code")) }
        return directory
    }

    func makeOld(_ directory: URL) throws {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                var info = stat()
                guard lstat(item.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { continue }
                try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: item.path)
            }
        }
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: directory.path)
        let indexFile = index(directory.lastPathComponent)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: indexFile.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class Fixture {
    final class Probe: ProcessProbing, @unchecked Sendable {
        var processIdentity: ProcessIdentity?
        func identity(for pid: Int32) -> ProcessIdentity? { processIdentity?.pid == pid ? processIdentity : nil }
        func sendTERM(to pid: Int32) throws {}
    }

    let root: URL
    let paths: WorkjetPaths
    let runDirectory: URL
    let probe = Probe()
    let now = Date(timeIntervalSince1970: 1_788_592_400)
    let pid: Int32 = 4242
    var worker: Worker

    init(workerModel: String = "configured-model", workerReasoning: ReasoningEffort? = .medium) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-run-metadata-\(UUID().uuidString)")
        paths = WorkjetPaths(homeDirectory: root, stateDirectory: root.appendingPathComponent("state"))
        runDirectory = paths.runsDirectory.appendingPathComponent("metadata-run")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        worker = WorkjetDefaults.configuration().workers[0]
        worker.model = workerModel
        worker.reasoningEffort = workerReasoning
        worker.invocation.executable = "claude-sol"
        try Data("\(pid)\n".utf8).write(to: runDirectory.appendingPathComponent("pid"))
        try Data((ISO8601DateFormatter().string(from: now) + "\n").utf8).write(to: runDirectory.appendingPathComponent("started-at"))
        try Data("claude-sol\n".utf8).write(to: runDirectory.appendingPathComponent("worker"))
        probe.processIdentity = ProcessIdentity(pid: pid, executablePath: "/usr/bin/claude", startToken: String(now.timeIntervalSince1970))
    }

    func writeSnapshot(model: String? = nil, reasoning: String? = nil, speed: String? = nil) throws {
        var value: [String: Any] = [
            "schemaVersion": 1,
            "sequence": 1,
            "state": "running",
            "heartbeatAt": ISO8601DateFormatter().string(from: now)
        ]
        value["model"] = model
        value["reasoning"] = reasoning
        value["speed"] = speed
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: runDirectory.appendingPathComponent("run-state.json"))
    }

    func scan() -> ActiveRun? {
        let scanNow = now
        return RunTelemetryStore(paths: paths, processProbe: probe, now: { scanNow })
            .scan(workers: [worker])
            .first?
            .activeRun
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
