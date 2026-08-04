import Foundation
import XCTest
@testable import WorkjetCore

/// These tests are the non-visual half of the click stories documented in
/// `app/UITests/README.md`. They deliberately exercise the same public draft,
/// view-model, and prompt composition APIs used by the SwiftUI views.
@MainActor
final class ClickUserStoryContractTests: XCTestCase {
    private let completionID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    func testPencilSelectionRoundTripsTheExactPersistedWorkerIdentityAndFields() throws {
        let original = try XCTUnwrap(
            WorkjetDefaults.configuration().workers.first { $0.id == completionID }
        )

        // Contract for tapping "Completion Engine bearbeiten": the editor draft
        // is derived from this exact Worker value, never from a name lookup,
        // default worker, or newly generated ID.
        let draft = WorkerDraft(worker: original)
        let reopened = try XCTUnwrap(draft.applied(to: original))

        XCTAssertEqual(reopened.id, completionID)
        XCTAssertEqual(reopened.name, original.name)
        XCTAssertEqual(reopened.harness, original.harness)
        XCTAssertEqual(reopened.model, original.model)
        XCTAssertEqual(reopened.instructions, original.instructions)
        XCTAssertEqual(reopened.reasoningEffort, original.reasoningEffort)
        XCTAssertEqual(reopened.computerID, original.computerID)
        XCTAssertEqual(reopened.providerRoute, original.providerRoute)
        XCTAssertEqual(reopened.invocation, original.invocation)
    }

    func testModelBlockShownForWorkerIsByteIdenticalToComposedPromptSource() throws {
        var configuration = WorkjetDefaults.configuration()
        let source = """
        - SOURCE SENTINEL: Sol completes difficult mandatory work.
        - Preserve acceptance criteria exactly.
        """
        configuration.modelPrompts?["GPT-5.6 Sol"] = source

        let editorValue = ModelPromptCatalog.prompt(for: "gpt-5.6-sol", in: configuration.modelPrompts ?? [:])
        let prompt = try promptText(configuration)
        let composedValue = try modelBlock(named: "GPT-5.6 Sol", in: prompt)

        XCTAssertEqual(editorValue, source)
        XCTAssertEqual(composedValue, source)
    }

    func testEditSaveReopenAndPromptCompositionUseTheSamePersistedValues() async throws {
        var configuration = WorkjetDefaults.configuration()
        let service = RecordingService()
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let original = try XCTUnwrap(model.workers.first { $0.id == completionID })

        var draft = WorkerDraft(worker: original)
        draft.name = "Completion Engine Updated"
        draft.model = "gpt-5.6-sol"
        draft.instructions = "WORKER SENTINEL: implement only the bounded brief."
        draft.reasoningEffort = .high
        let edited = try XCTUnwrap(draft.applied(to: original))
        model.upsertWorker(edited)
        model.setModelPrompt("MODEL SENTINEL: preserve scope and acceptance criteria.", for: edited.model)

        let didSave = await model.flushPersistence()
        XCTAssertTrue(didSave)
        configuration = try XCTUnwrap(service.lastSavedConfiguration)

        // Reopening the app/editor is modelled by constructing a fresh view
        // model and a fresh draft from the persisted configuration.
        let reopenedModel = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)
        let persisted = try XCTUnwrap(reopenedModel.workers.first { $0.id == completionID })
        let reopenedDraft = WorkerDraft(worker: persisted)
        XCTAssertEqual(reopenedDraft.name, "Completion Engine Updated")
        XCTAssertEqual(reopenedDraft.instructions, "WORKER SENTINEL: implement only the bounded brief.")
        XCTAssertEqual(reopenedDraft.reasoningEffort, .high)

