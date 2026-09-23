import AppKit
import SwiftUI

/// Every tool of the Tools panel (toolbars.adoc, "Tools section" and "View section"): id,
/// title, SF Symbol placeholder, the default set's keys (letter, then digit), flyout, section,
/// options sheet and help page.  Tools whose epic has not landed run `UnimplementedTool`; an
/// epic replaces one `make` (`ToolDescriptor.delivering`).  The Keyline and Fast Mode buttons
/// and the Colors and Snap controls are commands, not tools (`ToolPanelCommands`).
enum ToolCatalog {
    private static func key(_ character: String, _ modifiers: KeyModifiers = []) -> KeyEquivalent { KeyEquivalent(character, modifiers) }

    private static func stub(
        _ id: ToolID, _ title: String, _ symbol: String, _ keys: [KeyEquivalent] = [], group: FlyoutGroup? = nil,
        section: ToolSection = .tools, options: Bool = false, help: String
    ) -> ToolDescriptor {
        var sheet: (@MainActor @Sendable () -> NSViewController)?
        if options {
            sheet = { ToolOptionsPlaceholder.controller(title: title) }
        }
        return ToolDescriptor(
            id: id, title: title, symbolName: symbol, shortcuts: keys, group: group, section: section, options: sheet, helpSlug: help
        ) {
            UnimplementedTool(id: id, title: title)
        }
    }

    static let all: [ToolDescriptor] = [
        // Selection
        stub(.pointer, "Pointer", "cursorarrow", [key("v"), key("0")], options: true, help: "selecting"),
        stub("subselect", "Subselect", "cursorarrow.rays", [key("a"), key("1")], options: true, help: "selecting"),
        stub("lasso", "Lasso", "lasso", [key("l")], options: true, help: "selecting"),
        stub("page", "Page", "doc", [key("d")], help: "pages"),
        // Text
        stub("text", "Text", "textformat", [key("t")], help: "creating-text"),
        // Pen flyout
        stub("pen", "Pen", "pencil.tip", [key("p"), key("6")], group: .pen, help: "pen-bezigon"),
        stub("bezigon", "Bezigon", "point.topleft.down.to.point.bottomright.curvepath", [key("b"), key("5")], group: .pen, help: "pen-bezigon"),
        // Pencil flyout
        stub("pencil", "Pencil", "pencil", [key("y"), key("9")], group: .pencil, options: true, help: "freeform"),
        stub("variableStrokePen", "Variable Stroke Pen", "scribble.variable", group: .pencil, options: true, help: "freeform"),
        stub("calligraphicPen", "Calligraphic Pen", "paintbrush.pointed", group: .pencil, options: true, help: "freeform"),
        // Line
        stub("line", "Line", "line.diagonal", [key("n"), key("4")], help: "rectangles-ellipses-lines"),
        // Rectangle flyout: APP-003's sketch tool until the OBJ epic.
        ToolDescriptor(
            id: .rectangle, title: "Rectangle", symbolName: "rectangle", shortcuts: [key("r"), key("2")], group: .rectangle,
            helpSlug: "rectangles-ellipses-lines"
        ) { RectangleSketchTool() },
        stub("polygon", "Polygon", "pentagon", [key("g")], group: .rectangle, options: true, help: "polygons-stars"),
        // Ellipse flyout
        stub("ellipse", "Ellipse", "circle", [key("o"), key("3")], group: .ellipse, help: "rectangles-ellipses-lines"),
        stub("spiral", "Spiral", "hurricane", group: .ellipse, options: true, help: "spirals-arcs"),
        stub("arc", "Arc", "rainbow", group: .ellipse, options: true, help: "spirals-arcs"),
        // Freeform flyout
        stub("freeform", "Freeform", "hand.draw", [key("f")], group: .freeform, options: true, help: "editing-paths"),
        stub("roughen", "Roughen", "waveform.path", group: .freeform, options: true, help: "path-effects"),
        stub("bend", "Bend", "arrow.uturn.right", group: .freeform, options: true, help: "path-effects"),
        stub("fisheyeLens", "Fisheye Lens", "eye", group: .freeform, options: true, help: "path-effects"),
        stub("smudge", "Smudge", "hand.point.up.left", group: .freeform, options: true, help: "path-effects"),
        stub("shadow", "Shadow", "shadow", group: .freeform, options: true, help: "path-effects"),
        stub("mirror", "Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", group: .freeform, options: true, help: "path-effects"),
        stub("rotation3D", "3D Rotation", "rotate.3d", group: .freeform, options: true, help: "path-effects"),
        // Knife flyout
        stub("knife", "Knife", "scissors", [key("k"), key("7")], group: .knife, options: true, help: "editing-paths"),
        stub("eraser", "Eraser", "eraser", [key("e")], group: .knife, options: true, help: "editing-paths"),
        // Trace and color
        stub("trace", "Trace", "photo", [key("8")], options: true, help: "tracing"),
        stub("eyedropper", "Eyedropper", "eyedropper", [key("i")], help: "applying-color"),
        // Effects flyout
        stub("extrude", "Extrude", "cube", [key("x")], group: .effects, help: "extrude"),
        stub("blend", "Blend", "square.on.circle", [key("w")], group: .effects, help: "blends"),
        stub("perspective", "Perspective", "perspective", group: .effects, help: "perspective"),
        // Objects that link and repeat
        stub("graphicHose", "Graphic Hose", "sparkles", [key("h", .shift)], options: true, help: "graphic-hose"),
        stub("chart", "Chart", "chart.bar", options: true, help: "charts"),
        stub("connector", "Connector", "point.3.connected.trianglepath.dotted", help: "connectors"),
        stub("action", "Action", "hand.tap", help: "interactivity"),
        stub("outputArea", "Output Area", "crop", help: "output-area"),
        // Transform flyout
        stub("rotate", "Rotate", "rotate.right", group: .transform, options: true, help: "transforming"),
        stub("scale", "Scale", "arrow.up.left.and.arrow.down.right", group: .transform, options: true, help: "transforming"),
        stub("skew", "Skew", "rectangle.portrait.arrowtriangle.2.outward", group: .transform, options: true, help: "transforming"),
        stub("reflect", "Reflect", "flip.horizontal", group: .transform, options: true, help: "transforming"),
        // View section: APP-003's Zoom and Hand.
        ToolDescriptor(id: .zoom, title: "Zoom", symbolName: "plus.magnifyingglass", shortcuts: [key("z")], section: .view, helpSlug: "document-view") { ZoomTool() },
        ToolDescriptor(id: .hand, title: "Hand", symbolName: "hand.raised", shortcuts: [key("h")], section: .view, helpSlug: "document-view") { PanTool() },
    ]
}

/// The options sheet of a tool whose epic has not landed: names the tool and closes.
enum ToolOptionsPlaceholder {
    @MainActor
    static func controller(title: String) -> NSViewController {
        let controller = NSHostingController(rootView: ToolOptionsPlaceholderView(title: title, dismiss: {}))
        controller.rootView = ToolOptionsPlaceholderView(title: title) { [weak controller] in close(controller?.view.window) }
        controller.title = "\(title) Options"
        return controller
    }

    /// Ends the sheet `window` is, or closes it.
    @MainActor
    static func close(_ window: NSWindow?) {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }
}

struct ToolOptionsPlaceholderView: View {
    let title: String
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) Options").font(.headline)
            Text("The options for this tool arrive with its feature.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("tool-options.done")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
