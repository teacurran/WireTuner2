import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Arrowhead Editor's drawing (stroke-attributes.adoc, "Arrowheads"; ATTR-030): a scratch
/// document the miniature canvas edits with the ordinary tools, laid out so one arrowhead unit --
/// one stroke width -- is `scale` points, with the path's endpoint at `origin`.  btn:[New] reads
/// every drawn path back into arrowhead units as one `Arrowhead` (filled or stroked, with its
/// `path_trim`), saves it on this Mac and hands it to the stroke that asked; kbd:[Option]-click on a
/// head in a pop-up loads it for editing.
@MainActor
@Observable
final class ArrowheadEditorModel {
    /// Points per arrowhead unit on the miniature canvas.
    static let scale = 20.0
    /// Where the endpoint sits on the scratch pasteboard.
    static let origin = Point(x: 240, y: 150)
    /// How much of the reference stroke shows behind the endpoint, in units.
    static let referenceLength = 8.0

    @ObservationIgnored let document = DocumentHandle.memory(title: "Arrowhead")
    var name: String
    var filled: Bool
    /// How far (units) the path is shortened under the head.
    var pathTrim: Double

    init(loading head: Wiretuner_Doc_V1_Arrowhead? = nil) {
        name = head?.name ?? ""
        filled = head?.filled ?? true
        pathTrim = head?.pathTrim ?? 0
    }

    /// Unit point → scratch pasteboard.
    static func pasteboard(_ unit: Point) -> Point { Point(x: origin.x + unit.x * scale, y: origin.y + unit.y * scale) }
    /// Scratch pasteboard → units.
    static func unit(_ point: Point) -> Point { Point(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale) }

    /// Puts `head`'s outline on the canvas (one path per contour).
    @discardableResult
    func load(_ head: Wiretuner_Doc_V1_Arrowhead) -> Task<Void, Never> {
        let contours = head.contours.map { contour in
            NewContour(closed: contour.closed, points: contour.points.map { stored -> VectorPoint in
                let point = VectorPoint(stored)
                return VectorPoint(anchor: Self.pasteboard(point.anchor), inHandle: point.inHandle * Self.scale, outHandle: point.outHandle * Self.scale,
                                   kind: point.kind)
            })
        }
        let document = document
        return Task { @MainActor in
            for contour in contours where !contour.points.isEmpty {
                _ = await document.perform(CreatePath(contours: [contour], appearance: Appearances.standard)).value
            }
            await document.settle()
        }
    }

    /// Every drawn path's contours, in units.
    var contours: [Wiretuner_Doc_V1_Contour] {
        let state = document.state
        let objects = state.store.nodes.filter { Objects.isObject($0, in: state) }.sorted()
        var elements: [DisplayPath.Element] = []
        for node in objects {
            guard let object = document.object(for: SelectionID(node)), let path = object.path else { continue }
            for contour in path.contours where contour.isRenderable {
                let points = PathSplitting.map(contour.drawn, object.transform).map { point in
                    VectorPoint(anchor: Self.unit(point.anchor), inHandle: point.inHandle / Self.scale, outHandle: point.outHandle / Self.scale, kind: point.kind)
                }
                let segments = ContourPoints.segments(points, closed: contour.closed)
                elements.append(.move(to: points[0].anchor))
                for segment in segments { elements.append(.cubicCurve(control1: segment.p1, control2: segment.p2, end: segment.p3)) }
                if contour.closed { elements.append(.close) }
            }
        }
        return InlineShapes.contours(DisplayPath(elements: elements))
    }

    /// The arrowhead drawn so far; nil with nothing drawn.
    var arrowhead: Wiretuner_Doc_V1_Arrowhead? {
        let contours = contours
        guard !contours.isEmpty else { return nil }
        var head = Wiretuner_Doc_V1_Arrowhead()
        head.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom" : name.trimmingCharacters(in: .whitespaces)
        head.contours = contours
        head.filled = filled
        head.pathTrim = max(pathTrim, 0)
        return head
    }

    /// The reference stroke, the endpoint marker and the `path_trim` marker, drawn over the canvas.
    func drawGuides(in ctx: CGContext, viewport: Viewport) {
        let start = viewport.toView(Self.pasteboard(Point(x: -Self.referenceLength, y: 0)))
        let end = viewport.toView(Self.pasteboard(Point(x: 0, y: 0)))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(Self.scale * viewport.zoom)
        ctx.strokeLineSegments(between: [start.cgPoint, end.cgPoint])
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        for (x, color) in [(0.0, NSColor.systemBlue), (-max(pathTrim, 0), NSColor.systemOrange)] {
            let top = viewport.toView(Self.pasteboard(Point(x: x, y: -3))), bottom = viewport.toView(Self.pasteboard(Point(x: x, y: 3)))
            ctx.setStrokeColor(color.cgColor)
            ctx.strokeLineSegments(between: [top.cgPoint, bottom.cgPoint])
        }
        ctx.restoreGState()
    }
}

/// The window: the miniature canvas with the Pointer, Pen, Bezigon, Rectangle and Ellipse tools of
/// the app's tool registry (the tool framework unchanged), the head's name, *Filled* and *Path
/// trim*, and btn:[New] / btn:[Cancel].
@MainActor
final class ArrowheadEditorController: NSWindowController, NSWindowDelegate {
    static let tools: [ToolID] = [.pointer, .pen, PenTool.bezigonID, .rectangle, .ellipse]
    static let identifier = NSUserInterfaceItemIdentifier("arrowhead-editor")

