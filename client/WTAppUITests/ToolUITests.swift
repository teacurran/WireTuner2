import XCTest

/// The sample tool test (TEST-002): one Rectangle drag is one change, observed through the
/// canvas's accessibility value, with no socket opened while drawing.
final class ToolUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testARectangleDragIsOneChange() throws {
        let ui = WireTunerUI.launch()
        XCTAssertEqual(ui.canvasState["changes"], 0)
        ui.selectTool("rectangle")
        SandboxAudit.assertNoSockets(in: ui) {
            ui.drag(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 420, y: 300), modifiers: .shift)
            XCTAssertTrue(ui.waitForCanvas("changes", toBe: 1), "one drag, one change: \(ui.canvasState)")
        }
        try ScreenshotCapture.capture(ui.window, named: "rectangle-sketch", in: self)
    }

    @MainActor
    func testThePointerSelectsWhatItClicksAndMarquees() {
        let ui = WireTunerUI.launch()
        ui.selectTool("rectangle")
        ui.drag(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 400, y: 280))
        XCTAssertTrue(ui.waitForCanvas("changes", toBe: 1))
        ui.selectTool("pointer")
        ui.click(at: CGPoint(x: 350, y: 240))
        XCTAssertTrue(ui.waitForCanvas("selected", toBe: 1))
        ui.chooseMenu(["Edit", "Select", "None"])
        XCTAssertTrue(ui.waitForCanvas("selected", toBe: 0))
        ui.drag(from: CGPoint(x: 280, y: 180), to: CGPoint(x: 420, y: 300))
        XCTAssertTrue(ui.waitForCanvas("selected", toBe: 1))
        let summary = ui.panel("object", title: "Object").descendants(matching: .any)["object.selection-summary"]
        XCTAssertEqual(summary.label, "1 object selected", "the Object panel follows the selection")
    }
}

/// The harness checks itself (the app's `SocketMonitor` is unit-tested in WireTunerTests).
final class HarnessTests: XCTestCase {
    func testCanvasStateParses() {
        XCTAssertEqual(WireTunerUI.parseState("changes=3 selected=1"), ["changes": 3, "selected": 1])
        XCTAssertEqual(WireTunerUI.parseState("garbage"), [:])
    }

    func testSocketCountsAndViolations() {
        let state = WireTunerUI.parseState("changes=1 selected=0 net=0 unix=4")
        let before = SandboxAudit.counts(in: state)
        XCTAssertEqual(before, SandboxAudit.Counts(internet: 0, unixDomain: 4))
        XCTAssertNil(SandboxAudit.counts(in: ["changes": 1]))
        let after = SandboxAudit.Counts(internet: 1, unixDomain: 5)
        XCTAssertEqual(SandboxAudit.violations(before: before!, after: after, includeUnixDomain: false), ["1 internet socket(s)"])
        XCTAssertEqual(SandboxAudit.violations(before: before!, after: after, includeUnixDomain: true).count, 2)
        XCTAssertEqual(SandboxAudit.violations(before: before!, after: before!, includeUnixDomain: true), [])
    }

    func testScreenshotsGoToTheDocsImagesDirectoryWhenAsked() {
        XCTAssertNil(ScreenshotCapture.directory(environment: [:]))
        XCTAssertEqual(ScreenshotCapture.directory(environment: ["WT_DOCS_IMAGES": "/tmp/images"])?.path, "/tmp/images")
    }
}
