import XCTest

@MainActor final class ChatAgentSettingsChecks: XCTestCase {
    private func openThread(_ scenario: String = "settings") -> XCUIApplication {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_THREAD": scenario])
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        return app
    }

    func testSaveSettingsWhileWorking() {
        let app = openThread()
        let chip = app.buttons["composer.model"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertTrue(chip.wait(for: \.label, toEqual: "Default - Sonnet 5.5", timeout: 5))
        chip.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        let model = app.buttons["Opus 5.5"]
        if !model.isHittable { app.swipeUp() }
        model.tap()
        let effort = app.buttons["Medium"]
        for _ in 0..<3 where !effort.isHittable { app.swipeUp() }
        effort.tap()
        app.buttons["Save"].tap()
        let alert = app.alerts["Changing the model stops the current reply."]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        app.buttons["Save"].tap()
        alert.buttons["Save"].tap()
        XCTAssertTrue(chip.wait(for: \.label, toEqual: "Opus 5.5 - Medium", timeout: 5))
    }

    func testCompactSendsAndRefreshesOnIdle() {
        let app = openThread()
        let gauge = app.buttons["composer.context"]
        XCTAssertTrue(gauge.waitForExistence(timeout: 10))
        XCTAssertEqual(gauge.label, "99k of 165k tokens used (60%)")
        gauge.tap()
        app.buttons["Compact now"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'chat.message.' AND label CONTAINS %@ AND label CONTAINS 'Reached'", "/compact")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertTrue(gauge.wait(for: \.label, toEqual: "18k of 165k tokens used (11%)", timeout: 5))
    }

    func testReadOnlySettingsFromHeader() {
        let app = openThread("read-only")
        let menu = app.buttons["Thread menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Agent settings"].tap()
        let row = app.buttons["Sonnet 5.5"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.isEnabled)
        XCTAssertTrue(app.buttons["Done"].exists)
    }
}
