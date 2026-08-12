import XCTest

final class WorkjetClickUITests: XCTestCase {
    private let completionID = "00000000-0000-0000-0000-000000000011"
    private let reviewerID = "00000000-0000-0000-0000-000000000012"
    private let uiWorkerID = "00000000-0000-0000-0000-000000000013"
    private let bulkWorkerID = "00000000-0000-0000-0000-000000000014"
    private let prototypeAWorkerID = "00000000-0000-0000-0000-000000000015"
    private let prototypeBWorkerID = "00000000-0000-0000-0000-000000000016"
    private let prototypeCWorkerID = "00000000-0000-0000-0000-000000000017"
    private let researchWorkerID = "00000000-0000-0000-0000-000000000018"
    private let providerID = "00000000-0000-0000-0000-000000000101"
    private let localComputerID = "00000000-0000-0000-0000-000000000001"
    private let readyComputerID = "00000000-0000-0000-0000-000000000002"
    private let failedComputerID = "00000000-0000-0000-0000-000000000003"
    private var app: XCUIApplication!
    private var isolatedHome: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let testName = name.replacingOccurrences(of: " ", with: "-")
        isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("workjet-ui-tests-" + testName, isDirectory: true)
        try? FileManager.default.removeItem(at: isolatedHome)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        app = configuredApplication()
        app.launch()
        XCTAssertTrue(app.windows["Workjet UI Test"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: isolatedHome)
    }

    func testNoOpExistingWorkerEditorKeepsReadyStateAndDoesNotSaveOrInspect() throws {
        let workerRow = app.groups["worker.row.\(completionID.uppercased())"]
        XCTAssertTrue(workerRow.waitForExistence(timeout: 3))
        let anyWorkerStatus = workerRow.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Workerstatus:")
        ).firstMatch
        XCTAssertTrue(anyWorkerStatus.waitForExistence(timeout: 3), "Der Worker muss vor dem Öffnen des Editors einen ehrlichen Status zeigen.")
        let statusBefore = anyWorkerStatus.label
        let recoveryVisibleBefore = app.buttons["status-banner.open-recovery"].exists

