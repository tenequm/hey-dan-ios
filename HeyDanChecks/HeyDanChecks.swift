import AppIntentsTesting
import XCTest

/// What used to need hands on the phone, driven in the Simulator (`just sim-checks`). Every HEYDAN_* variable the
/// runner gets (xcodebuild passes `TEST_RUNNER_HEYDAN_*`) reaches the app; HEYDAN_CHECKS_OUT is where screenshots go.
@MainActor
final class HeyDanChecks: XCTestCase {
    /// The app's bundle ID: this bundle's (`<app>.Checks`, project.yml) without the suffix.
    nonisolated private static let appID = String(Bundle(for: HeyDanChecks.self).bundleIdentifier!.dropLast(".Checks".count))
    private let app = XCUIApplication(bundleIdentifier: HeyDanChecks.appID)

    func testE2EMicrophonePermission() {
        continueAfterFailure = false
        app.resetAuthorizationStatus(for: .microphone)
        app.launchEnvironment = ["HEYDAN_E2E_MIC_PERMISSION": "1"]
        app.launchForChecks()
        XCTAssertTrue(allowSpringBoardPermission(), "Microphone permission alert must be accepted")
        app.terminate()
    }

    private func allowSpringBoardPermission() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 15) else { return false }
        let allow = alert.buttons["Allow"].firstMatch
        guard allow.waitForExistence(timeout: 2) else { return false }
        // Waited on by identifier: `alert` is whichever SpringBoard alert shows, so one that follows this prompt matches it too.
        let identifier = allow.identifier
        guard !identifier.isEmpty else { return false }
        let permissionButton = springboard.buttons[identifier].firstMatch
        allow.tap()
        return permissionButton.waitForNonExistence(timeout: 5)
    }

    /// A stand-in call's Live Activity in the Dynamic Island (expanded by the sample's alert), then on the Lock Screen,
    /// with the system's "Allow Live Activities from Hey Dan?" choice under it when it asks.
    func testLiveActivityOnLockScreen() async throws {
        app.launchEnvironment = ["HEYDAN_PREVIEW_ACTIVITY": "listening", "HEYDAN_FIXTURE_CHAT": "1"]
        app.launchForChecks()
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

    func testDefaultAgentIsSuggestedToShortcuts() async throws {
        app.launchEnvironment = ["HEYDAN_FIXTURE_CHAT": "1"]
        app.launchForChecks()
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        let definitions = IntentDefinitions(bundleIdentifier: Self.appID)
        let agents = definitions.entities["AgentEntity"]
        let defaults = try await agents.entities(identifiers: [UUID(uuidString: "00000000-0000-0000-0000-000000000000")!])
        let suggested = try await agents.suggestedEntities()
        XCTAssertTrue(suggested.contains(try XCTUnwrap(defaults.first)))
        XCTAssertGreaterThan(suggested.count, 1)
    }

    // The Simulator exposes its lock button only through this selector.
    private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
    }

    private func unlock() {
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
    }

}

extension XCUIApplication {
    @MainActor func launchForChecks() {
        launchEnvironment["HEYDAN_UITEST"] = "1"
        launch()
    }
}

extension XCTestCase {
    /// The fixture host lists push, so the notification prompt can cover the list on a fresh Simulator.
    @MainActor func launchChat(_ environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = environment
        app.launchForChecks()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    @MainActor func shot(_ name: String, screenshot: XCUIScreenshot = XCUIScreen.main.screenshot()) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["HEYDAN_CHECKS_OUT"], !dir.isEmpty else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }
}
