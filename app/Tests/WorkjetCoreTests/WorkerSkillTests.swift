import CryptoKit
import Foundation
import XCTest
@testable import WorkjetCore

final class WorkerSkillTests: XCTestCase {
    private let computerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private var technicalRules: String { WorkjetDefaults.configuration().technicalRules ?? "" }
    private var greppyPrompt: String { WorkerSkillCatalog.technicalPrompt(for: WorkerSkillCatalog.greppyID, in: technicalRules) ?? "" }

    func testCatalogPublishesExactGreppyDescriptorAndPrompt() throws {
        let greppy = try XCTUnwrap(WorkerSkillCatalog.descriptor(for: "greppy"))
        XCTAssertEqual(WorkerSkillCatalog.all.count, 1)
        XCTAssertEqual(greppy.displayName, "Greppy")
        XCTAssertTrue(greppy.defaultEnabled)
        XCTAssertEqual(greppy.compatibleHarnesses, [.claudeCode, .codexCLI, .openCode])
        XCTAssertFalse(greppy.isCompatible(with: .piSidecar))
        XCTAssertFalse(greppy.isCompatible(with: .cursorAgent))
        XCTAssertFalse(greppy.isCompatible(with: .grokCLI))

        let prompt = try XCTUnwrap(WorkerSkillCatalog.technicalPrompt(for: greppy.id, in: technicalRules))
        XCTAssertTrue(prompt.contains("Greppy must not be installed or invoked as a\nglobal grep alias."))
        XCTAssertTrue(prompt.contains("greppy search QUERY"))
        XCTAssertTrue(prompt.contains("greppy trace --callers SYMBOL"))
        XCTAssertTrue(prompt.contains("greppy trace --callees SYMBOL"))
        XCTAssertTrue(prompt.contains("greppy trace --refs SYMBOL"))
        XCTAssertTrue(prompt.contains("greppy trace --impact SYMBOL"))
        XCTAssertFalse(prompt.contains("alias grep="))
        XCTAssertFalse(prompt.contains("greppy who-calls"))
    }

