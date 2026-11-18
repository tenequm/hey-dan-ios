import XCTest

@MainActor final class ChatCallChecks: XCTestCase {
    private func openCall(_ environment: [String: String]) -> (XCUIApplication, XCUIElement) {
        let app = launchChat(environment)
        let row = app.buttons["chat.conversation.conv_taylor01"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let call = app.buttons["chat.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        return (app, call)
    }

    func testFixtureCallRefusal() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_CALL_REFUSAL": "1"])
        XCTAssertFalse(call.isEnabled)
        XCTAssertEqual(app.staticTexts["chat.call.refusal"].label, "Voice is offline.")
    }

    func testFixtureCallAndPairingSettings() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1"])
        XCTAssertTrue(call.isEnabled)
        XCTAssertEqual(call.label, "Call")
        XCTAssertGreaterThanOrEqual(call.frame.height, 44)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Taylor tester"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pair a host"].exists)
        // One control per tap: a tap on Voice opens the picker and nothing else in its row.
        app.buttons["Voice: Taylor"].tap()
        XCTAssertTrue(app.staticTexts["picker.title"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["pairing.link"].exists)
        XCTAssertFalse(app.staticTexts["Unpair this host?"].exists)
    }

    /// The fixture refuses every start with 503: the cover shows the host's words, its own close control and the
    /// call screen's settings gear, and closing it returns to the thread.
    func testFixtureCallCoverShowsTheRefusal() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1"])
        call.tap()
        let refusal = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "calls are unavailable in this preview")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30))
        let close = app.buttons["chat.call.close"]
        XCTAssertTrue(close.isHittable)
        XCTAssertEqual(close.label, "Close")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertTrue(app.buttons["settings"].exists)
        XCTAssertTrue(close.frame.intersection(app.buttons["settings"].frame).isNull)
        close.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 10))
        XCTAssertTrue(call.isHittable)
        XCTAssertTrue(call.isEnabled)
    }
}
