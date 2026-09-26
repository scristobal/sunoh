import XCTest

@MainActor final class SessionCountsTests: XCTestCase {
    func testProcessedCountsStayInOverviewWhileMapShowsOneSection() throws {
        guard let app = openActivity(scenario: "ski-session") else { return }
        let overview = app.scrollViews["activity-overview-scroll"]
        assertCounts(in: overview)
        capture(app, name: "Summary retains the session totals above evenly spaced run metrics")
        assertRunMetricColumns(in: overview)
        XCTAssertFalse(overview.staticTexts["Session"].exists)
        XCTAssertFalse(overview.staticTexts["Ski areas"].exists)
        overview.swipeUp()
        capture(app, name: "Run metrics use three columns without a section heading")
        overview.swipeUp()
        capture(app, name: "Run statistics end without lift metrics or a vertical timeline")
        revealMap(app)
        app.buttons["open-activity-map"].tap()
        XCTAssertTrue(app.buttons["close-activity-details"].waitForExistence(timeout: 10))
        capture(app, name: "Full screen map opens with compact details")
        guard try resizeMapDetailsSheet(app, compact: false) else { return }
        assertMapHasNoAggregates(app)
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        assertCard(card, position: "run 1 of 3")
        capture(app, name: "Full screen map keeps only the selected run card")
        app.buttons["close-activity-details"].tap()
        guard waitUntilHittable(app.buttons["close-activity-overview"]) else { return }
        assertCounts(in: overview)
        XCTAssertTrue(app.buttons["delete-activity"].exists)
        XCTAssertTrue(app.buttons["export-gpx"].exists)
    }

    func testRunsWithoutElevationKeepMovementMetricsAndShowUnavailableHeightAndGrade() {
        guard let app = openActivity(scenario: "no-elevation") else { return }
        let overview = app.scrollViews["activity-overview-scroll"]
        XCTAssertTrue(overview.descendants(matching: .any).matching(identifier: "no-elevation-state").firstMatch.exists)
        assertSteepness(in: overview, run: "—")
        assertMetrics([("Trips", "1"), ("Speed", "6.0 km/h"), ("Top speed", "11.6 km/h"), ("Tallest", "—"),
                       ("Longest", "485 m"), ("Distance", "485 m"), ("Time", "4m"), ("Descent", "0 m")], group: "runs", in: overview)
        assertRemovedMetrics(in: overview)
        app.scrollViews["activity-overview-scroll"].swipeUp()
        capture(app, name: "Run movement metrics remain available without elevation")
        app.scrollViews["activity-overview-scroll"].swipeUp()
        capture(app, name: "Run summary keeps unavailable height and grade values without lift statistics")
    }

    func testClassifiedMapShowsSeparatedRoutesAndSavedCounts() throws {
        guard let app = openActivity(scenario: "classified-map") else { return }
        let overview = app.scrollViews["activity-overview-scroll"]
        assertSteepness(in: overview, run: "15.4%", steepestRun: "27.8%")
        assertMetrics([("Trips", "2")], group: "runs", in: overview)
        assertRemovedMetrics(in: overview)
        capture(app, name: "Classified overview map with blue outside-lift routes and a green lift")
        app.buttons["open-activity-map"].tap()
        XCTAssertTrue(app.buttons["close-activity-details"].waitForExistence(timeout: 10))
        capture(app, name: "Full screen map opens with compact details")
        guard try resizeMapDetailsSheet(app, compact: true) else { return }
        capture(app, name: "Classified map with blue runs including the traverse, a green lift, recording breaks and no singleton")
        guard try resizeMapDetailsSheet(app, compact: false) else { return }
        assertMapHasNoAggregates(app)
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        assertCard(card, position: "lift 1 of 1")
        let liftHeight = card.frame.height
        app.buttons["next-activity-section"].tap()
        assertCard(card, position: "run 1 of 2")
        XCTAssertEqual(card.frame.height, liftHeight, accuracy: 3)
        capture(app, name: "Classified map follows the selected run in a fitted card")
        app.buttons["close-activity-details"].tap()
        XCTAssertTrue(app.buttons["open-activity-map"].waitForExistence(timeout: 10))
    }