        let prompt = reopenedModel.generatedPromptPreview
        XCTAssertTrue(prompt.contains("### @Completion-Engine-Updated — Completion Engine Updated"))
        XCTAssertTrue(prompt.contains("WORKER SENTINEL: implement only the bounded brief."))
        XCTAssertEqual(
            try modelBlock(named: "GPT-5.6 Sol", in: prompt),
            "MODEL SENTINEL: preserve scope and acceptance criteria."
        )
    }

    func testMissingProviderRouteNeverErasesModelReasoningOrWorkerPromptText() throws {
        var worker = try XCTUnwrap(
            WorkjetDefaults.configuration().workers.first { $0.id == completionID }
        )
        worker.providerRoute = nil
        worker.model = "gpt-5.6-sol"
        worker.reasoningEffort = .xhigh
        worker.instructions = "NO ROUTE SENTINEL: this remains editable and visible."

        let draft = WorkerDraft(worker: worker)
        XCTAssertNil(draft.providerRoute)
        XCTAssertEqual(draft.model, "gpt-5.6-sol")
        XCTAssertEqual(draft.reasoningEffort, .xhigh)
        XCTAssertEqual(draft.instructions, "NO ROUTE SENTINEL: this remains editable and visible.")

        var configuration = WorkjetDefaults.configuration()
        configuration.workers = [worker]
        let prompt = try promptText(configuration)
        XCTAssertTrue(prompt.contains("- Anbieter/Zugangsroute: Nicht konfiguriert"))
        XCTAssertTrue(prompt.contains("- Modell: `gpt-5.6-sol`"))
        XCTAssertTrue(prompt.contains("- Reasoning: `xhigh`"))
        XCTAssertTrue(prompt.contains("NO ROUTE SENTINEL: this remains editable and visible."))
        XCTAssertTrue(prompt.contains("SOURCE SENTINEL") == false)
        XCTAssertFalse(try modelBlock(named: "GPT-5.6 Sol", in: prompt).isEmpty)
    }

    func testComputerSelectionFiltersWorkersAndEditingMovesWorkerBetweenComputers() throws {
        let remote = Computer(name: "gpu3-a4500", transport: .tailscale, host: "gpu3-a4500", user: "workjet")
        var configuration = WorkjetDefaults.configuration()
        configuration.computers.append(remote)
        let model = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)

        model.toggleComputerSelection(remote.id)
        XCTAssertEqual(model.selectedComputerID, remote.id)
        XCTAssertTrue(model.visibleWorkers.isEmpty)

        let original = try XCTUnwrap(model.workers.first { $0.id == completionID })
        var draft = WorkerDraft(worker: original)
        draft.computerID = remote.id
        let moved = try XCTUnwrap(draft.applied(to: original))
        model.upsertWorker(moved)

        XCTAssertEqual(model.visibleWorkers.map(\.id), [completionID])
        XCTAssertEqual(model.visibleWorkers.first?.computerID, remote.id)
        XCTAssertEqual(WorkerDraft(worker: model.visibleWorkers.first).computerID, remote.id)

        model.toggleComputerSelection(WorkjetDefaults.localID)
        XCTAssertFalse(model.visibleWorkers.contains { $0.id == completionID })
    }

    func testWorkerHealthInputsRemainWorkerSpecific() throws {
        var configuration = WorkjetDefaults.configuration()
        let provider = Provider(
            name: "Connected Sol",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            status: .connected,
            statusDetail: "Connected",
            capacity: .measured(used: 20, limit: 100, unit: "requests", rateLimited: false)
        )
        configuration.providers = [provider]
        configuration.workers[0].providerRoute = .account(provider.id)
        configuration.workers[1].providerRoute = nil
        let model = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)

        XCTAssertEqual(model.effectiveCapacity(for: configuration.workers[0]).fraction, 0.2)
        XCTAssertNil(model.effectiveCapacity(for: configuration.workers[1]).fraction)
        XCTAssertEqual(model.effectiveCapacity(for: configuration.workers[1]).reason, WorkjetDefaults.unavailableCapacity.reason)
        XCTAssertTrue(model.runtimeHealthIssues.contains("3 Worker ohne verbundene Anbieterroute"))
    }

    private func promptText(_ configuration: WorkjetConfiguration) throws -> String {
        try XCTUnwrap(String(data: ManagedPrompt.workerBody(configuration: configuration), encoding: .utf8))
    }

    private func modelBlock(named name: String, in prompt: String) throws -> String {
        let begin = "<!-- WORKJET MODEL PROMPT BEGIN \(name) -->"
        let end = "<!-- WORKJET MODEL PROMPT END \(name) -->"
        let beginRange = try XCTUnwrap(prompt.range(of: begin))
        let endRange = try XCTUnwrap(prompt.range(of: end, range: beginRange.upperBound..<prompt.endIndex))
        return String(prompt[beginRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class RecordingService: WorkjetService, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: WorkjetConfiguration?

    var lastSavedConfiguration: WorkjetConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
        lock.lock()
        saved = configuration
        lock.unlock()
    }

    func runs(workers: [Worker]) -> [RunRecord] { [] }
    func stop(_ run: ActiveRun) throws {}
    func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
        CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "test", capacity: .unavailable(reason: "test"))
    }
    func storeCredential(_ secret: Data, reference: String) throws {}
}
