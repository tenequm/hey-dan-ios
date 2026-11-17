import XCTest

final class ChatStoreChecks: XCTestCase {
    @MainActor func testFixtureListSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Stan"].waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Stan"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "Stan").count, 1)
    }
}
