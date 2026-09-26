import XCTest

@MainActor final class ActivityTimelineTests: XCTestCase {
    func testOverviewShowsProfileAndRunSummaryWithoutVerticalTimeline() throws {
        continueAfterFailure = false
        guard let app = launchTimelineApp(), openSavedActivity(app) else { return }
        let overview = app.scrollViews["activity-overview-scroll"]
        let heading = app.descendants(matching: .any).matching(identifier: "activity-overview-header").firstMatch
        XCTAssertEqual(heading.staticTexts["activity-heading-date"].label, "Saturday 25, 2:00am")
        XCTAssertFalse(heading.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved points")).firstMatch.exists)
        XCTAssertFalse(app.navigationBars["Activity"].exists)
        XCTAssertFalse(overview.staticTexts["Ski areas"].exists)
        XCTAssertFalse(overview.staticTexts["Session"].exists)
        let map = app.buttons["open-activity-map"]
        let profile = overview.descendants(matching: .any).matching(identifier: "activity-elevation-profile").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        capture(app, name: "Overview with date heading, square map and elevation profile")
        XCTAssertEqual(map.frame.width, map.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(profile.frame.minY, map.frame.maxY)
        XCTAssertEqual(profile.frame.height, map.frame.height / 4, accuracy: 3)
        for identifier in ["activity-timeline-toggle", "activity-timeline", "activity-statistics-lifts"] {
            XCTAssertFalse(overview.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        for title in ["Timeline", "Run", "Runs", "Lift", "Lifts"] { XCTAssertFalse(overview.staticTexts[title].exists) }
        for group in ["session", "runs"] {
            XCTAssertTrue(overview.descendants(matching: .any).matching(identifier: "activity-statistics-\(group)").firstMatch.exists)
        }
        overview.swipeUp()
        capture(app, name: "Summary keeps session totals and run metrics without section headings")
        overview.swipeUp()
        capture(app, name: "Summary ends after the run metrics without a vertical timeline or lift group")
        app.buttons["close-activity-overview"].tap()
        XCTAssertFalse(overview.exists)
        XCTAssertTrue(app.tabBars.buttons["Activities"].isHittable)
    }

    func testMapBrowsesSingleSectionsWithCompactAndFittedSheetPositions() throws {
        continueAfterFailure = false
        guard let app = launchTimelineApp(), openSavedActivity(app) else { return }
        let overviewDate = app.staticTexts["activity-heading-date"].label
        app.buttons["open-activity-map"].tap()
        let close = app.buttons["close-activity-details"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        assertMapZoomDoesNotExceed16(app)
        capture(app, name: "Compact full screen map shows the complete activity")
        let header = mapHeaderContainer(in: app)
        XCTAssertEqual(header.staticTexts["activity-heading-date"].label, overviewDate)
        let sheet = app.descendants(matching: .any).matching(identifier: "map-details-sheet").firstMatch
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        XCTAssertFalse(sectionFooterIsVisible(in: app))
        for identifier in ["activity-statistics-session", "activity-statistics-runs", "activity-statistics-lifts", "activity-timeline", "map-details-scroll"] {
            XCTAssertFalse(sheet.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        let compactTop = header.frame.minY
        guard try resizeMapDetailsSheet(app, compact: false) else { return }
        let expandedTop = header.frame.minY
        XCTAssertLessThan(expandedTop, compactTop - app.frame.height * 0.1)
        assertSection(card, position: "run 1 of 3", measurements: "↔ 1.0 km · ↕︎ 250 m", profileDuration: "3m 40s")
        assertMapZoomDoesNotExceed16(app)
        capture(app, name: "Run 1 profile appears above its heading with navigation at the bottom")
        let previous = app.buttons["previous-activity-section"]
        let next = app.buttons["next-activity-section"]
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)
        next.tap()
        assertSection(card, position: "lift 1 of 1", measurements: "↔ 540 m · ↕︎ 250 m", profileDuration: "3m")
        card.swipeLeft()
        assertSection(card, position: "run 2 of 3", measurements: "↔ 120 m · ↕︎ 0 m", profileDuration: "1m")
        card.swipeLeft()
        assertSection(card, position: "run 3 of 3", measurements: "↔ 240 m · ↕︎ 0 m", profileDuration: "2m")
        assertMapZoomDoesNotExceed16(app)
        capture(app, name: "Short Run 3 keeps surrounding map context at zoom 16 or below")
        XCTAssertFalse(next.isEnabled)
        card.swipeRight()
        assertSection(card, position: "run 2 of 3", measurements: "↔ 120 m · ↕︎ 0 m", profileDuration: "1m")
        previous.tap()
        assertSection(card, position: "lift 1 of 1", measurements: "↔ 540 m · ↕︎ 250 m", profileDuration: "3m")
        XCTAssertFalse(card.staticTexts["timeline-activity-title"].exists)
        XCTAssertFalse(sheet.descendants(matching: .any).matching(identifier: "activity-timeline").firstMatch.exists)
        try dragMapSheet(app, upward: true)
        XCTAssertEqual(header.frame.minY, expandedTop, accuracy: 3, "Dragging up from the fitted position must not open a larger sheet.")
        capture(app, name: "Map shows the selected lift above its fitted details card")
        guard try resizeMapDetailsSheet(app, compact: true) else { return }
        XCTAssertFalse(sectionFooterIsVisible(in: app))
        XCTAssertEqual(header.staticTexts["activity-heading-date"].label, overviewDate)
        assertMapZoomDoesNotExceed16(app)
        capture(app, name: "Collapsing the lift card restores the complete activity route")
        guard try resizeMapDetailsSheet(app, compact: false) else { return }
        XCTAssertEqual(card.staticTexts["activity-section-position"].label, "lift 1 of 1", "Changing the sheet position preserves the selected section.")
        assertProfileAndBottomControls(card, duration: "3m")
        assertMapZoomDoesNotExceed16(app)
        capture(app, name: "Expanding again returns to the selected Lift 1 route")
        close.tap()
        XCTAssertTrue(app.buttons["open-activity-map"].waitForExistence(timeout: 10))
    }

    private func assertSection(_ card: XCUIElement, position: String, measurements: String, profileDuration: String) {
        let matches = NSPredicate { _, _ in card.exists && card.staticTexts["activity-section-position"].label == position }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: card)], timeout: 5), .completed)
        XCTAssertEqual(card.staticTexts["timeline-measurements"].label, measurements)
        XCTAssertFalse(card.staticTexts["timeline-activity-title"].exists)
        XCTAssertFalse(card.images["timeline-quality-level"].exists)
        XCTAssertFalse(card.staticTexts["timeline-point-count"].exists)
        XCTAssertEqual(card.staticTexts["timeline-measurements"].frame.midX, card.frame.midX, accuracy: 2)
        assertNoRunMatching(in: card)
        assertProfileAndBottomControls(card, duration: profileDuration)
    }

    private func assertNoRunMatching(in row: XCUIElement) {
        XCTAssertEqual(row.staticTexts.matching(identifier: "timeline-feature-name").count, 0)
        XCTAssertFalse(row.staticTexts["timeline-match-coverage"].exists)
        XCTAssertFalse(row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Track matching")).firstMatch.exists)
    }

    private func assertProfileAndBottomControls(_ card: XCUIElement, duration: String) {
        let profiles = card.descendants(matching: .any).matching(identifier: "activity-elevation-profile")
        let profile = profiles.firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profiles.count, 1)
        let currentDuration = NSPredicate { _, _ in profile.staticTexts[duration].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: currentDuration, object: profile)], timeout: 5), .completed)
        XCTAssertTrue(profile.staticTexts["elevation-profile-minimum"].exists)
        XCTAssertTrue(profile.staticTexts["elevation-profile-maximum"].exists)
        XCTAssertTrue(profile.staticTexts["elevation-profile-time-range"].exists)
        XCTAssertFalse(profile.staticTexts["0s"].exists)
        XCTAssertLessThanOrEqual(profile.frame.maxY, card.staticTexts["timeline-measurements"].frame.minY + 1)
        XCTAssertGreaterThan(profile.frame.height, 0)
        XCTAssertLessThanOrEqual(profile.frame.height, card.frame.width / 4 + 3)
        let content = card.staticTexts.allElementsBoundByIndex.filter {
            $0.identifier != "activity-section-position"
        }
        for identifier in ["previous-activity-section", "next-activity-section"] {
            let control = card.buttons[identifier]
            XCTAssertTrue(control.exists)
            for element in content {
                XCTAssertGreaterThanOrEqual(control.frame.minY, element.frame.maxY - 1,
                                            "The section navigation should appear below its profile and measurements.")
            }
        }
    }

    private func assertMapZoomDoesNotExceed16(_ app: XCUIApplication) {
        let map = app.descendants(matching: .any).matching(identifier: "activity-section-map").firstMatch
        var samples: [Double] = []
        var previous: Double?
        var stableSince = Date()
        let settled = NSPredicate { _, _ in
            guard map.exists, let value = map.value as? String,
                  let range = value.range(of: #"(?<=Zoom )[0-9]+(?:\.[0-9]+)?(?=x)"#, options: .regularExpression),
                  let displayedZoom = Double(value[range]) else { return false }
            // MapLibre reports round(zoomLevel + 1); native map tests verify the exact cap.
            let zoom = displayedZoom - 1
            samples.append(zoom)
            if zoom != previous {
                previous = zoom
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: map)], timeout: 6), .completed,
                       "The native map should expose a settled zoom value after the route changes.")
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0 <= 16 }, "The native map exceeded zoom 16: \(samples)")
    }

    private func launchTimelineApp() -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLocale", "en_US"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = "timeline"
        app.launchEnvironment["TZ"] = "Europe/Vienna"
        app.launch()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        for identifier in ["close-activity-details", "close-activity-overview"] {
            let close = app.buttons[identifier]
            if close.isHittable { close.tap() }
        }
        guard waitUntilHittable(app.tabBars.buttons["Profile"]) else { return nil }
        return app
    }

    private func openSavedActivity(_ app: XCUIApplication) -> Bool {
        guard waitUntilHittable(app.tabBars.buttons["Activities"]) else { return false }
        app.tabBars.buttons["Activities"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        guard waitUntilHittable(activity) else { return false }
        XCTAssertTrue(activity.label.contains("Saturday 25, 2:00am"))
        activity.tap()
        XCTAssertTrue(app.scrollViews["activity-overview-scroll"].waitForExistence(timeout: 10))
        let ready = NSPredicate { _, _ in
            app.buttons["close-activity-overview"].isHittable && app.buttons["open-activity-map"].isHittable
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 10) == .completed else {
            XCTFail("The activity overview did not become the foreground presentation.")
            return false
        }
        return true
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let ready = NSPredicate { _, _ in element.isHittable }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 15) == .completed else {
            XCTFail("The control did not become ready to tap: \(element.identifier)")
            return false
        }
        return true
    }

    private func resizeMapDetailsSheet(_ app: XCUIApplication, compact: Bool) throws -> Bool {
        let close = app.buttons["close-activity-details"]
        let reached = NSPredicate { _, _ in
            guard close.exists else { return false }
            let expanded = self.sectionFooterIsVisible(in: app)
            return compact ? !expanded : expanded
        }
        for _ in 0..<3 {
            if reached.evaluate(with: app) { return waitForStableHeader(app) }
            try dragMapSheet(app, upward: !compact)
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reached, object: app)], timeout: 5) == .completed { return waitForStableHeader(app) }
        }
        XCTFail("The map details did not reach their \(compact ? "compact" : "expanded") position.")
        return false
    }

    private func sectionFooterIsVisible(in app: XCUIApplication) -> Bool {
        let card = app.descendants(matching: .any).matching(identifier: "activity-section-card").firstMatch
        let footer = card.staticTexts["activity-section-position"]
        // Clipped details remain in the tree; the settled expanded footer must be on screen with usable navigation.
        guard footer.exists, !footer.frame.isEmpty, app.frame.contains(footer.frame) else { return false }
        return card.buttons["previous-activity-section"].isHittable || card.buttons["next-activity-section"].isHittable
    }

    private func dragMapSheet(_ app: XCUIApplication, upward: Bool) throws {
        let header = mapHeaderContainer(in: app)
        let grabber = try XCTUnwrap(app.buttons.matching(identifier: "Sheet Grabber").allElementsBoundByIndex
            .filter { $0.isHittable && app.frame.intersects($0.frame) && $0.frame.midY < header.frame.midY }
            .min { abs($0.frame.maxY - header.frame.minY) < abs($1.frame.maxY - header.frame.minY) })
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.12 : 0.96)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(waitForStableHeader(app))
    }

    private func waitForStableHeader(_ app: XCUIApplication) -> Bool {
        let header = mapHeaderContainer(in: app)
        var previous: CGRect?
        var stableSince = Date()
        let stable = NSPredicate { _, _ in
            guard header.exists else { return false }
            let frame = header.frame
            if frame != previous {
                previous = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: app)], timeout: 5) == .completed
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
