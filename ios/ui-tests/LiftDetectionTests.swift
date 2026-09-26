import XCTest

@MainActor final class LiftDetectionTests: XCTestCase {
    func testReferenceLiftKeepsFlatAndDescendingSectionsInOneRide() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLocale", "en_US"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = "lift-detection"
        app.launchEnvironment["TZ"] = "Europe/Vienna"
        app.launch()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        let activities = app.tabBars.buttons["Activities"]
        XCTAssertTrue(waitUntilHittable(activities))
        activities.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        XCTAssertTrue(waitUntilHittable(saved))
        XCTAssertTrue(saved.label.contains("Saturday 25, July 2026"))
        saved.tap()
        let overview = app.scrollViews["activity-overview-scroll"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        let ready = NSPredicate { _, _ in
            app.buttons["close-activity-overview"].isHittable && app.buttons["open-activity-map"].isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts["activity-heading-date"].label, "Saturday 25, July 2026")
        let resort = app.staticTexts["activity-ski-areas"]
        let named = NSPredicate(format: "label == %@", "Plateau Mountain")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: named, object: resort)], timeout: 10), .completed)
        assertMetrics([("Total duration", "10m"), ("Total distance", "3.0 km"), ("Vertical", "515 m"),
                       ("Runs", "2"), ("Time on runs", "4m"), ("Distance on runs", "1.9 km"),
                       ("Average speed", "28.8 km/h"), ("Tallest run", "250 m"), ("Longest run", "960 m")], in: overview)
        for identifier in ["activity-timeline-toggle", "activity-timeline", "activity-statistics-session", "activity-statistics-runs", "activity-statistics-lifts"] {
            XCTAssertFalse(overview.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        for title in ["Timeline", "Lifts", "Descent"] { XCTAssertFalse(overview.staticTexts[title].exists) }
        assertNoFeatureOrSamplingDetails(overview)
        let statistics = overview.descendants(matching: .any).matching(identifier: "activity-statistics").firstMatch
        reveal(statistics, in: overview)
        capture(app, name: "Reference-assisted activity summary shows one statistics grid")

        reveal(app.buttons["open-activity-map"], in: overview)
        app.buttons["open-activity-map"].tap()
        XCTAssertTrue(app.buttons["close-activity-details"].waitForExistence(timeout: 10))
        try expandMapCard(app)
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        assertRun(card, number: 1)
        let runHeight = card.frame.height
        XCTAssertFalse(card.buttons["previous-activity-section"].isEnabled)
        card.buttons["next-activity-section"].tap()
        assertLift(card)
        XCTAssertEqual(card.frame.height, runHeight, accuracy: 3)
        let profile = card.descendants(matching: .any).matching(identifier: "activity-elevation-profile").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        let maximum = profile.staticTexts["elevation-profile-maximum"]
        let minimum = profile.staticTexts["elevation-profile-minimum"]
        let timeRange = profile.staticTexts["elevation-profile-time-range"]
        let duration = profile.staticTexts["elevation-profile-duration"]
        XCTAssertEqual(maximum.label, "2,050 m")
        XCTAssertEqual(minimum.label, "1,750 m")
        XCTAssertEqual(timeRange.label, "02:02 – 02:08")
        XCTAssertEqual(duration.label, "6m")
        XCTAssertLessThan(maximum.frame.maxX, timeRange.frame.minX)
        XCTAssertLessThan(minimum.frame.maxX, duration.frame.minX)
        XCTAssertLessThan(maximum.frame.maxY, minimum.frame.minY)
        XCTAssertFalse(profile.staticTexts["Elevation"].exists)
        XCTAssertFalse(profile.staticTexts["0s"].exists)
        XCTAssertLessThanOrEqual(profile.frame.maxY, card.staticTexts["timeline-measurements"].frame.minY + 1)
        let sheet = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        XCTAssertTrue(sheet.frame.intersection(app.frame).insetBy(dx: -1, dy: -1).contains(profile.frame))
        XCTAssertGreaterThanOrEqual(card.buttons["next-activity-section"].frame.minY,
                                   card.staticTexts["timeline-measurements"].frame.maxY - 1)
        capture(app, name: "Lift profile covers the whole six-minute ride without matching details")
        card.buttons["next-activity-section"].tap()
        assertRun(card, number: 2)
        XCTAssertEqual(card.frame.height, runHeight, accuracy: 3)
        XCTAssertFalse(card.buttons["next-activity-section"].isEnabled)
        card.buttons["previous-activity-section"].tap()
        assertLift(card)
        XCTAssertEqual(card.descendants(matching: .any).matching(identifier: "activity-elevation-profile").firstMatch.staticTexts["elevation-profile-duration"].label, "6m")
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let ready = NSPredicate { _, _ in element.exists && element.isHittable }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 20) == .completed
    }

    private func assertRun(_ row: XCUIElement, number: Int) {
        assertCard(row, position: "run \(number) of 2")
        XCTAssertEqual(row.staticTexts["timeline-measurements"].label, "↔ 960 m · ↕︎ 250 m")
        assertNoFeatureOrSamplingDetails(row)
    }

    private func assertLift(_ row: XCUIElement) {
        assertCard(row, position: "lift 1 of 1")
        XCTAssertEqual(row.staticTexts["timeline-measurements"].label, "↔ 1.1 km · ↕︎ 315 m")
        assertNoFeatureOrSamplingDetails(row)
    }

    private func assertCard(_ card: XCUIElement, position expected: String) {
        let position = card.staticTexts["activity-section-position"]
        XCTAssertEqual(position.label, expected)
        XCTAssertFalse(card.staticTexts["timeline-activity-title"].exists)
        let measurements = card.staticTexts["timeline-measurements"]
        XCTAssertEqual(measurements.frame.midX, card.frame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(position.frame.minY, measurements.frame.maxY - 1)
        XCTAssertEqual(position.frame.midX, card.frame.midX, accuracy: 2)
    }

    private func assertNoFeatureOrSamplingDetails(_ row: XCUIElement) {
        XCTAssertFalse(row.staticTexts["timeline-feature-name"].exists)
        XCTAssertFalse(row.staticTexts["timeline-match-coverage"].exists)
        XCTAssertFalse(row.staticTexts["timeline-point-count"].exists)
        XCTAssertFalse(row.images["timeline-quality-level"].exists)
        XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Track matching")).firstMatch.exists)
        XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Plateau Express")).firstMatch.exists)
    }

    private func assertMetrics(_ expected: [(String, String)], in overview: XCUIElement) {
        let container = overview.descendants(matching: .any).matching(identifier: "activity-statistics").firstMatch
        XCTAssertTrue(container.waitForExistence(timeout: 10))
        for (label, value) in expected {
            let metric = container.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(metric.exists)
            XCTAssertEqual(metric.value as? String, value, label)
        }
    }

    private func expandMapCard(_ app: XCUIApplication) throws {
        let close = app.buttons["close-activity-details"]
        let grabber = try XCTUnwrap(app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex
            .filter { $0.isHittable && app.frame.intersects($0.frame) && $0.frame.midY < close.frame.midY }
            .min { abs($0.frame.maxY - close.frame.minY) < abs($1.frame.maxY - close.frame.minY) })
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch.waitForExistence(timeout: 10))
    }

    private func reveal(_ element: XCUIElement, in overview: XCUIElement) {
        for _ in 0..<18 {
            let frame = element.exists ? element.frame : .null
            if !frame.isNull && overview.frame.contains(frame) { return }
            if !frame.isNull && frame.minY < overview.frame.minY {
                overview.swipeDown()
            } else {
                overview.swipeUp()
            }
        }
        XCTFail("The requested overview content did not appear: \(element.identifier)")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
