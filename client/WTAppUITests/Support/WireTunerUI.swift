import XCTest

// The UI test harness (TEST-002; docs/spec/testing.adoc, "UI").  Every test drives the app
// through accessibility identifiers, never titles or coordinates on the screen, following the
// convention on that page: `canvas`, `tool.<id>`, `menu.<command id>`, `panel.<id>`,
// `panel-tab.<id>`, `status.<part>`, `pref.<key id>`, `account.<part>`.

/// The launched app and the elements tests reach for.
@MainActor
struct WireTunerUI {
    /// Passed on every launch: tokens stay in memory, nothing touches the login keychain, and
    /// no stored session opens a socket (`LaunchEnvironment` in the app).
    static let testingArgument = "-WTUITesting"
    /// Makes a DEBUG build report socket counts on the canvas (`SandboxAudit`).
    static let socketAuditArgument = "-WTSocketAudit"
    static let launchTimeout: TimeInterval = 15

    let app: XCUIApplication

    /// Launches a fresh instance with a new untitled document in front.
    static func launch(arguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) -> WireTunerUI {
        let app = XCUIApplication()
        app.launchArguments += [testingArgument, socketAuditArgument, "-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        let ui = WireTunerUI(app: app)
        XCTAssertTrue(ui.window.waitForExistence(timeout: launchTimeout), "the document window did not appear", file: file, line: line)
        return ui
    }

    // MARK: Elements

    /// The front document window.
    var window: XCUIElement { app.windows["main-window"].firstMatch }

    /// Any element in the app with `identifier`.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    var canvas: XCUIElement { element("canvas") }

    /// The canvas's accessibility value parsed: `changes`, `selected`, and with the socket
    /// audit `net` and `unix` (the app writes `"changes=<n> selected=<n> net=<n> unix=<n>"`,
    /// `CanvasView.accessibilityStatus`).
    var canvasState: [String: Int] {
        Self.parseState(canvas.value as? String ?? "")
    }

    nonisolated static func parseState(_ text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for pair in text.split(separator: " ") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let value = Int(parts[1]) { result[String(parts[0])] = value }
        }
        return result
    }

    /// Waits until the canvas reports `key == value`.
    @discardableResult
    func waitForCanvas(_ key: String, toBe value: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canvasState[key] == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return canvasState[key] == value
    }

    // MARK: Tools

    /// Chooses a tool by clicking its Tools panel button (`tool.<id>`).
    func selectTool(_ id: String) {
        element("tool.\(id)").click()
    }

    /// Drags on the canvas between two points given in canvas view points (y down from the
    /// canvas's top-left), holding `modifiers` for the whole drag.
    func drag(from start: CGPoint, to end: CGPoint, modifiers: XCUIElement.KeyModifierFlags = [], on element: XCUIElement? = nil) {
        let target = element ?? canvas
        let origin = target.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: start.x, dy: start.y))
        let to = origin.withOffset(CGVector(dx: end.x, dy: end.y))
        XCUIElement.perform(withKeyModifiers: modifiers) {
            from.press(forDuration: 0.1, thenDragTo: to)
        }
    }

    /// Clicks on the canvas at a point in canvas view points, holding `modifiers`.
    func click(at point: CGPoint, modifiers: XCUIElement.KeyModifierFlags = []) {
        let location = canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
        XCUIElement.perform(withKeyModifiers: modifiers) { location.click() }
    }

    // MARK: Menus

    /// Chooses a menu item by its path of titles: `["Edit", "Select", "All"]`.
    func chooseMenu(_ path: [String]) {
        precondition(path.count >= 2, "a menu path names a menu and an item")
        let bar = app.menuBars.menuBarItems[path[0]]
        bar.click()
        var menu = bar.menus.firstMatch
        for title in path.dropFirst().dropLast() {
            let item = menu.menuItems[title]
            item.hover()
            menu = item.menus.firstMatch
        }
        menu.menuItems[path.last!].click()
    }

    /// Chooses the menu item of a command by its identifier (`menu.<command id>`), opening
    /// the top-level menu `menuTitle` first.
    func chooseMenuItem(command: String, in menuTitle: String) {
        app.menuBars.menuBarItems[menuTitle].click()
        app.menuItems["menu.\(command)"].click()
    }

    // MARK: Panels

    /// A panel's body by its id (`panel.<id>`), showing it through Window ▸ <title> when it
    /// is not in the dock.
    func panel(_ id: String, title: String? = nil) -> XCUIElement {
        let body = element("panel.\(id)")
        if !body.exists, let title {
            chooseMenu(["Window", title])
        }
        let tab = element("panel-tab.\(id)")
        if tab.exists, !body.isHittable { tab.click() }
        return body
    }
}
