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

    private func openStreamingCall() -> (XCUIApplication, XCUIElement, URL) {
        let step = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: step) }
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1",
                                    "HEYDAN_FIXTURE_THREAD": "call-stream", "HEYDAN_FIXTURE_STREAM_STEP": step.path])
        return (app, call, step)
    }

    func testFollowStreamingCall() throws {
        let (app, call, step) = openStreamingCall()
        let feed = app.scrollViews["chat.thread"]
        let start = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 24)),
                    withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["chat.scrollToEnd"].exists)
        call.tap()
        let caption = app.descendants(matching: .any)["chat.call.caption"].firstMatch
        let reply = app.descendants(matching: .any)["chat.message.msg_stream"].firstMatch
        let bar = app.buttons["controls.mute"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        let gap = bar.frame.minY - caption.frame.maxY
        XCTAssertGreaterThan(gap, 0)
        XCTAssertLessThan(gap, 40)
        let captionHeight = caption.frame.height
        let left = reply.frame.minX
        XCTAssertTrue(app.buttons["chat.scrollToEnd"].waitForNonExistence(timeout: 3))
        var replyHeight = reply.frame.height
        shot("call-follow-start")
        for (state, capture) in [("Thinking", "middle"), ("Speaking", "end")] {
            try state.write(to: step, atomically: true, encoding: .utf8)
            XCTAssertTrue(app.staticTexts[state].waitForExistence(timeout: 15))
            XCTAssertEqual(reply.frame.minX, left, accuracy: 0.5)
            XCTAssertGreaterThan(reply.frame.height, replyHeight)
            replyHeight = reply.frame.height
            XCTAssertGreaterThan(caption.frame.height, captionHeight)
            XCTAssertEqual(bar.frame.minY - caption.frame.maxY, gap, accuracy: 0.5)
            XCTAssertFalse(app.buttons["chat.scrollToEnd"].exists)
            shot("call-follow-" + capture)
        }
    }

    func testReadHistoryDuringStreamingCall() throws {
        let (app, call, step) = openStreamingCall()
        call.tap()
        let start = app.scrollViews["chat.thread"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let end = app.buttons["chat.scrollToEnd"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        let earlier = app.descendants(matching: .any)["chat.card.msg_card"].firstMatch
        XCTAssertTrue(earlier.isHittable)
        let y = earlier.frame.minY
        shot("call-history-start")
        for state in ["Thinking", "Speaking"] {
            try state.write(to: step, atomically: true, encoding: .utf8)
            XCTAssertTrue(app.staticTexts[state].waitForExistence(timeout: 15))
            XCTAssertTrue(end.isHittable)
            XCTAssertEqual(earlier.frame.minY, y, accuracy: 0.5)
        }
        shot("call-history-end")
        end.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["chat.call.caption"].firstMatch.isHittable)
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
        let callerCaption = app.staticTexts["call.callerCaption"]
        XCTAssertEqual(callerCaption.label, "Check the backup.")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Pair a host"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        shot("thread-call-mode")
        app.buttons["controls.mute"].tap()
        XCTAssertEqual(app.buttons["controls.mute"].label, "Unmute")
        XCTAssertFalse(callerCaption.exists)
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
        activeRow.swipeLeft()
        app.buttons["Hide"].tap()
        XCTAssertTrue(app.alerts.staticTexts["End the current call first."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(activeRow.exists)
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

    func testSettingsProtectsTheCallHostAndAgent() {
        let (app, call) = openCall(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1"])
        call.tap()
        XCTAssertTrue(app.buttons["keys.call"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let refusal = app.staticTexts["End the current call first."]
        app.buttons["chat.settings.host.studio.example.ts.net"].tap()
        app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
        app.buttons["chat.settings.host.back"].tap()

        app.buttons["Agents"].tap()
        let agent = app.switches["chat.settings.agent.ag_taylor"]
        agent.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
        XCTAssertEqual(agent.value as? String, "1")
        app.buttons["chat.settings.agents.back"].tap()

        seedPasteboard("https://example.invalid/app/pair#fixture")
        app.buttons["Pair a host"].tap()
        app.buttons["pairing.paste"].tap()
        allowPaste(in: app)
        app.buttons["pairing.submit"].tap()
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
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
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_THREAD": "control-admission"])
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let bundle = String(Bundle(for: Self.self).bundleIdentifier!.dropLast(".Checks".count))
        // Under load the app can go straight to suspended; either background state is fine for the intent.
        let backgrounded = NSPredicate { _, _ in [.runningBackground, .runningBackgroundSuspended].contains(app.state) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: backgrounded, object: nil)], timeout: 20), .completed)
        do {
            try await IntentDefinitions(bundleIdentifier: bundle).intents["CallDefaultAgentIntent"].makeIntent().run()
            XCTFail("The fixture host refuses admission")
        } catch {}
        app.activate()
        let admission = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CallKit admitted the")).firstMatch
        XCTAssertTrue(admission.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Call again"].exists)
        if admission.label.contains("background call") {
            print("check: CallKit admitted the background Control")
        } else {
            XCTAssertTrue(admission.label.contains("foreground call"))
            print("check: CallKit admitted the Control after foregrounding")
        }
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
        app.navigationBars["Taylor"].buttons.element(boundBy: 0).tap()
        app.buttons["chat.conversation.conv_taylor01"].tap()
        XCTAssertFalse(retry.exists)
        call.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let field = app.textFields["composer.text"]
        field.tap()
        field.typeText("Ready")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
    }
}
