import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// A closed document window lets go of its controller, canvas, tiles and document.  A test
/// host runs thousands of tests that open windows; if each closed window lived on (its layer
/// backing stores and up to 128 MB of cached tiles with it), the host grew by gigabytes over a
/// full suite until the machine ran out of swap.
@Suite(.serialized) @MainActor struct WindowReleaseTests {
    @Test func aClosedDocumentWindowIsReleased() async {
        weak var controller: DocumentWindowController?
        weak var canvas: CanvasView?
        weak var document: DocumentHandle?
        do {
            let environment = TestEnvironment()
            let window = DocumentWindowController(document: .memory(title: "Released"), environment: environment.document)
            controller = window
            canvas = window.canvas
            document = window.documentHandle
            await window.documentHandle.settle()
            window.close()
        }
        let released = await eventually { controller == nil && canvas == nil && document == nil }
        if !released, ProcessInfo.processInfo.environment["WT_LEAK_PAUSE"] != nil {
            print("LEAK PAUSE pid \(ProcessInfo.processInfo.processIdentifier)")
            try? await Task.sleep(for: .seconds(90))
        }
        #expect(controller == nil, "the window controller outlives its closed window")
        #expect(canvas == nil, "the canvas outlives its closed window")
        #expect(document == nil, "the document handle outlives its closed window")
    }

