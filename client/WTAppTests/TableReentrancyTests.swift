import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import WTGeometry
@testable import WireTuner

/// How many times AppKit warned "Application performed a reentrant operation in its NSTableView
/// delegate" in this test host (`Support/TableReentrancy.c`, an os_log hook).
@_silgen_name("wtTableReentrancyCount") func wtTableReentrancyCount() -> Int
/// How many unified-log messages the test host's hook saw.
@_silgen_name("wtLogMessageCount") func wtLogMessageCount() -> Int

/// The tables inside `-[NSTableView endUpdates]` now, innermost last: the warning's call stack
/// often starts at SwiftUI's run-loop flush with no app code on it, and the list may not be in a
/// window yet, so the report names the table instead.
@MainActor
enum TableTracker {
    static var updating: [NSTableView] = []
}

/// Wraps `-[NSTableView endUpdates]` to keep `TableTracker.updating` (`Support/TableReentrancy.c`
/// calls it when the test bundle loads).
@_cdecl("wtTrackTables")
func wtTrackTables() {
    let end = #selector(NSTableView.endUpdates)
    guard let method = class_getInstanceMethod(NSTableView.self, end) else { return }
    typealias EndUpdates = @convention(c) (AnyObject, Selector) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: EndUpdates.self)
    let wrapped: @convention(block) (AnyObject) -> Void = { object in
        guard Thread.isMainThread, let table = object as? NSTableView else { return original(object, end) }
        MainActor.assumeIsolated { TableTracker.updating.append(table) }
        original(object, end)
        MainActor.assumeIsolated { _ = TableTracker.updating.popLast() }
    }
    method_setImplementation(method, imp_implementationWithBlock(wrapped))
}

/// Prints the table the warning came from -- its rows, window, the hosting view around it (a
/// SwiftUI list's `NSHostingView<Root>` names its view) and its delegate's type -- after the
/// `WT-TABLE-REENTRANCY` call stack.
@_cdecl("wtDescribeLongTables")
func wtDescribeLongTables() {
    MainActor.assumeIsolated {
        guard let table = TableTracker.updating.last else {
            print("WT-TABLE-REENTRANCY-TABLE none in endUpdates")
            return
        }
        var chain: [String] = []
        var view: NSView? = table
        while let next = view {
            let name = String(describing: type(of: next))
            if name.contains("Hosting") || chain.isEmpty { chain.append(name) }
            view = next.superview
        }
        let window = table.window.map { "\(type(of: $0)) \"\($0.title)\" id=\($0.identifier?.rawValue ?? "")" } ?? "none"
        let delegate = table.delegate.map { String(describing: type(of: $0)) } ?? "none"
        print("WT-TABLE-REENTRANCY-TABLE rows=\(table.numberOfRows) window=\(window) views=\(chain.joined(separator: " < ")) delegate=\(delegate)")
    }
}

/// The app's SwiftUI lists are `NSTableView`s, and one that goes from no rows to more than about
/// 200 in one update re-enters its row-height cache: AppKit warns "Application performed a
/// reentrant operation in its NSTableView delegate" and says it will become an assert
/// (`ListRowGrowth`).  The long lists fill over two updates; these show their windows, search to
/// nothing and back, and fail on any warning.  A full-suite log names the code behind any other
/// warning (`WT-TABLE-REENTRANCY` with the call stack).
@Suite(.serialized) @MainActor struct TableReentrancyTests {
    @MainActor @Observable final class Rows {
        var count = 0
    }

    struct Numbers: View {
        let rows: Rows
        let growing: Bool

        var body: some View {
            if growing {
                GrowingRows(count: rows.count) { limit in List(0..<limit, id: \.self) { Text("Row \($0)") } }
            } else {
                List(0..<rows.count, id: \.self) { Text("Row \($0)") }
            }
        }
    }

