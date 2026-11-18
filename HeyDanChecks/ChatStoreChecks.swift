import XCTest

final class ChatStoreChecks: XCTestCase {
    @MainActor func testFixtureListRelaunchSmoke() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "chat.conversation.conv_taylor01").count, 1)
    }
}