    private func assertMapHasNoAggregates(_ app: XCUIApplication) {
        let sheet = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        for identifier in ["activity-statistics-session", "activity-statistics-runs", "activity-statistics-lifts", "activity-timeline", "map-details-scroll"] {
            XCTAssertFalse(sheet.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        for identifier in ["timeline-activity-title", "timeline-point-count", "timeline-quality-level", "timeline-feature-name", "timeline-match-coverage"] {
            XCTAssertFalse(sheet.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
    }

    private func assertCard(_ card: XCUIElement, position expected: String) {
        let position = card.staticTexts["activity-section-position"]
        XCTAssertEqual(position.label, expected)
        XCTAssertFalse(card.staticTexts["timeline-activity-title"].exists)
        XCTAssertFalse(card.staticTexts["timeline-point-count"].exists)
        XCTAssertFalse(card.images["timeline-quality-level"].exists)
        let measurements = card.staticTexts["timeline-measurements"]
        XCTAssertEqual(measurements.frame.midX, card.frame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(position.frame.minY, measurements.frame.maxY - 1)
        XCTAssertEqual(position.frame.midX, card.frame.midX, accuracy: 2)
    }

    private func revealMap(_ app: XCUIApplication) {
        let overview = app.scrollViews["activity-overview-scroll"]
        let map = app.buttons["open-activity-map"]
        for _ in 0..<10 {
            if map.exists && overview.frame.intersection(app.frame).contains(map.frame) { return }
            overview.swipeDown()
        }
        XCTFail("The overview map did not return into view.")
    }

    private func resizeMapDetailsSheet(_ app: XCUIApplication, compact: Bool) throws -> Bool {
        let sheet = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        let close = app.buttons["close-activity-details"]
        guard sheet.waitForExistence(timeout: 10), close.waitForExistence(timeout: 10) else {
            XCTFail("The foreground map details did not appear.")
            return false
        }
        let reachedDetent = NSPredicate { _, _ in
            guard sheet.exists, close.exists else { return false }
            let expanded = self.sectionFooterIsVisible(in: app)
            return compact ? !expanded : expanded
        }
        for _ in 0..<3 {
            guard waitForStableMapDetails(sheet, close: close, app: app) else { return false }
            if reachedDetent.evaluate(with: app) { return true }
            let header = close.frame
            let sheetTop = sheet.frame.minY
            let grabber = try XCTUnwrap(app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex
                .filter {
                    let frame = $0.frame
                    return $0.isHittable && app.frame.intersects(frame) && frame.midY < header.midY
                        && abs(frame.midY - sheetTop) <= max(32, frame.height * 2)
                }
                .min { abs($0.frame.maxY - header.minY) < abs($1.frame.maxY - header.minY) })
            let frame = grabber.frame
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: compact ? 0.97 : 0.1))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reachedDetent, object: app)], timeout: 3) == .completed {
                return waitForStableMapDetails(sheet, close: close, app: app)
            }
        }
        XCTFail("The foreground map details sheet did not reach its \(compact ? "compact" : "expanded") position.")
        return false
    }

    private func sectionFooterIsVisible(in app: XCUIApplication) -> Bool {
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        let footer = card.staticTexts["activity-section-position"]
        // Clipped details remain in the tree; the settled expanded footer must be on screen with usable navigation.
        guard footer.exists, !footer.frame.isEmpty, app.frame.contains(footer.frame) else { return false }
        return card.buttons["previous-activity-section"].isHittable || card.buttons["next-activity-section"].isHittable
    }

