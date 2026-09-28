import XCTest

@MainActor final class RecordingInteractionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTappingKnobReturnsToNormalSizeWithoutChangingRecording() {
        for recording in [false, true] {
            let app = launch(scenario: recording ? "recording" : "empty")
            let slider = slider(in: app)
            waitForRecording(recording, in: app)
            let originalFrame = slider.frame
            let knob = slider.coordinate(withNormalizedOffset: CGVector(dx: recording ? 0.93 : 0.07, dy: 0.5))

            for duration in [0.05, 0.75] {
                knob.press(forDuration: duration)
                let returnedToNormalSize = NSPredicate { _, _ in
                    abs(slider.frame.width - originalFrame.width) <= 1
                        && abs(slider.frame.height - originalFrame.height) <= 1
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returnedToNormalSize, object: app)], timeout: 3), .completed)
                waitForRecording(recording, in: app)
                XCTAssertFalse(app.alerts["Save this recording?"].exists)
                capture(app, name: "Knob released without moving while \(recording ? "recording" : "ready")")
            }
            app.terminate()
        }
    }

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
        XCTAssertTrue(app.buttons["open-live-map"].exists)
        capture(app, name: "Map remains visible after saving")
        app.tabBars.buttons["Activities"].tap()
        XCTAssertEqual(activityRows(in: app).count, 4)
        app.tabBars.buttons["Map"].tap()
        waitForRecording(false, in: app)
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

    func testLiveMapSheetFitsRecordingMetricsAndHidesAfterSaving() {
        let app = launch(scenario: "long-recording")
        waitForRecording(true, in: app)
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        let icon = liveMetric("recording-status", in: app)
        let duration = liveMetric("duration", in: app)
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        XCTAssertTrue(icon.exists)
        XCTAssertFalse(liveMetric("elevation", in: app).exists)
        XCTAssertFalse(app.staticTexts["Elapsed time"].exists)
        XCTAssertFalse(app.staticTexts["Saved points"].exists)
        let scroll = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        let collapsedFrame = scroll.frame
        let summaryFrame = icon.frame.union(duration.frame)
        XCTAssertEqual(summaryFrame.midX, collapsedFrame.midX, accuracy: 1)
        for metric in ["distance", "ascent", "descent"] {
            XCTAssertFalse(liveMetric(metric, in: app).exists)
        }
        capture(app, name: "Collapsed recording icon and duration")

        app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex.last!.swipeUp()
        XCTAssertTrue(liveMetric("distance", in: app).waitForExistence(timeout: 10))
        let expandedFrame = scroll.frame
        XCTAssertGreaterThan(expandedFrame.height, collapsedFrame.height)
        XCTAssertLessThan(expandedFrame.height, app.frame.height * 0.4)
        for metric in ["distance", "ascent", "descent"] {
            let field = liveMetric(metric, in: app)
            XCTAssertTrue(field.exists)
            XCTAssertTrue(expandedFrame.contains(field.frame))
            XCTAssertNotEqual(field.value as? String, "—")
        }
        capture(app, name: "Expanded distance ascent and descent")

        app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex.last!.swipeDown()
        let collapsed = NSPredicate { _, _ in abs(scroll.frame.height - collapsedFrame.height) <= 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: collapsed, object: app)], timeout: 5), .completed)
        app.buttons["close-live-map"].tap()
        drag(slider(in: app), start: false)
        waitForRecording(false, in: app)
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        XCTAssertFalse(scroll.exists)
        XCTAssertFalse(liveMetric("elevation", in: app).exists)
        XCTAssertFalse(duration.exists)
        XCTAssertFalse(icon.exists)
        XCTAssertFalse(liveMetric("distance", in: app).exists)
        capture(app, name: "Live map without a recording")
    }

    func testIdleLiveMapHasNoDetailsSheetWhenLocationIsUnavailable() {
        let app = launch(scenario: "empty", location: "waiting")
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch.exists)
        XCTAssertFalse(liveMetric("elevation", in: app).exists)
        XCTAssertFalse(liveMetric("duration", in: app).exists)
        capture(app, name: "Idle live map waiting for location")
    }

    private func liveMetric(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "live-\(name)").firstMatch
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
            .press(forDuration: complete ? 0.1 : 1,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
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
