import XCTest

final class ChatPairingChecks: XCTestCase {
    @MainActor func testInvalidLink() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_SHOW_PAIRING"] = "1"
        app.launch()
        let field = app.textFields["pairing.link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("invalid")
        app.buttons["pairing.submit"].tap()
        XCTAssertTrue(app.staticTexts["Paste a valid pairing link."].waitForExistence(timeout: 5))
    }

    @MainActor func testOfflinePairing() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_SHOW_PAIRING"] = "1"
        app.launchEnvironment["HEYDAN_OFFLINE_FOR"] = "60"
        app.launch()
        let field = app.textFields["pairing.link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://example.invalid/app/pair#fixture-not-a-real-code")
        app.buttons["pairing.submit"].tap()
        XCTAssertTrue(app.staticTexts["You are offline. Check your connection and try again."].waitForExistence(timeout: 5))
    }
    @MainActor func testPasteButton() throws {
        guard ProcessInfo.processInfo.environment["HEYDAN_TEST_PASTE_READY"] == "1" else {
            throw XCTSkip("Seed the Simulator pasteboard with synthetic invalid text before running this check")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_SHOW_PAIRING"] = "1"
        app.launch()
        let paste = app.buttons["pairing.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        let allow = app.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let submit = app.buttons["pairing.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()
        XCTAssertTrue(app.staticTexts["Paste a valid pairing link."].waitForExistence(timeout: 5))
    }

}
