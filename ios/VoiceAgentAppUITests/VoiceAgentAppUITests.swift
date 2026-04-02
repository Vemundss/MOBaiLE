import XCTest

final class VoiceAgentAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConfiguredEmptyPreviewShowsQuickStartAndReadyThread() {
        let app = launchApp(previewScenario: "configured-empty")

        XCTAssertTrue(app.staticTexts["Start with a focused task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start voice mode"].exists)

        threadToolbarButton(in: app).tap()

        XCTAssertTrue(app.staticTexts["New Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
    }

    func testConversationPreviewShowsThreadSwitcherMetadata() {
        let app = launchApp(previewScenario: "conversation")

        XCTAssertTrue(app.navigationBars.staticTexts["Run smoke test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Smoke test finished."].waitForExistence(timeout: 5))

        threadToolbarButton(in: app).tap()
        XCTAssertTrue(app.staticTexts["Dictate the next task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Draft"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Review repo changes"].waitForExistence(timeout: 5))
    }

    func testConversationPreviewShowsSettingsContext() {
        let app = launchApp(previewScenario: "conversation")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Current backend"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["demo.mobaile.app"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["app-preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Test"].exists)
    }

    func testRecordingPreviewShowsVoiceContextAndRecordingActions() {
        let app = launchApp(previewScenario: "recording")

        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Voice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Typed note + files included"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 attachments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Discard recording"].exists)
        XCTAssertTrue(app.buttons["Stop recording and send"].exists)
    }

    @discardableResult
    private func launchApp(previewScenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MOBAILE_PREVIEW_SCENARIO"] = previewScenario
        app.launch()
        return app
    }

    private func threadToolbarButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Threads,")).firstMatch
    }
}
