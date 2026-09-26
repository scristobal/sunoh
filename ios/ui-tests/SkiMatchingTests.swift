import XCTest

@MainActor final class SkiMatchingTests: XCTestCase {
    func testFeatureNamesAndMatchingRatingsStayHiddenWhileSkiAreasRemain() throws {
        let app = launch(scenario: "ski-matching")
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        let namedRow = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "South Bowl", "Valley Pass")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: namedRow, object: saved)], timeout: 15), .completed)
        XCTAssertTrue(saved.label.contains("Saturday 25, July 2026"))
        XCTAssertFalse(saved.label.contains("saved points"))
        XCTAssertFalse(saved.label.contains("North Peak"))
        let listScreenshot = XCTAttachment(screenshot: app.screenshot())
        listScreenshot.name = "Activity list shows all associated ski areas"
        listScreenshot.lifetime = .keepAlways
        add(listScreenshot)
        saved.tap()
        let scroll = app.scrollViews["activity-overview-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let overviewHeader = app.descendants(matching: .any).matching(identifier: "activity-overview-header").firstMatch
        let resorts = overviewHeader.staticTexts["activity-ski-areas"]
        let date = overviewHeader.staticTexts["activity-heading-date"].label
        XCTAssertEqual(date, "Saturday 25, July 2026")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: namedRow, object: resorts)], timeout: 15), .completed)
        XCTAssertFalse(resorts.label.contains("North Peak"))
        XCTAssertTrue(resorts.label.contains("South Bowl"))
        XCTAssertTrue(resorts.label.contains("Valley Pass"))
        let resortNames = resorts.label
        XCTAssertFalse(overviewHeader.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved points")).firstMatch.exists)
        let statistics = scroll.descendants(matching: .any).matching(identifier: "activity-statistics").firstMatch
        XCTAssertTrue(statistics.waitForExistence(timeout: 10))
        for label in ["Total duration", "Total distance", "Vertical", "Runs", "Time on runs", "Distance on runs",
                      "Average speed", "Top speed", "Average steep", "Tallest run", "Longest run", "Steepest run"] {
            XCTAssertTrue(statistics.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists)
        }
        let runs = statistics.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Runs")).firstMatch
        XCTAssertEqual(runs.value as? String, "3")
        for identifier in ["activity-timeline-toggle", "activity-timeline", "activity-statistics-session", "activity-statistics-runs", "activity-statistics-lifts"] {
            XCTAssertFalse(scroll.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        for title in ["Timeline", "Lifts", "Descent"] { XCTAssertFalse(scroll.staticTexts[title].exists) }
        assertNoFeatureOrSamplingDetails(in: scroll)
        reveal(statistics, in: scroll)
        capture(app, name: "Summary retains ski areas and a single statistics grid")
        reveal(app.buttons["open-activity-map"], in: scroll)
        app.buttons["open-activity-map"].tap()
        XCTAssertTrue(app.buttons["close-activity-details"].waitForExistence(timeout: 10))
        capture(app, name: "Full screen map opens with compact details")
        let mapHeader = mapHeaderContainer(in: app)
        XCTAssertEqual(mapHeader.staticTexts["activity-heading-date"].label, date)
        let matchingHeader = NSPredicate(format: "label == %@", resortNames)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matchingHeader, object: mapHeader.staticTexts["activity-ski-areas"])], timeout: 15), .completed)
        XCTAssertEqual(mapHeader.staticTexts["activity-ski-areas"].label, resortNames)
        try expandMapCard(app)
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        XCTAssertEqual(card.staticTexts["activity-section-position"].label, "run 1 of 3")
        XCTAssertEqual(card.staticTexts["timeline-measurements"].label, "↔ 1.0 km · ↕︎ 250 m")
        capture(app, name: "Run card fits its profile, measurements and navigation")
        assertSectionCardLayout(card, duration: "3m 40s", app: app)
        let runHeight = card.frame.height
        app.buttons["next-activity-section"].tap()
        XCTAssertEqual(card.staticTexts["activity-section-position"].label, "lift 1 of 1")
        XCTAssertEqual(card.staticTexts["timeline-measurements"].label, "↔ 540 m · ↕︎ 250 m")
        assertSectionCardLayout(card, duration: "3m", app: app)
        XCTAssertEqual(card.frame.height, runHeight, accuracy: 3)
        capture(app, name: "Lift card uses the same fitted height with its kind count below the measurements")
        app.buttons["next-activity-section"].tap()
        XCTAssertEqual(card.staticTexts["activity-section-position"].label, "run 2 of 3")
        assertNoFeatureOrSamplingDetails(in: card)
        XCTAssertFalse(card.staticTexts["timeline-activity-title"].exists)
        XCTAssertTrue(card.descendants(matching: .any).matching(identifier: "activity-elevation-profile").firstMatch.exists)
        app.buttons["previous-activity-section"].tap()
        XCTAssertEqual(card.staticTexts["activity-section-position"].label, "lift 1 of 1")
        assertNoFeatureOrSamplingDetails(in: card)
        XCTAssertEqual(mapHeader.staticTexts["activity-ski-areas"].label, resortNames)
    }

    private func launch(scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLocale", "en_US"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = scenario
        app.launchEnvironment["TZ"] = "Europe/Vienna"
        app.launch()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        let activities = app.tabBars.buttons["Activities"]
        XCTAssertTrue(activities.waitForExistence(timeout: 20))
        activities.tap()
        return app
    }

    private func assertNoFeatureOrSamplingDetails(in row: XCUIElement) {
        XCTAssertEqual(row.staticTexts.matching(identifier: "timeline-feature-name").count, 0)
        XCTAssertFalse(row.staticTexts["timeline-match-coverage"].exists)
        XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Track matching")).firstMatch.exists)
        XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "• ")).firstMatch.exists)
        XCTAssertFalse(row.staticTexts["timeline-point-count"].exists)
        XCTAssertFalse(row.images["timeline-quality-level"].exists)
        for name in ["Summit Express", "Ridge"] {
            XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists)
        }
    }

    private func assertSectionCardLayout(_ card: XCUIElement, duration: String, app: XCUIApplication) {
        let sheet = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        let profile = card.descendants(matching: .any).matching(identifier: "activity-elevation-profile").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.staticTexts["elevation-profile-duration"].label, duration)
        let measurements = card.staticTexts["timeline-measurements"]
        let position = card.staticTexts["activity-section-position"]
        XCTAssertFalse(card.staticTexts["timeline-activity-title"].exists)
        assertNoFeatureOrSamplingDetails(in: card)
        XCTAssertLessThanOrEqual(profile.frame.maxY, measurements.frame.minY + 1)
        XCTAssertEqual(measurements.frame.midX, card.frame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(position.frame.minY, measurements.frame.maxY - 1)
        XCTAssertEqual(position.frame.midX, card.frame.midX, accuracy: 2)
        let content = [profile, measurements]
        let controls = [card.buttons["previous-activity-section"], card.buttons["next-activity-section"]]
        let viewport = sheet.frame.intersection(app.frame).insetBy(dx: -1, dy: -1)
        for element in content + controls + [position] {
            XCTAssertTrue(viewport.contains(element.frame), "\(element.identifier) at \(element.frame) should fit in expanded sheet \(viewport).")
        }
        for control in controls {
            for element in content {
                XCTAssertGreaterThanOrEqual(control.frame.minY, element.frame.maxY - 1,
                                            "The section controls should remain below its profile and measurements.")
            }
            let contentBottom = content.map(\.frame.maxY).max() ?? 0
            XCTAssertLessThanOrEqual(control.frame.minY - contentBottom, control.frame.height,
                                     "The fitted card should not reserve an empty area above navigation.")
        }
    }

    private func mapHeaderContainer(in app: XCUIApplication) -> XCUIElement {
        let header = app.descendants(matching: .any).matching(identifier: "map-details-header").firstMatch
        if header.exists { return header }
        // SwiftUI can fold the compact header into the sheet's single containing element.
        let sheet = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        if sheet.staticTexts["activity-heading-date"].exists && sheet.staticTexts["activity-ski-areas"].exists { return sheet }
        return header
    }

    private func capture(_ app: XCUIApplication, name: String) {
        if app.buttons["close-activity-details"].exists {
            let frames = ["map-details-sheet", "map-details-header", "close-activity-details"].map { identifier in
                let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                return element.exists ? "\(identifier): \(element.frame)" : "\(identifier): absent"
            }
            let geometry = XCTAttachment(string: frames.joined(separator: "\n"))
            geometry.name = "\(name) container frames"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func expandMapCard(_ app: XCUIApplication) throws {
        let header = mapHeaderContainer(in: app)
        let grabber = try XCTUnwrap(app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex
            .filter { $0.isHittable && app.frame.intersects($0.frame) && $0.frame.midY < header.frame.midY }
            .min { abs($0.frame.maxY - header.frame.minY) < abs($1.frame.maxY - header.frame.minY) })
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch.waitForExistence(timeout: 10))
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<18 {
            let frame = element.exists ? element.frame : .null
            if !frame.isNull && scroll.frame.contains(frame) { return }
            if !frame.isNull && frame.minY < scroll.frame.minY {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        XCTFail("The requested overview content did not appear: \(element.identifier)")
    }
}
