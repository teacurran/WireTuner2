import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The menu:Modify[Extrude] submenu (extrude.adoc; FX-020): *Extrude* (the selection toward the
/// current page's centre at the default depth), *Remove*, *Release*, *Reset* and *Share Vanishing
/// Points*, which asks for a click on the canvas.  Each is one change.
@MainActor
enum ExtrudeMenu {
    typealias Target = ObjectMenuCommands.Target
    /// The window's tool manager (Share Vanishing Points pushes its click tool).
    typealias Tools = @MainActor () -> ToolManager?

    enum ID {
        static let extrude: CommandID = "modify.extrude.extrude"
        static let remove: CommandID = "modify.extrude.remove"
        static let release: CommandID = "modify.extrude.release"
        static let reset: CommandID = "modify.extrude.reset"
        static let share: CommandID = "modify.extrude.shareVanishingPoints"
    }

    static let submenu = "Extrude"
    static let noExtrusion = "Select an extruded object"
    static let nested = "Extrusions cannot be nested"
    static let twoExtrusions = "Select two or more extruded objects"

    /// The selected objects that can be extruded.
    static func flatObjects(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return editing.selectedNodes.filter { Objects.isObject($0, in: state) }
    }

    /// Why the selection cannot be extruded, or nil.
    static func extrudeRefusal(_ editing: ObjectEditing) -> String? {
        let state = editing.document.state
        let nodes = flatObjects(editing)
        guard !nodes.isEmpty else { return ObjectMenuCommands.noSelection }
        return nodes.contains { ExtrudeReading.isInsideExtrusion($0, in: state) || ExtrudeReading.containsExtrusion($0, in: state) } ? nested : nil
    }

    /// The extrusions the selection names (a selected shape inside one names it).
    static func extrusions(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        var seen: Set<OpID> = []
        return editing.selectedNodes.compactMap { ExtrudeTool.extrusion(of: $0, in: state) }.filter { seen.insert($0).inserted }
    }

    /// Where *Extrude* from the menu points the solid: the current page's centre.
    static func defaultVanishingPoint(_ editing: ObjectEditing) -> Point {
        (editing.document.currentPage ?? Pasteboard.letterPage).center
    }

    static func extrude(_ editing: ObjectEditing) -> Task<Void, Never>? {
        guard extrudeRefusal(editing) == nil else { return nil }
        return BlendMenu.performSelecting(Extrude(flatObjects(editing), vanishingPoint: defaultVanishingPoint(editing)), editing)
    }

    /// Pushes the click that places the shared vanishing point.
    static func share(_ editing: ObjectEditing, tools: ToolManager?) {
        let nodes = extrusions(editing)
        guard nodes.count >= 2, let tools else { return }
        tools.push(VanishingPointPicker(nodes: nodes, sink: editing, tools: tools))
    }

    static func commands(target: @escaping Target, tools: @escaping Tools) -> [Command] {
        let modify = ContextMenuCatalog.Menu.modify
        let path = MenuPath(modify, submenu, section: 4)
        func run(_ body: @escaping @MainActor (ObjectEditing) -> Void) -> CommandAction {
            .perform { if let editing = target() { body(editing) } }
        }
        let wrapped = BlendMenu.validation(target) { extrusions($0).isEmpty ? noExtrusion : nil }
        return [
            Command(id: ID.extrude, title: "Extrude", menu: path, keywords: ["3d", "solid", "extrude"],
                    validation: BlendMenu.validation(target, extrudeRefusal), action: run { _ = extrude($0) }),
            Command(id: ID.remove, title: "Remove", menu: path, keywords: ["extrude", "flat"], validation: wrapped,
                    action: run { editing in editing.perform(RemoveExtrusion(extrusions(editing))) }),
            Command(id: ID.release, title: "Release", menu: path, keywords: ["extrude", "faces", "expand"], validation: wrapped,
                    action: run { editing in editing.perform(ReleaseExtrusion(extrusions(editing))) }),
            Command(id: ID.reset, title: "Reset", menu: path, keywords: ["extrude", "rotation", "profile"], validation: wrapped,
                    action: run { editing in editing.perform(ResetExtrusion(extrusions(editing))) }),
            Command(id: ID.share, title: "Share Vanishing Points", menu: path, keywords: ["extrude", "perspective"],
                    validation: BlendMenu.validation(target) { extrusions($0).count < 2 ? twoExtrusions : nil },
                    action: run { editing in share(editing, tools: tools()) }),
        ]
    }
}

/// menu:Modify[Extrude > Share Vanishing Points]'s click (extrude.adoc): pushed over the window's
/// tool, the next click on the canvas becomes every chosen extrusion's vanishing point, then it
/// pops itself; kbd:[Esc] or another tool ends it without a change.
@MainActor
final class VanishingPointPicker: Tool {
    static let id: ToolID = "extrude.shareVanishingPoints"
    static let statusMessage = "Click where the shared vanishing point should be"

    let nodes: [OpID]
    let sink: any CommandSink
    weak var tools: ToolManager?

    init(nodes: [OpID], sink: any CommandSink, tools: ToolManager?) {
        self.nodes = nodes
        self.sink = sink
        self.tools = tools
    }

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) {
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {}
    func mouseDown(_ e: CanvasEvent) {}
    func mouseDragged(_ e: CanvasEvent) {}

    func mouseUp(_ e: CanvasEvent) {
        sink.perform(ShareVanishingPoints(nodes, at: e.pasteboardPoint))
        tools?.pop(self)
    }

    func flagsChanged(_ e: CanvasEvent) {}
    func keyDown(_ e: NSEvent) -> Bool { false }
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {}

    func cancel() {
        tools?.pop(self)
    }
}