    /// The same with every feature of the app attached to the window (comments, collaboration,
    /// branches, links, ...): none of them may hold the closed window.
    @Test func aClosedWindowOfTheWholeAppIsReleased() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // The controller only: AppKit itself may hold the closed NSWindow (and so its views) a
        // while longer as the previous key window.
        weak var controller: DocumentWindowController?
        do {
            let window = try #require(delegate.activeDocumentWindow)
            controller = window
            await window.documentHandle.settle()
            window.close()
        }
        let released = await eventually { controller == nil }
        if !released, ProcessInfo.processInfo.environment["WT_LEAK_PAUSE"] != nil {
            print("LEAK PAUSE pid \(ProcessInfo.processInfo.processIdentifier)")
            try? await Task.sleep(for: .seconds(120))
        }
        #expect(controller == nil, "a feature holds the closed window's controller")
        withExtendedLifetime(delegate) {}
    }

    /// Whatever may still hold a closed window, its canvas holds no pixels: the tiles and the
    /// overlay drawings go when the window closes.
    @Test func aClosedWindowsCanvasHoldsNoTiles() async throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Pixels"), environment: environment.document)
        await controller.documentHandle.settle()
        await controller.canvas.tiles.settle()
        let tiles = try #require(controller.canvas.tiles.fallbackCanvas)
        #expect(tiles.tileLayerCount > 0)
        controller.close()
        await controller.canvas.tiles.settle()
        #expect(tiles.tileLayerCount == 0)
        #expect(await tiles.cache.count == 0)
        #expect(controller.canvas.overlay.contents == nil)
    }

    /// The panels and notices that outlive their window hold it weakly: once it is gone they read
    /// as empty and do nothing (they held it `unowned` and crashed when touched after it went).
    @Test func panelsAndNoticesOutlivingTheirWindowDoNothing() async throws {
        AccessibilityCheckerFeatures.showsPanel = false
        ReadingOrderFeatures.showsPanel = false
        defer {
            AccessibilityCheckerFeatures.showsPanel = true
            ReadingOrderFeatures.showsPanel = true
        }
        let environment = TestEnvironment()
        weak var controller: DocumentWindowController?
        let checker: AccessibilityCheckerModel
        let order: ReadingOrderModel
        let notices: MasterNotices
        do {
            let window = DocumentWindowController(document: .memory(title: "Gone"), environment: environment.document)
            controller = window
            _ = try #require(await window.documentHandle.addRectangles([Rect(x: 10, y: 10, width: 20, height: 20)]).first)
            await window.documentHandle.settle()
            checker = AccessibilityCheckerFeatures.show(on: window)
            order = ReadingOrderFeatures.show(on: window)
            notices = MasterNotices(window: window)
            #expect(checker.window === window && order.window === window && notices.window === window)
            #expect(order.page != nil && order.document === window.documentHandle)
            window.close()
        }
        #expect(await eventually { controller == nil }, "a panel or the notices hold the closed window")
        #expect(checker.window == nil && order.window == nil && notices.window == nil)
        let node = OpID(counter: 1, replica: 1)
        // The checker keeps its report and does nothing.
        checker.refresh()
        checker.select(node)
        #expect(checker.name(node) == "" && checker.badges.isEmpty && checker.arrange() == nil)
        checker.drafts[node] = "alt"
        #expect(await checker.describe(node)?.value == nil)
        #expect(await checker.markDecorative(node).value == nil)
        // The reading order lists nothing and its gestures write nothing.
        #expect(order.document == nil && order.page == nil && order.pageName.isEmpty && order.order.isEmpty && order.rows.isEmpty)
        #expect(order.badges.isEmpty && order.object(at: Point(x: 15, y: 15)) == nil)
        #expect(order.click(node, toEnd: false) == nil)
        let arranged = await order.arrange([]).value
        let stacked = await order.useStackingOrder().value
        #expect(arranged == nil && stacked == nil)
        #expect(await order.move(from: [0], to: 0).value == nil)
        // The notices post nothing and stop quietly.
        #expect(notices.documentDidChange(Wiretuner_Doc_V1_Change()) == 0)
        notices.stop()
        // A window opened later (perhaps at the freed window's address) gets panels of its own.
        let next = DocumentWindowController(document: .memory(title: "Next"), environment: environment.document)
        defer { next.close() }
        let nextChecker = AccessibilityCheckerFeatures.show(on: next)
        #expect(nextChecker !== checker && nextChecker.window === next)
        #expect(ReadingOrderFeatures.show(on: next) !== order)
        AccessibilityCheckerFeatures.close(next)
        ReadingOrderFeatures.close(next)
    }

    /// A closed glyph tab lets go of its controller: the glyph bar in its title bar performs
    /// through the controller weakly (a method reference held it from its own window).
    @Test func aClosedGlyphTabIsReleased() async throws {
        weak var tab: DocumentWindowController?
        do {
            let fixture = await TypefaceWindowFixture.typeface()
            let opened = try #require(fixture.features.openGlyph(fixture.glyph("A"), from: fixture.window))
            tab = opened
            // The bar still performs while the tab is open.
            let bar = try #require(fixture.features.mode(of: opened)?.glyphBar)
            bar.widthText = "700"
            _ = await bar.commitWidth()?.value
            #expect(GlyphOutlines.metrics(of: fixture.glyph("A"), in: fixture.document.state)?.advanceWidth == 700)
            fixture.close()
        }
        #expect(await eventually { tab == nil }, "the glyph bar holds its closed tab")
    }

    /// A window that lived long enough to get events from the window server is deallocated once
    /// closed.  XCTest dispatches those events outside any autorelease pool the run pops, so what
    /// they autoreleased (the events, holding their window) stayed until the run ended and every
    /// such window leaked with its views; `Support/EventPools.c` gives each event a pool.
    ///
    /// That leak is for good, so the test waits up to 15 s: in one full run (after 1,800 tests, on
    /// a loaded machine) the window was still alive after 5 s -- something held it for a while and
    /// no rerun reproduced it (neither NSApp's current event nor the run loop's pools, both checked).
    /// A failure says what still refers to the window.
    @Test func aWindowThatHadEventsIsReleasedAfterClosing() async {
        weak var released: NSWindow?
        do {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            released = window
            try? await Task.sleep(for: .milliseconds(400))
            window.close()
        }
        let gone = await eventually(.seconds(15)) { released == nil }
        let holders = released.map { window in
            ["NSApp's current event: \(NSApp.currentEvent?.window === window)", "in NSApp.windows: \(NSApp.windows.contains { $0 === window })",
             "key: \(NSApp.keyWindow === window)", "main: \(NSApp.mainWindow === window)", "visible: \(window.isVisible)",
             "parent: \(window.parent != nil)", "active app: \(NSApp.isActive)"].joined(separator: ", ")
        } ?? ""
        #expect(gone, "the closed window outlives the events it got (\(holders))")
    }

    /// With `WT_LEAK_LINGER=<seconds>` (`TEST_RUNNER_WT_LEAK_LINGER`), keeps the test host alive that
    /// long, so a run of a few suites still reports the windows they leave (`WT-WINDOW-LEAK`
    /// comes 3 s after a test).
    @Test func lingerForTheLeakLog() async {
        guard let seconds = ProcessInfo.processInfo.environment["WT_LEAK_LINGER"].flatMap(Double.init) else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}
