import XCTest

final class ChatPushChecks: XCTestCase {
    @MainActor func testCommunicationBannerAndTap() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_DEBUG_NOTIFY": "conv_taylor01"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "New message")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        shot("communication-banner")
        banner.tap()
        XCTAssertTrue(app.navigationBars["Taylor"].waitForExistence(timeout: 15))
    }
    @MainActor func testCommunicationBannerOnLockScreen() async throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_DEBUG_NOTIFY": "conv_taylor01"])
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "New message")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        defer {
            XCUIDevice.shared.press(.home)
            XCUIDevice.shared.press(.home)
        }
        try await Task.sleep(for: .seconds(3))
        shot("communication-lock")
    }

}