        let configurationFile = isolatedHome
            .appendingPathComponent("Library/Application Support/Workjet/config.v1.json")
        let configurationBefore = try Data(contentsOf: configurationFile)
        let modificationBefore = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: configurationFile.path)[.modificationDate] as? Date
        )
        app.buttons["worker.edit.\(completionID.uppercased())"].click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
        app.buttons["Schließen ohne Speichern"].click()
        XCTAssertTrue(anyWorkerStatus.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(anyWorkerStatus.label, statusBefore, "Ein unverändert geschlossener Editor darf den Workerstatus nicht verändern.")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "wird geprüft")).firstMatch.exists,
            "Das bloße Erscheinen eines bestehenden Editors darf keine Harness-Prüfung starten."
        )
        XCTAssertEqual(try Data(contentsOf: configurationFile), configurationBefore)
        let modificationAfter = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: configurationFile.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(modificationAfter, modificationBefore)
        XCTAssertTrue(anyWorkerStatus.exists)
        XCTAssertEqual(app.buttons["status-banner.open-recovery"].exists, recoveryVisibleBefore)
    }

    func testProductionWorkerAndSettingsClickJourney() throws {
        let completionPencil = app.buttons["worker.edit.\(completionID.uppercased())"]
        XCTAssertTrue(completionPencil.waitForExistence(timeout: 5))
        completionPencil.click()

        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["worker.editor.name"].value as? String, "Sol · Completion")
        XCTAssertTrue(app.buttons["worker.editor.harness.claude-code"].exists)
        XCTAssertTrue(app.buttons["worker.editor.model.gpt-5.6-sol"].exists)
        XCTAssertTrue(app.buttons["worker.editor.reasoning.high"].exists)
        for provider in ["Kimi", "OpenAI", "Anthropic", "Antigravity", "xAI", "MiniMax", "Z.ai"] {
            let providerButton = app.buttons["worker.editor.provider.\(provider)"]
            XCTAssertTrue(providerButton.exists)
            XCTAssertEqual(
                providerButton.value as? String,
                "Originalmarke",
                "Die Worker-Auswahl muss das echte Anbieterlogo für \(provider) zeigen."
            )
        }
        let taskField = app.descendants(matching: .any)["worker.editor.instructions"]
        scrollToHittable(taskField)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "worker.editor.instructions").count, 1,
                       "Der Worker-Editor darf genau eine Worker-Aufgabenquelle zeigen.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Modellregeln")).count, 0,
                       "Modellregeln gehören in die Einstellungen und dürfen im Worker-Editor nicht als zweites Aufgabenfeld erscheinen.")
        let greppyVersion = app.descendants(matching: .any)["worker.editor.skill.greppy.version"]
        scrollToHittable(greppyVersion)
        XCTAssertEqual(greppyVersion.label, "Greppy verwaltete Version 0.3.1")
        let webResearch = app.switches["worker.editor.skill.web-research"]
        scrollToHittable(webResearch)
        XCTAssertEqual((webResearch.value as? NSNumber)?.intValue, 0)
        webResearch.click()
        XCTAssertEqual((webResearch.value as? NSNumber)?.intValue, 1)

        scrollToHittable(app.textFields["worker.editor.name"])
        replaceText(in: app.textFields["worker.editor.name"], with: "Sol · Completion UI")
        let instructions = app.descendants(matching: .any)["worker.editor.instructions"]
        scrollToHittable(instructions)
        replaceText(in: instructions, with: "Persistierte Aufgabe aus dem echten Klicktest.")
        app.buttons["worker.editor.save"].click()

        XCTAssertTrue(app.staticTexts["Sol · Completion UI"].waitForExistence(timeout: 5))
        app.terminate()
        app = configuredApplication()
        app.launch()
        XCTAssertTrue(app.windows["Workjet UI Test"].waitForExistence(timeout: 8))

        app.buttons["worker.edit.\(completionID.uppercased())"].click()
        XCTAssertEqual(app.textFields["worker.editor.name"].value as? String, "Sol · Completion UI")
        let reopenedInstructions = app.descendants(matching: .any)["worker.editor.instructions"]
        XCTAssertTrue(reopenedInstructions.exists)
        XCTAssertEqual(reopenedInstructions.value as? String, "Persistierte Aufgabe aus dem echten Klicktest.")
        let reopenedWebResearch = app.switches["worker.editor.skill.web-research"]
        scrollToHittable(reopenedWebResearch)
        XCTAssertEqual((reopenedWebResearch.value as? NSNumber)?.intValue, 1)

        // The production provider sheet must expose the masked, non-secret
        // account identity and allow a selected route to be cleared again.
        let providerSetup = app.buttons["worker.editor.provider.setup"]
        XCTAssertTrue(providerSetup.waitForExistence(timeout: 5))
        scrollToHittable(providerSetup)
        providerSetup.click()
        XCTAssertTrue(app.descendants(matching: .any)["Anbieter und Zugang"].waitForExistence(timeout: 5))
        let account = app.buttons["provider.account.select.\(providerID)"]
        XCTAssertTrue(account.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(account.label.contains("ui…@example.invalid"))
        let pool = app.buttons["provider.pool.select.OpenAI"]
        XCTAssertTrue(pool.waitForExistence(timeout: 3))
        XCTAssertTrue(pool.isSelected)
        pool.click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))

        openProviderSetup()
        let deselectedPool = app.buttons["provider.pool.select.OpenAI"]
        XCTAssertFalse(deselectedPool.isSelected)
        deselectedPool.click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
        saveAndReopenCompletionEditor()
        openProviderSetup()
        XCTAssertTrue(app.buttons["provider.pool.select.OpenAI"].isSelected)
        app.buttons["provider.account.disconnect.\(providerID)"].click()
        let confirmDisconnect = app.sheets.buttons["UI Test OpenAI trennen"].firstMatch
        XCTAssertTrue(confirmDisconnect.waitForExistence(timeout: 3))
        confirmDisconnect.click()
        XCTAssertTrue(waitForNonexistence(app.buttons["provider.account.select.\(providerID)"], timeout: 10))
        app.buttons["Anbieter schließen"].click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
        app.buttons["Schließen ohne Speichern"].click()

        let recovery = app.buttons["worker.recover.\(reviewerID.uppercased())"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3), "Ein Worker ohne Anbieterroute muss direkt eine Recovery-Aktion zeigen.")
        XCTAssertTrue(["Anbieter wählen", "Anmelden", "API-Key"].contains(recovery.label))

        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))
        assertSettingsJump(button: "Ausführung", sectionID: "settings.section.execution")
        assertSettingsJump(button: "Telemetrie", sectionID: "settings.section.telemetry")
        assertSettingsJump(button: "Computer", sectionID: "settings.section.computers")
        assertSettingsJump(button: "Anbieter", sectionID: "settings.section.providers")
        assertSettingsJump(button: "Prompt", sectionID: "settings.section.prompt")

        assertSettingsJump(button: "Anbieter", sectionID: "settings.section.providers")
        let customButton = app.buttons["provider.custom.open"]
        XCTAssertTrue(customButton.waitForExistence(timeout: 3))
        customButton.click()
        XCTAssertTrue(app.textFields["provider.custom.name"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["provider.custom.endpoint"].exists)
    }

    func testAllSettingsQuickJumpsMakeTheirProductionSectionsHittable() {
        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))

        assertSettingsJump(button: "Prompt", sectionID: "settings.section.prompt")
        assertSettingsJump(button: "Anbieter", sectionID: "settings.section.providers")
        assertSettingsJump(button: "Computer", sectionID: "settings.section.computers")
        assertSettingsJump(button: "Telemetrie", sectionID: "settings.section.telemetry")
        assertSettingsJump(button: "Ausführung", sectionID: "settings.section.execution")
        // Der gleiche Sprung muss auch dann funktionieren, wenn er bereits
        // ausgewählt ist und die Scrollposition zwischenzeitlich verändert wurde.
        assertSettingsJump(button: "Prompt", sectionID: "settings.section.prompt")
        assertSettingsJump(button: "Prompt", sectionID: "settings.section.prompt")
    }

    func testPromptOwnerInlineEditorsPersistModelAndWorkerTextsIndependently() {
        let modelSentinel = "WJ-PRM-003 MODEL OWNER SENTINEL"
        let workerSentinel = "WJ-PRM-003 WORKER OWNER SENTINEL"
        let modelEditID = "settings.prompt.edit-model.gpt-5-6-sol"
        let modelTextID = "settings.prompt.model-text.gpt-5-6-sol"
        let workerEditID = "settings.prompt.edit-worker.\(completionID.uppercased())"
        let workerTextID = "settings.prompt.worker-text.\(completionID.uppercased())"

        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))
        app.buttons["Prompt"].click()

        let modelEdit = app.buttons[modelEditID]
        scrollSettingsToHittable(modelEdit)
        modelEdit.click()
        let modelText = app.descendants(matching: .any)[modelTextID]
        scrollSettingsToHittable(modelText)
        replaceText(in: modelText, with: modelSentinel)
        XCTAssertEqual(modelText.value as? String, modelSentinel)
        XCTAssertFalse((modelText.value as? String)?.contains(workerSentinel) ?? true)
        modelEdit.click()
        XCTAssertFalse(app.descendants(matching: .any)[modelTextID].exists)

        let workerEdit = app.buttons[workerEditID]
        scrollSettingsToHittable(workerEdit)
        workerEdit.click()
        let workerText = app.descendants(matching: .any)[workerTextID]
        scrollSettingsToHittable(workerText)
        replaceText(in: workerText, with: workerSentinel)
        XCTAssertEqual(workerText.value as? String, workerSentinel)
        XCTAssertFalse((workerText.value as? String)?.contains(modelSentinel) ?? true)
        workerEdit.click()
        XCTAssertFalse(app.descendants(matching: .any)[workerTextID].exists)

        let promptSection = app.descendants(matching: .any)["settings.section.prompt"]
        XCTAssertTrue(promptSection.exists, "Nach beiden Inline-Edits muss derselbe Promptbereich geöffnet bleiben.")
        XCTAssertTrue(app.buttons["Prompt"].isSelected, "Die Inline-Editoren dürfen den Promptbereich nicht verlassen.")
        XCTAssertTrue(app.staticTexts[modelSentinel].exists)
        XCTAssertTrue(app.staticTexts[workerSentinel].exists)

        app.buttons["Einstellungen schließen"].click()
        XCTAssertTrue(app.buttons["main.open-settings"].waitForExistence(timeout: 3))
        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))
        app.buttons["Prompt"].click()

        let reopenedModelEdit = app.buttons[modelEditID]
        scrollSettingsToHittable(reopenedModelEdit)
        reopenedModelEdit.click()
        let reopenedModelText = app.descendants(matching: .any)[modelTextID]
        scrollSettingsToHittable(reopenedModelText)
        XCTAssertEqual(reopenedModelText.value as? String, modelSentinel)
        XCTAssertFalse((reopenedModelText.value as? String)?.contains(workerSentinel) ?? true)
        reopenedModelEdit.click()

        let reopenedWorkerEdit = app.buttons[workerEditID]
        scrollSettingsToHittable(reopenedWorkerEdit)
        reopenedWorkerEdit.click()
        let reopenedWorkerText = app.descendants(matching: .any)[workerTextID]
        scrollSettingsToHittable(reopenedWorkerText)
        XCTAssertEqual(reopenedWorkerText.value as? String, workerSentinel)
        XCTAssertFalse((reopenedWorkerText.value as? String)?.contains(modelSentinel) ?? true)
        XCTAssertTrue(app.staticTexts["MODELL · GPT-5.6 SOL"].exists)
        XCTAssertTrue(app.staticTexts["WORKER · SOL · COMPLETION"].exists)
    }

    func testProgressBoardPromptSourcePersistsAcrossSettingsReopen() {
        let sentinel = "WJ-PROGRESS-BOARD-UI-SENTINEL"
        let sectionID = "settings.prompt.progress-board"
        let textID = "settings.prompt.progress-board-text"

        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))
        app.buttons["Prompt"].click()

        let section = app.descendants(matching: .any)[sectionID]
        XCTAssertTrue(section.waitForExistence(timeout: 3))
        let editor = app.descendants(matching: .any)[textID]
        scrollSettingsToHittable(editor)
        replaceText(in: editor, with: sentinel)
        XCTAssertEqual(editor.value as? String, sentinel)
        XCTAssertTrue(section.frame.intersects(app.windows["Workjet UI Test"].frame))

        app.buttons["Einstellungen schließen"].click()
        XCTAssertTrue(app.buttons["main.open-settings"].waitForExistence(timeout: 3))
        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))
        app.buttons["Prompt"].click()

        let reopenedSection = app.descendants(matching: .any)[sectionID]
        XCTAssertTrue(reopenedSection.waitForExistence(timeout: 3))
        let reopenedEditor = app.descendants(matching: .any)[textID]
        scrollSettingsToHittable(reopenedEditor)
        XCTAssertEqual(reopenedEditor.value as? String, sentinel)
        XCTAssertTrue(reopenedSection.frame.intersects(app.windows["Workjet UI Test"].frame))
    }

    func testWorkerActiveDividerDragChangesProductionGeometry() {
        let divider = app.descendants(matching: .any)["main.worker-active-divider"]
        XCTAssertTrue(divider.waitForExistence(timeout: 3))
        XCTAssertTrue(divider.isHittable)
        let before = divider.frame
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = start.withOffset(CGVector(dx: 0, dy: -90))

        start.press(forDuration: 0.1, thenDragTo: destination)

        for _ in 0..<30 {
            if divider.frame.minY < before.minY - 20 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertLessThan(divider.frame.minY, before.minY - 20)
    }

    func testRemoteActiveRunShowsObservedFactsAndOpensComputerRecovery() {
        app.terminate()
        app = configuredApplication(remoteRunFixture: true)
        app.launch()
        XCTAssertTrue(app.windows["Workjet UI Test"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts["Kimi · UI/UX"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["kimi-k3-256k · Reasoning high · Tempo schnell · Kimi Testzugang"].exists)
        XCTAssertTrue(app.staticTexts["Remote Ready · Verbindung unterbrochen · Arbeitet"].exists)

        let recovery = app.descendants(matching: .any)["active.recover.remote:ui-test-remote-run"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(recovery.isHittable, app.debugDescription)
        recovery.click()
        XCTAssertTrue(app.staticTexts["Computer bearbeiten"].waitForExistence(timeout: 3))
        app.buttons["Schließen ohne Speichern"].click()

        let stop = app.descendants(matching: .any)["active.stop.remote:ui-test-remote-run"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertTrue(stop.isHittable)
        stop.click()
        XCTAssertTrue(app.staticTexts["Worker stoppen?"].waitForExistence(timeout: 3))
        guard let cancelStop = waitForHittableButton(label: "Abbrechen") else {
            XCTFail("Der Stop-Dialog muss einen erreichbaren Abbrechen-Button anbieten.")
            return
        }
        cancelStop.click()
        XCTAssertTrue(stop.exists)
    }

    func testHeaderHealthWarningOpensImmediateRecoveryWithoutRegressingMainActions() {
        XCTAssertTrue(app.buttons["Computer Local"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["main.add-worker"].exists)
        XCTAssertTrue(app.buttons["worker.edit.\(completionID.uppercased())"].exists)

        let recovery = app.buttons["header.health-recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3))
        recovery.click()

        XCTAssertTrue(app.descendants(matching: .any)["Anbieter und Zugang"].waitForExistence(timeout: 3),
                      "Die Header-Warnung muss die erste konkrete Recovery direkt öffnen.")
    }

    func testSettingsExposeRealWorkerProbeCredentialRenewalAndHonestLocalPiBoundary() {
        app.buttons["main.open-settings"].click()
        assertSettingsJump(button: "Anbieter", sectionID: "settings.section.providers")

        let probe = app.buttons["settings.providers.probe-all"]
        XCTAssertTrue(probe.waitForExistence(timeout: 3))
        XCTAssertTrue(probe.isHittable)
        XCTAssertTrue(app.staticTexts["Noch keine echte Worker-Probe ausgeführt"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["provider.pool.health.OpenAI"].exists)

        let renewal = app.buttons["provider.account.renew.\(providerID)"]
        scrollToHittable(renewal)
        XCTAssertTrue(renewal.exists)
        XCTAssertEqual(renewal.label, "Schlüssel für UI Test OpenAI ersetzen")

        assertSettingsJump(button: "Computer", sectionID: "settings.section.computers")
        let localPiNote = app.staticTexts["settings.harness.local.pi-note"]
        scrollToHittable(localPiNote)
        XCTAssertTrue(localPiNote.exists)
        let localPiAccessibilityText = [localPiNote.label, localPiNote.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            localPiAccessibilityText.contains("Remote-Computern"),
            "Der lokale Pi-Code-Hinweis muss seinen Inhalt für VoiceOver liefern, tatsächlich: \(localPiAccessibilityText)"
        )
    }

    func testLongRuntimeStatusNeverCollapsesComputerChoices() {
        let local = app.buttons["Computer Local"]
        let remote = app.buttons["Computer Remote Ready"]
        let add = app.buttons["Computer hinzufügen"]

        XCTAssertTrue(local.waitForExistence(timeout: 3))
        XCTAssertTrue(remote.waitForExistence(timeout: 3))
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(local.frame.width, 54, "Local darf nicht zu einem leeren vertikalen Balken kollabieren: \(local.frame)")
        XCTAssertGreaterThanOrEqual(remote.frame.width, 100, "Der erste Remote-Computer muss seinen Namen lesbar behalten: \(remote.frame)")
        XCTAssertTrue(local.isHittable)
        XCTAssertTrue(remote.isHittable)
        XCTAssertTrue(add.isHittable)
    }

    func testNewTailscaleComputerUsesManagedIdentityWithoutLocalSSHKey() {
        let addComputer = app.buttons["Computer hinzufügen"]
        XCTAssertTrue(addComputer.waitForExistence(timeout: 5))
        addComputer.click()

        XCTAssertTrue(app.staticTexts["Computer einrichten"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["computer.tailscale.account.help"].exists)
        let linuxAccount = app.textFields["computer.tailscale.user"]
        XCTAssertTrue(linuxAccount.exists)
        XCTAssertTrue(((linuxAccount.value as? String) ?? "").isEmpty)
        XCTAssertTrue(app.buttons["computer.tailscale.setup"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "SSH-Benutzer")).count, 0)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "SSH-Schlüssel")).count, 0)
        XCTAssertEqual(app.buttons.matching(identifier: "computer.ssh-host-key.scan").count, 0)
    }

    func testLiveTailscaleDiscoveryListsConfiguredPeerWithoutShellEnvironment() throws {
        let liveConfiguration = URL(fileURLWithPath: "/tmp/workjet-live-tailscale-ui-discovery")
        guard let deviceName = try? String(contentsOf: liveConfiguration, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceName.isEmpty else {
            throw XCTSkip("Live-Tailscale-Gerätediscovery ist nur mit explizitem Ziel aktiv.")
        }

        let addComputer = app.buttons["Computer hinzufügen"]
        XCTAssertTrue(addComputer.waitForExistence(timeout: 5))
        addComputer.click()
        XCTAssertTrue(app.staticTexts["Computer einrichten"].waitForExistence(timeout: 3))

        let device = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "\(deviceName),")
        ).firstMatch
        XCTAssertTrue(
            device.waitForExistence(timeout: 15),
            "Die launchd-ähnliche App-Sitzung muss das reale Tailscale-Ziel ohne geerbtes SHLVL auflisten."
        )
        XCTAssertFalse(app.staticTexts["Die Tailscale-Geräteliste konnte nicht geladen werden. Versuche es erneut."].exists)
    }

    func testLiveTailscaleSetupShowsActionableRecoveryInsteadOfGenericPreflight() throws {
        let liveConfiguration = URL(fileURLWithPath: "/tmp/workjet-live-tailscale-ui-blocked")
        guard let contents = try? String(contentsOf: liveConfiguration, encoding: .utf8) else {
            throw XCTSkip("Live-Tailscale-Preflight ist nur mit explizitem Ziel aktiv.")
        }
        let values = contents.split(whereSeparator: \.isNewline).map(String.init)
        guard let deviceName = values.first else {
            XCTFail("Die Live-Tailscale-Preflight-Konfiguration braucht einen Gerätenamen.")
            return
        }

        app.buttons["Computer hinzufügen"].click()
        XCTAssertTrue(app.staticTexts["Computer einrichten"].waitForExistence(timeout: 3))
        let device = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "\(deviceName),")
        ).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 15))
        device.click()
        let linuxAccount = app.textFields["computer.tailscale.user"]
        if linuxAccount.exists {
            linuxAccount.click()
            linuxAccount.typeText(values.dropFirst().first ?? "deck")
        }
        let setup = app.buttons["computer.tailscale.setup"]
        scrollToHittable(setup)
        XCTAssertTrue(setup.isHittable)
        setup.click()

        let recoveryTitle = app.descendants(matching: .any)["computer.tailscale.recovery.title"]
        XCTAssertTrue(
            recoveryTitle.waitForExistence(timeout: 25),
            "Die Einrichtung muss eine konkrete Tailscale-Diagnose anzeigen. UI: \(app.debugDescription)"
        )
        let command = app.descendants(matching: .any)["computer.tailscale.recovery-command"]
        XCTAssertTrue(command.exists, "Recovery-Befehl fehlt. UI: \(app.debugDescription)")
        let commandText = [command.label, command.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            commandText.contains("sudo tailscale set --ssh") || commandText.hasPrefix("id "),
            "Die echte Einrichtung muss den konkreten Zielschritt benennen statt einen ungültigen Preflight zu melden. Befehl: \(commandText). UI: \(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["computer.tailscale.copy-activation-command"].exists)
        XCTAssertTrue(app.links["Tailscale-Anleitung"].exists)
        XCTAssertEqual(app.buttons["computer.tailscale.setup"].label, "Erneut prüfen & einrichten")
        XCTAssertFalse(app.staticTexts["Der Computer konnte nicht vollständig geprüft werden."].exists)
    }

    func testPencilTargetsExactWorkerAndEditorHasOneTaskSource() {
        let row = app.descendants(matching: .any)["worker.row.\(completionID.uppercased())"]
        let pencil = app.buttons["worker.edit.\(completionID.uppercased())"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(pencil.waitForExistence(timeout: 3))
        pencil.click()

        XCTAssertEqual(app.textFields["worker.editor.name"].value as? String, "Sol · Completion")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "worker.editor.instructions").count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Modellregeln")).count, 0)
    }

    func testExistingWorkerDeletionCanBeCancelledThenConfirmedAndPersists() {
        let rowID = "worker.row.\(reviewerID.uppercased())"
        let deleteID = "worker.editor.delete.\(reviewerID.uppercased())"
        let cancelID = "worker.editor.delete.cancel.\(reviewerID.uppercased())"
        let confirmID = "worker.editor.delete.confirm.\(reviewerID.uppercased())"
        XCTAssertTrue(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 3))
        app.buttons["worker.edit.\(reviewerID.uppercased())"].click()

        XCTAssertTrue(app.buttons[deleteID].waitForExistence(timeout: 3))
        app.buttons[deleteID].click()
        XCTAssertTrue(app.descendants(matching: .any)["worker.editor.delete.confirmation.\(reviewerID.uppercased())"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["„Kimi · Cyber & Review“ wirklich löschen?"].exists)
        XCTAssertTrue(app.buttons[cancelID].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[cancelID].isHittable)
        app.buttons[cancelID].click()
        XCTAssertFalse(app.buttons[confirmID].exists)
        app.buttons["Schließen ohne Speichern"].click()
        XCTAssertTrue(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 3), "Abbrechen darf den Worker nicht verändern.")

        app.buttons["worker.edit.\(reviewerID.uppercased())"].click()
        app.buttons[deleteID].click()
        XCTAssertTrue(app.buttons[confirmID].waitForExistence(timeout: 3))
        app.buttons[confirmID].click()
        XCTAssertFalse(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 5))

        app.terminate()
        app = configuredApplication()
        app.launch()
        XCTAssertTrue(app.windows["Workjet UI Test"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)[rowID].exists, "Bestätigtes Löschen muss den Relaunch überleben.")
    }

    func testProviderRecoveryOpensMatchingMiniMaxProvider() {
        let recovery = app.buttons["worker.recover.\(bulkWorkerID)"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3), "Der MiniMax-Worker muss seine Provider-Recovery zeigen.")
        XCTAssertEqual(recovery.label, "API-Key")
        recovery.click()

        XCTAssertTrue(app.descendants(matching: .any)["Anbieter und Zugang"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Name des Zugangs"].waitForExistence(timeout: 3),
                      "Die Recovery muss den passenden MiniMax-Abschnitt direkt öffnen.")
        XCTAssertTrue(app.secureTextFields["API-Key"].isHittable)
        XCTAssertTrue(app.buttons["Verbinden"].exists)
    }

    func testLocalComputerDirectChoiceAndWorkerTargetUseSeededFixture() {
        let localChoice = app.buttons["Computer Local"]
        let readyChoice = app.buttons["Computer Remote Ready"]
        let failedChoice = app.buttons["Computer Remote Offline"]
        XCTAssertTrue(localChoice.waitForExistence(timeout: 3))
        XCTAssertTrue(readyChoice.waitForExistence(timeout: 3))
        XCTAssertTrue(failedChoice.waitForExistence(timeout: 3))
        XCTAssertTrue(localChoice.isSelected)
        localChoice.click()
        XCTAssertTrue(localChoice.isSelected)
        assertVisibleWorkerIDs(localWorkerIDs)

        app.buttons["worker.edit.\(completionID.uppercased())"].click()
        let workerComputer = app.buttons["worker.editor.computer.\(localComputerID)"]
        scrollToHittable(workerComputer)
        XCTAssertTrue(workerComputer.isSelected)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "worker.editor.computer.")).count,
            3,
            "Der Produktionseditor muss Local und beide deterministischen Remote-Ziele direkt anbieten."
        )
        XCTAssertTrue(app.buttons["worker.editor.computer.\(readyComputerID)"].exists)
        XCTAssertTrue(app.buttons["worker.editor.computer.\(failedComputerID)"].exists)
    }

    func testDirectPeerFilteringWorkerMoveAndRelaunchPersistence() {
        let localChoice = app.buttons["Computer Local"]
        let readyChoice = app.buttons["Computer Remote Ready"]
        let failedChoice = app.buttons["Computer Remote Offline"]

        for choice in [localChoice, readyChoice, failedChoice] {
            XCTAssertTrue(choice.waitForExistence(timeout: 3), "Jeder Computer muss als direkter Button sichtbar sein.")
        }
        XCTAssertEqual(
            app.popUpButtons.matching(NSPredicate(format: "label IN %@", ["Computer Local", "Computer Remote Ready", "Computer Remote Offline"])).count,
            0,
            "Die Computerwahl darf nicht in ein Dropdown zurückfallen."
        )
        XCTAssertTrue(localChoice.isSelected)
        assertVisibleWorkerIDs(localWorkerIDs)

        clickComputer("Computer Remote Ready")
        XCTAssertTrue(waitForSelection("Computer Remote Ready"))
        assertVisibleWorkerIDs([uiWorkerID])

        clickComputer("Computer Remote Offline")
        XCTAssertTrue(waitForSelection("Computer Remote Offline"))
        assertVisibleWorkerIDs([])

        clickComputer("Computer Local")
        XCTAssertTrue(waitForSelection("Computer Local"))
        assertVisibleWorkerIDs(localWorkerIDs)
        app.buttons["worker.edit.\(completionID.uppercased())"].click()

        let readyTarget = app.buttons["worker.editor.computer.\(readyComputerID)"]
        scrollToHittable(readyTarget)
        readyTarget.click()
        XCTAssertTrue(readyTarget.isSelected)
        app.buttons["worker.editor.save"].click()
        let returnedToMain = app.buttons["Computer Local"].waitForExistence(timeout: 20)
        if !returnedToMain {
            let saveError = app.staticTexts.matching(identifier: "worker.editor.save.error").firstMatch
            XCTFail("save-error label=[\(saveError.label)] value=[\(String(describing: saveError.value))] exists=\(saveError.exists)")
            return
        }

        assertVisibleWorkerIDs(localWorkerIDs.subtracting([completionID]))
        clickComputer("Computer Remote Ready")
        XCTAssertTrue(waitForSelection("Computer Remote Ready"))
        assertVisibleWorkerIDs([completionID, uiWorkerID])

        // Saving once more while the remote peer is selected flushes both the
        // moved worker and the selected peer before the process is terminated.
        app.buttons["worker.edit.\(completionID.uppercased())"].click()
        let movedTarget = app.buttons["worker.editor.computer.\(readyComputerID)"]
        scrollToHittable(movedTarget)
        XCTAssertTrue(movedTarget.isSelected)
        app.buttons["worker.editor.save"].click()
        XCTAssertTrue(readyChoice.waitForExistence(timeout: 5))

        app.terminate()
        app = configuredApplication()
        app.launch()
        XCTAssertTrue(app.windows["Workjet UI Test"].waitForExistence(timeout: 8))

        let relaunchedReadyChoice = app.buttons["Computer Remote Ready"]
        XCTAssertTrue(relaunchedReadyChoice.waitForExistence(timeout: 3))
        XCTAssertTrue(relaunchedReadyChoice.isSelected, "Auch die direkte Computer-Auswahl muss den Relaunch überleben.")
        assertVisibleWorkerIDs([completionID, uiWorkerID])

        app.buttons["worker.edit.\(completionID.uppercased())"].click()
        let persistedTarget = app.buttons["worker.editor.computer.\(readyComputerID)"]
        scrollToHittable(persistedTarget)
        XCTAssertTrue(persistedTarget.isSelected, "Der Worker-Umzug muss in der Produktionskonfiguration persistiert sein.")
        app.buttons["Schließen ohne Speichern"].click()

        app.buttons["Computer Local"].click()
        assertVisibleWorkerIDs(localWorkerIDs.subtracting([completionID]))
        app.buttons["Computer Remote Ready"].click()
        assertVisibleWorkerIDs([completionID, uiWorkerID])
    }

    func testLiveTailscaleComputerSetupUsesManagedIdentityDeploysAndPersists() throws {
        let liveConfiguration = URL(fileURLWithPath: "/tmp/workjet-live-tailscale-ui-test")
        guard let contents = try? String(contentsOf: liveConfiguration, encoding: .utf8) else {
            throw XCTSkip("Live-Tailscale-Abnahme ist nur mit explizitem Ziel aktiv.")
        }
        let values = contents.split(whereSeparator: \.isNewline).map(String.init)
        guard let deviceName = values.first else {
            XCTFail("Die Live-Tailscale-Testkonfiguration muss einen Gerätenamen enthalten.")
            return
        }

        let addComputer = app.buttons["Computer hinzufügen"]
        XCTAssertTrue(addComputer.waitForExistence(timeout: 5))
        addComputer.click()
        XCTAssertTrue(app.staticTexts["Computer einrichten"].waitForExistence(timeout: 3))

        let device = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "\(deviceName),")
        ).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 15), "Das reale Tailscale-Ziel muss in der Geräteliste erscheinen.")
        XCTAssertTrue(device.isHittable)
        device.click()
        XCTAssertTrue(device.isSelected)

        let setup = app.buttons["computer.tailscale.setup"]
        scrollToHittable(setup)
        XCTAssertEqual(setup.label, "Über Tailscale einrichten")
        setup.click()

        XCTAssertTrue(
            app.buttons["Computer \(deviceName)"].waitForExistence(timeout: 90),
            "Tailscale-SSH-Deployment und persistentes Speichern müssen bis zur Hauptansicht durchlaufen."
        )
    }

    private func configuredApplication(remoteRunFixture: Bool = false) -> XCUIApplication {
        let application = XCUIApplication()
        let sidecarFixture = isolatedHome.appendingPathComponent("ctox-pi-sidecar.mjs")
        try? Data("export default {};\n".utf8).write(to: sidecarFixture, options: .atomic)
        application.launchEnvironment["WORKJET_UI_TEST_WINDOW"] = "1"
        application.launchEnvironment["WORKJET_UI_TEST_HOME"] = isolatedHome.path
        application.launchEnvironment["WORKJET_UI_TEST_SEED"] = "1"
        application.launchEnvironment["WORKJET_UI_TEST_SIDECAR_PATH"] = sidecarFixture.path
        application.launchEnvironment["SHLVL"] = ""
        if remoteRunFixture {
            application.launchEnvironment["WORKJET_UI_TEST_REMOTE_RUN"] = "1"
        }
        return application
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(.delete, modifierFlags: [])
        element.typeText(text)
    }

    private func assertSettingsJump(button label: String, sectionID: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        // A horizontally clipped SwiftUI button may still report `isHittable`
        // while its center lies behind the scroll view's clipping edge. Click
        // the visible leading portion so this test exercises the button action,
        // not XCTest's out-of-bounds center-point heuristic.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        XCTAssertTrue(button.isSelected, "Der Schnellsprung \(label) muss seine Auswahl anzeigen.")
        let section = app.descendants(matching: .any)[sectionID]
        XCTAssertTrue(section.waitForExistence(timeout: 3), "Der Abschnitt \(label) muss nach dem Klick existieren.")
        let window = app.windows["Workjet UI Test"]
        XCTAssertTrue(
            section.frame.intersects(window.frame),
            "Der Schnellsprung \(label) muss den Abschnitt wirklich in den sichtbaren Bereich scrollen. Abschnitt: \(section.frame), Fenster: \(window.frame)"
        )
    }

    private func assertVisibleWorkerIDs(_ expectedIDs: Set<String>, timeout: TimeInterval = 3) {
        let expected = Set(expectedIDs.map { "worker.row." + $0.uppercased() })
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "worker.row.")
        )
        let deadline = Date().addingTimeInterval(timeout)
        var actual: Set<String> = []
        repeat {
            actual = Set(rows.allElementsBoundByAccessibilityElement.map(\.identifier))
            if actual == expected { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTAssertEqual(actual, expected, "Die Computerfilterung muss exakt die erwarteten Worker-UUIDs zeigen.")
    }

    private var localWorkerIDs: Set<String> {
        [completionID, reviewerID, bulkWorkerID, prototypeAWorkerID, prototypeBWorkerID, prototypeCWorkerID, researchWorkerID]
    }

    private func clickComputer(_ label: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        if label == "Computer Local" {
            XCTAssertTrue(button.isHittable)
            button.click()
            return
        }
        let scroll = app.scrollViews["header.computer-scroll"]
        for _ in 0..<8 {
            let visibleWidth = scroll.frame.intersection(button.frame).width
            if button.isHittable, visibleWidth >= min(24, button.frame.width) { break }
            let next = app.buttons["header.computer-scroll.right"]
            XCTAssertTrue(next.exists && next.isEnabled)
            next.click()
        }
        XCTAssertTrue(button.isHittable && scroll.frame.intersection(button.frame).width >= min(24, button.frame.width))
        button.click()
    }

    private func waitForHittableButton(label: String, timeout: TimeInterval = 3) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = app.buttons.matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByAccessibilityElement
                .first(where: \.isHittable) {
                return button
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return app.buttons.matching(NSPredicate(format: "label == %@", label))
            .allElementsBoundByAccessibilityElement
            .first(where: \.isHittable)
    }

    private func waitForSelection(_ label: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.buttons[label].isSelected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return app.buttons[label].isSelected
    }

    private func waitForNonexistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return !element.exists
    }

    private func openProviderSetup() {
        let button = app.buttons["worker.editor.provider.setup"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        scrollUpToHittable(button)
        XCTAssertTrue(app.buttons["worker.editor.provider.setup"].isHittable)
        app.buttons["worker.editor.provider.setup"].click()
        XCTAssertTrue(app.descendants(matching: .any)["Anbieter und Zugang"].waitForExistence(timeout: 3))
    }

    private func scrollUpToHittable(_ element: XCUIElement, attempts: Int = 12) {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return }
            let scrollView = app.scrollViews["worker.editor.scroll"]
            XCTAssertTrue(scrollView.exists, "Der Worker-Editor muss seinen Scrollbereich exponieren.")
            scrollView.scroll(byDeltaX: 0, deltaY: 180)
        }
        XCTAssertTrue(element.isHittable, "Element konnte nicht nach oben sichtbar gescrollt werden: \(element)")
    }

    private func saveAndReopenCompletionEditor() {
        app.buttons["worker.editor.save"].click()
        let pencil = app.buttons["worker.edit.\(completionID.uppercased())"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 20))
        pencil.click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
    }

    private func scrollToHittable(_ element: XCUIElement, attempts: Int = 12) {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return }
            let editorScroll = app.scrollViews["worker.editor.scroll"]
            let scrollView = editorScroll.exists ? editorScroll : app.scrollViews.firstMatch
            XCTAssertTrue(scrollView.exists, "Die Produktionsansicht muss ihren echten Scrollbereich exponieren.")
            let deltaY: CGFloat
            if element.exists, element.frame.maxY < scrollView.frame.minY {
                deltaY = 180
            } else {
                deltaY = -180
            }
            scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTAssertTrue(element.isHittable, "Element konnte nicht in den sichtbaren Bereich gescrollt werden: \(element)")
    }

    private func scrollSettingsToHittable(_ element: XCUIElement, attempts: Int = 16) {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return }
            let scrollViews = app.scrollViews.allElementsBoundByIndex
            guard let settingsScroll = scrollViews.max(by: { $0.frame.height < $1.frame.height }) else {
                XCTFail("Die Einstellungen müssen ihren vertikalen Scrollbereich exponieren.")
                return
            }
            settingsScroll.scroll(byDeltaX: 0, deltaY: -190)
        }
        XCTAssertTrue(element.isHittable, "Prompt-Owner konnte nicht sichtbar gescrollt werden: \(element)")
    }
}
