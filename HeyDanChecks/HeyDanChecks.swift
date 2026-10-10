import AppIntentsTesting
import XCTest

/// What used to need hands on the phone, driven in the Simulator (`just sim-checks`). Every HEYDAN_* variable the
/// runner gets (xcodebuild passes `TEST_RUNNER_HEYDAN_*`) reaches the app; HEYDAN_CHECKS_OUT is where screenshots go.
@MainActor
final class HeyDanChecks: XCTestCase {
    /// The app's bundle ID: this bundle's (`<app>.Checks`, project.yml) without the suffix.
    nonisolated private static let appID = String(Bundle(for: HeyDanChecks.self).bundleIdentifier!.dropLast(".Checks".count))
    private let app = XCUIApplication(bundleIdentifier: HeyDanChecks.appID)
    private let env = ProcessInfo.processInfo.environment
    /// Hooks that start calls or change the line's saved voice: a check passes them itself, never inherits them.
    private static let scriptedEnv: Set = ["HEYDAN_AUTOCALL", "HEYDAN_START_ON_SAMPLE", "HEYDAN_TTS_PATCH", "HEYDAN_VOICE_STEPS"]

    /// A stand-in call's Live Activity in the Dynamic Island (expanded by the sample's alert), then on the Lock Screen,
    /// with the system's "Allow Live Activities from Hey Dan?" choice under it when it asks.
    func testLiveActivityOnLockScreen() async throws {
        launch(["HEYDAN_PREVIEW_ACTIVITY": "listening"])
        try await Task.sleep(for: .seconds(2))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        shot("1-island-home")
        lock()
        try await Task.sleep(for: .seconds(3))
        // The screenshot is the check: a query into the Lock Screen waits on its ticking clock and never returns.
        shot("1-lock-screen")
        unlock()
    }

    /// The Start conversation intent run out of process, as Shortcuts or the Action Button would, with the app in the
    /// background (HEYDAN_CHECK_LOCKED=1: and the phone locked): the app comes forward and the call starts there.
    func testIntentStartsCallFromBackground() async throws {
        launch()
        try await Task.sleep(for: .seconds(2))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        if env["HEYDAN_CHECK_LOCKED"] == "1" {
            lock()
            try await Task.sleep(for: .seconds(2))
        }
        let intent = IntentDefinitions(bundleIdentifier: Self.appID).intents["StartConversationIntent"].makeIntent()
        let started = ContinuousClock.now
        do {
            try await intent.run()
            print("check: intent ran ms=\((ContinuousClock.now - started).components.seconds * 1000)")
        } catch {
            XCTFail("check: intent failed \(error)")
        }
        foreground()
        try await Task.sleep(for: .seconds(6))
        shot("2-intent-call")
        let hold = env["HEYDAN_CHECK_HOLD"].flatMap(Double.init) ?? 20
        try await Task.sleep(for: .seconds(hold))
        unlock()
    }

    /// The Action Button, set to Hey Dan's Start conversation (`testSetActionButtonToHeyDan`), pressed with the app in
    /// the background (HEYDAN_CHECK_LOCKED=1: on the locked phone): the app comes forward and the call starts there.
    func testActionButtonStartsCall() async throws {
        launch()
        try await Task.sleep(for: .seconds(2))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        if env["HEYDAN_CHECK_LOCKED"] == "1" {
            lock()
            try await Task.sleep(for: .seconds(2))
            // The Simulator takes a press on the dark screen as a key that wakes it, not as the button's action.
            XCUIDevice.shared.press(.action)
            try await Task.sleep(for: .seconds(2))
        }
        XCUIDevice.shared.press(.action)
        foreground()
        try await Task.sleep(for: .seconds(8))
        shot("3-action-button-call")
        let hold = env["HEYDAN_CHECK_HOLD"].flatMap(Double.init) ?? 20
        try await Task.sleep(for: .seconds(hold))
        unlock()
    }

