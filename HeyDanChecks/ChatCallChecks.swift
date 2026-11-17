import XCTest

@MainActor final class ChatCallChecks: XCTestCase {
    func testFixtureCallRefusal() {
        let app = XCUIApplication()
        app.launchEnvironment = ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_CALL_REFUSAL": "1"]
        app.launch()
        let stan = app.buttons["conversation.conv_stan01"].firstMatch
        XCTAssertTrue(stan.waitForExistence(timeout: 15))
        stan.tap()
        let call = app.buttons["chat.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertFalse(call.isEnabled)
        XCTAssertEqual(app.staticTexts["chat.call.refusal"].label, "Voice is offline.")
    }

    func testFixtureCallAndPairingSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launch()
        let stan = app.buttons["conversation.conv_stan01"].firstMatch
        XCTAssertTrue(stan.waitForExistence(timeout: 15))
        stan.tap()
        let call = app.buttons["chat.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertTrue(call.isEnabled)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Stan tester"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Voice: Stan"].exists)
        XCTAssertTrue(app.buttons["Pair a host"].exists)
    }
}
