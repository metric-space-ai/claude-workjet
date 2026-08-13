import Foundation
import XCTest
@testable import WorkjetCore

/// These tests are the non-visual half of the click stories documented in
/// `app/UITests/README.md`. They deliberately exercise the same public draft,
/// view-model, and prompt composition APIs used by the SwiftUI views.
@MainActor
final class ClickUserStoryContractTests: XCTestCase {
    private let completionID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    func testProductionBundleIsAgentOnlyAndLaunchServicesProhibitsMultipleInstances() throws {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "dev.workjet.menubar")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.1.0")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMultipleInstancesProhibited"] as? Bool, true)
    }

    func testAppOwnsExactlyOneAppKitStatusItemAndUITestWindowNeedsAllExplicitFlags() throws {
        let source = try sourceText("Sources/WorkjetApp/WorkjetApp.swift")
        XCTAssertEqual(source.components(separatedBy: "NSStatusBar.system.statusItem(").count - 1, 1)
        XCTAssertTrue(source.contains(#"item.autosaveName = "dev.workjet.menubar.status-item""#))
        XCTAssertTrue(source.contains("item.isVisible = true"))
        XCTAssertFalse(source.contains("MenuBarExtra"))
        XCTAssertTrue(source.contains("private let uiTestMode: Bool"))
        XCTAssertTrue(source.contains("environment[\"WORKJET_UI_TEST_WINDOW\"] == \"1\""))
        XCTAssertTrue(source.contains("environment[\"WORKJET_UI_TEST_SEED\"] == \"1\""))
        XCTAssertTrue(source.contains("testHome.hasPrefix(\"/\")"))
        XCTAssertTrue(source.contains("if uiTestMode {\n            showUITestWindow()"))
    }

    func testMenuBarRightClickExposesNativeStatusOpenSettingsAndQuitActions() throws {
        let app = try sourceText("Sources/WorkjetApp/WorkjetApp.swift")
        let root = try sourceText("Sources/WorkjetApp/RootView.swift")

        XCTAssertTrue(app.contains("button.sendAction(on: [.leftMouseUp, .rightMouseUp])"))
        XCTAssertTrue(app.contains("NSApp.currentEvent?.type == .rightMouseUp"))
        XCTAssertTrue(app.contains("Status: \\(model.runtimeSubtitle)"))
        for title in ["Workjet öffnen", "Einstellungen …", "Workjet beenden"] {
            XCTAssertTrue(app.contains(title), "Im nativen Kontextmenü fehlt: \(title)")
        }
        XCTAssertTrue(app.contains("NotificationCenter.default.post(name: .workjetOpenSettings"))
        XCTAssertTrue(root.contains("publisher(for: .workjetOpenSettings)"))
        XCTAssertTrue(app.contains("NSApp.terminate(nil)"))
    }

    func testMenuBarMarkIsAnEightBladeTurbineWithThreeUnambiguousStatusColors() throws {
        let app = try sourceText("Sources/WorkjetApp/WorkjetApp.swift")
        let mark = try sourceText("Sources/WorkjetApp/WorkjetMark.swift")
        XCTAssertTrue(mark.contains("for step in 0..<8"))
        XCTAssertTrue(mark.contains("front-facing turbofan"))
        XCTAssertFalse(mark.localizedCaseInsensitiveContains("paper plane"))
        XCTAssertFalse(mark.localizedCaseInsensitiveContains("arrow"))
        XCTAssertTrue(app.contains("case .ready: Color(nsColor: .labelColor)"))
        XCTAssertTrue(app.contains("case .active: Color(nsColor: .systemBlue)"))
        XCTAssertTrue(app.contains("case .attention: Color(nsColor: .systemOrange)"))
        XCTAssertTrue(app.contains("image?.isTemplate = status == .ready"))
    }

    func testBuildPackagesACompleteICNSAndRejectsMissingIconOutput() throws {
        let build = try sourceText("build-app.sh")
        for name in [
            "icon_16x16.png", "icon_16x16@2x.png",
            "icon_32x32.png", "icon_32x32@2x.png",
            "icon_128x128.png", "icon_128x128@2x.png",
            "icon_256x256.png", "icon_256x256@2x.png",
            "icon_512x512.png", "icon_512x512@2x.png"
        ] {
            XCTAssertTrue(build.contains(name), "missing iconset member \(name)")
        }
        XCTAssertTrue(build.contains("iconutil -c icns"))
        XCTAssertTrue(build.contains("[[ -s \"$contents/Resources/WorkjetAppIcon.icns\" ]]"))
        XCTAssertTrue(build.contains("plutil -lint \"$contents/Info.plist\""))
        XCTAssertTrue(build.contains("swift build -c release --arch arm64 --product workjet"))
        XCTAssertTrue(build.contains("--scratch-path \"$swift_scratch\""))
        XCTAssertTrue(build.contains("cp \"$bin_dir/workjet\" \"$contents/MacOS/workjet\""))
        XCTAssertTrue(build.contains("strip -S \"$executable\""))
    }

    func testReleasePipelineIsPinnedAtomicSignedAndInstallableWithoutLaunching() throws {
        let build = try sourceText("build-app.sh")
        let install = try sourceText("../install.sh")
        let providerLogo = try sourceText("Sources/WorkjetApp/ProviderLogo.swift")
        let app = try sourceText("Sources/WorkjetApp/WorkjetApp.swift")
        let project = try sourceText("Workjet.xcodeproj/project.pbxproj")
        let releaseWorkflow = try sourceText("../.github/workflows/release.yml")

        XCTAssertTrue(build.contains(#"release_inputs="$script_dir/ReleaseInputs""#))
        XCTAssertTrue(build.contains(#"sidecar_source="$release_inputs/ctox-pi-sidecar.mjs""#))
        XCTAssertTrue(build.contains(#"sidecar_manifest="$release_inputs/ctox-pi-sidecar.sha256""#))
        XCTAssertFalse(build.contains("../../ctox"))
        XCTAssertFalse(build.contains("WORKJET_PI_SIDECAR_BUNDLE"))
        XCTAssertTrue(build.contains("actual_sidecar_hash=$(shasum -a 256"))
        XCTAssertTrue(build.contains("mktemp -d \"$dist_dir/.workjet-build.XXXXXX\""))
        XCTAssertTrue(build.contains("WORKJET_ALLOW_ADHOC_SIGNING"))
        XCTAssertTrue(build.contains(#"signing_identity="${WORKJET_SIGNING_IDENTITY:-}""#))
        XCTAssertTrue(build.contains("WORKJET_REQUIRE_RELEASE_SIGNING"))
        XCTAssertTrue(build.contains("Release signing was required, but WORKJET_SIGNING_IDENTITY is empty."))
        XCTAssertFalse(build.contains("Developer ID Application:"))
        XCTAssertTrue(build.contains("--options runtime --timestamp"))
        XCTAssertLessThan(
            try XCTUnwrap(build.range(of: #"codesign --force --options runtime --timestamp --sign "$signing_identity" "$contents/MacOS/workjet""#))
                .lowerBound,
            try XCTUnwrap(build.range(of: #"codesign --force --options runtime --timestamp --sign "$signing_identity" "$new_bundle""#))
                .lowerBound
        )
        XCTAssertTrue(build.contains("codesign --verify --strict"))
        XCTAssertTrue(build.contains("WORKJET_NOTARY_PROFILE"))
        XCTAssertTrue(build.contains("xcrun notarytool submit"))
        XCTAssertTrue(build.contains("xcrun stapler staple"))
        XCTAssertTrue(build.contains("spctl --assess"))
        XCTAssertEqual(build.components(separatedBy: "ditto -c -k --norsrc --noextattr --keepParent").count - 1, 2)
        XCTAssertTrue(build.contains(#"ditto --norsrc --noextattr "$new_bundle" "$release_root/Workjet.app""#))
        XCTAssertTrue(build.contains("cp \"$repo_root/LICENSE\""))
        XCTAssertTrue(build.contains("THIRD_PARTY_NOTICES.md"))
        XCTAssertTrue(build.contains("WORKJET_HOME=\"$prompt_home\" \"$contents/MacOS/workjet\" workers list --json"))
        XCTAssertTrue(build.contains("default-workjet-agents.md"))
        XCTAssertTrue(build.contains("LaunchAgents/dev.workjet.menubar.plist"))

        XCTAssertFalse(providerLogo.contains("bundles.append(Bundle.module)"))
        XCTAssertTrue(providerLogo.contains("Workjet_WorkjetApp.bundle"))
        XCTAssertTrue(providerLogo.contains("bundles.append(Bundle.main)"))
        XCTAssertTrue(app.contains("#if DEBUG\n            if environment[\"WORKJET_PREVIEW\"]"))

        XCTAssertEqual(project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = dev.workjet.menubar").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "MARKETING_VERSION = 0.1.0").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "INFOPLIST_FILE = Info.plist").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "ENABLE_HARDENED_RUNTIME = YES").count - 1, 2)

        XCTAssertTrue(install.contains("APPLICATIONS_DIR=${WORKJET_APPLICATIONS_DIR:-/Applications}"))
        XCTAssertTrue(install.contains("needs_local_build=1"))
        XCTAssertTrue(install.contains("Workjet bundle is missing or incomplete; building a local verified artifact"))
        XCTAssertTrue(install.contains("Workjet is running. Quit Workjet"))
        XCTAssertTrue(install.contains("ditto \"$SOURCE_APP\""))
        XCTAssertTrue(install.contains("Previous.app"))
        XCTAssertTrue(install.contains("DEFAULT_PROMPT=\"$SOURCE_APP/Contents/Resources/default-workjet-agents.md\""))
        XCTAssertTrue(install.contains("cp -- \"$DEFAULT_PROMPT\" \"$prompt_stage_root/New.AGENTS.md\""))
        XCTAssertFalse(install.contains("cp -- \"$HERE/AGENTS.md\" \"$prompt_stage_root/New.AGENTS.md\""))
        XCTAssertFalse(install.contains("open \"$APP_DEST\""))
        XCTAssertFalse(install.contains("swift build"))
        XCTAssertTrue(install.contains("dev.workjet.menubar.launch-at-login"))
        XCTAssertTrue(install.contains("plutil -remove ProgramArguments.0"))
        XCTAssertTrue(install.contains("plutil -insert ProgramArguments.0 -string"))
        XCTAssertTrue(install.contains("Previous.plist"))

        XCTAssertTrue(releaseWorkflow.contains("AppleDouble metadata is forbidden"))
        XCTAssertTrue(releaseWorkflow.contains("-name '._*' -o -name '__MACOSX'"))
    }

    func testGlobalActivationCanBeRemovedWithoutDeletingConfigurationOrCredentials() throws {
        let cli = try sourceText("Sources/WorkjetCLI/main.swift")
        XCTAssertTrue(cli.contains(#"arguments == ["activation", "uninstall"]"#))
        XCTAssertTrue(cli.contains("uninstallGlobalInclude()"))
        XCTAssertTrue(cli.contains("Konfiguration, Zugänge und der verwaltete Prompt bleiben erhalten"))
    }

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

    func testExistingWorkerEditorDoesNotAutoInspectAndOnlyChecksAfterDeliberateSelection() throws {
        let source = try sourceText("Sources/WorkjetApp/WorkerEditorView.swift")

        XCTAssertFalse(source.contains(".task(id: lifecycleTaskID)"))
        XCTAssertFalse(source.contains("private var lifecycleTaskID"))
        XCTAssertTrue(source.contains(".onDisappear { cancelHarnessInspection() }"))
        XCTAssertTrue(source.contains("draft.selectHarness(adapter.harness)\n                            applyAdapterOptionDefaults()\n                            inspectSelectedHarness()"))
        XCTAssertTrue(source.contains("clearValidation(.computer)\n                            inspectSelectedHarness()"))
        XCTAssertTrue(source.contains("case .unknown, .checking:"))
        XCTAssertTrue(source.contains("let status = await model.inspectHarness(harness, on: selectedComputer)"))
        XCTAssertTrue(source.contains("guard status.state == .installed else"))
        XCTAssertTrue(source.contains("if worker == nil"))
    }

    func testWorkerProviderLogoTargetsTheProviderThatWasClicked() throws {
        let source = try sourceText("Sources/WorkjetApp/WorkerEditorView.swift")

        XCTAssertTrue(source.contains("providerToOpen = provider\n                            showProviderSetup = true"))
        XCTAssertTrue(source.contains("initiallyOpenProvider: providerToOpen"))
        XCTAssertTrue(source.contains("providerToOpen = nil\n                        showProviderSetup = true"))
    }

    func testEditorsUseDurableMutationsKeepFailuresInlineAndBlockDuplicateTaps() throws {
        let worker = try sourceText("Sources/WorkjetApp/WorkerEditorView.swift")
        let computer = try sourceText("Sources/WorkjetApp/ComputerEditorView.swift")

        XCTAssertTrue(worker.contains("let result = await model.saveWorkerDurably(saved)"))
        XCTAssertTrue(worker.contains("persistenceMessage = message"))
        XCTAssertTrue(worker.contains("worker.editor.save.error"))
        XCTAssertTrue(worker.contains(".disabled(saving || deleting)"))
        XCTAssertFalse(worker.contains("model.upsertWorker(saved)"))

        XCTAssertTrue(computer.contains("let result = await model.saveComputerDurably(saved)"))
        XCTAssertTrue(computer.contains("let result = await model.deleteComputerDurably(id: computer.id)"))
        XCTAssertTrue(computer.contains("validationMessage = message"))
        XCTAssertTrue(computer.contains("computer.editor.inline.error"))
        XCTAssertTrue(computer.contains("guard !persistenceOperationInFlight else { return }"))
        XCTAssertTrue(computer.contains(".disabled(computer?.isLocal == true || persistenceOperationInFlight || isDeploying)"))
        XCTAssertFalse(computer.contains("model.upsertComputer(saved)"))
        XCTAssertFalse(computer.contains("model.removeComputer(id: computer.id)"))
    }

    func testRemoteWorkerSavePersistsBeforeBackgroundProvisioningWhileComputerSetupStaysTransactional() throws {
        let worker = try sourceText("Sources/WorkjetApp/WorkerEditorView.swift")
        let computer = try sourceText("Sources/WorkjetApp/ComputerEditorView.swift")
        let model = try sourceText("Sources/WorkjetCore/ViewModel.swift")

        XCTAssertTrue(worker.contains("if selectedComputer?.isLocal == false"))
        XCTAssertTrue(worker.contains("startDurableSave()\n            return"))
        XCTAssertTrue(worker.contains("let result = await model.saveWorkerDurably(saved)"))
        XCTAssertTrue(model.contains("let result = await performDurableConfigurationMutation"))
        XCTAssertTrue(model.contains("Remote-Komponenten werden im Hintergrund eingerichtet."))
        XCTAssertTrue(model.contains("_ = await self.provisionRemoteWorker(worker, on: computer)"))
        XCTAssertTrue(model.range(of: "let result = await performDurableConfigurationMutation")!.lowerBound < model.range(of: "_ = await self.provisionRemoteWorker(worker, on: computer)")!.lowerBound)

        XCTAssertTrue(computer.contains("let provisioning = await model.provisionConfiguredWorkers(on: deployed)"))
        XCTAssertTrue(computer.contains("deploymentStatus = .failed"))
        XCTAssertTrue(computer.contains(#"Worker sind nicht bereit. \(failure.userVisibleDetail)"#))
        XCTAssertTrue(computer.range(of: "provisionConfiguredWorkers(on: deployed)")!.lowerBound < computer.range(of: "saveComputerDurably(deployed)")!.lowerBound)
    }

    func testComputerPrimarySetupUsesManagedTailscaleOrExplicitSSHTrustWithoutFallback() throws {
        let computer = try sourceText("Sources/WorkjetApp/ComputerEditorView.swift")

        XCTAssertTrue(computer.contains("if pendingHostKey == nil"))
        XCTAssertTrue(computer.contains("if usesManagedTailscaleSSH { deploy() }"))
        XCTAssertTrue(computer.contains("else { scanHostKey() }"))
        XCTAssertTrue(computer.contains("\"Über Tailscale einrichten\""))
        XCTAssertTrue(computer.contains("\"Erneut prüfen & einrichten\""))
        XCTAssertTrue(computer.contains("Button(\"Bestätigen & einrichten\") { confirmHostKey(pendingHostKey) }"))
        XCTAssertTrue(computer.contains("try model.confirmRemoteHostKey(candidate, for: target)"))
        XCTAssertTrue(computer.contains("deploymentDetail = \"Host-Key wurde bestätigt und privat gespeichert. Einrichtung wird erneut versucht.\"\n            deploy()"))
        XCTAssertFalse(computer.contains("Button(isDeploying ? \"Wird eingerichtet …\" : \"Einrichten & speichern\") { deploy() }"))
        XCTAssertTrue(computer.contains("Button(persistenceOperationInFlight ? \"Wird gespeichert …\" : \"Für später speichern\") { saveConnectionForLater() }"))
        XCTAssertTrue(computer.contains("let template = preferredRemoteDefaults"))
        XCTAssertTrue(computer.contains("draft.identityFilePath = template.identityFilePath"))
        XCTAssertTrue(computer.contains("Tailscale übernimmt Schlüssel und Geräteidentität"))
        XCTAssertTrue(computer.contains("label: \"Linux-Konto\""))
        XCTAssertTrue(computer.contains("!usesManagedTailscaleSSH,"))
        XCTAssertTrue(computer.contains("Workjet übernimmt es nicht von einem anderen Computer"))
        XCTAssertTrue(computer.contains("Button(\"Auf Tailscale SSH umstellen\")"))
    }

    func testProviderDeletionRequiresConfirmationUsesDurableAsyncAPIAndBlocksDuplicateActions() throws {
        let accounts = try sourceText("Sources/WorkjetApp/ProviderAccountsView.swift")

        XCTAssertTrue(accounts.contains(".confirmationDialog("))
        XCTAssertTrue(accounts.contains("let result = await model.deleteProviderDurably(id: account.id)"))
        XCTAssertTrue(accounts.contains("guard disconnectingAccountID == nil else { return }"))
        XCTAssertTrue(accounts.contains(".disabled(disconnectingAccountID != nil)"))
        XCTAssertTrue(accounts.contains("disconnectFailure = message"))
        XCTAssertTrue(accounts.contains("provider.account.delete.error"))
        XCTAssertFalse(accounts.contains("model.removeProvider"))
    }

    func testExistingProviderEditorUsesCancelableLocalDraftAndOneDurableSavePath() throws {
        let accounts = try sourceText("Sources/WorkjetApp/ProviderAccountsView.swift")
        let settings = try sourceText("Sources/WorkjetApp/SettingsView.swift")

        XCTAssertTrue(accounts.contains("@State private var accountDraft: Provider?"))
        XCTAssertTrue(accounts.contains("accountDraft = account"))
        XCTAssertTrue(accounts.contains("private func mutateDraft("))
        XCTAssertTrue(accounts.contains("TextField(\"Name\", text: draftBinding(\\.name))"))
        XCTAssertTrue(accounts.contains("SecureField(\"API-Key ersetzen (leer = bisherigen behalten)\", text: $accountSecret)"))
        XCTAssertTrue(accounts.contains("Button(\"Abbrechen\") { discardEditor() }"))
        XCTAssertTrue(accounts.contains("if accountDraft?.id == account.id {\n            discardEditor()"))
        XCTAssertTrue(accounts.contains("guard busyAccountID == nil, var draft = accountDraft else { return }"))
        XCTAssertTrue(accounts.contains("let result = await model.saveAndTestProviderDurably(draft, secret: secret)"))
        XCTAssertTrue(accounts.contains("TextEditor(text: localDraftTextBinding($accountModelsText))"))
        XCTAssertTrue(accounts.contains("draft.modelIDs = Provider.normalizedModels("))
        XCTAssertTrue(accounts.contains("provider.account.save.error"))
        XCTAssertTrue(accounts.contains(".disabled(inFlight || disconnectingAccountID != nil)"))
        XCTAssertTrue(accounts.contains(".disabled(providerDraftHasUnsavedChanges(draft))"))
        XCTAssertTrue(accounts.contains("typedModels != persisted.modelIDs"))
        XCTAssertTrue(accounts.contains("typedArguments != persisted.loginArguments"))
        XCTAssertTrue(accounts.contains("!accountSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        XCTAssertTrue(accounts.contains(".disabled(busyAccountID != nil || disconnectingAccountID != nil)"))
        XCTAssertFalse(accounts.contains("model.updateProvider("), "Keystrokes must never enter the view model.")
        XCTAssertFalse(accounts.contains("await model.testProvider(id:"), "The existing editor must use the durable typed transaction.")

        XCTAssertTrue(settings.contains("private struct AccessSettingsSection: View"))
        XCTAssertTrue(settings.contains("ProviderAccountsView()"))
        XCTAssertTrue(settings.contains("Alle Worker prüfen"))
        XCTAssertTrue(settings.contains("await model.probeAllWorkersNow()"))
        XCTAssertTrue(settings.contains("HarnessAdapterRegistry.local.map(\\.harness)"))
        XCTAssertTrue(providersContainRenewalAndRuntimeTruth(accounts))
        for removed in [
            "editingProviderID", "providerSecret", "testingProviderID", "pendingProviderDeletion",
            "providerEditor(", "providerBinding(", "providerEndpointBinding(", "updateCurrent("
        ] {
            XCTAssertFalse(settings.contains(removed), "Dead Settings provider editor helper remains: \(removed)")
        }
    }

    private func providersContainRenewalAndRuntimeTruth(_ source: String) -> Bool {
        source.contains("Neu anmelden")
            && source.contains("providerPoolPresentation(for: provider)")
            && source.contains("provider.pool.health.")
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
        XCTAssertTrue(model.runtimeHealthIssues.contains("\(configuration.workers.count - 1) Worker ohne Anbieterzugang"))
    }

    func testEveryWorkerGetsTruthfulOperationalStatusFromItsOwnDependencies() throws {
        var configuration = WorkjetDefaults.configuration()
        let provider = Provider(
            name: "Connected Sol",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            status: .connected,
            statusDetail: "Verbunden"
        )
        configuration.providers = [provider]
        configuration.workers[0].providerRoute = .account(provider.id)
        configuration.workers[1].providerRoute = nil
        let model = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)

        XCTAssertEqual(model.operationalStatus(for: configuration.workers[0]).state, .unverified)
        XCTAssertEqual(model.operationalStatus(for: configuration.workers[0]).label, "Harness nicht geprüft")
        XCTAssertEqual(model.operationalStatus(for: configuration.workers[1]).state, .unavailable)
        XCTAssertEqual(model.operationalStatus(for: configuration.workers[1]).label, "Anbieter fehlt")

        var missingHarness = configuration.workers[2]
        missingHarness.invocation.executable = ""
        XCTAssertEqual(model.operationalStatus(for: missingHarness).label, "Ausführungsart fehlt")

        let missingComputer = Worker(
            name: "Orphan",
            harness: .claudeCode,
            model: "gpt-5.6-sol",
            computerID: UUID(),
            providerID: provider.id,
            invocation: WorkerInvocation(executable: "claude")
        )
        XCTAssertEqual(model.operationalStatus(for: missingComputer).label, "Computer fehlt")
    }

    func testUnavailableWorkersExposeTheMatchingProviderRecovery() throws {
        var configuration = WorkjetDefaults.configuration()
        configuration.workers[0].providerRoute = nil
        configuration.workers[0].model = "gpt-5.6-sol"
        configuration.workers[1].providerRoute = nil
        configuration.workers[1].model = "MiniMax-M3"
        let model = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)

        XCTAssertEqual(model.providerRecovery(for: configuration.workers[0]), .connect(.openAI))
        XCTAssertEqual(model.providerRecovery(for: configuration.workers[1]), .configure(.miniMax))

        let account = Provider(
            name: "xAI Abo",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .xAI,
            status: .offline
        )
        configuration.providers = [account]
        configuration.workers[2].providerRoute = .account(account.id)
        configuration.workers[2].model = "grok-4.6"
        let offlineModel = WorkjetViewModel(configuration: configuration, persistenceDelay: 60)
        XCTAssertEqual(
            offlineModel.providerRecovery(for: configuration.workers[2]),
            .reauthenticate(accountID: account.id, provider: .xAI)
        )
    }

    func testCustomCompatibleEndpointConnectsAndSuppliesWorkerModels() async throws {
        let service = RecordingService()
        let model = WorkjetViewModel(
            configuration: WorkjetDefaults.configuration(),
            service: service,
            persistenceDelay: 60
        )

        let connectedAccount = await model.connectCustomProvider(
            name: "Internal Gateway",
            endpoint: "https://models.example/v1",
            authentication: .bearerToken,
            apiKey: "secret"
        )
        let account = try XCTUnwrap(connectedAccount)

        XCTAssertNil(account.modelProvider)
        XCTAssertEqual(account.endpoint, "https://models.example/v1")
        XCTAssertEqual(account.status, .connected)
        XCTAssertEqual(account.modelIDs, ["custom-code-1", "custom-code-2"])
        XCTAssertEqual(
            WorkerModelSuggestions.values(route: .account(account.id), providers: model.providers),
            ["custom-code-1", "custom-code-2"]
        )
    }

    func testMainPopoverUsesNativeResizableSplitAndActionableCompactHealthUI() throws {
        let main = try sourceText("Sources/WorkjetApp/MainView.swift")
        let root = try sourceText("Sources/WorkjetApp/RootView.swift")
        let active = try sourceText("Sources/WorkjetApp/ActiveAreaView.swift")
        let settings = try sourceText("Sources/WorkjetApp/SettingsView.swift")
        let workers = try sourceText("Sources/WorkjetApp/WorkerListView.swift")

        XCTAssertTrue(main.contains("GeometryReader"))
        XCTAssertTrue(main.contains("main.worker-active-divider"))
        XCTAssertTrue(main.contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(main.contains("minimumWorker = min(170"))
        XCTAssertTrue(main.contains("minimumActive = min(72"))
        XCTAssertTrue(main.contains("activePaneHeight ?? activePaneIdealHeight"))
        XCTAssertTrue(main.contains("header.health-recovery"))
        XCTAssertFalse(main.contains("Claude · Neustart erforderlich"))
        XCTAssertTrue(main.contains("Claude · Workjet aktuell"))
        XCTAssertFalse(main.contains("Claude Code · Workjet aktiv"), "Ein laufender Prozess beweist nicht, dass seine bereits geladene Sitzung den aktuellen Prompt kennt.")
        XCTAssertTrue(root.contains("status-banner.open-recovery"))
        XCTAssertTrue(root.contains("openRuntimeRecovery"))
        XCTAssertTrue(root.contains("displayMessage(for:"))
        XCTAssertFalse(active.contains("Aktivitätsdetails verfügbar"))
        XCTAssertFalse(active.contains("Details nach Abschluss"))
        XCTAssertTrue(active.contains("Laufzeitdetails nicht erfasst"))
        XCTAssertTrue(active.contains("weitere Details nicht erfasst"))
        for placeholder in ["Modell —", "Reasoning —", "Tempo —", "Anbieter —"] {
            XCTAssertFalse(active.contains(placeholder), "Historische Metadaten dürfen nicht als kryptische Gedankenstriche erscheinen: \(placeholder)")
        }

        XCTAssertTrue(settings.contains("ScrollViewReader"))
        XCTAssertTrue(settings.contains("proxy.scrollTo(section, anchor: .top)"))
        XCTAssertTrue(settings.contains("private func settingsNavigation"))
        XCTAssertFalse(settings.contains(".scrollPosition(id:"), "Ein erneuter Klick auf denselben Schnellsprung muss erneut scrollen können.")
        XCTAssertFalse(settings.contains("Erzeugte Worker-Konfiguration"))
        XCTAssertFalse(settings.contains("Skill-Loader"))
        XCTAssertFalse(settings.contains("YAML-Metadaten"))

        XCTAssertTrue(main.contains("model.toggleComputerSelection(computer.id)"))
        XCTAssertTrue(workers.contains(#"worker.edit.\(worker.id.uuidString)"#))
        XCTAssertTrue(workers.contains(#"worker.recover.\(worker.id.uuidString)"#))
    }

    func testUserFlowsKeepDiagnosticsOutOfVisibleCopyAndAccessibilityLabels() throws {
        let root = try sourceText("Sources/WorkjetApp/RootView.swift")
        let providers = try sourceText("Sources/WorkjetApp/ProviderAccountsView.swift")
        let settings = try sourceText("Sources/WorkjetApp/SettingsView.swift")
        let worker = try sourceText("Sources/WorkjetApp/WorkerEditorView.swift")

        XCTAssertTrue(root.contains(#"accessibilityLabel("\(visibleMessage). Öffnet die passende Stelle zur Behebung.")"#))
        XCTAssertFalse(root.contains(#"accessibilityLabel("Warnung öffnen: \(message)")"#))
        XCTAssertTrue(root.contains("Einstellungen prüfen"))

        XCTAssertFalse(providers.contains("Kapazität nicht verfügbar"))
        XCTAssertFalse(settings.contains("text: $model.skillLoaderInstructions"))
        XCTAssertTrue(settings.contains("model.generatedWorkerPreview"))
        XCTAssertTrue(settings.contains("settings.prompt.generated-worker-facts"))
        XCTAssertTrue(providers.contains("Priorität im Pool"))
        XCTAssertFalse(providers.contains("Quote/Rate nicht verfügbar"))
        XCTAssertFalse(providers.contains(#"Text("Reihenfolge")"#))

        XCTAssertTrue(worker.contains(#"WJSectionHeader(title: "Startbefehl")"#))
        XCTAssertTrue(worker.contains("Pi Code erhält nur die Dateien des aktuellen Auftrags."))
        for forbidden in ["Stabile Invocation", "Executable und Argumente", "NDJSON-Antwort", "Pi-Events post-hoc"] {
            XCTAssertFalse(worker.contains(forbidden), "Visible worker copy contains \(forbidden)")
        }
    }

    private func promptText(_ configuration: WorkjetConfiguration) throws -> String {
        try XCTUnwrap(String(data: ManagedPrompt.workerBody(configuration: configuration), encoding: .utf8))
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
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
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult {
        ProviderProbeResult(
            status: .connected,
            detail: "Verbindung geprüft.",
            modelIDs: ["custom-code-1", "custom-code-2"]
        )
    }
}
