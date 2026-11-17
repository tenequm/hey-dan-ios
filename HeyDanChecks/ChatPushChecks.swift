import XCTest

final class ChatPushChecks: XCTestCase {
    @MainActor func testSimulatedPushRouting() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["Stan"].waitForExistence(timeout: 15))
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "New message")).firstMatch
        print("h5-ready-list")
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        banner.tap()
        XCTAssertTrue(app.navigationBars["Stan"].waitForExistence(timeout: 15))
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10))
        print("h5-ready-suppressed")
        XCTAssertFalse(banner.waitForExistence(timeout: 8))
        print("h5-ready-unknown")
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        banner.tap()
        XCTAssertTrue(app.buttons["Stan"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["Stan"].exists)
    }

    @MainActor func testCommunicationBannerAndTap() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launchEnvironment["HEYDAN_DEBUG_NOTIFY"] = "conv_stan01"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["Stan"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "New message")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "h5-communication-banner"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        banner.tap()
        XCTAssertTrue(app.navigationBars["Stan"].waitForExistence(timeout: 15))
    }
}
