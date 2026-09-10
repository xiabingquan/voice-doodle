import XCTest

/// Smoke test only: the app is a menu-bar (LSUIElement) app, so deep UI
/// navigation is unreliable in CI. Permission dialogs are handled by
/// interruption monitors where possible; this asserts the app launches.
final class OnboardingSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        // Menu bar apps have no windows by default; a successful launch
        // (process alive after a short settle) is the smoke signal.
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
    }
}
