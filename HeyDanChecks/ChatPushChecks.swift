import XCTest

final class ChatPushChecks: XCTestCase {
    @MainActor func testCommunicationBannerAndTap() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launchEnvironment["HEYDAN_DEBUG_NOTIFY"] = "conv_taylor01"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "New message")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "communication-banner"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        banner.tap()
        XCTAssertTrue(app.navigationBars["Taylor"].waitForExistence(timeout: 15))
    }
}
