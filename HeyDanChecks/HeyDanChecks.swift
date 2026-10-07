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

    /// The call link never goes through here: `just sim-checks` seeds it into the Simulator's keychain, and a result
    /// bundle records every launch environment.
    private func launch(_ extra: [String: String] = [:]) {
        let withheld: Set = ["HEYDAN_CHECKS_OUT", "HEYDAN_CALL_LINK"]
        app.launchEnvironment = env.filter { $0.key.hasPrefix("HEYDAN_") && !withheld.contains($0.key) }
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
