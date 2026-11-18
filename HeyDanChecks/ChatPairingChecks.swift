import UIKit
import XCTest

@MainActor final class ChatPairingChecks: XCTestCase {
    private func pasteAndSubmit(_ value: String, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_SHOW_PAIRING"] = "1"
        if offline { app.launchEnvironment["HEYDAN_OFFLINE_FOR"] = "60" }
        app.launch()
        UIPasteboard.general.string = value
        let paste = app.buttons["pairing.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        shot("pairing-empty")
        paste.tap()
        let allow = app.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        shot("pairing-filled")
        app.buttons["pairing.submit"].tap()
        return app
    }

    func testInvalidLink() {
        let app = pasteAndSubmit("invalid")
        XCTAssertTrue(app.staticTexts["Paste a valid pairing link."].waitForExistence(timeout: 5))
        shot("pairing-error")
    }

    func testOfflinePairing() {
        let app = pasteAndSubmit("https://example.invalid/app/pair#fixture-not-a-real-code", offline: true)
        XCTAssertTrue(app.staticTexts["You are offline. Check your connection and try again."].waitForExistence(timeout: 5))
    }
}
