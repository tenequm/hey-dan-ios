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
        XCTAssertTrue(app.buttons["chat.settings.host.app.example.com"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pair a host"].exists)
        // One control per tap: a tap on Voice opens the picker and nothing else in its row.
        app.buttons["Voice: Taylor"].tap()
        XCTAssertTrue(app.staticTexts["picker.title"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["pairing.link"].exists)
        XCTAssertFalse(app.staticTexts["Unpair this host?"].exists)
    }

    func testChatsSearchAndHostDetail() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        shot("conversation-list")
        app.buttons["Search"].tap()
        let field = app.textFields["Search chats"]
        field.tap()
        field.typeText("absent")
        XCTAssertTrue(app.staticTexts["No matching chats"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let host = app.buttons["chat.settings.host.app.example.com"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        shot("paired-settings")
        host.tap()
        XCTAssertTrue(app.buttons["Unpair"].waitForExistence(timeout: 5))
        shot("host-detail")
        app.buttons["Unpair"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        shot("unpair-sheet")
        cancel.tap()
        app.buttons["Back"].tap()
        app.buttons["Chats"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testFixtureCallCoverShowsTheRefusal() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1"])
        call.tap()
        let refusal = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "calls are unavailable in this preview")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30))
        let close = app.buttons["chat.call.close"]
        XCTAssertTrue(close.isHittable)
        XCTAssertEqual(close.label, "Close")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertTrue(app.buttons["keys.call"].isEnabled)
        app.buttons["controls.options"].tap()
        app.buttons["options.voice"].tap()
        XCTAssertTrue(app.staticTexts["picker.title"].waitForExistence(timeout: 5))
        app.buttons["picker.close"].tap()
        close.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 10))
        XCTAssertTrue(call.isHittable)
        XCTAssertTrue(call.isEnabled)
    }
}
