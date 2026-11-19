import UIKit
import XCTest

@MainActor final class ChatPairingChecks: XCTestCase {
    private func pasteAndSubmit(_ value: String, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_SHOW_PAIRING"] = "1"
        if offline { app.launchEnvironment["HEYDAN_OFFLINE_FOR"] = "60" }
        seedPasteboard(value)
        app.launchForChecks()
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
        app.launchForChecks()
        let pair = app.buttons["Pair a host"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        pair.tap()
        XCTAssertTrue(app.buttons["pairing.paste"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
    }

    func testAgentSwipesAndSettings() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        func swipe(_ action: String, leading: Bool) {
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: leading ? 110 : -110, dy: 0)))
            let button = app.buttons[action]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }

        swipe("Read", leading: true)
        XCTAssertTrue(row.wait(for: \.label, toEqual: "Taylor, Working", timeout: 5))
        swipe("Unread", leading: true)
        XCTAssertTrue(row.wait(for: \.label, toEqual: "Taylor, Working, 1 unread", timeout: 5))
        swipe("Hide", leading: false)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hidden. Show it again in Settings > Agents."].exists)

        app.buttons["Settings"].tap()
        app.buttons["Agents"].tap()
        let toggle = app.switches["chat.settings.agent.ag_taylor"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed)
        app.navigationBars["Agents"].buttons.firstMatch.tap()
        app.buttons["Chats"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
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
