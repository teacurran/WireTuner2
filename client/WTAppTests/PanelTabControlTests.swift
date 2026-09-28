import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// D-077, revised after use: our own tab control.  The selected tab is a surface joined to the
/// card, with an accent bar, a bold label and a full-contrast icon; unselected tabs are dimmer and
/// highlight under the pointer; the focused tab shows a ring; crowded strips drop labels to icons,
/// then overflow into a menu; a group with one panel shows no strip.
@Suite @MainActor struct TabStripLayoutTests {
    private let tabs = [
        TabStripLayout.Tab(full: 80, compact: 32), TabStripLayout.Tab(full: 90, compact: 32), TabStripLayout.Tab(full: 70, compact: nil),
    ]

    @Test func tabsThatFitKeepTheirLabels() {
        let result = TabStripLayout.layout(tabs, selected: 1, width: 300, height: 28)
        #expect(result.compact == [false, false, false] && result.overflow == nil && result.hidden.isEmpty)
        #expect(result.frames.map { $0?.width } == [80, 90, 70])
        #expect(result.frames[1]?.minX == 80 + TabStripLayout.spacing)
        // Filling (a panel's inner sections): the spare width is shared.
        let filled = TabStripLayout.layout(tabs, selected: 1, width: 300, height: 24, fill: true)
        #expect(abs((filled.frames[2]?.maxX ?? 0) - 300) < 0.001)
        #expect(TabStripLayout.layout([], selected: nil, width: 100, height: 28) == TabStripLayout.Result(frames: [], compact: [], overflow: nil))
    }

    @Test func crowdedStripsDropUnselectedLabelsToIconsThenOverflow() {
        // 80 + 90 + 70 + 4 = 244 does not fit 200; icons for the unselected tabs that have one.
        let compact = TabStripLayout.layout(tabs, selected: 1, width: 200, height: 28)
        #expect(compact.compact == [true, false, false], "the selected tab keeps its label; a tab without an icon keeps its")
        #expect(compact.overflow == nil && compact.frames.allSatisfy { $0 != nil })
        // Still too wide: the selected tab and what else fits, and an overflow button.
        // Icons: 32 + 32 + 70 + 4 = 138 fits 140, not 130.
        #expect(TabStripLayout.layout(tabs, selected: 2, width: 140, height: 28).overflow == nil)
        let overflow = TabStripLayout.layout(tabs, selected: 2, width: 130, height: 28)
        #expect(overflow.frames[2] != nil, "the selected tab always shows")
        #expect(overflow.overflow != nil && overflow.hidden == [1])
        #expect(overflow.frames[0]?.minX == 0 && (overflow.frames[2]?.minX ?? 0) > (overflow.frames[0]?.maxX ?? 0), "visible tabs keep their order")
        #expect((overflow.overflow?.maxX ?? 999) <= 130)
        // Not even the selected tab fits: it takes the room left beside the overflow button.
        let tiny = TabStripLayout.layout(tabs, selected: 0, width: 60, height: 28)
        #expect(tiny.frames[0]?.width == 60 - TabStripLayout.overflowWidth - TabStripLayout.spacing)
        #expect(tiny.hidden == [1, 2])
        // An out-of-range selection is none.
        #expect(TabStripLayout.layout(tabs, selected: 9, width: 300, height: 28).frames.count == 3)
    }
}