    /// Settings > Action Button > Shortcut > Hey Dan's Start conversation, once per Simulator.
    func testSetActionButtonToHeyDan() async throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.staticTexts["Action Button"].firstMatch.tap()
        let dots = settings.pageIndicators.firstMatch
        XCTAssertTrue(dots.waitForExistence(timeout: 5))
        let choose = settings.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Choose a Shortcut'")).firstMatch
        // Settings reopens on the page it showed last: back to the first, then forward to Shortcut.
        for _ in 0 ..< 2 {
            settings.swipeRight()
            try await Task.sleep(for: .seconds(1))
        }
        for _ in 0 ..< 4 where !choose.exists {
            dots.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            try await Task.sleep(for: .seconds(1))
        }
        choose.tap()
        let heyDan = settings.staticTexts.matching(NSPredicate(format: "label == 'Hey Dan'")).firstMatch
        XCTAssertTrue(heyDan.waitForExistence(timeout: 10), "Hey Dan is not in the Action Button's shortcut list")
        heyDan.tap()
        let start = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Start conversation'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Hey Dan offers no Start conversation shortcut")
        // The tile is a remote view: its label shows to queries, but only a tap at its place (the sheet's first
        // tile, top left) selects it.
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.21)).press(forDuration: 0.15)
        try await Task.sleep(for: .seconds(5))
        shot("action-button-set")
        let picked = settings.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Start conversation'")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 5) && !settings.buttons["Close"].exists, "the shortcut was not picked")

    }

    func testVoicePickerSaved() throws {
        fixture("saved", voice: "pending")
        openVoice()
        assertText(ID.pickerSaved, "en-us-techagent-4")
        assertText(ID.pickerLive, "alnilam")
        assertText(ID.pickerNext, "bIHbv24MWmeRgasZH58o")
        shot("saved-pending")
        let requestedAt = Date()
        element(ID.pickerUseForCall).tap()
        XCTAssertTrue(element(ID.pickerResult).label.contains("Queued"), "picker.result must report queued before promotion")
        shot("saved-queued")
        let promoted = NSPredicate { [self] _, _ in
            text(ID.pickerLive).contains("en-us-techagent-4") && !element(ID.pickerNext).exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: promoted, object: nil)], timeout: remaining(5, since: requestedAt)), .completed)
        shot("saved-active")
        expandPicker()
        element(ID.pickerVoice).tap()
        XCTAssertTrue(element(ID.pickerSearch).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Achernar'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(samples.count, 0)
        shot("saved-gemini-catalog")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        chooseElevenLabs()
        element(ID.pickerVoice).tap()
        XCTAssertTrue(element(ID.pickerSample("bIHbv24MWmeRgasZH58o")).waitForExistence(timeout: 5))
        XCTAssertFalse(element(ID.pickerSample("bIHbv24MWmeRgasZH58o")).isEnabled)
        shot("saved-eleven-catalog")
    }

    func testVoicePickerLive() throws {
        fixture("saved", voice: "active")
        openVoice()
        assertText(ID.pickerLive, "bIHbv24MWmeRgasZH58o")
        XCTAssertFalse(element(ID.pickerNext).exists)
        shot("live-active")
        fixture("saved", voice: "refused")
        openVoice()
        let before = text(ID.pickerLive)
        element(ID.pickerUseForCall).tap()
        assertText(ID.pickerResult, "refused")
        XCTAssertEqual(text(ID.pickerLive), before)
        XCTAssertTrue(element(ID.pickerNext).exists)
        shot("live-refused")
        fixture("saved", voice: "ended")
        openVoice()
        XCTAssertFalse(element(ID.pickerUseForCall).exists)
        XCTAssertFalse(element(ID.pickerLive).exists)
        XCTAssertTrue(element(ID.pickerSave).exists)
        shot("live-ended")
    }

    func testVoicePickerFailures() throws {
        fixture("unsaved")
        openVoice()
        assertText(ID.pickerSaved, "Server default")
        shot("failure-unsaved")
        fixture("eleven-unavailable")
        openVoice()
        expandPicker()
        element(ID.pickerProvider).tap()
        let unavailable = app.buttons.matching(NSPredicate(format: "label CONTAINS 'ElevenLabs'")).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        XCTAssertFalse(unavailable.isEnabled)
        shot("failure-eleven-unavailable")
        fixture("no-route")
        openVoice(loaded: false)
        XCTAssertTrue(element(ID.pickerRetry).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This voice line does not support voice settings."].exists)
        XCTAssertFalse(element(ID.pickerSave).isEnabled)
        shot("failure-no-route")
        fixture("forbidden")
        openVoice()
        chooseElevenLabs()
        element(ID.pickerSave).tap()
        assertText(ID.pickerResult, "Access lost")
        XCTAssertTrue(element(ID.pickerSaved).exists)
        shot("failure-forbidden-save")
    }

    func testVoicePickerFailuresCatalog() throws {
        fixture("catalog-fail")
        openVoice()
        expandPicker()
        element(ID.pickerVoice).tap()
        XCTAssertTrue(element(ID.pickerRetry).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Could not load voices"].exists)
        shot("failure-catalog")
        element(ID.pickerRetry).tap()
        XCTAssertTrue(element(ID.pickerRetry).waitForExistence(timeout: 5))
        shot("failure-catalog-retry")
        fixture("search-empty")
        openVoice()
        expandPicker()
        element(ID.pickerVoice).tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no matching voice")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(samples.count, 0)
        shot("failure-search-empty")
        fixture("forbidden")
        openVoice()
        chooseElevenLabs()
        element(ID.pickerVoice).tap()
        XCTAssertTrue(element(ID.pickerRetry).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Access lost. Check this line's call link in Settings."].exists)
        shot("failure-forbidden-catalog")
    }

    func testCallOptions() throws {
        for phase in ["waiting", "manual"] {
            fixture("saved", phase: phase)
            XCTAssertTrue(element(ID.controlsMode).waitForExistence(timeout: 5))
            XCTAssertTrue(element(ID.controlsVoice).exists)
            element(ID.controlsOptions).tap()
            XCTAssertTrue(element(ID.optionsTyping).waitForExistence(timeout: 5))
            XCTAssertTrue(element(ID.optionsTyping).isEnabled)
            if phase == "waiting" {
                XCTAssertTrue(element(ID.optionsWake).exists)
                XCTAssertTrue(element(ID.optionsPauseSends).exists)
                XCTAssertTrue(element(ID.optionsWake).isEnabled)
                XCTAssertTrue(element(ID.optionsPauseSends).isEnabled)
            } else {
                XCTAssertFalse(element(ID.optionsWake).exists)
                XCTAssertFalse(element(ID.optionsPauseSends).exists)
            }
            shot("options-\(phase)")
        }
    }

    func testVoicePickerSaves() throws {
        guard let restore = env["HEYDAN_TTS_RESTORE"], !restore.isEmpty,
              let data = restore.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["reset"] as? Bool == true || body["provider"] as? String != nil else {
            XCTFail("HEYDAN_TTS_RESTORE must contain the captured restore body before any mutation")
            return
        }
        launchReal()
        openVoice()
        XCTAssertEqual(element(ID.pickerTitle).label, "Stan's voice")
        guard element(ID.pickerTitle).label == "Stan's voice" else { return }
        let original = text(ID.pickerSaved)
        addTeardownBlock { @MainActor [self] in
            app.terminate()
            launchReal(["HEYDAN_TTS_PATCH": restore])
            let deadline = Date().addingTimeInterval(30)
            var restored = false
            repeat {
                openVoice()
                let matches = NSPredicate { [self] _, _ in text(ID.pickerSaved) == original }
                restored = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)],
                                         timeout: max(0, min(5, deadline.timeIntervalSinceNow))) == .completed
                if !restored { element(ID.pickerClose).tap() }
            } while !restored && Date() < deadline
            XCTAssertTrue(restored, "The captured saved voice was not restored")
            shot("saves-restored")
        }
        shot("saves-before")
        chooseProvider("Gemini")
        element(ID.pickerVoice).tap()
        XCTAssertTrue(element(ID.pickerSearch).waitForExistence(timeout: 10))
        let choices = app.buttons.matching(NSPredicate(format: "label CONTAINS 'No sample available' AND NOT label CONTAINS 'Selected' AND enabled == true"))
        guard choices.firstMatch.waitForExistence(timeout: 15) else {
            XCTFail("The Gemini catalog did not load")
            return
        }
        guard let choice = choices.allElementsBoundByIndex.first(where: {
            let name = $0.label.components(separatedBy: ",").first ?? $0.label
            return $0.isEnabled && $0.isHittable && !original.localizedCaseInsensitiveContains(name)
        }) else {
            XCTFail("No available voice different from the current selection")
            return
        }
        choice.tap()
        XCTAssertTrue(element(ID.pickerSave).waitForExistence(timeout: 5))
        XCTAssertTrue(element(ID.pickerSave).isEnabled)
        element(ID.pickerSave).tap()
        assertText(ID.pickerResult, "Saved for next calls", timeout: 20)
        XCTAssertNotEqual(text(ID.pickerSaved), original)
        shot("saves-changed")
    }

    func testSampleThenCall() async throws {
        launchReal(["HEYDAN_START_ON_SAMPLE": "1", "HEYDAN_HANGUP_AFTER": "40"])
        openVoice()
        chooseElevenLabs()
        element(ID.pickerVoice).tap()
        XCTAssertTrue(samples.firstMatch.waitForExistence(timeout: 15))
        let sampledAt = Date()
        let firstSample = samples.firstMatch
        firstSample.tap()
        let disabledDeadline = Date().addingTimeInterval(2)
        let enabledSamples = samples.matching(NSPredicate(format: "enabled == true"))
        var allDisabled = false
        while Date() < disabledDeadline {
            if !firstSample.isEnabled && enabledSamples.count == 0 {
                allDisabled = Date() <= disabledDeadline
                break
            }
            try await Task.sleep(for: .seconds(min(0.1, max(0, disabledDeadline.timeIntervalSinceNow))))
        }
        XCTAssertTrue(allDisabled, "Every picker.sample.* button must be disabled within 2 s of the sample tap returning")
        acceptCallOpenAlert()
        XCTAssertTrue(element(ID.pickerSearch).exists)
        shot("sample-call-claimed")
        // The medium detent exposes the background accessibility tree without dismissing the catalog.
        element(ID.pickerSearch).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.49)))
        XCTAssertTrue(element(ID.pickerSearch).exists)
        assertCallKey("End call", timeout: remaining(20, since: sampledAt))
        XCTAssertTrue(element(ID.pickerSearch).exists)
        shot("sample-call-live")
        assertCallKey("Call again", timeout: remaining(50, since: sampledAt))
        shot("sample-call-ended")
    }

    /// Popping the catalog stops its sample before Close dismisses the picker and one Call tap starts the call.
    func testSampleDismissThenCall() async throws {
        launchReal(["HEYDAN_HANGUP_AFTER": "40"])
        openVoice()
        chooseElevenLabs()
        element(ID.pickerVoice).tap()
        XCTAssertTrue(samples.firstMatch.waitForExistence(timeout: 15))
        samples.firstMatch.tap()
        try await Task.sleep(for: .seconds(2))
        shot("sample-dismiss-playing")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        guard element(ID.pickerClose).waitForExistence(timeout: 5) else {
            XCTFail("picker.close must be available after returning to the summary")
            return
        }
        element(ID.pickerClose).tap()
        if app.buttons["Discard changes"].waitForExistence(timeout: 2) { app.buttons["Discard changes"].tap() }
        XCTAssertTrue(element(ID.keysCall).waitForExistence(timeout: 5))
        element(ID.keysCall).tap()
        acceptCallOpenAlert()
        try await Task.sleep(for: .seconds(45))
        assertCallKey("Call again", timeout: 5)
        shot("sample-dismiss-call-ended")
    }

    private func acceptCallOpenAlert() {
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) {
            open.tap()
            app.activate()
        }
    }

    private enum ID {
        static let controlsMode = "controls.mode", controlsVoice = "controls.voice",
            controlsOptions = "controls.options", keysCall = "keys.call", optionsWake = "options.wake",
            optionsPauseSends = "options.pauseSends", optionsTyping = "options.typing", pickerTitle = "picker.title",
            pickerClose = "picker.close", pickerSaved = "picker.saved", pickerLive = "picker.live", pickerNext = "picker.next",
            pickerProvider = "picker.provider", pickerVoice = "picker.voice", pickerSearch = "picker.search",
            pickerUseForCall = "picker.useForCall", pickerSave = "picker.save", pickerResult = "picker.result",
            pickerRetry = "picker.retry"
        static func pickerSample(_ id: String) -> String { "picker.sample.\(id)" }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var samples: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'picker.sample.'"))
    }

    private func text(_ id: String) -> String {
        let item = element(id)
        guard item.exists else { return "" }
        return item.label + " " + (item.value as? String ?? "")
    }

    private func assertText(_ id: String, _ expected: String, timeout: TimeInterval = 5) {
        let matches = NSPredicate { [self] _, _ in text(id).localizedCaseInsensitiveContains(expected) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: timeout), .completed,
                       "\(id) must show \(expected)")
    }

    private func remaining(_ seconds: TimeInterval, since start: Date) -> TimeInterval {
        max(0, seconds - Date().timeIntervalSince(start))
    }

    private func assertCallKey(_ label: String, timeout: TimeInterval) {
        let prefix = label == "End call" ? "end" : "call again"
        let matches = NSPredicate { [self] _, _ in element(ID.keysCall).label.lowercased().hasPrefix(prefix) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: timeout), .completed,
                       "The call key must show \(label)")
    }

    private func fixture(_ scenario: String, voice: String = "", phase: String = "waiting") {
        app.terminate()
        launch(["HEYDAN_PREVIEW_TTS": scenario, "HEYDAN_PREVIEW_VOICE": voice, "HEYDAN_PREVIEW_PHASE": phase])
    }

    private func openVoice(loaded: Bool = true) {
        XCTAssertTrue(element(ID.controlsVoice).waitForExistence(timeout: 10))
        element(ID.controlsVoice).tap()
        XCTAssertTrue(element(ID.pickerTitle).waitForExistence(timeout: 5))
        if loaded { XCTAssertTrue(element(ID.pickerSaved).waitForExistence(timeout: 10)) }
    }

    private func expandPicker() {
        let title = element(ID.pickerTitle)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.8))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
    }

    private func chooseElevenLabs() { chooseProvider("ElevenLabs") }

    private func chooseProvider(_ name: String) {
        expandPicker()
        element(ID.pickerProvider).tap()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@", name, ID.pickerProvider)).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        XCTAssertTrue(provider.isEnabled)
        provider.tap()
    }

    private func launchReal(_ extra: [String: String] = [:]) {
        launch(extra, excluding: Set(env.keys.filter { $0.hasPrefix("HEYDAN_PREVIEW_") }))
    }

    /// The call link never goes through here: `just sim-checks` seeds it into the Simulator's keychain, and a result
    /// bundle records every launch environment.
    private func launch(_ extra: [String: String] = [:], excluding: Set<String> = []) {
        let withheld = Self.scriptedEnv.union(["HEYDAN_CHECKS_OUT", "HEYDAN_CALL_LINK"])
        app.launchEnvironment = env.filter { $0.key.hasPrefix("HEYDAN_") && !withheld.contains($0.key) && !excluding.contains($0.key) }
            .merging(extra) { $1 }
        app.launch()
    }

    private func foreground() {
        let up = app.wait(for: .runningForeground, timeout: 15)
        print("check: app in front=\(up)")
        XCTAssertTrue(up, "Hey Dan did not come forward")
    }

    // The Simulator's lock (Device Hub > Controls > Lock) has no public XCUIDevice button; pressLockButton is its
    // private counterpart, used only here.
    private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
    }

    private func unlock() {
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = env["HEYDAN_CHECKS_OUT"], !dir.isEmpty else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }
}
