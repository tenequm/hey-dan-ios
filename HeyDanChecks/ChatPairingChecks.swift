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
}