@Suite @MainActor struct PanelTabControlTests {
    private func items() -> [PanelTabStrip.Item] {
        let icon = { (name: String) in NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        return [
            .init(id: "object", title: "Object", image: icon("slider.horizontal.3")),
            .init(id: "document", title: "Document", image: icon("doc")),
            .init(id: "layers", title: "Layers", image: icon("square.3.layers.3d")),
        ]
    }

    /// A strip over a group card, as a panel group draws it, `width` wide.
    private func host(selected: PanelID, width: CGFloat = 260, appearance: NSAppearance.Name = .aqua) -> (NSView, PanelTabStrip, PanelCardView) {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        container.appearance = NSAppearance(named: appearance)
        // The dock's chrome under the strip (solid, so the pixels are opaque).
        let chrome = PanelFrostView(level: .chrome, translucent: false, cornerRadius: 0)
        chrome.frame = container.bounds
        container.addSubview(chrome)
        let card = PanelCardView(translucent: false)
        card.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        card.bodyTop = PanelTabStrip.height
        container.addSubview(card)
        let strip = PanelTabStrip(items: items(), selected: selected, accessibilityLabel: "Properties")
        strip.frame = NSRect(x: 0, y: 0, width: width, height: PanelTabStrip.height)
        strip.onSelectionFrameChange = { frame in card.tabRect = frame }
        container.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        card.tabRect = strip.selectedTabFrame
        return (container, strip, card)
    }

    @Test func theSelectedTabIsJoinedToTheCardAndDrawnDistinctly() throws {
        let (container, strip, card) = host(selected: "object")
        let objectFrame = try #require(strip.buttons[0].isHidden ? nil : strip.buttons[0].frame)
        let selected = TestBitmap(of: container)
        // Select Document: the same place now holds the Object tab unselected.
        strip.select("document", animated: false)
        let unselected = TestBitmap(of: container)
        let difference = selected.meanDifference(to: unselected, in: objectFrame)
        #expect(difference > 0.02, "selected and unselected tabs render differently (\(difference))")
        // The selected tab has the accent bar along its top; the unselected one does not.
        let accent = try #require(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        let bar = CGRect(x: objectFrame.midX - 4, y: objectFrame.minY + 1, width: 8, height: PanelTabStrip.accentThickness)
        #expect(selected.fraction(near: accent, in: bar) > 0.5)
        #expect(unselected.fraction(near: accent, in: bar) < 0.1)
        // The card rises into the selected tab: its shape covers the tab, not the other tabs.
        let shape = card.shape()
        let documentFrame = strip.buttons[1].frame
        #expect(shape.contains(CGPoint(x: documentFrame.midX, y: documentFrame.midY)))
        #expect(!shape.contains(CGPoint(x: objectFrame.midX, y: objectFrame.midY)), "the unselected tab sits on the chrome")
        // Bold label, full-contrast icon for the selected tab.
        #expect(strip.buttons[1].font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(strip.buttons[1].contentTintColor == .labelColor)
        #expect(strip.buttons[0].contentTintColor == PanelTabButton.unselectedColor)
    }

    @Test func hoverAndKeyboardFocusAreVisible() throws {
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 260, height: 80))
        defer { window.close() }
        let (container, strip, _) = host(selected: "object")
        window.contentView = container
        strip.layoutSubtreeIfNeeded()
        let frame = strip.buttons[2].frame
        let plain = TestBitmap(of: container)
        strip.hover(at: CGPoint(x: frame.midX, y: frame.midY))
        #expect(strip.hoveredID == "layers" && strip.buttons[2].isHovered)
        let hovered = TestBitmap(of: container)
        #expect(plain.meanDifference(to: hovered, in: frame) > 0.01, "an unselected tab highlights under the pointer")
        strip.hover(at: nil)
        #expect(strip.hoveredID == nil)
        strip.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)

        // The focused tab draws a ring in the focus colour (the window is not on screen, so the
        // ring shows as in a key window).
        #expect(window.makeFirstResponder(strip.buttons[2]))
        #expect(strip.buttons[2].showsFocus && !strip.buttons[1].showsFocus)
        let focused = TestBitmap(of: container)
        // The ring is the (blue) focus colour: along the tab's top edge, blue pixels appear.
        let edge = CGRect(x: frame.minX + 4, y: frame.minY + 1.5, width: frame.width - 8, height: 3)
        #expect(focused.fraction(bluerBy: 0.2, in: edge) > 0.3 && plain.fraction(bluerBy: 0.2, in: edge) < 0.05)
        #expect(focused.meanDifference(to: plain, in: frame) > 0.01)
        window.makeFirstResponder(nil)
        #expect(!strip.buttons[2].showsFocus)
        strip.updateTrackingAreas()
        #expect(!strip.trackingAreas.isEmpty)
    }

    @Test func aCrowdedStripShowsIconsThenAnOverflowMenu() throws {
        let (_, strip, _) = host(selected: "document", width: 170)
        #expect(strip.buttons[0].isCompact && !strip.buttons[1].isCompact, "unselected labels drop to icons")
        #expect(strip.overflowButton.isHidden)
        let (_, narrow, _) = host(selected: "document", width: 96)
        #expect(!narrow.overflowButton.isHidden && narrow.overflowButton.accessibilityIdentifier() == "panel-tab.overflow")
        let hidden = narrow.arrangement.hidden
        #expect(!hidden.isEmpty && !hidden.contains(1), "the selected tab stays")
        #expect(hidden.allSatisfy { narrow.buttons[$0].isHidden })
        var presented: NSMenu?
        narrow.presentOverflow = { menu, _ in presented = menu }
        narrow.overflowButton.performClick(nil)
        let menu = try #require(presented)
        #expect(menu.items.map(\.title) == hidden.map { narrow.items[$0].accessibilityLabel })
        var chosen: [PanelID] = []
        narrow.onSelect = { chosen.append($0) }
        let item = try #require(menu.items.first)
        narrow.overflowChosen(item)
        #expect(chosen == [narrow.items[hidden[0]].id] && narrow.selectedID == narrow.items[hidden[0]].id)
        #expect(!narrow.buttons[hidden[0]].isHidden, "the chosen tab comes into the strip")
        // Dropping onto a crowded strip: hidden tabs count as lying after the visible ones.
        #expect(narrow.tabIndex(atX: 95) == narrow.items.count)
        narrow.overflowChosen(NSMenuItem())
    }

    @Test func textOnlyLabelsOverflowWithoutIcons() {
        let items = ["Alpha", "Beta", "Gamma", "Delta"].map { PanelTabStrip.Item(id: PanelID($0), title: $0) }
        let strip = PanelTabStrip(items: items, selected: "Gamma")
        strip.frame = NSRect(x: 0, y: 0, width: 120, height: PanelTabStrip.height)
        strip.layoutSubtreeIfNeeded()
        #expect(strip.buttons.allSatisfy { !$0.isCompact }, "a tab without an icon keeps its label")
        #expect(!strip.overflowButton.isHidden && !strip.buttons[2].isHidden)
    }

    @Test func theSectionVariantDrawsItsOwnSelection() {
        let items = ["Move", "Rotate", "Scale"].map { PanelTabStrip.Item(id: PanelID($0.lowercased()), title: $0) }
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 240, height: PanelTabStrip.sectionHeight))
        container.appearance = NSAppearance(named: .aqua)
        let strip = PanelTabStrip(items: items, selected: "move", variant: .section)
        strip.frame = container.bounds
        container.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        #expect(strip.stripHeight == PanelTabStrip.sectionHeight && strip.intrinsicContentSize.height == PanelTabStrip.sectionHeight)
        #expect(abs((strip.buttons.last?.frame.maxX ?? 0) - 240) < 0.5, "section tabs span their strip")
        let frame = strip.buttons[0].frame
        let selected = TestBitmap(of: container)
        strip.select("rotate", animated: false)
        let unselected = TestBitmap(of: container)
        #expect(selected.meanDifference(to: unselected, in: frame) > 0.02)
        // A drop highlight tints the whole strip.
        strip.isDropTarget = true
        let target = TestBitmap(of: container)
        #expect(target.meanDifference(to: unselected, in: container.bounds) > 0.01)
    }

    @Test func aGroupWithOnePanelShowsNoStripAndDragsByItsTitle() throws {
        let single = PanelGroup(id: "layers", name: "Layers", panels: ["layers"])
        let view = PanelGroupView(group: single, title: { $0.rawValue.capitalized }, body: { _ in NSView() })
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
        view.layoutSubtreeIfNeeded()
        #expect(!view.showsTabs && view.tabStrip.isHidden)
        #expect(view.bodyCard.frame.minY == PanelGroupView.titleHeight && view.bodyCard.bodyTop == 0 && view.bodyCard.tabRect == nil)
        #expect(PanelGroupView.chromeHeight(of: single) == PanelGroupView.titleHeight + PanelGroupView.margin)
        #expect(PanelInteraction.dragRect(of: view).height == PanelGroupView.titleHeight)
        #expect(view.joins(at: CGPoint(x: 10, y: 10)))

        let pair = PanelGroup(id: "g", name: "Pair", panels: ["a", "b"])
        let tabbed = PanelGroupView(group: pair, title: { $0.rawValue }, body: { _ in NSView() })
        tabbed.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
        tabbed.layoutSubtreeIfNeeded()
        #expect(tabbed.showsTabs && tabbed.bodyCard.bodyTop == PanelGroupView.tabRowHeight)
        let tab = try #require(tabbed.bodyCard.tabRect)
        #expect(tab == tabbed.bodyCard.convert(tabbed.tabStrip.buttons[0].frame, from: tabbed.tabStrip), "the card's folder tab is the selected tab")
        #expect(PanelGroupView.chromeHeight(of: pair) == PanelGroupView.titleHeight + PanelGroupView.tabRowHeight + PanelGroupView.margin)

        // A drag on a docked group's title drags the group.
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 260, height: 300))
        defer { window.close() }
        window.contentView?.addSubview(view)
        var drags = 0
        view.onDragGroup = { _ in drags += 1 }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 290), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .eventTracking, dequeue: true) != nil {}
        window.postEvent(mouse(.leftMouseDragged, x: 160), atStart: false)
        view.titleBar.mouseDown(with: mouse(.leftMouseDown, x: 100))
        #expect(drags == 1)
    }

    @Test func theSelectedTabMovesTheCardsFolderTab() throws {
        let group = PanelGroup(id: "g", name: "Pair", panels: ["a", "b", "c"], activePanel: "a")
        let view = PanelGroupView(group: group, title: { $0.rawValue.uppercased() }, body: { _ in NSView() })
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
        view.layoutSubtreeIfNeeded()
        let before = try #require(view.bodyCard.tabRect)
        var moved = group
        moved.activePanel = "c"
        view.show(moved, body: { _ in NSView() })
        let after = try #require(view.bodyCard.tabRect)
        #expect(after.minX > before.maxX, "the folder tab follows the selection")
        // The card's outline: a tab away from the edges has fillets on both sides.
        #expect(!view.bodyCard.shape().isEmpty)
        view.bodyCard.tabRect = CGRect(x: 60, y: 0, width: 50, height: PanelTabStrip.height)
        #expect(view.bodyCard.shape().contains(CGPoint(x: 85, y: 10)) && !view.bodyCard.shape().contains(CGPoint(x: 20, y: 10)))
        view.bodyCard.tabRect = CGRect(x: 200, y: 0, width: 48, height: PanelTabStrip.height)
        #expect(view.bodyCard.shape().contains(CGPoint(x: 220, y: 10)))
        _ = TestBitmap(of: view)
    }
}

