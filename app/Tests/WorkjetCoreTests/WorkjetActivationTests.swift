import Darwin
import XCTest
@testable import WorkjetCore

final class WorkjetActivationTests: XCTestCase {
    func testMissingGlobalIncludeIsReportedWithoutClaimingSessionActivation() throws {
        let fixture = try Fixture()

        let status = fixture.store.inspect(configuration: fixture.configuration)

        XCTAssertEqual(status.state, .missing)
        XCTAssertTrue(status.detail.contains("CLAUDE.md"))
        XCTAssertFalse(status.detail.localizedCaseInsensitiveContains("Session aktiviert"))
    }

    func testCurrentPromptAndMissingIncludeRemainTwoSeparateFacts() throws {
        let fixture = try Fixture()
        try fixture.store.installOrRepair(configuration: fixture.configuration)
        try FileManager.default.removeItem(at: fixture.paths.globalClaudeFile)

        let status = fixture.store.inspect(configuration: fixture.configuration)

        XCTAssertEqual(status.state, .missing)
        guard case .synchronized = status.promptStatus else {
            return XCTFail("AGENTS.md must remain reported as synchronized")
        }
        XCTAssertTrue(status.detail.contains("CLAUDE.md"))
    }

    func testEverySuccessfulServiceSaveUpdatesPromptAndRepairsGlobalActivation() throws {
        let fixture = try Fixture()
        let bootstrap = WorkjetBootstrap.live(paths: fixture.paths)
        try FileManager.default.removeItem(at: fixture.paths.globalClaudeFile)
        var changed = bootstrap.configuration
        changed.skillRules = "GENERAL RULE SENTINEL"
        changed.progressBoardRules = "BOARD SENTINEL"
        changed.technicalRules = "TECHNICAL SENTINEL"
        changed.workers[0].name = "Updated Worker"
        changed.workers[0].instructions = "WORKER SENTINEL"
        let modelName = ModelPromptCatalog.canonicalName(for: changed.workers[0].model)
        changed.modelPrompts?[modelName] = "MODEL SENTINEL"

        try bootstrap.service.save(changed, handwrittenRulesChanged: true)

        let prompt = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)
        XCTAssertEqual(try ManagedPrompt.parse(prompt).body, ManagedPrompt.workerBody(configuration: changed))
        XCTAssertEqual(try ManagedPrompt.handwrittenContent(from: prompt), "GENERAL RULE SENTINEL")
        let global = try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile)
        XCTAssertTrue(try WorkjetActivationStore.hasCurrentGlobalInclude(in: global))
        let status = fixture.store.inspect(configuration: changed)
        XCTAssertEqual(status.state, .ready)
        guard case .synchronized = status.promptStatus else {
            return XCTFail("Successful save must leave the prompt synchronized")
        }
        XCTAssertTrue(status.detail.contains("bereits laufender Sitzungen kann Workjet nicht beobachten"))
    }

    func testFailedActivationRollsBackConfigurationAndPromptToExactPreviousBytes() throws {
        let fixture = try Fixture()
        let bootstrap = WorkjetBootstrap.live(paths: fixture.paths)
        let previousConfiguration = try SecureFile.readRegularOwnedFile(at: fixture.paths.configurationFile)
        let previousPrompt = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)
        let malformedOwnerGlobal = Data("OWNER CONTENT\n\(WorkjetActivationStore.includeBegin)\nunterminated\n".utf8)
        try AtomicFile.write(malformedOwnerGlobal, to: fixture.paths.globalClaudeFile)
        var changed = bootstrap.configuration
        changed.workers[0].name = "MUST NOT PERSIST"
        changed.skillRules = "MUST NOT REPLACE OWNER RULES"

        XCTAssertThrowsError(try bootstrap.service.save(changed, handwrittenRulesChanged: true))

        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.configurationFile), previousConfiguration)
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile), previousPrompt)
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile), malformedOwnerGlobal)
    }

    func testFailedFirstActivationDoesNotCreateConfigurationOrPrompt() throws {
        let fixture = try Fixture()
        let malformedOwnerGlobal = Data("OWNER CONTENT\n\(WorkjetActivationStore.includeBegin)\nunterminated\n".utf8)
        try AtomicFile.write(malformedOwnerGlobal, to: fixture.paths.globalClaudeFile)

        let bootstrap = WorkjetBootstrap.live(paths: fixture.paths)

        XCTAssertFalse(bootstrap.messages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.configurationFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.promptFile.path))
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile), malformedOwnerGlobal)
    }

    func testConfigurationMigrationRegeneratesTheManagedPrompt() throws {
        let fixture = try Fixture()
        var legacy = fixture.configuration
        legacy.technicalRules = "OWNER TECHNICAL RULE"
        legacy.transparentWorkerPromptsMigrated = true
        try JSONConfigurationStore(fileURL: fixture.paths.configurationFile).save(legacy)
        try fixture.store.installOrRepair(configuration: legacy)

        let bootstrap = WorkjetBootstrap.live(paths: fixture.paths)

        XCTAssertTrue(bootstrap.messages.isEmpty)
        XCTAssertNotEqual(bootstrap.configuration, legacy)
        let persisted = try XCTUnwrap(JSONConfigurationStore(fileURL: fixture.paths.configurationFile).load())
        XCTAssertEqual(persisted, bootstrap.configuration)
        let prompt = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)
        XCTAssertEqual(try ManagedPrompt.parse(prompt).body, ManagedPrompt.workerBody(configuration: bootstrap.configuration))
        XCTAssertTrue(String(decoding: prompt, as: UTF8.self).contains(LegacyPromptMigration.cliExecutionContractBeginMarker))
    }

    func testFailedPromptRegenerationRestoresThePreMigrationConfiguration() throws {
        let fixture = try Fixture()
        var legacy = fixture.configuration
        legacy.technicalRules = "OWNER TECHNICAL RULE"
        legacy.transparentWorkerPromptsMigrated = true
        let store = JSONConfigurationStore(fileURL: fixture.paths.configurationFile)
        try store.save(legacy)
        let legacyBytes = try SecureFile.readRegularOwnedFile(at: fixture.paths.configurationFile)
        let malformedOwnerGlobal = Data("OWNER CONTENT\n\(WorkjetActivationStore.includeBegin)\nunterminated\n".utf8)
        try AtomicFile.write(malformedOwnerGlobal, to: fixture.paths.globalClaudeFile)

        let bootstrap = WorkjetBootstrap.live(paths: fixture.paths)

        XCTAssertFalse(bootstrap.messages.isEmpty)
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.configurationFile), legacyBytes)
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile), malformedOwnerGlobal)
    }

    func testOrdinaryReopenPreservesConfigurationActivationAndLearningsBytesAndMTimes() throws {
        let fixture = try Fixture()
        try AtomicFile.write(Data("- REOPEN LEARNING SENTINEL\n".utf8), to: fixture.paths.learningsFile)
        let firstLaunch = WorkjetBootstrap.live(paths: fixture.paths)
        XCTAssertTrue(firstLaunch.messages.isEmpty)

        let protectedFiles = [
            fixture.paths.configurationFile,
            fixture.paths.promptFile,
            fixture.paths.globalClaudeFile,
            fixture.paths.learningsFile,
        ]
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        for file in protectedFiles {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }
        let before = try protectedFiles.map(ExactFileState.init)

        let reopened = WorkjetBootstrap.live(paths: fixture.paths)

        XCTAssertTrue(reopened.messages.isEmpty)
        XCTAssertEqual(reopened.configuration, firstLaunch.configuration)
        XCTAssertEqual(try protectedFiles.map(ExactFileState.init), before)
    }

    func testReopenDoesNotSilentlyRepairMissingActivation() async throws {
        let fixture = try Fixture()
        let firstLaunch = WorkjetBootstrap.live(paths: fixture.paths)
        XCTAssertTrue(firstLaunch.messages.isEmpty)
        try FileManager.default.removeItem(at: fixture.paths.globalClaudeFile)
        let protectedFiles = [fixture.paths.configurationFile, fixture.paths.promptFile]
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        for file in protectedFiles {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }
        let before = try protectedFiles.map(ExactFileState.init)

        let reopened = WorkjetBootstrap.live(paths: fixture.paths)
        let status = await reopened.service.inspectWorkjetActivation(reopened.configuration)

        XCTAssertTrue(reopened.messages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.globalClaudeFile.path))
        XCTAssertEqual(try protectedFiles.map(ExactFileState.init), before)
        XCTAssertEqual(status.state, .missing)
        XCTAssertTrue(status.detail.contains("CLAUDE.md"))
    }

    func testAdHocLearningSaveAlsoUpdatesManagedPromptAndActivation() throws {
        let fixture = try Fixture()
        let bootstrap = WorkjetBootstrap.live(paths: fixture.paths)
        try FileManager.default.removeItem(at: fixture.paths.globalClaudeFile)
        var changed = bootstrap.configuration
        changed.adHocLearnings = "PERSISTENT LEARNING SENTINEL"

        try bootstrap.service.saveAdHocLearnings("PERSISTENT LEARNING SENTINEL", configuration: changed)

        let prompt = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)
        XCTAssertEqual(try ManagedPrompt.parse(prompt).body, ManagedPrompt.workerBody(configuration: changed))
        XCTAssertTrue(String(decoding: prompt, as: UTF8.self).contains("PERSISTENT LEARNING SENTINEL"))
        XCTAssertEqual(fixture.store.inspect(configuration: changed).state, .ready)
    }

    func testInstallPreservesGlobalContentAndAddsOneCanonicalInclude() throws {
        let fixture = try Fixture()
        let original = "# Meine globalen Regeln\n\n- Bestehende Anweisung.\n"
        try AtomicFile.write(Data(original.utf8), to: fixture.paths.globalClaudeFile)

        try fixture.store.installOrRepair(configuration: fixture.configuration)
        let once = try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile)
        let promptState = try ExactFileState(fixture.paths.promptFile)
        let globalState = try ExactFileState(fixture.paths.globalClaudeFile)
        try fixture.store.installOrRepair(configuration: fixture.configuration)
        let twice = try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile)

        XCTAssertEqual(once, twice, "Wiederholte Installation muss byte-identisch sein.")
        XCTAssertEqual(try ExactFileState(fixture.paths.promptFile), promptState, "Unveränderter Prompt darf nicht neu geschrieben werden.")
        XCTAssertEqual(try ExactFileState(fixture.paths.globalClaudeFile), globalState, "Unverändertes globales Include darf nicht neu geschrieben werden.")
        let text = String(decoding: once, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(original))
        XCTAssertEqual(text.components(separatedBy: WorkjetActivationStore.includeBegin).count - 1, 1)
        XCTAssertTrue(text.contains("@workjet/AGENTS.md"))
        XCTAssertEqual(fixture.store.inspect(configuration: fixture.configuration).state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.workjetSkillLoaderFile.path))
    }

    func testRepairReplacesOnlyManagedGlobalBlockAndCurrentPrompt() throws {
        let fixture = try Fixture()
        let global = """
        OWNER CONTENT

        \(WorkjetActivationStore.includeBegin)
        @wrong/path.md
        \(WorkjetActivationStore.includeEnd)

        OWNER TRAILER
        """
        try AtomicFile.write(Data(global.utf8), to: fixture.paths.globalClaudeFile)
        try AtomicFile.write(Data("tampered prompt".utf8), to: fixture.paths.promptFile)

        XCTAssertEqual(fixture.store.inspect(configuration: fixture.configuration).state, .outOfDate)
        try fixture.store.installOrRepair(configuration: fixture.configuration)

        let repairedGlobal = String(decoding: try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile), as: UTF8.self)
        XCTAssertTrue(repairedGlobal.contains("OWNER CONTENT"))
        XCTAssertTrue(repairedGlobal.contains("OWNER TRAILER"))
        XCTAssertFalse(repairedGlobal.contains("@wrong/path.md"))
        XCTAssertEqual(repairedGlobal.components(separatedBy: WorkjetActivationStore.includeBegin).count - 1, 1)
        XCTAssertEqual(fileMode(fixture.paths.globalClaudeFile), 0o600)
        XCTAssertEqual(fileMode(fixture.paths.promptFile), 0o600)
        let prompt = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)
        XCTAssertEqual(try ManagedPrompt.parse(prompt).body, ManagedPrompt.workerBody(configuration: fixture.configuration))
    }

    func testTamperedPromptAndConfigurationChangeAreReported() throws {
        let fixture = try Fixture()
        try fixture.store.installOrRepair(configuration: fixture.configuration)
        var tamperedPrompt = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)
        let managedBody = try XCTUnwrap(ManagedPrompt.parse(tamperedPrompt).body)
        let range = try XCTUnwrap(tamperedPrompt.range(of: managedBody))
        tamperedPrompt[range.lowerBound] ^= 0x01
        try AtomicFile.write(tamperedPrompt, to: fixture.paths.promptFile)

        var status = fixture.store.inspect(configuration: fixture.configuration)
        XCTAssertEqual(status.state, .outOfDate)
        XCTAssertTrue(status.detail.contains("SHA-256"))

        try fixture.store.installOrRepair(configuration: fixture.configuration)
        var changed = fixture.configuration
        changed.skillRules += "\nAktualisierte sichtbare Regel."
        status = fixture.store.inspect(configuration: changed)
        XCTAssertEqual(status.state, .outOfDate)
        XCTAssertTrue(status.detail.contains("aktuellen Workjet-Konfiguration"))
    }

    func testMalformedOrDuplicateManagedIncludeIsRejectedWithoutOverwritingOwnerContent() throws {
        let fixture = try Fixture()
        let malformed = "OWNER\n\(WorkjetActivationStore.includeBegin)\n@workjet/AGENTS.md\n"
        try AtomicFile.write(Data(malformed.utf8), to: fixture.paths.globalClaudeFile)

        XCTAssertThrowsError(try fixture.store.installOrRepair(configuration: fixture.configuration))
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile), Data(malformed.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.promptFile.path))
    }

    func testUninstallRemovesOnlyMarkedIncludeAndLeavesPromptAndProjectFilesUntouched() throws {
        let fixture = try Fixture()
        let original = "OWNER GLOBAL\n"
        try AtomicFile.write(Data(original.utf8), to: fixture.paths.globalClaudeFile)
        let project = fixture.root.appendingPathComponent("project")
        let projectClaude = project.appendingPathComponent("CLAUDE.md")
        let projectAgents = project.appendingPathComponent("AGENTS.md")
        try AtomicFile.write(Data("PROJECT CLAUDE".utf8), to: projectClaude)
        try AtomicFile.write(Data("PROJECT AGENTS".utf8), to: projectAgents)
        try fixture.store.installOrRepair(configuration: fixture.configuration)
        let promptBefore = try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile)

        try fixture.store.uninstallGlobalInclude()

        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.globalClaudeFile), Data(original.utf8))
        XCTAssertEqual(try SecureFile.readRegularOwnedFile(at: fixture.paths.promptFile), promptBefore)
        XCTAssertEqual(try Data(contentsOf: projectClaude), Data("PROJECT CLAUDE".utf8))
        XCTAssertEqual(try Data(contentsOf: projectAgents), Data("PROJECT AGENTS".utf8))
    }

    private func fileMode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }
}

private struct ExactFileState: Equatable {
    let data: Data
    let modificationSeconds: Int
    let modificationNanoseconds: Int

    init(_ url: URL) throws {
        data = try SecureFile.readRegularOwnedFile(at: url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
    }
}

private struct Fixture {
    let root: URL
    let paths: WorkjetPaths
    let store: WorkjetActivationStore
    let configuration: WorkjetConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-activation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = WorkjetPaths(homeDirectory: root)
        store = WorkjetActivationStore(paths: paths)
        configuration = WorkjetDefaults.configuration()
    }
}
