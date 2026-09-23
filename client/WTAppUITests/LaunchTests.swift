import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheMainWindow() {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows["main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the main window did not appear")
        XCTAssertEqual(window.title, "Untitled", "a new blank document opens at launch")
    }
}
