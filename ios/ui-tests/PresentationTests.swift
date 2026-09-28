import XCTest

@MainActor final class PresentationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testLargestText() throws {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL")
        try audit(app, name: "map-accessibility")
        app.tabBars.buttons["Activities"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 15))
        try audit(app, name: "activities-accessibility")
        activity.tap()
        XCTAssertTrue(app.buttons["open-activity-map"].waitForExistence(timeout: 10))
        try audit(app, name: "overview-accessibility")
        let scroll = app.scrollViews["activity-overview-scroll"]
        let delete = app.buttons["delete-activity"]
        reveal(delete, in: scroll, app: app)
        XCTAssertTrue(delete.isHittable)
        try audit(app, name: "activity-bottom-accessibility")
        delete.tap()
        XCTAssertTrue(app.alerts["Delete Activity?"].waitForExistence(timeout: 5))
        try audit(app, name: "delete-confirmation-accessibility", systemPresentation: true)
        app.alerts.buttons["Cancel"].tap()
        reveal(delete, in: scroll, app: app)
        XCTAssertTrue(delete.isHittable)
        reveal(app.buttons["open-activity-map"], in: scroll, app: app, direction: .down)
        app.buttons["open-activity-map"].tap()
        XCTAssertTrue(app.buttons["close-activity-details"].waitForExistence(timeout: 10))
        try audit(app, name: "compact-activity-accessibility")
        XCTAssertFalse(app.scrollViews["map-details-scroll"].buttons["delete-activity"].exists)
        expandSheet(app)
        try audit(app, name: "expanded-activity-accessibility")
        XCTAssertFalse(app.scrollViews["map-details-scroll"].buttons["delete-activity"].exists)
        app.buttons["close-activity-details"].tap()
        XCTAssertTrue(app.buttons["open-activity-map"].waitForExistence(timeout: 10))
    }

    func testLiveMapRecordingDetails() throws {
        let app = launch(scenario: "recording", location: "ready")
        assertMapStatus(app, status: "Recording")
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        assertCollapsedRecordingDetails(app, status: "Recording")
        let collapsedHeight = recordingSheet(app).frame.height
        try audit(app, name: "compact-live-map")
        expandSheet(app)
        assertRecordingDetails(app)
        XCTAssertGreaterThan(recordingSheet(app).frame.height, collapsedHeight)
        try audit(app, name: "expanded-live-map")
        collapseRecordingSheet(app, to: collapsedHeight)
        assertCollapsedRecordingDetails(app, status: "Recording")
        XCTAssertEqual(recordingSheet(app).frame.height, collapsedHeight, accuracy: 1)
        app.buttons["close-live-map"].tap()
        slideToStop(app)
        app.alerts["Save this recording?"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["recording-slider"].waitForExistence(timeout: 10))
        assertMapStatus(app)
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Current recording"].exists)
        XCTAssertFalse(recordingSheet(app).exists)
        try audit(app, name: "ready-live-map-details")
        app.buttons["close-live-map"].tap()
        XCTAssertTrue(app.buttons["open-live-map"].waitForExistence(timeout: 10))
    }

    private func slideToStop(_ app: XCUIApplication) {
        let slider = app.buttons["recording-slider"]
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)))
    }

    private func assertMapStatus(_ app: XCUIApplication, status: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "Map", file: file, line: line)
        let slider = app.buttons["recording-slider"]
        let matchesState = NSPredicate { _, _ in
            guard slider.exists else { return false }
            if status == "Recording" { return slider.label == "Slide to stop recording" }
            if status == "Recording unavailable" { return slider.label == "Storage unavailable" }
            return slider.value as? String == "Stopped"
                && slider.label != "Saving"
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matchesState, object: app)],
                                    timeout: 10) == .completed, file: file, line: line)
    }

    private func assertRecordingDetails(_ app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let viewport = recordingSheet(app).frame.intersection(app.frame)
        for label in ["Duration", "Distance", "Ascent", "Descent"] {
            let metric = recordingMetric(app, label)
            XCTAssertTrue(metric.waitForExistence(timeout: 10), file: file, line: line)
            XCTAssertTrue(metric.isHittable && viewport.contains(metric.frame), "The sheet must contain the entire metric: \(label)", file: file, line: line)
        }
        for identifier in ["recording-slider"] {
            XCTAssertFalse(app.buttons.matching(identifier: identifier).allElementsBoundByIndex.contains(where: \.isHittable), file: file, line: line)
        }
        XCTAssertFalse(app.buttons["Map tracking"].isHittable, file: file, line: line)
    }

    private func assertCollapsedRecordingDetails(_ app: XCUIApplication, status: String,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["close-live-map"].isHittable, file: file, line: line)
        let icon = app.descendants(matching: .any).matching(identifier: "live-recording-status").firstMatch
        XCTAssertTrue(icon.isHittable, file: file, line: line)
        XCTAssertEqual(icon.label, status, file: file, line: line)
        let viewport = recordingSheet(app).frame.intersection(app.frame)
        let duration = recordingMetric(app, "Duration")
        XCTAssertTrue(duration.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(duration.isHittable && viewport.contains(duration.frame), "The collapsed sheet must contain the entire duration", file: file, line: line)
        for metric in ["Distance", "Ascent", "Descent"] {
            XCTAssertFalse(metricIntersectsSheet(app, metric), "The collapsed sheet must hide the metric below its viewport: \(metric)", file: file, line: line)
        }
        for identifier in ["recording-slider"] {
            XCTAssertFalse(app.buttons.matching(identifier: identifier).allElementsBoundByIndex.contains(where: \.isHittable), file: file, line: line)
        }
        XCTAssertFalse(app.staticTexts["Current recording"].exists, file: file, line: line)
    }

    private func recordingMetric(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        recordingSheet(app).staticTexts
            .matching(NSPredicate(format: "label == %@ AND value != nil", label)).firstMatch
    }

    private func recordingSheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
    }

    private func metricIntersectsSheet(_ app: XCUIApplication, _ label: String) -> Bool {
        let metric = recordingMetric(app, label)
        guard metric.exists, metric.isHittable else { return false }
        let viewport = recordingSheet(app).frame.intersection(app.frame)
        let visibleFrame = viewport.intersection(metric.frame)
        return !visibleFrame.isNull && !visibleFrame.isEmpty
    }

    func testEmptyHistoryAndProfile() throws {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL", scenario: "empty")
        app.tabBars.buttons["Activities"].tap()
        XCTAssertTrue(app.staticTexts["No activities"].waitForExistence(timeout: 10))
        try audit(app, name: "empty-activities-accessibility")
        app.scrollViews.firstMatch.swipeUp()
        try audit(app, name: "empty-activities-bottom-accessibility")
        app.tabBars.buttons["Profile"].tap()
        XCTAssertFalse(app.buttons["export-all-gpx"].isEnabled)
        try audit(app, name: "empty-profile-accessibility")
        app.swipeUp()
        try audit(app, name: "empty-profile-bottom-accessibility")
    }

    func testStorageFailureRemainsReadable() throws {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL", scenario: "storage-error")
        assertMapStatus(app, status: "Recording unavailable")
        app.scrollViews.firstMatch.swipeUp()
        try audit(app, name: "storage-failure-accessibility")
        let restart = app.staticTexts["Restart Sunō to reopen storage. Pending points have not been saved."]
        reveal(restart, in: app.scrollViews.firstMatch, app: app)
        XCTAssertTrue(restart.isHittable)
        try audit(app, name: "storage-failure-bottom-accessibility")
    }

    #if !targetEnvironment(simulator)
    /// Physical-device evidence for the extension in system-owned presentations.
    /// These snapshots complement, rather than replace, app accessibility audits.
    func testLiveActivitySystemSnapshots() throws {
        let app = launch(scenario: "recording")
        XCTAssertTrue(app.buttons["recording-slider"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let island = system.otherElements.matching(identifier: "regular.view")
            .matching(NSPredicate(format: "label CONTAINS %@", "saved points")).firstMatch
        if island.waitForExistence(timeout: 10) {
            captureSystem(system, name: "live-activity-home")
            island.press(forDuration: 1)
            XCTAssertTrue(system.staticTexts["Recording"].waitForExistence(timeout: 5))
            captureSystem(system, name: "live-activity-expanded-island")
            XCUIDevice.shared.press(.home)
        }

        // Notification Center uses the Lock Screen Live Activity presentation.
        // Use relative screen-edge gestures, independent of the device's size.
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8)))
        captureSystem(system, name: "live-activity-notification-center")
        app.activate()
        XCTAssertTrue(app.buttons["recording-slider"].waitForExistence(timeout: 10))
    }

    private func captureSystem(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) - hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
    #endif

    func testStartupFailureAtLargestText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = "startup-error"
        app.launch()
        XCTAssertTrue(app.staticTexts["Unable to Open Recordings"].waitForExistence(timeout: 10))
        try audit(app, name: "startup-failure-accessibility")
        let retry = app.buttons["Retry"]
        reveal(retry, in: app.scrollViews.firstMatch, app: app)
        XCTAssertTrue(retry.isHittable)
        try audit(app, name: "startup-failure-bottom-accessibility")
        retry.tap()
        XCTAssertTrue(app.staticTexts["Unable to Open Recordings"].exists)
    }

    func testExportAndImportPresentations() throws {
        let app = launch()
        app.tabBars.buttons["Activities"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        let export = app.buttons["export-gpx"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        try audit(app, name: "export-activity", systemPresentation: true)
        close.tap()
        app.buttons["close-activity-overview"].tap()
        app.tabBars.buttons["Profile"].tap()
        app.buttons["export-all-gpx"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        try audit(app, name: "export-all", systemPresentation: true)
        close.tap()
        app.buttons["import-gpx"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        try audit(app, name: "import-picker", systemPresentation: true)
        cancel.tap()
        XCTAssertTrue(app.buttons["import-gpx"].exists)
    }

    func testDeleteReturnsToHistory() throws {
        let app = launch()
        app.tabBars.buttons["Activities"].tap()
        let activities = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-"))
        XCTAssertTrue(activities.firstMatch.waitForExistence(timeout: 10))
        let deletedID = activities.firstMatch.identifier
        activities.firstMatch.tap()
        XCTAssertTrue(app.buttons["open-activity-map"].waitForExistence(timeout: 10))
        let delete = app.buttons["delete-activity"]
        reveal(delete, in: app.scrollViews["activity-overview-scroll"], app: app)
        try audit(app, name: "activity-delete")
        delete.tap()
        XCTAssertTrue(app.alerts["Delete Activity?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        XCTAssertTrue(app.alerts["Delete Activity?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.tabBars.buttons["Activities"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[deletedID].exists)
        XCTAssertEqual(activities.count, 2)
    }

    func testRecordingDetailsAtLargestText() throws {
        let app = launch(category: "UICTContentSizeCategoryAccessibilityXXXL", scenario: "recording")
        assertMapStatus(app, status: "Recording")
        app.buttons["open-live-map"].tap()
        XCTAssertTrue(app.buttons["close-live-map"].waitForExistence(timeout: 10))
        assertCollapsedRecordingDetails(app, status: "Recording")
        try audit(app, name: "recording-compact-accessibility")
        let collapsedHeight = recordingSheet(app).frame.height
        expandSheet(app)
        let scroll = recordingSheet(app)
        for label in ["Duration", "Distance", "Ascent", "Descent"] {
            reveal(recordingMetric(app, label), in: scroll, app: app)
        }
        try audit(app, name: "recording-details-bottom-accessibility")
        collapseRecordingSheet(app, to: collapsedHeight)
        assertCollapsedRecordingDetails(app, status: "Recording")
        app.buttons["close-live-map"].tap()
        slideToStop(app)
        XCTAssertTrue(app.alerts["Save this recording?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Discard"].tap()
        XCTAssertTrue(app.buttons["recording-slider"].waitForExistence(timeout: 10))
        assertMapStatus(app)
    }

    func testLargerTextAndLocalizedDates() throws {
        let app = launch(category: "UICTContentSizeCategoryXXXL", locale: "de_DE")
        app.tabBars.buttons["Activities"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        try audit(app, name: "activities-larger-localized")
        activity.tap()
        app.buttons["open-activity-map"].tap()
        XCTAssertTrue(app.buttons["close-activity-details"].waitForExistence(timeout: 10))
        try audit(app, name: "compact-activity-larger-localized")
        expandSheet(app)
        try audit(app, name: "expanded-activity-larger-localized")
    }

    private func expandSheet(_ app: XCUIApplication, holdBeforeRelease: Bool = false) {
        let grabber = app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex.last!
        if holdBeforeRelease {
            let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
        } else {
            grabber.swipeUp()
        }
    }

    private func collapseRecordingSheet(_ app: XCUIApplication, to height: CGFloat) {
        let scroll = recordingSheet(app)
        let collapsed = NSPredicate { _, _ in abs(scroll.frame.height - height) <= 1 }
        for _ in 0..<2 {
            app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex.last!.swipeDown()
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: collapsed, object: app)],
                              timeout: 3) == .completed { return }
        }
        XCTAssertEqual(scroll.frame.height, height, accuracy: 1)
    }

    private enum ScrollDirection { case up, down }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, app: XCUIApplication,
                        direction: ScrollDirection = .up, file: StaticString = #filePath, line: UInt = #line) {
        func viewport() -> CGRect {
            var bounds = scroll.frame.intersection(app.frame)
            if let bar = app.tabBars.allElementsBoundByIndex.first(where: \.isHittable) {
                bounds.size.height = min(bounds.maxY, bar.frame.minY) - bounds.minY
            }
            if let navigation = app.navigationBars.allElementsBoundByIndex.first(where: \.isHittable) {
                let top = max(bounds.minY, navigation.frame.maxY)
                bounds = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
            }
            return bounds
        }
        func fullyVisible() -> Bool {
            element.exists && element.isHittable && viewport().contains(element.frame)
        }
        for _ in 0..<15 where !fullyVisible() {
            let bounds = viewport()
            let moveDown = element.exists ? element.frame.midY < bounds.midY : direction == .down
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * (moveDown ? 0.35 : 0.65)))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * (moveDown ? 0.60 : 0.40)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(fullyVisible(), "The entire element must be reachable inside the viewport: \(element)", file: file, line: line)
    }

    private func launch(category: String = "UICTContentSizeCategoryL", scenario: String = "populated", locale: String = "en_US", location: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", category, "-AppleLocale", locale]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = scenario
        if let location { app.launchEnvironment["SUNOH_UI_LOCATION"] = location }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        XCTAssertTrue(app.tabBars.buttons["Activities"].waitForExistence(timeout: 15))
        return app
    }

    private func audit(_ app: XCUIApplication, name: String, systemPresentation: Bool = false) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try app.screenshot().pngRepresentation.write(to: documents.appendingPathComponent("\(name).png"))
        try app.debugDescription.write(to: documents.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if systemPresentation {
            // UIKit owns the Files and share-sheet controls. Preserve their
            // diagnostics, but gate this test on presentation and dismissal.
            var systemFindings: [String] = []
            try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription]) { issue in
                systemFindings.append("\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element")")
                return true
            }
            let systemReport = XCTAttachment(string: systemFindings.joined(separator: "\n\n"))
            systemReport.name = "\(name) - system control diagnostics"
            systemReport.lifetime = .keepAlways
            add(systemReport)
        } else {
            try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription])
        }
        // The installed runtime also reports contrast failures for black text
        // on native material and disabled controls. Keep the full diagnostics
        // with screenshots for visual review, alongside the native references.
        var contrast: [String] = []
        try app.performAccessibilityAudit(for: .contrast) { issue in
            contrast.append("\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element")")
            return true
        }
        let contrastReport = contrast.isEmpty ? "No contrast diagnostics." : contrast.joined(separator: "\n\n")
        try contrastReport.write(to: documents.appendingPathComponent("\(name)-contrast-audit.txt"), atomically: true, encoding: .utf8)
        let contrastAttachment = XCTAttachment(string: contrastReport)
        contrastAttachment.name = "\(name) - contrast diagnostics (manual review)"
        contrastAttachment.lifetime = .keepAlways
        add(contrastAttachment)

        // On the installed iOS 27 runtime this reports clipped text for plain
        // native Label/Form and floating-sheet controls (see the reference tests),
        // as well as text crossing normal scroll boundaries. Preserve every
        // finding and screenshot for review; do not change native controls to
        // silence these diagnostics or claim this audit is a passing text check.
        var findings: [String] = []
        try app.performAccessibilityAudit(for: .textClipped) { issue in
            print("SUNOH_AUDIT \(name): \(issue.compactDescription) \(issue.element?.debugDescription ?? "no element")")
            findings.append("\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element supplied by the SDK")")
            return true
        }
        let report = findings.isEmpty ? "No text-clipping diagnostics." : findings.joined(separator: "\n\n")
        try report.write(to: documents.appendingPathComponent("\(name)-text-audit.txt"), atomically: true, encoding: .utf8)
        let diagnostics = XCTAttachment(string: report)
        diagnostics.name = "\(name) - text audit diagnostics (manual review)"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
    }
}
