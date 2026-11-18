import UIKit
import XCTest

@MainActor final class ChatPairingChecks: XCTestCase {
    private func pasteAndSubmit(_ value: String, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_SHOW_PAIRING"] = "1"
        if offline { app.launchEnvironment["HEYDAN_OFFLINE_FOR"] = "60" }
        seedPasteboard(value)
        app.launch()
        let paste = app.buttons["pairing.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        XCTAssertTrue(paste.isEnabled)
        shot("pairing-empty")
        paste.tap()
        allowPaste(in: app)
        XCTAssertTrue(app.buttons["pairing.submit"].isEnabled)
        shot("pairing-filled")
        app.buttons["pairing.submit"].tap()
        return app
    }

    func testPairingFromUnpairedVoiceLines() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_PREVIEW_SETTINGS"] = "1"
        app.launch()
        let pair = app.buttons["Pair a host"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        pair.tap()
        XCTAssertTrue(app.buttons["pairing.paste"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
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

extension XCTestCase {
    @MainActor func seedPasteboard(_ text: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    }

    @MainActor func allowPaste(in app: XCUIApplication) {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"].firstMatch
        if system.waitForExistence(timeout: 2) { system.tap(); return }
        let local = app.buttons["Allow Paste"].firstMatch
        if local.exists { local.tap() }
    }
}