/// A flipped plain container for rendering tests.
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A view rendered into a 2x sRGB bitmap (drawn, as `cacheDisplay` does: glass and backdrop
/// blurs do not render, so what is measured is the worst case of the frost alone).
@MainActor
struct TestBitmap {
    let rep: NSBitmapImageRep
    /// Points of the rendered view (flipped: y down).
    let size: CGSize
    let scale: CGFloat = 2

    init(of view: NSView) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        // Retagged as sRGB (no conversion), sized in points so it renders at 2x.
        let tagged = rep.retagging(with: .sRGB) ?? rep
        tagged.size = bounds.size
        view.cacheDisplay(in: bounds, to: tagged)
        self.rep = tagged
        size = bounds.size
    }

    /// The pixel at pixel coordinates (top-left origin) as sRGB components.
    func rgb(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// The pixel coordinates inside `rect` (points, y down).
    func pixels(in rect: CGRect) -> [(Int, Int)] {
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return [] }
        var result: [(Int, Int)] = []
        for y in Int(clipped.minY * scale)..<Int(clipped.maxY * scale) {
            for x in Int(clipped.minX * scale)..<Int(clipped.maxX * scale) { result.append((x, y)) }
        }
        return result
    }

    /// The pixel's opacity.
    func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }

    /// The mean per-channel difference (colour and opacity) to `other` inside `rect`.
    func meanDifference(to other: TestBitmap, in rect: CGRect) -> CGFloat {
        let points = pixels(in: rect)
        guard !points.isEmpty else { return 0 }
        var total: CGFloat = 0
        for (x, y) in points {
            let a = rgb(x, y), b = other.rgb(x, y)
            total += (abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) + abs(alpha(x, y) - other.alpha(x, y))) / 4
        }
        return total / CGFloat(points.count)
    }

    /// The largest per-channel difference to `other` inside `rect`.
    func maximumDifference(to other: TestBitmap, in rect: CGRect) -> CGFloat {
        pixels(in: rect).reduce(0) { worst, point in
            let a = rgb(point.0, point.1), b = other.rgb(point.0, point.1)
            return max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        }
    }

    /// The share of pixels in `rect` within `tolerance` of `color` on every channel.
    func fraction(near color: NSColor, in rect: CGRect, tolerance: CGFloat = 0.2) -> CGFloat {
        let points = pixels(in: rect)
        guard !points.isEmpty, let target = color.usingColorSpace(.sRGB) else { return 0 }
        let near = points.filter { x, y in
            let p = rgb(x, y)
            return abs(p.r - target.redComponent) < tolerance && abs(p.g - target.greenComponent) < tolerance && abs(p.b - target.blueComponent) < tolerance
        }
        return CGFloat(near.count) / CGFloat(points.count)
    }

    /// The share of pixels in `rect` whose blue exceeds their red by `margin` (the accent and
    /// focus colours are blue by default).
    func fraction(bluerBy margin: CGFloat, in rect: CGRect) -> CGFloat {
        let points = pixels(in: rect)
        guard !points.isEmpty else { return 0 }
        return CGFloat(points.filter { x, y in let p = rgb(x, y); return p.b - p.r > margin }.count) / CGFloat(points.count)
    }

    /// WCAG relative luminance of the pixel.
    func luminance(_ x: Int, _ y: Int) -> CGFloat {
        let p = rgb(x, y)
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(p.r) + 0.7152 * channel(p.g) + 0.0722 * channel(p.b)
    }
}
