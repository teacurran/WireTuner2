import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// A toolbar lays out by where it is hosted (D-077 revised): one row in a top or bottom strip, a
/// column in a narrow side strip, and rows that wrap in a panel group, docked or floating.
@Suite(.serialized) @MainActor struct ToolbarFlowTests {
    typealias Item = ToolbarFlowLayout.Item

    static func textToolbar(_ fixture: ToolbarFixture) -> ToolbarView {
        fixture.controller.controls = FontToolbarControls.makers(window: { nil }, recents: FontControlTests.recents())
        return ToolbarView(controller: fixture.controller, toolbar: .text)
    }

    // MARK: The layout rule

    @Test func aFlowWrapsAtTheWidthAndGivesAWideItemARowOfItsOwn() {
        let button = Item(size: CGSize(width: 26, height: 24))
        let wide = Item(size: CGSize(width: 200, height: 24), minimumWidth: 120, fullRow: true)
        let style = Item(size: CGSize(width: 130, height: 24))
        let size = Item(size: CGSize(width: 72, height: 24))
        let items = [wide, style, size] + Array(repeating: button, count: 10)
        let result = ToolbarFlowLayout.layout(items, placement: .flow, width: 240)
        let available = 240 - ToolbarFlowLayout.insets.left - ToolbarFlowLayout.insets.right
        #expect(result.rows[0] == [0], "the wide control alone")
        #expect(result.frames[0].width == available, "stretched to the row")
        #expect(result.rows[1] == [1, 2], "style and size share a row")
        #expect(result.rows.count >= 4 && result.rows.dropFirst(2).allSatisfy { $0.count > 1 }, "buttons flow in rows")
        #expect(result.frames.allSatisfy { $0.maxX <= 240 - ToolbarFlowLayout.insets.right + 0.5 })
        #expect(result.size.width == 240)
        // Too narrow for the wide control: it keeps its minimum.
        let narrow = ToolbarFlowLayout.layout(items, placement: .flow, width: 80)
        #expect(narrow.frames[0].width == 120)
        // An item taller than its row's others is centred with them.
        let mixed = ToolbarFlowLayout.layout([button, Item(size: CGSize(width: 30, height: 30))], placement: .flow, width: 400)
        #expect(mixed.rows == [[0, 1]] && mixed.frames[0].minY == ToolbarFlowLayout.insets.top + 3)
        // A row never wraps and ignores full rows; a column puts one item under another.
        let row = ToolbarFlowLayout.layout(items, placement: .row, width: 100)
        #expect(row.rows.count == 1 && row.frames[0].width == 200 && row.size.width > 100)
        let column = ToolbarFlowLayout.layout(items, placement: .column, width: 1_000)
        #expect(column.rows.count == items.count && column.frames.allSatisfy { $0.minX == ToolbarFlowLayout.insets.left })
        #expect(ToolbarFlowLayout.layout([], placement: .flow, width: 100).size.height == ToolbarFlowLayout.insets.top + ToolbarFlowLayout.insets.bottom)
        #expect(Item(size: CGSize(width: 20, height: 20), minimumWidth: 50).minimumWidth == 20)
    }

