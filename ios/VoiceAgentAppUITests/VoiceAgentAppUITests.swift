import XCTest

final class VoiceAgentAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConfiguredEmptyPreviewShowsChatChromeAndThreadSwitcher() {
        let app = launchApp(previewScenario: "configured-empty")

        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Type or speak a prompt below."].exists)

        let threadButton = threadToolbarButton(in: app)
        XCTAssertTrue(threadButton.waitForExistence(timeout: 5))
        threadButton.tap()

        XCTAssertTrue(app.staticTexts["New Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
    }

    func testConfiguredEmptyPreviewKeepsComposerActiveWhileTyping() {
        let app = launchApp(previewScenario: "configured-empty")
        let composer = app.textViews["composer.textEditor"]

        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        composer.tap()
        composer.typeText("a")
        composer.typeText("b")

        let value = String(describing: composer.value)
        XCTAssertTrue(value.contains("ab"))
        XCTAssertTrue(app.buttons["Send prompt"].exists)
    }

    func testConversationPreviewShowsThreadSwitcherMetadata() {
        let app = launchApp(previewScenario: "conversation")

        XCTAssertTrue(app.navigationBars.staticTexts["MOBaiLE"].waitForExistence(timeout: 5))
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
        revealRuntimeSection(in: app)
        XCTAssertTrue(element(in: app, identifier: "settings.runtime.codexModel").exists)
        XCTAssertTrue(element(in: app, identifier: "settings.runtime.codexEffort").exists)

        revealAppearanceSection(in: app)

        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Light"].exists)
        XCTAssertTrue(app.buttons["Dark"].exists)
    }

    func testConversationPreviewOpensRunLogsSheet() {
        let app = launchApp(previewScenario: "conversation", previewPresentation: "logs")

        XCTAssertTrue(app.staticTexts["Run Highlights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Health"].exists)
        XCTAssertTrue(app.staticTexts["3 raw events"].exists)
        XCTAssertTrue(app.staticTexts["Preparing the release summary."].exists)
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Highlights"].exists)
    }

    func testConversationPreviewOpensWorkspaceBrowser() {
        let app = launchApp(previewScenario: "conversation", previewPresentation: "workspace")

        XCTAssertTrue(app.navigationBars.staticTexts["Workspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Future runs"].exists)
        XCTAssertTrue(app.staticTexts["Selected workspace"].exists)
        XCTAssertTrue(app.staticTexts["Browsing"].exists)
        XCTAssertTrue(app.staticTexts["Selected for future runs"].exists)
    }

    func testLiveActivityPreviewShowsStreamingCard() {
        let app = launchApp(previewScenario: "live-activity")

        XCTAssertTrue(app.staticTexts["Live Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Running the smoke test")).firstMatch.exists
        )
    }

    func testBlockedPreviewShowsSuggestedReplyRecovery() {
        let app = launchApp(previewScenario: "blocked")

        XCTAssertTrue(app.staticTexts["Continue this run"].waitForExistence(timeout: 5))
        app.buttons["Use Suggested Reply"].tap()

        let composer = app.textViews["composer.textEditor"]
        let value = String(describing: composer.value)
        XCTAssertTrue(value.contains("I approved the production gate"))
    }

    func testRecordingPreviewShowsVoiceContextAndRecordingActions() {
        let app = launchApp(previewScenario: "recording")

        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Voice mode")).firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 attachments")).firstMatch.exists
        )
        XCTAssertTrue(app.buttons["Stop voice mode"].exists)
        XCTAssertTrue(app.buttons["Send voice prompt"].exists)
    }

    func testRepairPreviewShowsScanAgainAction() {
        let app = launchApp(previewScenario: "repair")

        XCTAssertTrue(app.staticTexts["Reconnect this phone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan pairing QR again"].exists)
    }

    func testTimeoutPreviewShowsRetryAndRunLogsActions() {
        let app = launchApp(previewScenario: "timeout")

        XCTAssertTrue(app.staticTexts["Run timed out"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Retry Last Prompt"].exists)
        XCTAssertTrue(app.buttons["Open Run Logs"].exists)
    }

    func testRestoredRunningPreviewKeepsLiveActivityVisible() {
        let app = launchApp(previewScenario: "restored-running")

        XCTAssertTrue(app.staticTexts["Live Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Running the smoke test")).firstMatch.exists
        )
    }

    func testLivePairingPayloadCompletesAndDismissesConfirmation() throws {
        guard let pairingPayload = ProcessInfo.processInfo.environment["MOBAILE_E2E_PAIRING_PAYLOAD"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pairingPayload.isEmpty else {
            throw XCTSkip("Set MOBAILE_E2E_PAIRING_PAYLOAD to run the live pairing UI test.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["MOBAILE_UI_TESTING"] = "1"
        app.launchEnvironment["MOBAILE_TEST_PAIRING_PAYLOAD"] = pairingPayload
        app.launch()

        let confirmationTitle = app.navigationBars.staticTexts["Confirm Pairing"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["One-time pair code"].exists)

        app.buttons["Pair"].tap()

        XCTAssertTrue(confirmationTitle.waitUntilMissing(timeout: 30))
        XCTAssertFalse(app.staticTexts["Pairing failed"].exists)
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 10))
    }

    @discardableResult
    private func launchApp(previewScenario: String, previewPresentation: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MOBAILE_PREVIEW_SCENARIO"] = previewScenario
        if let previewPresentation {
            app.launchEnvironment["MOBAILE_PREVIEW_PRESENTATION"] = previewPresentation
        }
        app.launch()
        return app
    }

    private func threadToolbarButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Open chats"]
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func revealAppearanceSection(in app: XCUIApplication) {
        for _ in 0..<5 where !app.buttons["System"].exists {
            app.swipeUp()
        }
    }

    private func revealRuntimeSection(in app: XCUIApplication) {
        let codexModel = element(in: app, identifier: "settings.runtime.codexModel")
        let codexEffort = element(in: app, identifier: "settings.runtime.codexEffort")

        for _ in 0..<5 where !(codexModel.exists && codexEffort.exists) {
            app.swipeUp()
        }
    }
}

private extension XCUIElement {
    func waitUntilMissing(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