    private func waitForStableMapDetails(_ sheet: XCUIElement, close: XCUIElement, app: XCUIApplication) -> Bool {
        var previousSheet: CGRect?
        var previousHeader: CGRect?
        var stableSince = Date()
        let stable = NSPredicate { _, _ in
            guard sheet.exists, close.exists else { return false }
            let frame = sheet.frame
            let header = close.frame
            // The compact group is the union of its children; frame rounding can differ by a fraction of a point.
            guard !frame.isEmpty, app.frame.intersects(frame), frame.insetBy(dx: -1, dy: -1).contains(header) else { return false }
            if frame != previousSheet || header != previousHeader {
                previousSheet = frame
                previousHeader = header
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 1
        }
        let settled = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: app)], timeout: 6) == .completed
        if !settled { XCTFail("The foreground map details did not remain visible with stable geometry.") }
        return settled
    }

    private func openActivity(scenario: String) -> XCUIApplication? {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLocale", "en_US"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = scenario
        app.launch()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        for identifier in ["close-activity-details", "close-activity-overview"] {
            let close = app.buttons[identifier]
            if close.isHittable { close.tap() }
        }
        guard waitUntilHittable(app.tabBars.buttons["Activities"]) else { return nil }
        app.tabBars.buttons["Activities"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        guard waitUntilHittable(activity) else { return nil }
        activity.tap()
        XCTAssertTrue(app.scrollViews["activity-overview-scroll"].waitForExistence(timeout: 10))
        let ready = NSPredicate { _, _ in
            app.buttons["close-activity-overview"].isHittable && app.buttons["open-activity-map"].isHittable
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 10) == .completed else {
            XCTFail("The activity overview did not become the foreground presentation.")
            return nil
        }
        return app
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let ready = NSPredicate { _, _ in element.isHittable }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 15) == .completed else {
            XCTFail("The control did not become ready to tap: \(element.identifier)")
            return false
        }
        return true
    }

    private func assertCounts(in scroll: XCUIElement) {
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        assertSteepness(in: scroll, run: "26.0%")
        assertMetrics([("Duration", "12m"), ("Distance", "4.0 km"), ("Descent", "750 m")], group: "session", in: scroll)
        assertMetrics([("Trips", "3"), ("Time", "6m"), ("Distance", "2.9 km"), ("Descent", "750 m"),
                       ("Speed", "28.8 km/h"), ("Top speed", "28.8 km/h"), ("Tallest", "250 m"), ("Longest", "960 m")], group: "runs", in: scroll)
        assertRemovedMetrics(in: scroll)
    }

    private func statisticsGroup(_ group: String, in scroll: XCUIElement) -> XCUIElement {
        let container = scroll.descendants(matching: .any).matching(identifier: "activity-statistics-\(group)").firstMatch
        XCTAssertTrue(container.exists || container.waitForExistence(timeout: 15))
        return container
    }

    private func assertMetrics(_ expected: [(String, String)], group: String, in scroll: XCUIElement) {
        let container = statisticsGroup(group, in: scroll)
        for (label, value) in expected {
            let metric = container.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(metric.exists || metric.waitForExistence(timeout: 15))
            XCTAssertEqual(metric.value as? String, value, "\(group): \(label)")
        }
    }

    private func assertSteepness(in scroll: XCUIElement, run: String, steepestRun: String? = nil) {
        assertMetrics([("Steep", run), ("Steepest", steepestRun ?? run)], group: "runs", in: scroll)
    }

    private func assertRunMetricColumns(in scroll: XCUIElement) {
        let session = statisticsGroup("session", in: scroll)
        let runs = statisticsGroup("runs", in: scroll)
        func metric(_ label: String, in group: XCUIElement) -> XCUIElement {
            group.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        let columnCenters = ["Duration", "Distance", "Descent"].map { metric($0, in: session).frame.midX }
        let rows = [["Trips", "Time", "Distance"], ["Descent", "Speed", "Top speed"],
                    ["Tallest", "Longest", "Steep"], ["Steepest"]]
        var previousBottom: CGFloat?
        for labels in rows {
            let elements = labels.map { metric($0, in: runs) }
            let frames = elements.map(\.frame)
            for (column, frame) in frames.enumerated() {
                XCTAssertEqual(frame.midX, columnCenters[column], accuracy: 2,
                               "Run metrics should use the same three columns as the session totals.")
                XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 2)
            }
            if let previousBottom, let top = frames.map(\.minY).min() {
                XCTAssertGreaterThan(top, previousBottom, "Run metric rows should have space between them.")
            }
            previousBottom = frames.map(\.maxY).max()
        }
    }

    private func assertRemovedMetrics(in scroll: XCUIElement) {
        let session = statisticsGroup("session", in: scroll)
        for label in ["Ascent", "Total ascent", "Peak", "Lowest"] {
            XCTAssertFalse(session.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists)
        }
        for identifier in ["activity-timeline-toggle", "activity-timeline", "activity-statistics-lifts"] {
            XCTAssertFalse(scroll.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        for title in ["Timeline", "Run", "Runs", "Lift", "Lifts"] { XCTAssertFalse(scroll.staticTexts[title].exists) }
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
