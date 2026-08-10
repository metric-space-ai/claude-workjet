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
        XCTAssertEqual(WorkerSkillCatalog.all.count, 2)
        XCTAssertEqual(greppy.displayName, "Greppy")
        XCTAssertEqual(greppy.version, "0.3.1")
        XCTAssertTrue(greppy.defaultEnabled)
        XCTAssertEqual(greppy.compatibleHarnesses, [.claudeCode])
        XCTAssertFalse(greppy.isCompatible(with: .piSidecar))
        XCTAssertFalse(greppy.isCompatible(with: .cursorAgent))
        XCTAssertFalse(greppy.isCompatible(with: .grokCLI))

        let prompt = try XCTUnwrap(WorkerSkillCatalog.technicalPrompt(for: greppy.id, in: technicalRules))
        XCTAssertTrue(prompt.hasPrefix("Use greppy for every code-navigation step in this repository"))
        XCTAssertTrue(prompt.contains("Use greppy for every code-navigation step"))
        XCTAssertTrue(prompt.contains("greppy who-calls"))
        XCTAssertTrue(prompt.contains("search-symbol NAME"))
        XCTAssertTrue(prompt.contains("bash-smart [-e REGEX]"))
        XCTAssertFalse(prompt.contains("alias grep="))
        let hash = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "e184b412f549db701f1ab5fa299e88850aae9e7bdb3420ceff033f6b4e6f9a16", "Workjet must install the prescribed Greppy v0.3.1 prompt byte-for-byte")
    }

    func testCatalogPublishesOptInAdditiveWebResearchSkillAndExactPrompt() throws {
        let skill = try XCTUnwrap(WorkerSkillCatalog.descriptor(for: WorkerSkillCatalog.webResearchID))
        XCTAssertEqual(skill.displayName, "Web Research")
        XCTAssertFalse(skill.defaultEnabled)
        XCTAssertEqual(skill.compatibleHarnesses, [.claudeCode, .codexCLI])
        XCTAssertFalse(skill.requiresRepository)
        XCTAssertFalse(skill.usesManagedRemoteBinary)
        XCTAssertEqual(skill.systemPromptHarnesses, [.claudeCode])
        let prompt = try XCTUnwrap(WorkerSkillCatalog.technicalPrompt(for: skill.id, in: technicalRules))
        XCTAssertEqual(prompt, WebResearchPrompt.text + "\n")
        XCTAssertTrue(prompt.contains("normal harness\ntools"))
        XCTAssertTrue(prompt.contains("codex --search"))
        XCTAssertTrue(prompt.contains("exact URL"))
        XCTAssertTrue(prompt.contains("agy --sandbox"))
    }

    func testWebResearchAddsSystemPromptWithoutRequiringRepositoryOrRemovingNormalTools() throws {
        var configured = worker(harness: .claudeCode)
        configured.skillOverrides = [WorkerSkillCatalog.greppyID: false, WorkerSkillCatalog.webResearchID: true]
        let tools = try XCTUnwrap(HarnessAdapterRegistry.allowedTools(in: configured.invocation))
        let prompt = try XCTUnwrap(preparedLocalSystemPrompt(
            worker: configured,
            repositoryAvailable: false,
            availableSkillIDs: [WorkerSkillCatalog.webResearchID]
        ))
        XCTAssertEqual(tools, ["Read", "Write", "Edit", "Grep", "Glob", "Bash"])
        XCTAssertTrue(prompt.contains(WorkerSkillCatalog.beginMarker(for: WorkerSkillCatalog.webResearchID)))
        XCTAssertTrue(prompt.contains("normal harness\ntools"))
        XCTAssertFalse(prompt.contains(WorkerSkillCatalog.beginMarker(for: WorkerSkillCatalog.greppyID)))
    }

    func testCodexAndAntigravityHealthMakeWebResearchAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-web-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let environment = ["PATH": bin.path, "HOME": root.path, "TMPDIR": root.path]
        let gateway = ResolvedProviderRuntimeRoute(displayName: "Gateway", candidates: [
            ProviderRuntimeCandidate(kind: .gatewayPool, providerID: nil, modelProvider: .openAI, displayName: "OpenAI Gateway", endpoint: "http://127.0.0.1:8317", authentication: .bearerToken, credentialReference: "fixture")
        ])
        let direct = ResolvedProviderRuntimeRoute(displayName: "Direct", candidates: [
            ProviderRuntimeCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .miniMax, displayName: "MiniMax", endpoint: "https://example.invalid", authentication: .apiKeyHeader, credentialReference: "fixture")
        ])

        try writeExecutable("#!/bin/sh\n[ \"$1\" = \"--version\" ] && printf 'codex 1.0\\n'\n", to: bin.appendingPathComponent("codex"))
        let gatewaySkills = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: root, route: gateway, sourceEnvironment: environment)
        let directSkills = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: root, route: direct, sourceEnvironment: environment)
        XCTAssertTrue(gatewaySkills.contains(WorkerSkillCatalog.webResearchID))
        XCTAssertFalse(directSkills.contains(WorkerSkillCatalog.webResearchID))

        try writeExecutable("#!/bin/sh\n[ \"$1\" = \"--version\" ] && printf 'agy 1.1.3\\n'\n", to: bin.appendingPathComponent("agy"))
        let antigravitySkills = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: root, route: direct, sourceEnvironment: environment)
        XCTAssertTrue(antigravitySkills.contains(WorkerSkillCatalog.webResearchID))
    }

    func testOldWorkerJSONUsesCatalogDefaultForCompatibleHarnesses() throws {
        for harness in Harness.allCases {
            let encoded = try JSONEncoder().encode(worker(harness: harness))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "skillOverrides")
            let legacy = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(Worker.self, from: legacy)

            XCTAssertEqual(decoded.skillOverrides, [:])
            XCTAssertEqual(WorkerSkillCatalog.effectiveSkills(for: decoded).map(\.id), harness == .claudeCode ? ["greppy"] : [])
            let roundTripped = try JSONDecoder().decode(Worker.self, from: JSONEncoder().encode(decoded))
            XCTAssertTrue(roundTripped.skillOverrides.isEmpty, "Default true must remain a sparse configuration")
            XCTAssertEqual(WorkerSkillCatalog.effectiveSkills(for: roundTripped).map(\.id), harness == .claudeCode ? ["greppy"] : [])
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

    func testCompatibleLocalSystemPromptInstallsGreppyWithoutChangingBrief() throws {
        let compatible = worker(harness: .claudeCode)
        let prompt = try XCTUnwrap(preparedLocalSystemPrompt(worker: compatible, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
        XCTAssertEqual(prompt.components(separatedBy: greppyPrompt).count - 1, 1)
        XCTAssertEqual(prompt.components(separatedBy: WorkerSkillCatalog.beginMarker(for: "greppy")).count - 1, 1)

        for harness in [Harness.codexCLI, .openCode] {
            XCTAssertNil(preparedLocalSystemPrompt(worker: worker(harness: harness), repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
        }

        var disabled = worker(harness: .claudeCode)
        disabled.skillOverrides = ["greppy": false]
        XCTAssertNil(preparedLocalSystemPrompt(worker: disabled, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
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
        try writeExecutable("#!/bin/sh\nprintf 'managed target missing\\n' >&2\nexit 78\n", to: greppy)
        let brokenAvailable = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: repository, sourceEnvironment: environment)
        XCTAssertTrue(brokenAvailable.isEmpty, "An executable shim that exits nonzero is unavailable")
        XCTAssertNil(preparedLocalSystemPrompt(worker: configured, repositoryAvailable: true, availableSkillIDs: brokenAvailable))

        try writeExecutable("#!/bin/sh\n[ \"$#\" -eq 1 ] && [ \"$1\" = \"--version\" ] || exit 64\nprintf 'greppy 0.3.0\\n'\n", to: greppy)
        let staleAvailable = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: repository, sourceEnvironment: environment)
        XCTAssertTrue(staleAvailable.isEmpty, "A responsive but stale Greppy version must not be advertised")

        try writeExecutable("#!/bin/sh\nif [ \"$#\" -eq 1 ] && [ \"$1\" = \"--version\" ]; then printf 'greppy 0.3.1\\n'; elif [ \"$#\" -eq 1 ] && [ \"$1\" = \"--help\" ]; then printf 'who-calls search-symbol bash-smart\\n'; else exit 64; fi\n", to: greppy)
        let healthyAvailable = await LiveWorkjetCLIBacking.availableLocalSkillIDs(at: repository, sourceEnvironment: environment)
        XCTAssertEqual(healthyAvailable, [WorkerSkillCatalog.greppyID])
        let prepared = preparedLocalSystemPrompt(
            worker: configured,
            repositoryAvailable: true,
            availableSkillIDs: healthyAvailable
        )
        let text = try XCTUnwrap(prepared)
        XCTAssertEqual(text.components(separatedBy: greppyPrompt).count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: WorkerSkillCatalog.beginMarker(for: WorkerSkillCatalog.greppyID)).count - 1, 1)
    }

    func testCompatibleRemoteLaunchKeepsBriefExactAndCarriesGreppyAsSystemPrompt() throws {
        let computer = Computer(id: computerID, name: "Remote", transport: .tailscale)
        let registry = RemoteHarnessAdapterRegistry()
        let configured = worker(harness: .claudeCode)
        let original = Data("REMOTE BRIEF".utf8)
        XCTAssertNil(preparedRemoteSystemPrompt(worker: configured, workspaceImported: false, verifiedCapabilities: [WorkerSkillCatalog.greppyCapability]))
        XCTAssertNil(preparedRemoteSystemPrompt(worker: configured, workspaceImported: true, verifiedCapabilities: ["greppy-configured-but-unverified"]))
        let systemPrompt = try XCTUnwrap(preparedRemoteSystemPrompt(worker: configured, workspaceImported: true, verifiedCapabilities: [WorkerSkillCatalog.greppyCapability]))
        let launch = try registry.launch(worker: configured, computer: computer, input: original, systemPrompt: systemPrompt, workspace: RemoteWorkspaceDescriptor(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40)))
        XCTAssertEqual(launch.greppy, true)
        XCTAssertEqual(Data(base64Encoded: launch.inputBase64), original)
        let promptData = try XCTUnwrap(launch.systemPromptBase64.flatMap { Data(base64Encoded: $0) })
        let decodedPrompt = try XCTUnwrap(String(data: promptData, encoding: .utf8))
        XCTAssertEqual(decodedPrompt, systemPrompt)
        XCTAssertEqual(systemPrompt.components(separatedBy: greppyPrompt).count - 1, 1)

        for harness in [Harness.codexCLI, .openCode] {
            XCTAssertNil(preparedRemoteSystemPrompt(worker: worker(harness: harness), workspaceImported: true, verifiedCapabilities: [WorkerSkillCatalog.greppyCapability]))
        }
    }

    func testRemoteClaudeWebResearchLaunchKeepsNormalToolsAndDeclaresCapability() throws {
        let computer = Computer(id: computerID, name: "Remote", transport: .tailscale)
        var configured = worker(harness: .claudeCode)
        configured.skillOverrides = [WorkerSkillCatalog.greppyID: false, WorkerSkillCatalog.webResearchID: true]
        let systemPrompt = try XCTUnwrap(preparedRemoteSystemPrompt(
            worker: configured,
            workspaceImported: true,
            verifiedCapabilities: [WorkerSkillCatalog.webResearchCapability]
        ))
        let launch = try RemoteHarnessAdapterRegistry().launch(
            worker: configured,
            computer: computer,
            input: Data("research".utf8),
            systemPrompt: systemPrompt,
            workspace: RemoteWorkspaceDescriptor(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40))
        )
        XCTAssertEqual(launch.webResearch, true)
        XCTAssertEqual(launch.allowedTools, ["Read", "Write", "Edit", "Grep", "Glob", "Bash"])
        XCTAssertTrue(systemPrompt.contains("codex --search"))
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
        XCTAssertNil(preparedLocalSystemPrompt(worker: configured, repositoryAvailable: false, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
        XCTAssertNotNil(preparedLocalSystemPrompt(worker: configured, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
    }

    func testPiCursorAndGrokNeverReceiveGreppyEvenWithTrueOverride() throws {
        let original = Data(#"{"files":[]}"#.utf8)
        let computer = Computer(id: computerID, name: "Remote", transport: .tailscale, sandboxEnabled: true)
        let registry = RemoteHarnessAdapterRegistry()

        var pi = worker(harness: .piSidecar)
        pi.skillOverrides = ["greppy": true]
        XCTAssertNil(systemPrompt(for: pi, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
        let piLaunch = try registry.launch(worker: pi, computer: computer, input: original)
        XCTAssertEqual(Data(base64Encoded: piLaunch.inputBase64), original)

        for harness in [Harness.cursorAgent, .grokCLI] {
            var unsupported = worker(harness: harness)
            unsupported.skillOverrides = ["greppy": true]
            XCTAssertNil(systemPrompt(for: unsupported, repositoryAvailable: true, availableSkillIDs: [WorkerSkillCatalog.greppyID]))
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
        XCTAssertTrue(source.contains(#"worker.editor.skill.\(skill.id).version"#))
        XCTAssertTrue(source.contains("skill.version"))
        XCTAssertTrue(source.contains("skill.incompatibilityDescription(for: draft.harness)"))
        XCTAssertFalse(source.contains("if skill.id == WorkerSkillCatalog.greppyID"))
    }

    private func preparedLocalSystemPrompt(worker: Worker, repositoryAvailable: Bool, availableSkillIDs: Set<String>) -> String? {
        LiveWorkjetCLIBacking.preparedLocalSystemPrompt(
            worker: worker,
            repositoryAvailable: repositoryAvailable,
            availableSkillIDs: availableSkillIDs,
            technicalRules: technicalRules
        )
    }

    private func preparedRemoteSystemPrompt(worker: Worker, workspaceImported: Bool, verifiedCapabilities: [String]) -> String? {
        LocalWorkjetService.preparedRemoteSystemPrompt(
            worker: worker,
            workspaceImported: workspaceImported,
            verifiedCapabilities: verifiedCapabilities,
            technicalRules: technicalRules
        )
    }

    private func systemPrompt(for worker: Worker, repositoryAvailable: Bool, availableSkillIDs: Set<String>) -> String? {
        WorkerSkillCatalog.systemPrompt(
            for: worker,
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
            invocation: WorkerInvocation(executable: "/usr/bin/true", arguments: ["--bare", "-p", "<WORKJET_BRIEF>", "--allowedTools", "Read,Write,Edit,Grep,Glob,Bash"])
        )
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
