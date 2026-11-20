import AVFAudio
import AppIntentsTesting
import XCTest

@MainActor final class PairedVoiceChecks: XCTestCase {
    private func openPicker(_ environment: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1"].merging(environment) { _, new in new })
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let voice = app.buttons["Voice: Taylor"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()
        XCTAssertTrue(app.staticTexts["picker.title"].waitForExistence(timeout: 5))
        return app
    }

    private func catalog(_ app: XCUIApplication) {
        let button = app.buttons["picker.voice"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.navigationBars["Choose a voice"].waitForExistence(timeout: 5))
    }

    private func voice(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    func testLoadRetryAndCatalogFilters() {
        let app = openPicker(["HEYDAN_FIXTURE_VOICE_FAILURE": "load"])
        let retry = app.buttons["picker.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        catalog(app)
        let roger = voice("Roger", in: app)
        XCTAssertTrue(roger.waitForExistence(timeout: 5))
        app.buttons["picker.filter"].tap()
        app.buttons["Female"].firstMatch.tap()
        XCTAssertTrue(roger.waitForNonExistence(timeout: 5))
        XCTAssertTrue(voice("Sarah", in: app).exists)
    }

    func testCatalogFailure() {
        let app = openPicker(["HEYDAN_FIXTURE_VOICE_FAILURE": "catalog"])
        catalog(app)
        let retry = app.buttons["picker.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(app.staticTexts["Could not load voices"].waitForExistence(timeout: 5))
        XCTAssertFalse(voice("Roger", in: app).exists)
    }

    func testVoiceNameRetryAndReset() {
        let app = openPicker(["HEYDAN_FIXTURE_VOICE_FAILURE": "names"])
        let retry = app.buttons["picker.nameRetry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        let saved = app.descendants(matching: .any)["picker.saved"].firstMatch
        XCTAssertEqual(saved.value as? String, "Aria (ElevenLabs)")
        let reset = app.buttons["picker.reset"].firstMatch
        reset.tap()
        app.buttons["Reset saved voice"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Saved voice reset")).firstMatch.waitForExistence(timeout: 5))
    }

    private func openCallPicker(refusesChange: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        var environment = ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_LIVE_CALL": "1"]
        if refusesChange { environment["HEYDAN_FIXTURE_VOICE_FAILURE"] = "live" }
        let app = launchChat(environment)
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["chat.call"].tap()
        app.buttons["controls.options"].tap()
        app.buttons["options.voice"].tap()
        XCTAssertTrue(app.staticTexts["picker.title"].waitForExistence(timeout: 5))
        return app
    }

    func testRefusedLiveVoiceKeepsItsName() {
        let app = openCallPicker(refusesChange: true)
        let use = app.buttons["picker.useForCall"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.tap()
        let refused = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "change was refused")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["picker.live"].firstMatch.value as? String, "Aria (ElevenLabs)")
    }

    func testInCallVoiceSwitchUpdatesOnlyTheLiveVoice() {
        let app = openCallPicker()
        catalog(app)
        let roger = voice("Roger", in: app)
        XCTAssertTrue(roger.waitForExistence(timeout: 5))
        roger.tap()
        let use = app.buttons["picker.useForCall"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.tap()
        let active = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "picker.live", "Roger")).firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["picker.saved"].firstMatch.value as? String, "Aria (ElevenLabs)")
    }

    func testLostSaveReadsBackTheSelectedVoice() {
        let app = openPicker(["HEYDAN_FIXTURE_VOICE_FAILURE": "lost-save"])
        catalog(app)
        let roger = voice("Roger", in: app)
        XCTAssertTrue(roger.waitForExistence(timeout: 5))
        roger.tap()
        let save = app.buttons["picker.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let confirmed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "confirmed after retry")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 5))
        app.buttons["picker.close"].tap()
        app.buttons["Voice: Taylor"].tap()
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "picker.saved", "Roger")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
    }

    func testCallTakesAudioFromPlayingSample() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let app = openPicker(["HEYDAN_FIXTURE_SAMPLE": url.path])
        catalog(app)
        let sample = app.buttons["picker.sample.roger"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertTrue(app.buttons["Stop sample: Roger"].waitForExistence(timeout: 5))
        let bundle = String(Bundle(for: Self.self).bundleIdentifier!.dropLast(".Checks".count))
        let definitions = IntentDefinitions(bundleIdentifier: bundle)
        let agents = try await withRegisteredIntentMetadata {
            try await definitions.entities["VoiceLineEntity"].entities(identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000000")!])
        }
        try await definitions.intents["CallLineIntent"].makeIntent(destination: XCTUnwrap(agents.first),
            audioVisualMode: definitions.enums["CallAVMode"].makeCase("audio")).run()
        XCTAssertTrue(app.buttons["Stop sample: Roger"].waitForNonExistence(timeout: 5))
        if sample.exists { XCTAssertFalse(sample.isEnabled) }
        if app.navigationBars["Choose a voice"].exists {
            app.navigationBars["Choose a voice"].buttons.element(boundBy: 0).tap()
        }
        if app.buttons["picker.close"].exists { app.buttons["picker.close"].tap() }
        if app.buttons["Chats"].exists { app.buttons["Chats"].tap() }
        XCTAssertTrue(app.buttons["keys.call"].waitForExistence(timeout: 5))
        app.buttons["keys.call"].tap()
    }
}