    let model: ArrowheadEditorModel
    let canvas: CanvasView
    let selection: SelectionController
    let editing: ObjectEditing
    let manager: ToolManager
    /// btn:[New]'s head, or nil for btn:[Cancel]; the window closes after.
    let finish: @MainActor (Wiretuner_Doc_V1_Arrowhead?) -> Void

    init(model: ArrowheadEditorModel, tools: ToolRegistry, finish: @escaping @MainActor (Wiretuner_Doc_V1_Arrowhead?) -> Void) {
        self.model = model
        self.finish = finish
        let document = model.document
        canvas = CanvasView(document: document, frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        selection = SelectionController(document: document)
        editing = ObjectEditing(document: document, selection: selection)
        let subset = ToolRegistry()
        for id in Self.tools { if let descriptor = tools.descriptor(for: id) { subset.replace(descriptor) } }
        var context = ToolContext(document: document, host: canvas, selection: selection)
        context.commandSink = editing
        context.objectEditing = editing
        manager = ToolManager(registry: subset, context: context)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Arrowhead Editor"
        window.identifier = Self.identifier
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        canvas.toolManager = manager
        canvas.selectionController = selection
        canvas.presenceDrawer = { [weak model, weak canvas] ctx in
            guard let model, let canvas else { return }
            model.drawGuides(in: ctx, viewport: canvas.viewport)
        }
        let controls = NSHostingView(rootView: ArrowheadEditorControls(model: model, manager: manager, commit: { [weak self] in self?.commit() },
                                                                        cancel: { [weak self] in self?.cancel() }))
        let stack = NSStackView(views: [controls, canvas])
        stack.orientation = .vertical
        stack.spacing = 0
        window.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ArrowheadEditorController is built in code")
    }

    /// btn:[New]: the drawn head (nothing drawn: nothing happens).
    func commit() {
        guard let head = model.arrowhead else { return }
        finish(head)
        close()
    }

    func cancel() {
        finish(nil)
        close()
    }
}

/// The editor's controls above the canvas.
struct ArrowheadEditorControls: View {
    @Bindable var model: ArrowheadEditorModel
    let manager: ToolManager
    let commit: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    static let symbols: [ToolID: String] = [.pointer: "cursorarrow", .pen: "pencil.tip", PenTool.bezigonID: "point.3.connected.trianglepath.dotted",
                                            .rectangle: "rectangle", .ellipse: "circle"]

    static func choosing(_ id: ToolID, _ manager: ToolManager) -> () -> Void {
        { manager.select(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(ArrowheadEditorController.tools, id: \.self) { id in
                    Button(action: Self.choosing(id, manager)) { Image(systemName: Self.symbols[id] ?? "questionmark") }
                        .accessibilityIdentifier("arrowhead-editor.tool.\(id.rawValue)")
                }
                Spacer()
                Toggle("Filled", isOn: $model.filled).accessibilityIdentifier("arrowhead-editor.filled")
            }
            HStack {
                TextField("Name", text: $model.name).accessibilityIdentifier("arrowhead-editor.name")
                Text("Path trim")
                TextField("Trim", value: $model.pathTrim, format: .number).frame(width: 50).accessibilityIdentifier("arrowhead-editor.trim")
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("New", action: commit).keyboardShortcut(.defaultAction).accessibilityIdentifier("arrowhead-editor.new")
            }
        }
        .padding(8)
    }
}

/// Opening the editor from the stroke editor's arrowhead pop-ups: *New…* with an empty canvas,
/// kbd:[Option]-click with that head loaded; btn:[New] saves the head on this Mac and applies it to
/// the pop-up's end of the stroke (existing strokes keep what they had).
@MainActor
enum ArrowheadEditing {
    /// The app's tools (set at launch); nil opens nothing.
    static var tools: ToolRegistry?
    /// Shows the window; replaceable in tests.
    static var present: @MainActor (ArrowheadEditorController) -> Void = { $0.showWindow(nil) }
    /// The editor last opened.
    private(set) static var current: ArrowheadEditorController?

    @discardableResult
    static func open(loading head: Wiretuner_Doc_V1_Arrowhead?, finish: @escaping @MainActor (Wiretuner_Doc_V1_Arrowhead?) -> Void) -> ArrowheadEditorController? {
        guard let tools else { return nil }
        let model = ArrowheadEditorModel(loading: head)
        if let head { model.load(head) }
        let controller = ArrowheadEditorController(model: model, tools: tools, finish: finish)
        current = controller
        present(controller)
        return controller
    }

    /// The editor for `end` of `model`'s stroke.
    @discardableResult
    static func edit(_ head: Wiretuner_Doc_V1_Arrowhead?, end: Bool, model: StrokeEditorModel) -> ArrowheadEditorController? {
        open(loading: head) { made in
            guard let made else { return }
            model.presets.add(made)
            model.context.perform(model.setArrowhead(made, end: end))
        }
    }
}

extension AppDelegate {
    func installArrowheadEditor() {
        ArrowheadEditing.tools = tools
    }
}
