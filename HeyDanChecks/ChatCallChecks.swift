import AppIntentsTesting
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
        let host = app.buttons["chat.settings.host.app.example.com"]
        host.tap()
        XCTAssertTrue(app.buttons["Unpair"].waitForExistence(timeout: 5))
        app.buttons["chat.settings.host.back"].tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Default agent")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Taylor")).firstMatch.tap()
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
        app.buttons["chat.settings.host.back"].tap()
        app.buttons["Chats"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testCallStaysInThread() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1"])
        let feed = app.scrollViews["chat.thread"]
        let composer = app.descendants(matching: .any)["composer.text"].firstMatch
        call.tap()
        let end = app.buttons["keys.call"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(feed.exists)
        XCTAssertTrue(app.navigationBars["Taylor"].exists)
        XCTAssertTrue(feed.descendants(matching: .any)["chat.call.caption"].firstMatch.exists)
        XCTAssertFalse(call.exists)
        XCTAssertFalse(composer.exists)
        shot("thread-call-mode")
        app.buttons["controls.mute"].tap()
        XCTAssertEqual(app.buttons["controls.mute"].label, "Unmute")
        app.buttons["controls.options"].tap()
        XCTAssertTrue(app.switches["options.typing"].firstMatch.waitForExistence(timeout: 5))
        shot("thread-call-options")
        XCTAssertTrue(app.buttons["options.voice"].isEnabled)
        app.buttons["options.voice"].tap()
        XCTAssertTrue(app.staticTexts["picker.title"].waitForExistence(timeout: 5))
        app.buttons["picker.close"].tap()
        app.navigationBars["Taylor"].buttons.element(boundBy: 0).tap()
        let activeRow = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(activeRow.waitForExistence(timeout: 5))
        XCTAssertTrue(activeRow.label.contains("On call"))
        app.buttons["chat.conversation.conv_second"].tap()
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertFalse(call.isEnabled)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Taylor"].exists)
        end.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(call.exists)
        XCTAssertFalse(app.buttons["Call again"].exists)
    }

    func testDefaultAgentControlOpensItsThread() async throws {
        let app = XCUIApplication()
        // The id of the second fixture agent in the same preference the Settings picker writes.
        app.launchArguments = ["-defaultCallAgent", "D74EE161-D39B-8676-8284-073F5027332F"]
        app.launchEnvironment = ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1"]
        app.launchForChecks()
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let bundle = String(Bundle(for: Self.self).bundleIdentifier!.dropLast(".Checks".count))
        try await IntentDefinitions(bundleIdentifier: bundle).intents["CallDefaultAgentIntent"].makeIntent().run()
        app.activate()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Alex"].exists)
        XCTAssertTrue(app.buttons["keys.call"].exists)
        app.buttons["keys.call"].tap()
    }

    func testSavedCallShortcutUsesTheCurrentDefault() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-defaultCallAgent", "D74EE161-D39B-8676-8284-073F5027332F"]
        app.launchEnvironment = ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1"]
        app.launchForChecks()
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 10))
        let bundle = String(Bundle(for: Self.self).bundleIdentifier!.dropLast(".Checks".count))
        let definitions = IntentDefinitions(bundleIdentifier: bundle)
        let entities = definitions.entities["VoiceLineEntity"]
        for id in [UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, UUID()] {
            let matches = try await entities.entities(identifiers: [id])
            let destination = try XCTUnwrap(matches.first)
            let intent = definitions.intents["CallLineIntent"].makeIntent(destination: destination,
                audioVisualMode: definitions.enums["CallAVMode"].makeCase("audio"))
            XCUIDevice.shared.press(.home)
            try await intent.run()
            app.activate()
            let end = app.buttons["keys.call"]
            XCTAssertTrue(end.waitForExistence(timeout: 10))
            XCTAssertTrue(app.scrollViews["chat.thread"].exists)
            XCTAssertTrue(app.navigationBars["Alex"].exists)
            end.tap()
            XCTAssertTrue(app.buttons["chat.call"].waitForExistence(timeout: 5))
        }
    }

    func testBackgroundControlReachesPairedCallAdmission() async throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let bundle = String(Bundle(for: Self.self).bundleIdentifier!.dropLast(".Checks".count))
        do {
            try await IntentDefinitions(bundleIdentifier: bundle).intents["CallDefaultAgentIntent"].makeIntent().run()
            XCTFail("The fixture host refuses admission")
        } catch {}
        app.activate()
        let reason = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "calls are unavailable in this preview"))
        XCTAssertTrue(reason.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Call again"].exists)
    }

    func testBackgroundCallShortcutReachesPairedCallAdmission() async throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 10))
        let bundle = String(Bundle(for: Self.self).bundleIdentifier!.dropLast(".Checks".count))
        let definitions = IntentDefinitions(bundleIdentifier: bundle)
        let agents = try await definitions.entities["VoiceLineEntity"].suggestedEntities()
        let intent = definitions.intents["CallLineIntent"].makeIntent(destination: try XCTUnwrap(agents.first),
            audioVisualMode: definitions.enums["CallAVMode"].makeCase("audio"))
        XCUIDevice.shared.press(.home)
        do {
            try await intent.run()
            XCTFail("The fixture host refuses admission")
        } catch {}
        app.activate()
        let reason = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "calls are unavailable in this preview"))
        XCTAssertTrue(reason.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Call again"].exists)
    }

    func testFailureOffersCallAgainInThread() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1"])
        call.tap()
        let retry = app.buttons["Call again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let reason = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "calls are unavailable in this preview"))
        XCTAssertTrue(reason.firstMatch.exists)
        XCTAssertTrue(app.scrollViews["chat.thread"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["composer.text"].firstMatch.exists)
        XCTAssertTrue(retry.isEnabled)
    }
}
