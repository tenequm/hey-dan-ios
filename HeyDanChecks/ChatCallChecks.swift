import XCTest

@MainActor final class ChatCallChecks: XCTestCase {
    func testFixtureCallRefusal() {
        let app = XCUIApplication()
        app.launchEnvironment = ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_CALL_REFUSAL": "1"]
        app.launch()
        let row = app.buttons["chat.conversation.conv_taylor01"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let call = app.buttons["chat.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertFalse(call.isEnabled)
        XCTAssertEqual(app.staticTexts["chat.call.refusal"].label, "Voice is offline.")
    }

    func testFixtureCallAndPairingSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launch()
        let row = app.buttons["chat.conversation.conv_taylor01"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let call = app.buttons["chat.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertTrue(call.isEnabled)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Taylor tester"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Voice: Taylor"].exists)
        XCTAssertTrue(app.buttons["Pair a host"].exists)
    }
}
