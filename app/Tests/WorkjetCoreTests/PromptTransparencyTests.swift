import XCTest
@testable import WorkjetCore

final class PromptTransparencyTests: XCTestCase {
    @MainActor
    func testGeneratedWorkerPreviewContainsOnlyExactGeneratedWorkerFacts() {
        let configuration = WorkjetDefaults.configuration()
        let model = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)
        let expected = configuration.workers
            .map { ManagedPrompt.generatedWorkerConfiguration(for: $0, configuration: configuration) }
            .joined(separator: "\n\n")

        XCTAssertEqual(model.generatedWorkerPreview, expected)
        XCTAssertFalse(model.generatedWorkerPreview.contains("## Progress Board"))
        XCTAssertFalse(model.generatedWorkerPreview.contains("## Ad-hoc Learnings"))
        XCTAssertFalse(model.generatedWorkerPreview.contains("## Technische Regeln"))
    }

    func testEveryPromptSourceSentinelAppearsInItsVisibleGeneratedDocument() {
        var configuration = WorkjetDefaults.configuration()
        configuration.skillRules = "GENERAL-SOURCE-SENTINEL"
        configuration.skillLoaderInstructions = "LOADER-SOURCE-SENTINEL"
        configuration.progressBoardRules = "PROGRESS-BOARD-SOURCE-SENTINEL"
        configuration.workers[0].instructions = "WORKER-SOURCE-SENTINEL"
        let model = ModelPromptCatalog.canonicalName(for: configuration.workers[0].model)
        configuration.modelPrompts?[model] = "MODEL-SOURCE-SENTINEL"
        configuration.adHocLearnings = "LEARNING-SOURCE-SENTINEL"
        configuration.technicalRules = "TECHNICAL-SOURCE-SENTINEL"

        let managed = String(decoding: ManagedPrompt.workerBody(configuration: configuration), as: UTF8.self)
        XCTAssertTrue(managed.contains("PROGRESS-BOARD-SOURCE-SENTINEL"))
        XCTAssertTrue(managed.contains("WORKER-SOURCE-SENTINEL"))
        XCTAssertTrue(managed.contains("MODEL-SOURCE-SENTINEL"))
        XCTAssertTrue(managed.contains("LEARNING-SOURCE-SENTINEL"))
        XCTAssertTrue(managed.contains("TECHNICAL-SOURCE-SENTINEL"))
        XCTAssertEqual(configuration.skillRules, "GENERAL-SOURCE-SENTINEL")

        let loader = WorkjetActivationStore.loaderDocument(instructions: configuration.skillLoaderInstructions!)
        XCTAssertTrue(loader.contains("LOADER-SOURCE-SENTINEL"))
        XCTAssertFalse(managed.contains("LOADER-SOURCE-SENTINEL"))
    }

    func testProgressBoardDefaultAndBackwardCompatibleNormalizationPreserveExplicitEmptyValue() throws {
        let defaults = WorkjetDefaults.configuration()
        XCTAssertEqual(defaults.progressBoardRules, WorkjetDefaults.progressBoardRules)
        XCTAssertTrue(WorkjetDefaults.progressBoardRules.hasPrefix("## Progress board (mandatory for every larger orchestrated task) — v2"))
        XCTAssertTrue(WorkjetDefaults.progressBoardRules.hasSuffix("Headline = the current critical path in one sentence."))

        let encoded = try JSONEncoder().encode(defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "progressBoardRules")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkjetConfiguration.self, from: legacy)
        XCTAssertNil(decoded.progressBoardRules)
        XCTAssertEqual(WorkjetBootstrap.normalized(decoded).progressBoardRules, WorkjetDefaults.progressBoardRules)

        var intentionallyEmpty = decoded
        intentionallyEmpty.progressBoardRules = ""
        XCTAssertEqual(WorkjetBootstrap.normalized(intentionallyEmpty).progressBoardRules, "")
    }

    func testPromptOrdersEveryVisibleSourceAndEscapesProgressBoardMarkers() {
        var configuration = WorkjetDefaults.configuration()
        configuration.skillRules = "GENERAL-ORDER-SENTINEL"
        configuration.progressBoardRules = "PROGRESS-ORDER-SENTINEL\n\(ManagedPrompt.progressBoardBeginMarker)"
        configuration.workers[0].instructions = "WORKER-ORDER-SENTINEL"
        let model = ModelPromptCatalog.canonicalName(for: configuration.workers[0].model)
        configuration.modelPrompts?[model] = "MODEL-ORDER-SENTINEL"
        configuration.adHocLearnings = "LEARNING-ORDER-SENTINEL"
        configuration.technicalRules = "TECHNICAL-ORDER-SENTINEL"

        let generated = String(decoding: ManagedPrompt.workerBody(configuration: configuration), as: UTF8.self)
        let effective = configuration.skillRules + "\n\n" + generated
        let orderedNeedles = [
            "GENERAL-ORDER-SENTINEL",
            "## Progress Board",
            "PROGRESS-ORDER-SENTINEL",
            "## Worker",
            "MODEL-ORDER-SENTINEL",
            "WORKER-ORDER-SENTINEL",
            "## Ad-hoc Learnings",
            "LEARNING-ORDER-SENTINEL",
            "## Technische Regeln",
            "TECHNICAL-ORDER-SENTINEL"
        ]
        let positions = orderedNeedles.map { needle in
            effective.range(of: needle).map { effective.distance(from: effective.startIndex, to: $0.lowerBound) }
        }
        XCTAssertTrue(positions.allSatisfy { $0 != nil })
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertEqual(generated.components(separatedBy: ManagedPrompt.progressBoardBeginMarker).count - 1, 1)
        XCTAssertTrue(generated.contains("WORKJET-PROGRESS-BOARD BEGIN -->"))
    }

    @MainActor
    func testProgressBoardEditUsesExistingSavePathAndPersistsAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-progress-board-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkjetPaths(
            homeDirectory: root,
            applicationSupportDirectory: root.appendingPathComponent("support"),
            stateDirectory: root.appendingPathComponent("state")
        )
        let model = WorkjetViewModel.live(paths: paths)
        model.progressBoardRules = "PERSISTED-PROGRESS-BOARD-SENTINEL"
        let flushed = await model.flushPersistence()
        XCTAssertTrue(flushed)

        let persisted = try XCTUnwrap(JSONConfigurationStore(fileURL: paths.configurationFile).load())
        XCTAssertEqual(persisted.progressBoardRules, "PERSISTED-PROGRESS-BOARD-SENTINEL")
        let reopened = WorkjetViewModel(configuration: persisted, persistenceDelay: 60)
        XCTAssertEqual(reopened.progressBoardRules, "PERSISTED-PROGRESS-BOARD-SENTINEL")
        XCTAssertTrue(reopened.promptPreview.contains("## Progress Board"))
        XCTAssertTrue(reopened.promptPreview.contains("PERSISTED-PROGRESS-BOARD-SENTINEL"))
    }

    func testDeletedTechnicalBlocksStayDeletedAcrossNormalizationAndRelaunchDecode() throws {
        var configuration = WorkjetDefaults.configuration()
        configuration.technicalRules = "USER-KEPT-ONLY"
        configuration.transparentWorkerPromptsMigrated = true

        let first = WorkjetBootstrap.normalized(configuration)
        XCTAssertEqual(first.technicalRules, "USER-KEPT-ONLY")
        XCTAssertFalse(first.technicalRules!.contains("WORKJET WORKER PREAMBLE"))

        let relaunched = try JSONDecoder().decode(WorkjetConfiguration.self, from: JSONEncoder().encode(first))
        let second = WorkjetBootstrap.normalized(relaunched)
        XCTAssertEqual(second.technicalRules, "USER-KEPT-ONLY")

        var deletedAll = second
        deletedAll.technicalRules = ""
        XCTAssertEqual(WorkjetBootstrap.normalized(deletedAll).technicalRules, "")
    }

    func testGeneratedWorkerFactsAreByteIdenticalToVisibleWorkerConfigurationSource() {
        var configuration = WorkjetDefaults.configuration()
        configuration.workers[0].reasoningEffort = .xhigh
        configuration.workers[0].invocation.options = ["speed": "fast"]
        let worker = configuration.workers[0]

        let visible = ManagedPrompt.generatedWorkerConfiguration(for: worker, configuration: configuration)
        let managed = String(decoding: ManagedPrompt.workerBody(configuration: configuration), as: UTF8.self)

        XCTAssertFalse(visible.isEmpty)
        XCTAssertEqual(managed.components(separatedBy: visible).count - 1, 1)
        XCTAssertTrue(visible.contains("- Reasoning: `xhigh`"))
        XCTAssertTrue(visible.contains("- Harness-Optionen: `speed=fast` (App-Fakt; nicht direkt ausführen)"))
    }

    func testLegacyMissingLoaderSourceGetsVisibleDefaultOnce() throws {
        let encoded = try JSONEncoder().encode(WorkjetDefaults.configuration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "skillLoaderInstructions")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkjetConfiguration.self, from: legacy)
        XCTAssertNil(decoded.skillLoaderInstructions)
        XCTAssertEqual(WorkjetBootstrap.normalized(decoded).skillLoaderInstructions, WorkjetDefaults.skillLoaderInstructions)
    }
}