    /// The table inside `view`.
    func table(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    /// Lays out `view` a few times with the run loop turning in between.
    func settle(_ view: NSView?) async {
        for _ in 0..<3 {
            view?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        view?.layoutSubtreeIfNeeded()
    }

    /// The check works: the unified log reaches the hook, and AppKit's own warning is counted.
    @Test func theHookCountsAppKitsWarning() {
        let messages = wtLogMessageCount()
        NSLog("WT log hook check")
        #expect(wtLogMessageCount() > messages)
        // A plain List filled with 300 rows at once: the warning the rest of the suite must not
        // print (the one expected occurrence in a full-suite log).
        print("WT-TABLE-REENTRANCY-EXPECTED: TableReentrancyTests.theHookCountsAppKitsWarning fills a plain List with 300 rows")
        let before = wtTableReentrancyCount()
        let rows = Rows()
        rows.count = 300
        let host = NSHostingView(rootView: Numbers(rows: rows, growing: false))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        host.layoutSubtreeIfNeeded()
        #expect(wtTableReentrancyCount() == before + 1, "AppKit's warning no longer reaches the hook: the checks below would pass vacuously")
    }

    /// `GrowingRows` fills a long list without the warning -- at first, and after it emptied -- and
    /// shows every row once laid out.
    @Test func growingRowsFillALongListQuietly() async throws {
        let before = wtTableReentrancyCount()
        let rows = Rows()
        rows.count = 300
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled, .closable, .resizable])
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: Numbers(rows: rows, growing: true))
        await settle(window.contentView)
        #expect(table(in: window.contentView)?.numberOfRows == 300)
        rows.count = 0
        await settle(window.contentView)
        #expect(table(in: window.contentView)?.numberOfRows == 0)
        rows.count = 400
        await settle(window.contentView)
        #expect(table(in: window.contentView)?.numberOfRows == 400)
        #expect(wtTableReentrancyCount() == before)
    }

    @Test func theLimitAndThePrefix() {
        #expect(ListRowGrowth.limit(count: 300, shown: 0) == ListRowGrowth.firstRows)
        #expect(ListRowGrowth.limit(count: 40, shown: 0) == 40)
        #expect(ListRowGrowth.limit(count: 300, shown: 100) == 300)
        #expect(ListRowGrowth.limit(count: 0, shown: 300) == 0)
        let groups = [("a", [1, 2, 3]), ("b", [4, 5]), ("c", [6])]
        let make: ((String, [Int]), [Int]) -> (String, [Int]) = { ($0.0, $1) }
        #expect(ListRowGrowth.prefix(groups, limit: 4, rows: \.1, with: make).map(\.1) == [[1, 2, 3], [4]])
        #expect(ListRowGrowth.prefix(groups, limit: 3, rows: \.1, with: make).map(\.0) == ["a"])
        #expect(ListRowGrowth.prefix(groups, limit: 10, rows: \.1, with: make).map(\.1) == [[1, 2, 3], [4, 5], [6]])
        #expect(ListRowGrowth.prefix(groups, limit: 0, rows: \.1, with: make).isEmpty)
    }

    /// menu:Edit[Keyboard Shortcuts…]: every command in one outline, searched to nothing and back.
    @Test func theKeyboardShortcutsWindowWarnsOfNothing() async throws {
        let before = wtTableReentrancyCount()
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let model = KeyboardShortcutsModel(store: ShortcutSetStore(url: nil), registry: registry)
        // The outline's rows: the commands and a header per category.
        let rows = model.categories.reduce(0) { $0 + 1 + $1.rows.count }
        #expect(rows > 200, "the list is long enough to warn when filled at once")
        let controller = KeyboardShortcutsWindowController(model: model)
        defer { controller.close() }
        controller.show()
        await settle(controller.window?.contentView)
        #expect((table(in: controller.window?.contentView)?.numberOfRows ?? 0) >= rows)
        model.selectedCommandID = StandardCommands.ID.new
        model.searchText = "zzzz-matches-nothing"
        await settle(controller.window?.contentView)
        model.searchText = ""
        await settle(controller.window?.contentView)
        #expect((table(in: controller.window?.contentView)?.numberOfRows ?? 0) >= rows)
        #expect(wtTableReentrancyCount() == before)
    }

    /// menu:Window[Toolbars > Customize…]: every command in one list, searched to nothing and back.
    @Test func theCustomizeToolbarsWindowWarnsOfNothing() async throws {
        let before = wtTableReentrancyCount()
        let fixture = ToolbarFixture()
        let window = CustomizeToolbarsWindowController(controller: fixture.controller)
        defer { window.close() }
        // The list's rows: the commands and a header per group.
        let rows = window.model.groups.reduce(0) { $0 + 1 + $1.commands.count }
        #expect(rows > 200, "the list is long enough to warn when filled at once")
        window.show()
        await settle(window.window?.contentView)
        #expect((table(in: window.window?.contentView)?.numberOfRows ?? 0) >= rows)
        window.model.selection = "edit.copy"
        window.model.query = "zzzz-matches-nothing"
        await settle(window.window?.contentView)
        window.model.query = ""
        await settle(window.window?.contentView)
        #expect((table(in: window.window?.contentView)?.numberOfRows ?? 0) >= rows)
        #expect(wtTableReentrancyCount() == before)
    }

    /// Reading Order: a run of reorders (drags, canvas clicks, undo) with the panel's list showing.
    /// Rows identified by object moved while the table re-measured them and warned; they are
    /// identified by position.
    @Test func theReadingOrderListReordersQuietly() async throws {
        ReadingOrderFeatures.showsPanel = false
        defer { ReadingOrderFeatures.showsPanel = true }
        let world = TypeWorld()
        defer { world.close() }
        let origin = world.document.activePage.origin
        let squares = await world.document.addRectangles((0..<3).map { Rect(x: origin.x + 100 + Double($0) * 60, y: origin.y + 100, width: 40, height: 40) }).map(\.opID)
        let model = ReadingOrderFeatures.show(on: world.window)
        defer { ReadingOrderFeatures.close(world.window) }
        await settle(nil)
        let before = wtTableReentrancyCount()
        // As in StyleChartShareOrderTests: a drag, canvas clicks, Shift-click to the end.
        _ = await model.move(from: IndexSet(integer: 2), to: 0).value
        for (node, toEnd) in [(squares[1], false), (squares[0], false), (squares[1], true)] {
            _ = await model.click(node, toEnd: toEnd)?.value
            await world.document.settle()
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = await world.document.undo().value
        model.refresh()
        _ = await world.document.addRectangles([Rect(x: origin.x + 100, y: origin.y + 200, width: 40, height: 40)])
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.rows.count == 4)
        #expect(wtTableReentrancyCount() == before)
    }
}
