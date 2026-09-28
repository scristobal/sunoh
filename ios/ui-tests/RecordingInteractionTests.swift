import XCTest

@MainActor final class RecordingInteractionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSliderExplainsWhyRecordingCannotStart() {
        let cases = [
            (scenario: "empty", location: "waiting", message: "Waiting for location"),
            (scenario: "empty", location: "undetermined", message: "Location permission required"),
            (scenario: "empty", location: "denied", message: "Location access denied"),
            (scenario: "empty", location: "restricted", message: "Location access restricted"),
            (scenario: "storage-error", location: "ready", message: "Storage unavailable")
        ]
        for item in cases {
            let app = launch(scenario: item.scenario, location: item.location)
            let alert = app.alerts["Location access needed"]
            if alert.exists {
                if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap() }
                else { alert.buttons["OK"].tap() }
            }
            let slider = slider(in: app)
            XCTAssertEqual(slider.label, item.message)
            capture(app, name: item.message)
            drag(slider, start: true)
            XCTAssertEqual(slider.label, item.message)
            XCTAssertEqual(slider.value as? String, "Stopped")
            XCTAssertFalse(app.staticTexts["Slide to start recording"].exists)
            app.terminate()
        }
    }

    func testSliderStartsAndIncompleteDragsReturnToTheirEndpoint() {
        let app = launch(scenario: "empty")
        let slider = slider(in: app)
        waitForRecording(false, in: app)
        capture(app, name: "Ready to record")
        slider.tap()
        waitForRecording(false, in: app)
        drag(slider, start: true, complete: false)
        waitForRecording(false, in: app)
        XCTAssertEqual(slider.label, "Slide to start recording")

        drag(slider, start: true)
        waitForRecording(true, in: app)
        XCTAssertEqual(slider.label, "Slide to stop recording")
        capture(app, name: "Recording slider locked right")
        drag(slider, start: false, complete: false)
        waitForRecording(true, in: app)
        XCTAssertFalse(app.alerts["Save this recording?"].exists)
        app.tabBars.buttons["Activities"].tap()
        app.tabBars.buttons["Map"].tap()
        waitForRecording(true, in: app)
        drag(slider, start: false)
        let decision = app.alerts["Save this recording?"]
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        decision.buttons["Discard"].tap()
        waitForRecording(false, in: app)
    }

    func testShortRecordingCanBeSaved() {
        let app = launch(scenario: "recording")
        drag(slider(in: app), start: false)
        let decision = app.alerts["Save this recording?"]
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        XCTAssertTrue(decision.buttons["Save"].exists)
        XCTAssertTrue(decision.buttons["Discard"].exists)
        XCTAssertFalse(decision.buttons["Cancel"].exists)
        capture(app, name: "Short recording save or discard")
        decision.buttons["Save"].tap()
        let saving = app.descendants(matching: .any).matching(identifier: "saving-progress").firstMatch
        XCTAssertTrue(saving.waitForExistence(timeout: 5))
        capture(app, name: "Saving stopped recording")
        waitForRecording(false, in: app)
        app.tabBars.buttons["Activities"].tap()
        XCTAssertEqual(activityRows(in: app).count, 4)
    }

    func testShortRecordingCanBeDiscarded() {
        let app = launch(scenario: "recording")
        drag(slider(in: app), start: false)
        let decision = app.alerts["Save this recording?"]
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        decision.buttons["Discard"].tap()
        waitForRecording(false, in: app)
        XCTAssertEqual(slider(in: app).label, "Slide to start recording")
        app.tabBars.buttons["Activities"].tap()
        XCTAssertEqual(activityRows(in: app).count, 3)
    }

    func testNormalRecordingSavesAutomaticallyOnStop() {
        let app = launch(scenario: "long-recording")
        let slider = slider(in: app)
        waitForRecording(true, in: app)
        let originalFrame = slider.frame
        let preview = app.buttons["open-live-map"].frame
        XCTAssertEqual(originalFrame.width, preview.width, accuracy: 1)
        XCTAssertEqual(originalFrame.minX, preview.minX, accuracy: 1)
        for identifier in ["recording-start", "recording-pause", "recording-resume", "recording-save", "recording-discard"] {
            XCTAssertFalse(app.buttons[identifier].exists)
        }
        capture(app, name: "Full width recording slider")
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        app.buttons["close-live-map"].tap()
        waitForRecording(true, in: app)
        drag(slider, start: false)
        let saving = app.descendants(matching: .any).matching(identifier: "saving-progress").firstMatch
        XCTAssertTrue(saving.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Save this recording?"].exists)
        waitForRecording(false, in: app)
        XCTAssertEqual(slider.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(slider.frame.minY, originalFrame.minY, accuracy: 1)
        capture(app, name: "Automatically saved and ready")
        app.tabBars.buttons["Activities"].tap()
        XCTAssertEqual(activityRows(in: app).count, 4)
    }

    func testStoppedShortRecordingRestoresSaveDecision() {
        let app = launch(scenario: "stopped")
        let decision = app.alerts["Save this recording?"]
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        decision.buttons["Save"].tap()
        waitForRecording(false, in: app)
        app.tabBars.buttons["Activities"].tap()
        XCTAssertEqual(activityRows(in: app).count, 4)
    }

    private func launch(scenario: String, location: String = "ready") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = scenario
        app.launchEnvironment["SUNOH_UI_LOCATION"] = location
        app.launch()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        XCTAssertTrue(app.tabBars.buttons["Map"].waitForExistence(timeout: 15))
        return app
    }

    private func slider(in app: XCUIApplication) -> XCUIElement {
        let slider = app.descendants(matching: .any).matching(identifier: "recording-slider").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        return slider
    }

    private func drag(_ slider: XCUIElement, start: Bool, complete: Bool = true) {
        let from = start ? 0.07 : 0.93
        let to = complete ? 1 - from : 0.5
        slider.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
    }

    private func waitForRecording(_ recording: Bool, in app: XCUIApplication) {
        let slider = app.descendants(matching: .any).matching(identifier: "recording-slider").firstMatch
        let expected = NSPredicate { _, _ in
            slider.exists && slider.label == (recording ? "Slide to stop recording" : "Slide to start recording")
                && slider.value as? String == (recording ? "Recording" : "Stopped")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: app)], timeout: 15), .completed)
    }

    private func activityRows(in app: XCUIApplication) -> XCUIElementQuery {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        return rows
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