    func testOldWorkerJSONUsesCatalogDefaultForCompatibleHarnesses() throws {
        for harness in [Harness.claudeCode, .codexCLI, .openCode] {
            let encoded = try JSONEncoder().encode(worker(harness: harness))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "skillOverrides")
            let legacy = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(Worker.self, from: legacy)

            XCTAssertEqual(decoded.skillOverrides, [:])
            XCTAssertEqual(WorkerSkillCatalog.effectiveSkills(for: decoded).map(\.id), ["greppy"])
            let roundTripped = try JSONDecoder().decode(Worker.self, from: JSONEncoder().encode(decoded))
            XCTAssertTrue(roundTripped.skillOverrides.isEmpty, "Default true must remain a sparse configuration")
            XCTAssertEqual(WorkerSkillCatalog.effectiveSkills(for: roundTripped).map(\.id), ["greppy"])
        }
    }

    func testSparseOverrideControlsConfiguredAndEffectiveEnablement() throws {
        let greppy = try XCTUnwrap(WorkerSkillCatalog.descriptor(for: "greppy"))
        var draft = WorkerDraft(worker: worker(harness: .claudeCode))
        XCTAssertTrue(draft.configuredEnabled(for: greppy))
        XCTAssertTrue(draft.effectiveEnabled(for: greppy))
        XCTAssertTrue(draft.skillOverrides.isEmpty)

        draft.setConfiguredEnabled(false, for: greppy)
        XCTAssertEqual(draft.skillOverrides, ["greppy": false])
        XCTAssertFalse(draft.effectiveEnabled(for: greppy))

        draft.setConfiguredEnabled(true, for: greppy)
        XCTAssertTrue(draft.skillOverrides.isEmpty, "Selecting the catalog default must remain sparse")
        XCTAssertTrue(draft.effectiveEnabled(for: greppy))

        draft.skillOverrides["greppy"] = true
        draft.selectHarness(.piSidecar)
        XCTAssertTrue(draft.configuredEnabled(for: greppy))
        XCTAssertFalse(draft.effectiveEnabled(for: greppy))
        XCTAssertEqual(draft.skillOverrides["greppy"], true)
    }

    func testUnknownOverridesRoundTripThroughCodableAndDraftSave() throws {
        var original = worker(harness: .claudeCode)
        original.skillOverrides = ["greppy": false, "future-symbol-skill": true, "retired-skill": false]

        let decoded = try JSONDecoder().decode(Worker.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.skillOverrides, original.skillOverrides)

        var draft = WorkerDraft(worker: decoded)
        draft.name = "Edited"
        draft.selectHarness(.grokCLI)
        let saved = try XCTUnwrap(draft.applied(to: decoded))
        XCTAssertEqual(saved.skillOverrides, original.skillOverrides)
        XCTAssertEqual(saved.harness, .grokCLI)
    }

    func testHarnessSwitchingNeverDiscardsKnownOrUnknownSkillOverrides() {
        var draft = WorkerDraft(worker: worker(harness: .claudeCode))
        draft.skillOverrides = ["greppy": false, "future-skill": true]

        for harness in Harness.allCases {
            draft.selectHarness(harness)
            XCTAssertEqual(draft.skillOverrides, ["greppy": false, "future-skill": true], "\(harness)")
        }
    }

    func testCompatibleLocalTaskInputInjectsGreppyExactlyOnce() throws {
        for harness in [Harness.claudeCode, .codexCLI, .openCode] {
            let compatible = worker(harness: harness)
            let once = preparedLocalTaskInput(worker: compatible, brief: Data("USER BRIEF".utf8), repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID])
            let twice = preparedLocalTaskInput(worker: compatible, brief: once, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID])
            let text = try XCTUnwrap(String(data: once, encoding: .utf8))

            XCTAssertTrue(text.hasPrefix("USER BRIEF\n\n"))
            XCTAssertEqual(text.components(separatedBy: greppyPrompt).count - 1, 1)
            XCTAssertEqual(text.components(separatedBy: WorkerSkillCatalog.beginMarker(for: "greppy")).count - 1, 1)
            XCTAssertEqual(twice, once, "Remote/local bridge composition must be idempotent")
        }

        var disabled = worker(harness: .claudeCode)
        disabled.skillOverrides = ["greppy": false]
        XCTAssertEqual(
            preparedLocalTaskInput(worker: disabled, brief: Data("USER BRIEF".utf8), repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]),
            Data("USER BRIEF".utf8)
        )
    }

    func testLocalGreppyHealthCheckRejectsBrokenShimAndAcceptsHealthyBinary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-greppy-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let greppy = bin.appendingPathComponent("greppy")
        let environment = ["PATH": bin.path, "HOME": root.path, "TMPDIR": root.path]
        let configured = worker(harness: .claudeCode)
        let unchangedBrief = Data([0x00, 0xff, 0x0a, 0x41])

        try writeExecutable("#!/bin/sh\nprintf 'managed target missing\\n' >&2\nexit 78\n", to: greppy)
        let brokenAvailable = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: repository, sourceEnvironment: environment)
        XCTAssertTrue(brokenAvailable.isEmpty, "An executable shim that exits nonzero is unavailable")
        XCTAssertEqual(
            preparedLocalTaskInput(worker: configured, brief: unchangedBrief, repositoryAvailable: true, availableSkillIDs: brokenAvailable),
            unchangedBrief,
            "Unavailable skills must preserve every original brief byte"
        )

        try writeExecutable("#!/bin/sh\n[ \"$#\" -eq 1 ] && [ \"$1\" = \"--version\" ] || exit 64\nprintf 'greppy 1.0.0\\n'\n", to: greppy)
        let healthyAvailable = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: repository, sourceEnvironment: environment)
        XCTAssertEqual(healthyAvailable, [WorkerSkillCatalog.greppyID])
        let prepared = preparedLocalTaskInput(
            worker: configured,
            brief: Data("HEALTHY BRIEF".utf8),
            repositoryAvailable: true,
            availableSkillIDs: healthyAvailable
        )
        let text = try XCTUnwrap(String(data: prepared, encoding: .utf8))
        XCTAssertEqual(text.components(separatedBy: greppyPrompt).count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: WorkerSkillCatalog.beginMarker(for: WorkerSkillCatalog.greppyID)).count - 1, 1)
    }

    func testCompatibleRemoteLaunchesRequireConfirmedWorkspaceAndVerifiedCapabilityExactlyOnce() throws {
        let computer = Computer(id: computerID, name: "Remote", transport: .tailscale)
        let registry = RemoteHarnessAdapterRegistry()

        for harness in [Harness.claudeCode, .codexCLI, .openCode] {
            let configured = worker(harness: harness)
            let original = Data("REMOTE BRIEF".utf8)
            let withoutWorkspace = preparedRemoteTaskInput(
                worker: configured,
                input: original,
                workspaceImported: false,
                verifiedCapabilities: [WorkerSkillCatalog.greppyCapability]
            )
            XCTAssertEqual(withoutWorkspace, original)
            let withoutCapability = preparedRemoteTaskInput(
                worker: configured,
                input: original,
                workspaceImported: true,
                verifiedCapabilities: ["greppy-configured-but-unverified"]
            )
            XCTAssertEqual(withoutCapability, original, "Configured defaults are not remote launch evidence")
            let prepared = preparedRemoteTaskInput(
                worker: configured,
                input: original,
                workspaceImported: true,
                verifiedCapabilities: [WorkerSkillCatalog.greppyCapability]
            )
            let launch = try registry.launch(worker: configured, computer: computer, input: prepared, workspace: RemoteWorkspaceDescriptor(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40)))
            let data = try XCTUnwrap(Data(base64Encoded: launch.inputBase64))
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertEqual(text.components(separatedBy: greppyPrompt).count - 1, 1, "\(harness)")
            XCTAssertEqual(text.components(separatedBy: WorkerSkillCatalog.beginMarker(for: "greppy")).count - 1, 1, "\(harness)")

            var disabled = worker(harness: harness)
            disabled.skillOverrides = ["greppy": false]
            let disabledInput = preparedRemoteTaskInput(worker: disabled, input: original, workspaceImported: true, verifiedCapabilities: [WorkerSkillCatalog.greppyCapability])
            let disabledLaunch = try registry.launch(worker: disabled, computer: computer, input: disabledInput, workspace: RemoteWorkspaceDescriptor(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40)))
            XCTAssertEqual(Data(base64Encoded: disabledLaunch.inputBase64), Data("REMOTE BRIEF".utf8))
        }
    }

    func testLocalGreppyRepositoryAvailabilityUsesRealGitWorktreeTruth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-skill-repository-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nonRepository = root.appendingPathComponent("plain", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let plainAvailable = await LiveWorkjetCLIBacking.repositoryAvailable(at: nonRepository)
        XCTAssertFalse(plainAvailable)

        try runGit(["init"], in: repository)
        let nested = repository.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let repositoryAvailable = await LiveWorkjetCLIBacking.repositoryAvailable(at: nested)
        XCTAssertTrue(repositoryAvailable)

        let configured = worker(harness: .claudeCode)
        let brief = Data("USER BRIEF".utf8)
        XCTAssertEqual(
            preparedLocalTaskInput(worker: configured, brief: brief, repositoryAvailable: false, availableSkillIDs: [WorkerSkillCatalog.greppyID]),
            brief
        )
        XCTAssertNotEqual(
            preparedLocalTaskInput(worker: configured, brief: brief, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]),
            brief
        )
    }

    func testPiCursorAndGrokNeverReceiveGreppyEvenWithTrueOverride() throws {
        let original = Data(#"{"files":[]}"#.utf8)
        let computer = Computer(id: computerID, name: "Remote", transport: .tailscale, sandboxEnabled: true)
        let registry = RemoteHarnessAdapterRegistry()

        var pi = worker(harness: .piSidecar)
        pi.skillOverrides = ["greppy": true]
        XCTAssertEqual(taskInput(for: pi, input: original, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]), original)
        let piLaunch = try registry.launch(worker: pi, computer: computer, input: original)
        XCTAssertEqual(Data(base64Encoded: piLaunch.inputBase64), original)

        for harness in [Harness.cursorAgent, .grokCLI] {
            var unsupported = worker(harness: harness)
            unsupported.skillOverrides = ["greppy": true]
            XCTAssertEqual(taskInput(for: unsupported, input: Data("brief".utf8), repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]), Data("brief".utf8))
            XCTAssertThrowsError(try registry.launch(worker: unsupported, computer: computer, input: Data("brief".utf8)))
        }
    }

    func testManagedPromptReportsOnlyConfiguredAndEffectiveFacts() {
        var configuration = WorkjetDefaults.configuration()
        configuration.workers = [worker(harness: .piSidecar)]
        let prompt = String(decoding: ManagedPrompt.workerBody(configuration: configuration), as: UTF8.self)

        XCTAssertTrue(prompt.contains("Skills (konfiguriert): Greppy: aktiviert (Katalogstandard)"))
        XCTAssertTrue(prompt.contains("Skills (effektiv): Keine (Greppy: für Pi Code nicht unterstützt)"))
        XCTAssertTrue(prompt.contains("keine Aussage über Binärverfügbarkeit oder erfolgreiche Nutzung"))
        XCTAssertFalse(prompt.contains("CODE-NAVIGATION COMMANDS"), "The task skill prompt must not leak into the managed global prompt")
    }

    func testWorkerEditorIsCatalogDrivenAndExposesStableUnsupportedIdentifiers() throws {
        let source = try String(contentsOf: appRoot.appendingPathComponent("Sources/WorkjetApp/WorkerEditorView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"WJSectionHeader(title: "Skills")"#))
        XCTAssertTrue(source.contains("ForEach(WorkerSkillCatalog.all)"))
        XCTAssertTrue(source.contains(#"worker.editor.skills"#))
        XCTAssertTrue(source.contains(#"worker.editor.skill.\(skill.id)"#))
        XCTAssertTrue(source.contains(#"worker.editor.skill.\(skill.id).unsupported"#))
        XCTAssertTrue(source.contains("skill.incompatibilityDescription(for: draft.harness)"))
        XCTAssertFalse(source.contains("if skill.id == WorkerSkillCatalog.greppyID"))
    }

    private func preparedLocalTaskInput(worker: Worker, brief: Data, repositoryAvailable: Bool, availableSkillIDs: Set<String>) -> Data {
        LiveWorkjetCLIBacking.preparedLocalTaskInput(
            worker: worker,
            brief: brief,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: technicalRules
        )
    }

    private func preparedRemoteTaskInput(worker: Worker, input: Data, workspaceImported: Bool, verifiedCapabilities: [String]) -> Data {
        LocalWorkjetService.preparedRemoteTaskInput(
            worker: worker,
            input: input,
            workspaceImported: workspaceImported,
            verifiedCapabilities: verifiedCapabilities,
            technicalRules: technicalRules
        )
    }

    private func taskInput(for worker: Worker, input: Data, repositoryAvailable: Bool, availableSkillIDs: Set<String>) -> Data {
        WorkerSkillCatalog.taskInput(
            for: worker,
            input: input,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: technicalRules
        )
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = GitRepositoryInspector.gitEnvironment
        process.standardOutput = FileHandle.nullDevice
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
    }

    private func worker(harness: Harness) -> Worker {
        Worker(
            name: "Skill Worker",
            harness: harness,
            model: "fixture-model",
            instructions: "Do the bounded task.",
            computerID: computerID,
            invocation: WorkerInvocation(executable: "/usr/bin/true", arguments: ["-p", "<WORKJET_BRIEF>"])
        )
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
