import XCTest

final class DockTests: XCTestCase {
    @MainActor
    func testMainWindowShowsThePanelDock() {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows["main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the main window did not appear")
        let dock = window.descendants(matching: .any).matching(identifier: "panel-dock").firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "the panel dock did not appear")
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "canvas").firstMatch.exists)
    }
}
