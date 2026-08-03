import XCTest
@testable import WorkjetCore

final class WorkerFilterTests: XCTestCase {
    private let localID = PreviewData.localComputer.id
    private let devboxID = PreviewData.devbox.id

    func testEmptyQueryReturnsAllWorkers() {
        let result = WorkerFilter.filtered(PreviewData.workers, query: "", computerID: nil)
        XCTAssertEqual(result.count, PreviewData.workers.count)
    }

    func testQueryMatchesNameCaseInsensitively() {
        let result = WorkerFilter.filtered(PreviewData.workers, query: "completion", computerID: nil)
        XCTAssertEqual(result.map(\.name), ["Completion Engine"])
    }

    func testQueryMatchesModel() {
        let result = WorkerFilter.filtered(PreviewData.workers, query: "minimax", computerID: nil)
        XCTAssertEqual(result.map(\.name), ["Bulk Worker"])
    }

    func testComputerFilterNarrowsResults() {
        let result = WorkerFilter.filtered(PreviewData.workers, query: "", computerID: devboxID)
        XCTAssertEqual(result.map(\.name), ["UI/UX-Experte"])
    }

    func testQueryAndComputerCompose() {
        let result = WorkerFilter.filtered(PreviewData.workers, query: "kimi", computerID: localID)
        XCTAssertEqual(result.map(\.name), ["Reviewer"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(WorkerFilter.filtered(PreviewData.workers, query: "zzz", computerID: nil).isEmpty)
    }
}

final class DurationFormatterTests: XCTestCase {
    func testSeconds() {
        XCTAssertEqual(DurationFormatter.string(for: 47), "47s")
        XCTAssertEqual(DurationFormatter.string(for: 0), "0s")
    }

    func testMinutesAndSeconds() {
        XCTAssertEqual(DurationFormatter.string(for: 192), "3m 12s")
        XCTAssertEqual(DurationFormatter.string(for: 59.9), "59s")
        XCTAssertEqual(DurationFormatter.string(for: 60), "1m 0s")
    }

    func testHours() {
        XCTAssertEqual(DurationFormatter.string(for: 3725), "1h 2m")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(DurationFormatter.string(for: -5), "0s")
    }
}

final class SkillPromptTests: XCTestCase {
    func testContainsRulesAndFableStatement() {
        let prompt = SkillPrompt.compose(
            rules: "Regeln hier.",
            activation: .skillOnly,
            injectWorkers: true,
            workers: PreviewData.workers
        )
        XCTAssertTrue(prompt.contains("Regeln hier."))
        XCTAssertTrue(prompt.contains(SkillPrompt.fableStatement))
        XCTAssertTrue(prompt.contains("Fable erhält Skill + Worker-Deklarationen"))
    }

    func testWorkerDeclarationsAppendedWhenInjectionEnabled() {
        let prompt = SkillPrompt.compose(
            rules: "R",
            activation: .global,
            injectWorkers: true,
            workers: PreviewData.workers
        )
        for worker in PreviewData.workers {
            XCTAssertTrue(prompt.contains(worker.name), "missing \(worker.name)")
            XCTAssertTrue(prompt.contains(worker.model))
        }
        XCTAssertTrue(prompt.contains("## Worker-Deklarationen"))
    }

    func testWorkerDeclarationsOmittedWhenInjectionDisabled() {
        let prompt = SkillPrompt.compose(
            rules: "R",
            activation: .skillOnly,
            injectWorkers: false,
            workers: PreviewData.workers
        )
        XCTAssertFalse(prompt.contains("## Worker-Deklarationen"))
        XCTAssertFalse(prompt.contains("Completion Engine"))
        // Fable statement stays regardless.
        XCTAssertTrue(prompt.contains(SkillPrompt.fableStatement))
    }

    func testActivationIsReflected() {
        let skill = SkillPrompt.compose(rules: "", activation: .skillOnly, injectWorkers: false, workers: [])
        let global = SkillPrompt.compose(rules: "", activation: .global, injectWorkers: false, workers: [])
        XCTAssertTrue(skill.contains("Skill (/workjet)"))
        XCTAssertTrue(global.contains("Global"))
    }
}

final class DraftValidationTests: XCTestCase {
    func testWorkerDraftInvalidWhenEmpty() {
        XCTAssertFalse(WorkerDraft().isValid)
    }

    func testWorkerDraftValidWhenComplete() {
        var draft = WorkerDraft()
        draft.name = "Reviewer"
        draft.model = "Kimi K3"
        draft.computerID = PreviewData.localComputer.id
        XCTAssertTrue(draft.isValid)
        let worker = draft.applied(to: nil)
        XCTAssertEqual(worker?.name, "Reviewer")
        XCTAssertEqual(worker?.harness, .claudeCode)
        XCTAssertEqual(worker?.computerID, PreviewData.localComputer.id)
    }

    func testWorkerDraftTrimsWhitespace() {
        var draft = WorkerDraft()
        draft.name = "  Bulk Worker  "
        draft.model = " MiniMax M3 "
        draft.computerID = PreviewData.localComputer.id
        XCTAssertEqual(draft.applied(to: nil)?.name, "Bulk Worker")
    }

    func testWorkerDraftPreservesIDAndQuotaWhenEditing() {
        let existing = PreviewData.workers[0]
        var draft = WorkerDraft(worker: existing)
        draft.name = "Completion Engine v2"
        let updated = draft.applied(to: existing)
        XCTAssertEqual(updated?.id, existing.id)
        XCTAssertEqual(updated?.quota, existing.quota)
        XCTAssertEqual(updated?.name, "Completion Engine v2")
    }

    func testComputerDraftValidation() {
        var draft = ComputerDraft()
        XCTAssertFalse(draft.isValid)
        draft.name = "devbox"
        draft.host = "devbox.ts.net"
        XCTAssertTrue(draft.isValid)
        draft.port = 0
        XCTAssertFalse(draft.isValid)
    }

    func testComputerDraftDefaultsToTailscaleForNewComputer() {
        XCTAssertEqual(ComputerDraft().transport, .tailscale)
    }
}

final class ViewModelTests: XCTestCase {
    private final class SpyService: WorkjetService {
        var persistedWorkers: [Worker] = []
        var persistedComputers: [Computer] = []
        var persistedProviders: [Provider] = []
        var stoppedRunIDs: [UUID] = []

        func persistWorker(_ worker: Worker) { persistedWorkers.append(worker) }
        func persistComputer(_ computer: Computer) { persistedComputers.append(computer) }
        func persistProvider(_ provider: Provider) { persistedProviders.append(provider) }
        func stopRun(id: UUID) { stoppedRunIDs.append(id) }
    }

    func testUpsertWorkerInsertsAndPersists() {
        let spy = SpyService()
        let model = PreviewData.makeViewModel(service: spy)
        let count = model.workers.count
        let worker = Worker(name: "Neuer Worker", harness: .piSidecar, model: "Kimi K3", computerID: PreviewData.localComputer.id)
        model.upsertWorker(worker)
        XCTAssertEqual(model.workers.count, count + 1)
        XCTAssertEqual(spy.persistedWorkers.count, 1)
    }

    func testUpsertWorkerUpdatesInPlace() {
        let spy = SpyService()
        let model = PreviewData.makeViewModel(service: spy)
        var worker = model.workers[0]
        worker.model = "GPT-5.7"
        model.upsertWorker(worker)
        XCTAssertEqual(model.workers.count, PreviewData.workers.count)
        XCTAssertEqual(model.workers[0].model, "GPT-5.7")
    }

    func testToggleComputerSelection() {
        let model = PreviewData.makeViewModel()
        let id = PreviewData.devbox.id
        XCTAssertNil(model.selectedComputerID)
        model.toggleComputerSelection(id)
        XCTAssertEqual(model.selectedComputerID, id)
        model.toggleComputerSelection(id)
        XCTAssertNil(model.selectedComputerID)
    }

    func testVisibleWorkersRespectSelectionAndSearch() {
        let model = PreviewData.makeViewModel()
        model.toggleComputerSelection(PreviewData.builder.id)
        XCTAssertEqual(model.visibleWorkers.map(\.name), ["Bulk Worker"])
        model.searchQuery = "nix gefunden"
        XCTAssertTrue(model.visibleWorkers.isEmpty)
    }

    func testStopRunRemovesRunAndNotifiesService() {
        let spy = SpyService()
        let model = PreviewData.makeViewModel(service: spy)
        let runID = model.activeRuns[0].id
        model.stopRun(id: runID)
        XCTAssertFalse(model.activeRuns.contains { $0.id == runID })
        XCTAssertEqual(spy.stoppedRunIDs, [runID])
    }

    func testPromptPreviewComposesFromCurrentState() {
        let model = PreviewData.makeViewModel()
        XCTAssertTrue(model.promptPreview.contains("## Worker-Deklarationen"))
        model.injectWorkerDeclarations = false
        XCTAssertFalse(model.promptPreview.contains("## Worker-Deklarationen"))
        XCTAssertTrue(model.promptPreview.contains(SkillPrompt.fableStatement))
    }

    func testLocalComputerIsPresent() {
        let model = PreviewData.makeViewModel()
        XCTAssertTrue(model.computers.contains { $0.isLocal })
    }
}

final class QuotaStatusTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(QuotaStatus(usedPercent: 0.2, rateLimited: false).level, .ok)
        XCTAssertEqual(QuotaStatus(usedPercent: 0.75, rateLimited: false).level, .warning)
        XCTAssertEqual(QuotaStatus(usedPercent: 0.95, rateLimited: true).level, .critical)
    }

    func testPercentClamped() {
        XCTAssertEqual(QuotaStatus(usedPercent: 1.4, rateLimited: false).usedPercent, 1)
        XCTAssertEqual(QuotaStatus(usedPercent: -0.2, rateLimited: false).usedPercent, 0)
    }
}
