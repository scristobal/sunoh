import XCTest

@MainActor final class MapStyleSelectionTests: XCTestCase {
    private let app = XCUIApplication()
    private let styles = ["Blue Snow", "Sunō", "Standard"]
    private var capturedChoices = false

    func testStyleSelectionUpdatesMapsAndPersistsAcrossLaunches() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-testing", "-AppleLocale", "en_US"]
        app.launchEnvironment["SUNOH_UI_SCENARIO"] = "timeline"
        app.launchEnvironment["TZ"] = "Europe/Vienna"
        launch()
        openProfile()
        let originalStyle = try XCTUnwrap(selectedStyle())
        addTeardownBlock { [app] in
            await Self.restoreStyle(originalStyle, in: app)
        }

        for style in ["Sunō", "Blue Snow", "Standard"] {
            selectStyle(style)
            app.tabBars.buttons["Map"].tap()
            let openMap = app.buttons["open-live-map"]
            XCTAssertTrue(openMap.waitForExistence(timeout: 10))
            openMap.tap()
            let closeMap = app.buttons["close-live-map"]
            XCTAssertTrue(closeMap.waitForExistence(timeout: 10))
            capture("Live map with \(style)")
            closeMap.tap()
            openProfile()
            XCTAssertEqual(selectedStyle(), style)
        }

        selectStyle("Standard")
        app.terminate()
        launch()
        openProfile()
        XCTAssertEqual(selectedStyle(), "Standard")
        capture("Profile preserves Standard after relaunch")

        app.tabBars.buttons["Activities"].tap()
        let activity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity-row-")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 15))
        activity.tap()
        let openMap = app.buttons["open-activity-map"]
        XCTAssertTrue(openMap.waitForExistence(timeout: 10))
        openMap.tap()
        let closeMap = app.buttons["close-activity-details"]
        XCTAssertTrue(closeMap.waitForExistence(timeout: 10))
        capture("Saved activity opens with the persisted style")
        closeMap.tap()
        let closeOverview = app.buttons["close-activity-overview"]
        XCTAssertTrue(closeOverview.waitForExistence(timeout: 10))
        closeOverview.tap()
        openProfile()
        XCTAssertEqual(selectedStyle(), "Standard")
    }

    private func launch() {
        app.launch()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 15))
    }

    private func openProfile() {
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(stylePicker.waitForExistence(timeout: 10))
    }

    private var stylePicker: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "map-style-picker").firstMatch
    }

    private func selectedStyle() -> String? {
        styles.first { style in
            (stylePicker.value as? String) == style || stylePicker.label.contains(style)
                || stylePicker.staticTexts[style].exists
        }
    }

    private func selectStyle(_ style: String) {
        stylePicker.tap()
        if !capturedChoices {
            capture("Profile map style choices")
            capturedChoices = true
        }
        for title in styles {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
        }
        app.buttons[style].tap()
        let back = app.navigationBars.buttons["Profile"]
        if back.exists { back.tap() }
        XCTAssertTrue(stylePicker.waitForExistence(timeout: 10))
        XCTAssertEqual(selectedStyle(), style)
    }

    private static func restoreStyle(_ style: String, in app: XCUIApplication) {
        app.terminate()
        app.launch()
        defer { app.terminate() }
        let profile = app.tabBars.buttons["Profile"]
        guard profile.waitForExistence(timeout: 15) else {
            XCTFail("Unable to reopen Profile to restore the original map style.")
            return
        }
        profile.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "map-style-picker").firstMatch
        guard picker.waitForExistence(timeout: 10) else {
            XCTFail("Unable to find the map style picker during cleanup.")
            return
        }
        if (picker.value as? String) == style || picker.label.contains(style) || picker.staticTexts[style].exists { return }
        picker.tap()
        let choice = app.buttons[style]
        guard choice.waitForExistence(timeout: 5) else {
            XCTFail("Unable to restore the original map style: \(style).")
            return
        }
        choice.tap()
        let back = app.navigationBars.buttons["Profile"]
        if back.exists { back.tap() }
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue((picker.value as? String) == style || picker.label.contains(style) || picker.staticTexts[style].exists)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
