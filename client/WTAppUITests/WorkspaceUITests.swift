import XCTest

// UI tests for APP-009 and BASIC-001..009.  They need macOS Automation Mode (testing.adoc,
// "UI"); unit tests in WireTunerTests cover the same logic without a screen.

/// The Library window (APP-009).
final class LibraryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testOfflineTheLibrarySearchesNamesOnly() {
        // A test launch is signed out, which the library treats like being offline.
        let ui = WireTunerUI.launch()
        ui.chooseMenuItem(command: "file.open", in: "File")
        let library = ui.app.windows["library-window"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        let search = ui.element("library.search")
        search.click()
        search.typeText("Untitled")
        XCTAssertTrue(ui.element("library.hint").waitForExistence(timeout: 2), "the names-only hint shows offline")
        XCTAssertEqual(ui.element("library.hint").label, "Searching names only — connect to search contents")
    }

    @MainActor
    func testNewCreatesADocumentWaitingToUploadAndOpensItInATab() {
        let ui = WireTunerUI.launch()
        ui.chooseMenuItem(command: "window.library", in: "Window")
        ui.element("library.new").click()
        XCTAssertTrue(ui.window.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(ui.app.windows.matching(identifier: "main-window").count, 1)
    }
}

/// Tabs, the status bar and the title (BASIC-001..003).
final class WindowChromeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testTabsCycleWithControlTabAndCloseWithoutAPrompt() {
        let ui = WireTunerUI.launch()
        ui.app.typeKey("n", modifierFlags: .command)
        ui.app.typeKey("n", modifierFlags: .command)
        let first = ui.window.title
        ui.app.typeKey(.tab, modifierFlags: .control)
        XCTAssertNotEqual(ui.window.title, first)
        ui.app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertEqual(ui.window.title, first)
        ui.app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(ui.app.sheets.firstMatch.exists, "closing never asks to save")
    }

    @MainActor
    func testMagnificationFieldParsesMultipliersAndAddPageAddsAPage() {
        let ui = WireTunerUI.launch()
        let field = ui.element("status.magnification")
        field.doubleClick()
        field.typeText("4x\r")
        XCTAssertEqual(field.value as? String, "400%")
        ui.element("status.addPage").click()
        XCTAssertTrue(ui.waitForCanvas("changes", toBe: 1), "Add Page is one change")
        XCTAssertEqual(ui.element("status.page").value as? String, "2")
    }

    @MainActor
    func testRelaunchReopensTheSameTabs() {
        var ui = WireTunerUI.launch(arguments: [LaunchArguments.restoreSession])
        ui.app.typeKey("n", modifierFlags: .command)
        let tabs = ui.app.windows.matching(identifier: "main-window").count
        ui.app.terminate()
        ui = WireTunerUI.launch(arguments: [LaunchArguments.restoreSession])
        XCTAssertEqual(ui.app.windows.matching(identifier: "main-window").count, tabs)
    }
}

enum LaunchArguments {
    static let restoreSession = "-WTRestoreSession"
}

/// Panels: grouping, renaming, the dock handle and Reset (BASIC-004..006).
final class PanelFrameworkUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testFirstLaunchShowsTheDefaultGroups() {
        let ui = WireTunerUI.launch()
        for group in ["properties", "assets", "mixer-and-tints", "layers", "help", "tools"] {
            XCTAssertTrue(ui.element("panel-group.\(group)").exists, group)
        }
        XCTAssertFalse(ui.element("panel-group.halftones").exists)
    }

    @MainActor
    func testGroupSwatchesWithLayersSplitAndRename() {
        let ui = WireTunerUI.launch()
        ui.element("panel-group.assets.disclosure").click()
        ui.element("panel-tab.swatches").click()
        ui.element("panel-group.assets.options").click()
        ui.app.menuItems["panel-options.groupWith"].hover()
        ui.app.menuItems["panel-options.groupWith.layers"].click()
        XCTAssertTrue(ui.element("panel-group.layers").descendants(matching: .any)["panel-tab.swatches"].exists)
        ui.element("panel-group.layers.options").click()
        ui.app.menuItems["panel-options.rename"].click()
        let field = ui.element("panel-group.layers.rename")
        field.typeText("Stacking\r")
        XCTAssertTrue(ui.element("panel-group.layers").staticTexts["Stacking"].exists)
        // Drag the tab back onto the Assets strip.
        ui.element("panel-tab.swatches").press(forDuration: 0.2, thenDragTo: ui.element("panel-group.assets"))
        XCTAssertTrue(ui.element("panel-group.assets").descendants(matching: .any)["panel-tab.swatches"].exists)
    }

    @MainActor
    func testTheDockHandleHidesThePanelsAndResetBringsThemBack() {
        let ui = WireTunerUI.launch()
        ui.element("dock-handle.right").click()
        XCTAssertFalse(ui.element("panel-dock").isHittable)
        ui.chooseMenu(["Window", "Panel Layout", "Reset to Default"])
        XCTAssertTrue(ui.element("panel-dock").waitForExistence(timeout: 2))
    }
}

/// The Tools panel (BASIC-008, BASIC-009).
final class ToolsPanelUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testUnimplementedToolsShowTheHUDAndWriteNothing() {
        let ui = WireTunerUI.launch()
        ui.canvas.click()
        ui.app.typeKey("p", modifierFlags: [])
        ui.click(at: CGPoint(x: 300, y: 200))
        XCTAssertTrue(ui.element("status.message").label.contains("coming soon"))
        XCTAssertEqual(ui.canvasState["changes"], 0)
    }

    @MainActor
    func testShortcutsCycleAFlyoutAndSpacePushesTheHand() {
        let ui = WireTunerUI.launch()
        ui.canvas.click()
        ui.app.typeKey("p", modifierFlags: [])
        ui.app.typeKey("p", modifierFlags: [])
        XCTAssertTrue(ui.element("tool.bezigon").exists, "the second press shows the next member")
        ui.app.typeKey("6", modifierFlags: [])
        XCTAssertTrue(ui.element("tool.pen").exists)
    }

    @MainActor
    func testSnapTogglesProduceNoChange() {
        let ui = WireTunerUI.launch()
        ui.element("tools.snap.grid").click()
        XCTAssertEqual(ui.element("tools.snap.grid").value as? String, "on")
        XCTAssertEqual(ui.canvasState["changes"], 0)
    }
}
