import XCTest

final class WorkjetClickUITests: XCTestCase {
    private let completionID = "00000000-0000-0000-0000-000000000011"
    private let reviewerID = "00000000-0000-0000-0000-000000000012"
    private let providerID = "00000000-0000-0000-0000-000000000101"
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

    func testProductionWorkerAndSettingsClickJourney() throws {
        let completionPencil = app.buttons["worker.edit.\(completionID.uppercased())"]
        XCTAssertTrue(completionPencil.waitForExistence(timeout: 5))
        completionPencil.click()

        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["worker.editor.name"].value as? String, "Completion Engine")
        XCTAssertTrue(app.buttons["worker.editor.harness.claude-code"].exists)
        XCTAssertTrue(app.buttons["worker.editor.model.gpt-5.6-sol"].exists)
        XCTAssertTrue(app.buttons["worker.editor.reasoning.high"].exists)
        let taskField = app.descendants(matching: .any)["worker.editor.instructions"]
        scrollToHittable(taskField)
        scrollToHittable(app.descendants(matching: .any)["worker.editor.model-prompt.GPT-5.6 Sol"])

        replaceText(in: app.textFields["worker.editor.name"], with: "Completion Engine UI")
        let instructions = app.descendants(matching: .any)["worker.editor.instructions"]
        scrollToHittable(instructions)
        replaceText(in: instructions, with: "Persistierte Aufgabe aus dem echten Klicktest.")
        app.buttons["worker.editor.save"].click()

        XCTAssertTrue(app.staticTexts["Completion Engine UI"].waitForExistence(timeout: 5))
        app.terminate()
        app = configuredApplication()
        app.launch()
        XCTAssertTrue(app.windows["Workjet UI Test"].waitForExistence(timeout: 8))

        app.buttons["worker.edit.\(completionID.uppercased())"].click()
        XCTAssertEqual(app.textFields["worker.editor.name"].value as? String, "Completion Engine UI")
        let reopenedInstructions = app.descendants(matching: .any)["worker.editor.instructions"]
        XCTAssertTrue(reopenedInstructions.exists)
        XCTAssertEqual(reopenedInstructions.value as? String, "Persistierte Aufgabe aus dem echten Klicktest.")

        // The production provider sheet must expose the masked, non-secret
        // account identity and allow a selected route to be cleared again.
        app.buttons["worker.editor.provider.setup"].click()
        let account = app.buttons["provider.account.select.\(providerID)"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        XCTAssertTrue(account.label.contains("mi…@gmail.com"))
        XCTAssertTrue(account.isSelected)
        account.click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))

        app.buttons["worker.editor.provider.setup"].click()
        XCTAssertFalse(app.buttons["provider.account.select.\(providerID)"].isSelected)
        app.buttons["provider.account.select.\(providerID)"].click()
        app.buttons["worker.editor.provider.setup"].click()
        XCTAssertTrue(app.buttons["provider.account.select.\(providerID)"].isSelected)
        app.buttons["provider.account.disconnect.\(providerID)"].click()
        XCTAssertTrue(app.staticTexts["Worker bearbeiten"].waitForExistence(timeout: 3))
        app.buttons["worker.editor.provider.setup"].click()
        XCTAssertFalse(app.buttons["provider.account.select.\(providerID)"].exists)
        app.buttons["Anbieter schließen"].click()
        app.buttons["Schließen ohne Speichern"].click()

        let recovery = app.buttons["worker.recover.\(reviewerID.uppercased())"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3), "Ein Worker ohne Anbieterroute muss direkt eine Recovery-Aktion zeigen.")
        XCTAssertTrue(["Anbieter wählen", "Anmelden", "API-Key"].contains(recovery.label))

        app.buttons["main.open-settings"].click()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 3))
        app.buttons["Ausführung"].click()
        XCTAssertTrue(app.buttons["Ausführung"].isSelected)

        app.buttons["Anbieter"].click()
        XCTAssertTrue(app.buttons["Anbieter"].isSelected)
        let customButton = app.buttons["provider.custom.open"]
        XCTAssertTrue(customButton.waitForExistence(timeout: 3))
        customButton.click()
        XCTAssertTrue(app.textFields["provider.custom.name"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["provider.custom.endpoint"].exists)
    }

    private func configuredApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["WORKJET_UI_TEST_WINDOW"] = "1"
        application.launchEnvironment["WORKJET_UI_TEST_HOME"] = isolatedHome.path
        application.launchEnvironment["WORKJET_UI_TEST_SEED"] = "1"
        return application
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }

    private func scrollToHittable(_ element: XCUIElement, attempts: Int = 12) {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return }
            let editorScroll = app.scrollViews["worker.editor.scroll"]
            let scrollView = editorScroll.exists ? editorScroll : app.scrollViews.firstMatch
            XCTAssertTrue(scrollView.exists, "Die Produktionsansicht muss ihren echten Scrollbereich exponieren.")
            scrollView.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(element.isHittable, "Element konnte nicht in den sichtbaren Bereich gescrollt werden: \(element)")
    }
}
