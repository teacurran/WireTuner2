import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A drag carrying whatever `pasteboard` holds, over a view at `location` (AppKit points).
@MainActor
final class PasteboardDragging: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    init(_ pasteboard: NSPasteboard, at location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Colour drops on the canvas with the kbd:[Shift] / kbd:[Cmd] / kbd:[Option] rules, and the Tools
/// panel wells' palettes and drops (applying-color.adoc; COLOR-011).
@Suite(.serialized) @MainActor struct ColorDropTests {
    static let red = RenderColor(red: 1, green: 0, blue: 0)
    static let blue = RenderColor(red: 0, green: 0, blue: 1)

    /// A window with a lone square at (100, 100) and a group of two squares at (300, 100) and
    /// (360, 100), each 40 × 40 with a white fill and a black stroke.
    @MainActor
    final class Canvas {
        let world = ImportWorld()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.colordrop.\(UUID().uuidString)"))
        var lone = OpID(counter: 0, replica: 0)
        var members: [OpID] = []
        var group = OpID(counter: 0, replica: 0)

        func build() async {
            await world.document.settle()
            let ids = await world.document.addRectangles([Rect(x: 100, y: 100, width: 40, height: 40), Rect(x: 300, y: 100, width: 40, height: 40),
                                                          Rect(x: 360, y: 100, width: 40, height: 40)])
            lone = ids[0].opID
            members = [ids[1].opID, ids[2].opID]
            _ = await world.document.perform(GroupObjects(members)).value
            await world.document.settle()
            group = Objects.parent(of: members[0], in: world.state)!
        }

        var drop: CanvasColorDrop { world.window.canvas.colorDrop! }
        var viewport: Viewport { world.window.canvas.viewport }

        /// The view point over pasteboard point (`x`, `y`).
        func view(_ x: Double, _ y: Double) -> Point { viewport.toView(Point(x: x, y: y)) }

        func put(_ color: RenderColor, name: String = "") {
            ColorDrag.write(ColorRefPasteboard(ref: ColorResolver.inline(color), color: color, name: name), to: pasteboard)
        }

        func paint(_ node: OpID, _ kind: AttributeKind) -> RenderColor? {
            let entry = AppearanceEditing.entries(node, in: world.state).last { $0.kind == kind }
            return entry.flatMap(AttributeFields.color).flatMap { SwatchList(world.state).resolver.color($0) }
        }

        func fill(_ node: OpID) -> RenderColor? { paint(node, .fill(.basic)) }
        func stroke(_ node: OpID) -> RenderColor? { paint(node, .stroke(.basic)) }

        /// Drops at pasteboard (`x`, `y`) with `modifiers` and waits for the change.
        func drop(at x: Double, _ y: Double, _ modifiers: KeyModifiers = []) async {
            _ = await drop.drop(pasteboard, at: view(x, y), viewport: viewport, modifiers: modifiers)?.value
        }
    }

    @Test func theModifiersAndThePartUnderThePointerChooseThePaint() {
        #expect(CanvasColorDrop.paint(for: .fill, modifiers: []) == .fill)
        #expect(CanvasColorDrop.paint(for: .text, modifiers: []) == .fill && CanvasColorDrop.paint(for: .image, modifiers: []) == .fill)
        let location = PathLocation(contour: 0, segment: 0, t: 0)
        for kind in [HitKind.stroke(nil), .segment(location), .point(element: 0), .handle(element: 0, control: 1)] {
            #expect(CanvasColorDrop.paint(for: kind, modifiers: []) == .stroke)
            #expect(CanvasColorDrop.paint(for: kind, modifiers: [.shift]) == .fill)
        }
        #expect(CanvasColorDrop.paint(for: .fill, modifiers: [.command]) == .stroke)
    }

    @Test func aDropColoursTheFillOrStrokeUnderThePointerOrWhatTheModifiersSay() async throws {
        let canvas = Canvas()
        defer { canvas.world.close() }
        await canvas.build()
        canvas.put(Self.red)
        // Over the fill: the fill highlights and takes the colour.
        #expect(canvas.drop.update(canvas.pasteboard, at: canvas.view(120, 120), viewport: canvas.viewport, modifiers: []))
        #expect(canvas.drop.highlight?.node == canvas.lone && canvas.drop.highlight?.target == .fill)
        #expect(canvas.drop.highlight?.bounds.minX ?? 0 <= 100)
        await canvas.drop(at: 120, 120)
        #expect(canvas.fill(canvas.lone) == Self.red && canvas.stroke(canvas.lone) != Self.red && canvas.drop.highlight == nil)
        #expect(canvas.world.document.undoTitle == "Undo Apply color")
        // Over the stroke: the stroke.
        canvas.put(Self.blue, name: "Navy")
        #expect(canvas.drop.update(canvas.pasteboard, at: canvas.view(99, 120), viewport: canvas.viewport, modifiers: []))
        #expect(canvas.drop.highlight?.target == .stroke)
        await canvas.drop(at: 99, 120)
        #expect(canvas.stroke(canvas.lone) == Self.blue && canvas.fill(canvas.lone) == Self.red)
        // Shift over the stroke colours the fill; Cmd over the fill colours the stroke.
        canvas.put(Self.red)
        await canvas.drop(at: 99, 120, [.shift])
        #expect(canvas.fill(canvas.lone) == Self.red)
        await canvas.drop(at: 120, 120, [.command])
        #expect(canvas.stroke(canvas.lone) == Self.red)
        // Empty pasteboard does nothing.
        #expect(!canvas.drop.update(canvas.pasteboard, at: canvas.view(700, 700), viewport: canvas.viewport, modifiers: []))
        #expect(canvas.drop.drop(canvas.pasteboard, at: canvas.view(700, 700), viewport: canvas.viewport, modifiers: []) == nil)
        // A drag carrying no colour highlights nothing.
        canvas.pasteboard.clearContents()
        #expect(!canvas.drop.update(canvas.pasteboard, at: canvas.view(120, 120), viewport: canvas.viewport, modifiers: []))
        #expect(canvas.drop.drop(canvas.pasteboard, at: canvas.view(120, 120), viewport: canvas.viewport, modifiers: []) == nil)
    }

    @Test func aGroupTakesTheColourOnEveryMemberUnlessOptionPicksTheOneUnderThePointer() async throws {
        let canvas = Canvas()
        defer { canvas.world.close() }
        await canvas.build()
        canvas.put(Self.red)
        #expect(canvas.drop.target(at: canvas.view(320, 120), viewport: canvas.viewport, modifiers: [])?.node == canvas.group)
        await canvas.drop(at: 320, 120)
        #expect(canvas.members.map(canvas.fill) == [Self.red, Self.red])
        #expect(canvas.world.document.undoTitle == "Undo Apply color")
        canvas.put(Self.blue)
        #expect(canvas.drop.target(at: canvas.view(380, 120), viewport: canvas.viewport, modifiers: [.option])?.node == canvas.members[1])
        await canvas.drop(at: 380, 120, [.option])
        #expect(canvas.members.map(canvas.fill) == [Self.red, Self.blue])
    }

    @Test func theCanvasRoutesColourDragsAndDrawsTheHighlight() async throws {
        let canvas = Canvas()
        defer { canvas.world.close() }
        await canvas.build()
        let view = canvas.world.window.canvas
        canvas.put(Self.blue)
        final class Held { var modifiers: KeyModifiers = [.command] }
        let held = Held()
        view.dragModifiers = { held.modifiers }
        let over = view.convert(NSPoint(x: canvas.view(120, 120).x, y: view.bounds.height - canvas.view(120, 120).y), to: nil)
        let drag = PasteboardDragging(canvas.pasteboard, at: over)
        #expect(view.draggingEntered(drag) == .copy && view.draggingUpdated(drag) == .copy)
        #expect(canvas.drop.highlight?.target == .stroke)
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        view.drawOverlay(in: context)
        held.modifiers = []
        _ = view.draggingUpdated(drag)
        view.drawOverlay(in: context)
        view.draggingExited(drag)
        #expect(canvas.drop.highlight == nil)
        held.modifiers = [.command]
        #expect(view.performDragOperation(drag))
        #expect(await eventually { canvas.stroke(canvas.lone) == Self.blue })
        // Nothing under the pointer: refused.
        let empty = PasteboardDragging(canvas.pasteboard, at: view.convert(NSPoint(x: 5, y: 5), to: nil))
        #expect(view.draggingUpdated(empty) == [] && !view.performDragOperation(empty))
        // Without a colour target the canvas refuses colours.
        #expect(canvas.drop.defaultSpace() == .displayP3)
        _ = canvas.world.environment.preferences.set("srgb", for: PreferenceCatalog.Colors.defaultColorSpace)
        #expect(canvas.drop.defaultSpace() == .sRGB)
        view.colorDrop = nil
        #expect(view.draggingUpdated(drag) == [] && !view.performDragOperation(drag))
        view.draggingExited(nil)
        #expect(KeyEquivalentResolver.modifiers(NSEvent.modifierFlags) == CanvasView(document: canvas.world.document).dragModifiers())
    }

    // MARK: The Tools panel wells

    @Test func wellsPickAndTakeDropsForTheSelectionOrTheCurrentColours() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let palette = ToolPaletteModel()
        // Without the colour panels the wells show and set the current colours.
        #expect(palette.wellModel(.fill) == nil && !palette.drop(from: fixture.pasteboard, on: .fill))
        palette.choose(ColorResolver.inline(Self.red), color: Self.red, for: .fill)
        #expect(palette.wells.fill == .solid(Self.red))
        palette.choose(ColorResolver.none, for: .stroke)
        #expect(palette.wells.stroke == .none)
        palette.restoreDefaultWells()

        let swatches = SwatchesPanelModel(workspace: fixture.workspace)
        palette.coloring = ToolWellColoring(swatches: swatches)
        #expect(ActiveWell.fill.target == .fill && ActiveWell.stroke.target == .stroke)
        // Nothing selected: the palette shows the current colour; a pick changes it.
        #expect(palette.wellModel(.fill)?.chip == .color(.white) && palette.wellModel(.stroke)?.chip == .color(.black))
        palette.openPalette(.stroke)
        #expect(palette.paletteWell == .stroke && palette.activeWell == .stroke)
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        palette.choose(fixture.list.resolver.reference(to: grape), name: "Grape", for: .stroke)
        #expect(palette.paletteWell == nil && palette.wells.stroke == .solid(RenderColor(red: 0.5, green: 0, blue: 0.5)))
        palette.choose(ColorResolver.none, for: .fill)
        #expect(palette.wells.fill == .none && palette.wellModel(.fill)?.chip == ColorWellModel.Chip.none)
        // A colour dropped on a well with nothing selected: the current colour.
        fixture.put(ColorRefPasteboard(ref: ColorResolver.inline(Self.blue), color: Self.blue))
        #expect(palette.drop(from: fixture.pasteboard, on: .fill))
        #expect(await eventually { palette.wells.fill == .solid(Self.blue) })

        // Objects selected: picks and drops colour their fills and strokes as one change each.
        let first = await fixture.rect()
        let second = await fixture.rect()
        fixture.select([first, second])
        #expect(palette.wellModel(.fill)?.chip == .color(.white))
        palette.choose(fixture.list.resolver.reference(to: grape), name: "Grape", for: .fill)
        #expect(await eventually { fixture.fill(first) == fixture.list.resolver.reference(to: grape) })
        #expect(fixture.document.undoTitle == "Undo Apply \"Grape\" to 2 objects" && palette.wells.fill == .solid(Self.blue))
        fixture.put(ColorRefPasteboard(ref: ColorResolver.inline(Self.red), color: Self.red))
        #expect(palette.drop(from: fixture.pasteboard, on: .stroke))
        #expect(await eventually { fixture.document.undoTitle == "Undo Apply color to 2 objects" })
        fixture.pasteboard.clearContents()
        #expect(!palette.drop(from: fixture.pasteboard, on: .fill))

        // Without a document the palette has nothing to list; a drop still sets the colour.
        let away = ColorPanelFixture()
        let loose = ToolPaletteModel()
        loose.coloring = ToolWellColoring(swatches: SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection())))
        #expect(loose.wellModel(.fill) == nil)
        away.put(ColorRefPasteboard(ref: ColorResolver.inline(Self.red), color: Self.red))
        #expect(loose.drop(from: away.pasteboard, on: .stroke) && loose.wells.stroke == .solid(Self.red))
        #expect(ToolWellColoring.reference(.none) == ColorResolver.none && ToolWellColoring.reference(.solid(Self.red)) == ColorResolver.inline(Self.red))
    }

    @Test func theWellsViewShowsChipsPalettesAndTakesDrops() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let palette = ToolPaletteModel()
        #expect(ToolWellsView.chip(.solid(Self.red), model: nil) == .color(Self.red) && ToolWellsView.chip(.none, model: nil) == .none)
        ColorPanelFixture.render(ToolWellsView(model: palette))
        ColorPanelFixture.render(ToolWellsView.palette(palette, .fill))
        palette.coloring = ToolWellColoring(swatches: SwatchesPanelModel(workspace: fixture.workspace))
        #expect(ToolWellsView.chip(.solid(Self.red), model: palette.wellModel(.fill)) == .color(.white))
        let shows = ToolWellsView.showsPalette(palette, .fill)
        ToolWellsView.opening(palette, .fill)()
        #expect(shows.wrappedValue)
        ColorPanelFixture.render(ToolWellsView(model: palette))
        ColorPanelFixture.render(ToolWellsView.palette(palette, .fill))
        ToolWellsView.choosing(palette, .fill)(ColorResolver.none)
        #expect(palette.wells.fill == .none && palette.paletteWell == nil)
        ToolWellsView.opening(palette, .fill)()
        ToolWellsView.showsPalette(palette, .stroke).wrappedValue = false
        #expect(palette.paletteWell == .fill, "closing another well's palette leaves this one")
        shows.wrappedValue = false
        #expect(palette.paletteWell == nil && !shows.wrappedValue)
        fixture.put(ColorRefPasteboard(ref: ColorResolver.inline(Self.red), color: Self.red))
        #expect(ToolWellsView.dropping(palette, .stroke, pasteboard: fixture.pasteboard)([]))
        #expect(await eventually { palette.wells.stroke == .solid(Self.red) })
    }
}
