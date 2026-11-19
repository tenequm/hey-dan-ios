import XCTest

@MainActor final class ChatAgentSettingsChecks: XCTestCase {
    private func openThread(_ scenario: String = "settings", call: Bool = false) -> XCUIApplication {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_THREAD": scenario,
                              "HEYDAN_FIXTURE_LIVE_CALL": call ? "1" : "0"])
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    private func save(in app: XCUIApplication, cancelFirst: Bool = false) {
        app.buttons["Save"].tap()
        let alert = app.alerts["Changes Taylor in every chat. A reply in progress stops."]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        if cancelFirst {
            alert.buttons["Cancel"].tap()
            app.buttons["Save"].tap()
        }
        alert.buttons["Save"].tap()
    }

    func testSaveSettingsWhileWorking() {
        let app = openThread()
        let chip = app.buttons["composer.model"]
        XCTAssertTrue(chip.wait(for: \.label, toEqual: "Model, Default - Sonnet 5.5, effort High", timeout: 10))
        chip.tap()
        let model = app.buttons["Opus 5.5"]
        reveal(model, in: app)
        model.tap()
        let effort = app.buttons["Extra high"]
        reveal(effort, in: app)
        effort.tap()
        save(in: app, cancelFirst: true)
        XCTAssertTrue(chip.wait(for: \.label, toEqual: "Model, Opus 5.5, effort Extra high", timeout: 5))

        chip.tap()
        app.buttons["Default - Sonnet 5.5"].tap()
        save(in: app)
        XCTAssertTrue(chip.wait(for: \.label, toEqual: "Model, Default - Sonnet 5.5, effort Extra high", timeout: 5))
        chip.tap()
        XCTAssertFalse(app.buttons["Default"].exists)
    }

    func testCompactSendsAndRefreshesOnIdle() {
        let app = openThread("idle")
        let gauge = app.buttons["composer.context"]
        let chip = app.buttons["composer.model"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertFalse(gauge.exists)
        app.descendants(matching: .any)["composer.text"].firstMatch.tap()
        XCTAssertTrue(gauge.wait(for: \.label, toEqual: "99 thousand of 165 thousand tokens, 60 percent", timeout: 5))
        gauge.tap()
        app.buttons["Compact now"].tap()
        let completed = app.staticTexts.matching(NSPredicate(format: "label == %@", "Context compacted")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 10))
        XCTAssertFalse(gauge.exists)
        XCTAssertFalse(app.staticTexts["Received."].exists)
        chip.tap()
        app.buttons["Opus 5.5"].tap()
        save(in: app)
        XCTAssertTrue(chip.wait(for: \.label, toEqual: "Model, Opus 5.5, effort High", timeout: 5))
    }

    func testReadOnlySettingsFromHeader() {
        let app = openThread("read-only")
        let menu = app.buttons["chat.thread.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(menu.label, "Taylor")
        XCTAssertEqual(menu.value as? String, "app.example.com")
        menu.tap()
        app.buttons["Agent settings"].tap()
        let row = app.buttons["Sonnet 5.5"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.isEnabled)
        let context = app.staticTexts["Context"]
        reveal(context, in: app)
        XCTAssertFalse(app.buttons["Compact now"].exists)
        app.buttons["Done"].tap()
        app.descendants(matching: .any)["composer.text"].firstMatch.tap()
        app.buttons["composer.context"].tap()
        XCTAssertFalse(app.buttons["Compact now"].exists)
    }

    func testHostRefusalKeepsSettingsOpen() {
        let app = openThread("permission-changed")
        let chip = app.buttons["composer.model"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        app.buttons["Opus 5.5"].tap()
        save(in: app)
        XCTAssertTrue(app.staticTexts["Admin access is required."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(chip.label, "Model, Default - Sonnet 5.5, effort High")
    }

    func testSettingsDisabledDuringCall() {
        let app = openThread(call: true)
        app.buttons["chat.call"].tap()
        let end = app.buttons["keys.call"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        let header = app.buttons["chat.thread.menu"]
        XCTAssertEqual(header.label, "Taylor")
        XCTAssertTrue((header.value as? String)?.contains("On call") == true)
        header.tap()
        let settings = app.buttons["Agent settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.isEnabled)
        app.scrollViews["chat.thread"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        end.tap()
    }
}