    @Test func theHostDecidesThePlacementNotTheShape() {
        let fixture = ToolbarFixture()
        let panel = ToolbarID.text.panelID
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .flow, "not in the layout: another view hosts it")
        fixture.layout.update { _ = $0.movePanel(panel, toNewGroupAt: .top) }
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .row)
        fixture.layout.update { _ = $0.movePanel(panel, toNewGroupAt: .bottom) }
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .row)
        fixture.layout.update { _ = $0.movePanel(panel, toNewGroupAt: .left) }
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .column, "the narrow left strip")
        fixture.layout.update { $0.setDockWidth(280, edge: .left) }
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .flow)
        fixture.layout.update { _ = $0.movePanel(panel, toNewGroupAt: .right) }
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .flow)
        fixture.layout.update { _ = $0.floatPanel(panel, frame: LayoutRect(x: 0, y: 0, width: 200, height: 600)) }
        #expect(ToolbarPlacement.hosting(.text, in: fixture.layout.layout) == .flow, "floating, however tall")
    }

    // MARK: The view

    @Test func inANarrowPanelTheTextToolbarRunsInWrappedRows() throws {
        let fixture = ToolbarFixture()
        fixture.layout.update { _ = $0.movePanel(ToolbarID.text.panelID, toNewGroupAt: .right) }
        let view = Self.textToolbar(fixture)
        // Tall and narrow, as in the side dock: still rows.
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        view.layout()
        #expect(view.placement == .flow && view.isHorizontal)
        let family = try #require(view.arranged.first as? FontFamilyPicker)
        let style = try #require(view.arranged.compactMap { $0 as? StylePopUp }.first)
        let size = try #require(view.arranged.compactMap { $0 as? SizeComboBox }.first)
        let rows = view.flow.rows
        #expect(rows.count > 2)
        #expect(rows[0] == [0] && family.frame.width == 240 - ToolbarFlowLayout.insets.left - ToolbarFlowLayout.insets.right)
        #expect(style.frame.minY == size.frame.minY && size.frame.minX > style.frame.maxX, "style and size share a row")
        let buttonRows = rows.dropFirst(2)
        #expect(buttonRows.allSatisfy { $0.count > 1 }, "icon buttons flow in rows, not a column")
        // No control narrower than its minimum; nothing past the right edge.
        for case let control as any ToolbarControl in view.arranged {
            #expect(control.frame.width >= control.minimumToolbarWidth)
        }
        #expect(view.arranged.allSatisfy { $0.frame.maxX <= view.bounds.width })
        #expect(view.intrinsicContentSize.height == view.flow.size.height && view.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        // Narrower still: the family keeps its minimum.
        view.setFrameSize(NSSize(width: 100, height: 600))
        view.layout()
        #expect(family.frame.width == FontFamilyPicker.minimumWidth)
        #expect(view.arranged.allSatisfy { $0.frame.width > 0 })
    }

    @Test func aStripKeepsOneRowAndANarrowSideStripAColumn() {
        let fixture = ToolbarFixture()
        let view = Self.textToolbar(fixture)
        fixture.layout.update { _ = $0.movePanel(ToolbarID.text.panelID, toNewGroupAt: .top) }
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        view.layout()
        #expect(view.placement == .row && view.flow.rows.count == 1)
        #expect(view.intrinsicContentSize.width > 300, "a row is as wide as its items")
        fixture.layout.update { _ = $0.movePanel(ToolbarID.text.panelID, toNewGroupAt: .left) }
        view.frame = NSRect(x: 0, y: 0, width: 84, height: 800)
        view.layout()
        #expect(view.placement == .column && !view.isHorizontal)
        #expect(view.flow.rows.allSatisfy { $0.count == 1 })
        #expect(view.intrinsicContentSize.height == view.flow.size.height)
        // An Info toolbar's readout comes first.
        let info = ToolbarView(controller: fixture.controller, toolbar: .info)
        info.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        info.layout()
        #expect(info.layoutViews.first === info.readout && info.flow.frames.count == 1)
    }

    @Test func theToolsPanelsButtonsWrapAtTheWidthSwiftUIOffers() {
        let fixture = ToolbarFixture()
        for command in ["edit.copy", "edit.paste", "edit.cut", "edit.selectAll"] { fixture.controller.add(CommandID(command), to: .tools) }
        let representable = ToolbarViewRepresentable(controller: fixture.controller, toolbar: .tools)
        let hosting = NSHostingView(rootView: representable.frame(width: 70))
        hosting.frame = NSRect(x: 0, y: 0, width: 70, height: 300)
        hosting.layoutSubtreeIfNeeded()
        let view = ToolbarView(controller: fixture.controller, toolbar: .tools, placement: .flow)
        #expect(view.placement == .flow)
        let one = ToolbarViewRepresentable.size(of: view, proposedWidth: nil)
        let narrow = ToolbarViewRepresentable.size(of: view, proposedWidth: 70)
        #expect(narrow.height > one.height && one.width > narrow.width)
        #expect(ToolbarViewRepresentable.size(of: view, proposedWidth: .infinity) == one)
    }
}
