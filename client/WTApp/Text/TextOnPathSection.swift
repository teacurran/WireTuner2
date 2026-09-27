import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Writes registers of a text node's `on_path` (`TextProps.on_path`, STRUCT; text-on-path.adoc,
/// "Data model"): the fields `fields` name below `TextOnPathProps` (`[2]` orientation, `[6]`
/// the left offset ...), from `values`.  Attaching and detaching are TYPE-041's commands; this
/// edits the settings of text already on a path.
struct SetTextOnPath: WTModel.Command {
    let node: OpID
    let values: Wiretuner_Doc_V1_TextOnPathProps
    let fields: [UInt32]
    let label: String

    /// `TextProps.on_path`.
    static let base = RegisterPath([TextFields.kind, 6])

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.isEmpty else { throw TextEditError.invalidValue("fields") }
        guard state.nodeKind(node) == .text else { throw TextEditError.notText(node) }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.onPath = values
        builder.append(Ops.set(node, fields.map { Self.base.child($0) }, values: props))
    }
}

/// What text on a path reads: its settings, its path (the node's live `path` child with the
/// smallest id) and where along the path the text starts (text-on-path.adoc, read-time
/// normalizations: `on_path` without a live path child is an ordinary block).
struct TextOnPath: Equatable {
    let node: OpID
    let props: Wiretuner_Doc_V1_TextOnPathProps
    let path: OpID
    /// The path's first contour in pasteboard space (the path's own transform chain).
    let contour: Contour
    /// The first paragraph's alignment, which says where the drag triangle sits.
    let alignment: Wiretuner_Doc_V1_Alignment

    init?(_ node: OpID, in state: EngineState) {
        guard state.nodeKind(node) == .text, state.isLive(node) else { return nil }
        let text = state.props(node).text
        guard text.hasOnPath,
              let path = state.liveChildren(node).filter({ state.nodeKind($0) == .path }).min(),
              let vector = VectorPath(state.props(path).path, node: path, state: state).contours.first(where: { $0.drawn.count >= 2 }) else { return nil }
        let transform = Objects.pasteboardTransform(of: path, in: state)
        let segments = vector.segments.map { $0.cubic.applying(transform) }
        self.node = node
        props = text.onPath
        self.path = path
        contour = Contour(segments: segments, closed: false)
        alignment = state.textNode(node)?.paragraphs.first?.props.alignment ?? .left
    }

    var length: Double { contour.length(tolerance: 1e-4) }

    /// The arc length along the path of the point nearest `point`.
    func arcLength(nearest point: Point) -> Double {
        guard let location = contour.nearestPoint(to: point) else { return 0 }
        let before = contour.segments.prefix(location.segmentIndex).reduce(0) { $0 + $1.length(tolerance: 1e-4) }
        return before + contour.segments[location.segmentIndex].length(from: 0, to: location.t, tolerance: 1e-4)
    }

    /// The point `distance` along the path, clamped to it.
    func point(atLength distance: Double) -> Point {
        var remaining = min(max(distance, 0), length)
        for segment in contour.segments {
            let length = segment.length(tolerance: 1e-4)
            if remaining <= length { return segment.point(atLength: remaining, tolerance: 1e-4) }
            remaining -= length
        }
        return contour.endPoint ?? .zero
    }

    /// Where the triangle sits along the path: at the left offset for left-aligned (and
    /// justified) text, at the right one for right-aligned, midway for centred.
    func handleLength(start: Double? = nil, end: Double? = nil) -> Double {
        let start = start ?? props.offsetStart, end = end ?? props.offsetEnd
        switch alignment {
        case .right: return length - end
        case .center: return (start + length - end) / 2
        default: return start
        }
    }

    /// The offsets after dragging the triangle to arc length `distance`: the left one follows for
    /// left-aligned text, the right one for right-aligned, both (keeping their sum) for centred.
    func offsets(draggedTo distance: Double) -> (start: Double, end: Double) {
        let distance = min(max(distance, 0), length)
        switch alignment {
        case .right: return (props.offsetStart, Measure.rounded(length - distance))
        case .center:
            let shift = distance - handleLength()
            return (Measure.rounded(props.offsetStart + shift), Measure.rounded(props.offsetEnd - shift))
        default: return (Measure.rounded(distance), props.offsetEnd)
        }
    }
}

extension ObjectPanelModel {
    /// The *Text on path* section: every selected object is text on a path.
    struct TextOnPathSection: Equatable {
        let items: [TextOnPath]

        var nodes: [OpID] { items.map(\.node) }
        var orientation: Wiretuner_Doc_V1_PathOrientation? { shared(items.map { Self.orientation($0.props.orientation) }) }
        var showPath: MixedState { MixedState(items.map(\.props.showPath)) }
        var top: Wiretuner_Doc_V1_PathAlignment? { shared(items.map { Self.alignment($0.props.top) }) }
        var bottom: Wiretuner_Doc_V1_PathAlignment? { shared(items.map { Self.alignment($0.props.bottom) }) }
        var offsetStart: Double? { shared(items.map(\.props.offsetStart)) }
        var offsetEnd: Double? { shared(items.map(\.props.offsetEnd)) }

        /// Unspecified reads as the first named value (text-on-path.adoc).
        static func orientation(_ value: Wiretuner_Doc_V1_PathOrientation) -> Wiretuner_Doc_V1_PathOrientation {
            value == .unspecified ? .rotate : value
        }

        static func alignment(_ value: Wiretuner_Doc_V1_PathAlignment) -> Wiretuner_Doc_V1_PathAlignment {
            value == .unspecified ? .none : value
        }
    }

    var textOnPath: TextOnPathSection? {
        let state = document.state
        let items = selection.ids.compactMap { TextOnPath($0.opID, in: state) }
        guard !items.isEmpty, items.count == selection.ids.count else { return nil }
        return TextOnPathSection(items: items)
    }

    private func writeOnPath(_ label: String, _ fields: [UInt32], _ build: (inout Wiretuner_Doc_V1_TextOnPathProps) -> Void) -> (any WTModel.Command)? {
        guard let section = textOnPath else { return nil }
        var values = Wiretuner_Doc_V1_TextOnPathProps()
        build(&values)
        return CommandBatch(label, section.nodes.map { SetTextOnPath(node: $0, values: values, fields: fields, label: label) })
    }

    func setPathOrientation(_ orientation: Wiretuner_Doc_V1_PathOrientation) -> (any WTModel.Command)? {
        writeOnPath("Orientation", [2]) { $0.orientation = orientation }
    }

    func setShowPath(_ show: Bool) -> (any WTModel.Command)? {
        writeOnPath("Show Path", [3]) { $0.showPath = show }
    }

    /// *Top* (`top: true`) or *Bottom* alignment.
    func setPathAlignment(_ alignment: Wiretuner_Doc_V1_PathAlignment, top: Bool) -> (any WTModel.Command)? {
        writeOnPath(top ? "Top Alignment" : "Bottom Alignment", [top ? 4 : 5]) {
            if top { $0.top = alignment } else { $0.bottom = alignment }
        }
    }

    /// *Left* (`start: true`) or *Right*: points from the path's start or end.
    func setPathOffset(_ value: Double, start: Bool) -> (any WTModel.Command)? {
        guard value.isFinite else { return nil }
        return writeOnPath(start ? "Left Offset" : "Right Offset", [start ? 6 : 7]) {
            if start { $0.offsetStart = value } else { $0.offsetEnd = value }
        }
    }
}

/// The Text on path section: Orientation, Show path, Top and Bottom alignment, Left and Right.
struct TextOnPathSectionView: View {
    let section: ObjectPanelModel.TextOnPathSection
    let model: ObjectPanelModel

    static let mixed = "Mixed"
    static let orientations: [(value: Wiretuner_Doc_V1_PathOrientation, title: String)] = [
        (.rotate, "Rotate around path"), (.vertical, "Vertical"), (.skewHorizontal, "Skew horizontal"), (.skewVertical, "Skew vertical"),
    ]
    static let alignments: [(value: Wiretuner_Doc_V1_PathAlignment, title: String)] = [
        (.none, "None"), (.baseline, "Baseline"), (.ascent, "Ascent"), (.descent, "Descent"),
    ]

    static func title<Value: Equatable>(_ value: Value?, in table: [(value: Value, title: String)]) -> String {
        value.flatMap { value in table.first { $0.value == value }?.title } ?? mixed
    }

    static func orientation(_ section: ObjectPanelModel.TextOnPathSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { title(section.orientation, in: orientations) },
                set: { chosen in if let value = orientations.first(where: { $0.title == chosen })?.value { model.perform(model.setPathOrientation(value)) } })
    }

    static func alignment(_ section: ObjectPanelModel.TextOnPathSection, _ model: ObjectPanelModel, top: Bool) -> Binding<String> {
        Binding(get: { title(top ? section.top : section.bottom, in: alignments) },
                set: { chosen in if let value = alignments.first(where: { $0.title == chosen })?.value { model.perform(model.setPathAlignment(value, top: top)) } })
    }

    static func showPath(_ section: ObjectPanelModel.TextOnPathSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.showPath.isOn }, set: { model.perform(model.setShowPath($0)) })
    }

    static func offset(_ model: ObjectPanelModel, start: Bool) -> (Double) -> Void {
        { model.perform(model.setPathOffset($0, start: start)) }
    }

    var body: some View {
        Form {
            Picker("Orientation", selection: Self.orientation(section, model)) {
                if section.orientation == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.orientations, id: \.title) { Text($0.title).tag($0.title) }
            }
            .accessibilityIdentifier("object.textOnPath.orientation")
            Toggle("Show path", isOn: Self.showPath(section, model))
                .accessibilityIdentifier("object.textOnPath.showPath")
                .accessibilityValue(PathSectionView.accessibilityValue(section.showPath))
            Picker("Top", selection: Self.alignment(section, model, top: true)) {
                if section.top == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.alignments, id: \.title) { Text($0.title).tag($0.title) }
            }
            .accessibilityIdentifier("object.textOnPath.top")
            Picker("Bottom", selection: Self.alignment(section, model, top: false)) {
                if section.bottom == nil { Text(Self.mixed).tag(Self.mixed) }
                ForEach(Self.alignments, id: \.title) { Text($0.title).tag($0.title) }
            }
            .accessibilityIdentifier("object.textOnPath.bottom")
            MeasureField(title: "Left", value: section.offsetStart, unit: model.unit, identifier: "object.textOnPath.left", commit: Self.offset(model, start: true))
            MeasureField(title: "Right", value: section.offsetEnd, unit: model.unit, identifier: "object.textOnPath.right", commit: Self.offset(model, start: false))
        }
        .padding(.horizontal)
    }
}

/// The triangle that slides text along its path (text-on-path.adoc, "Orientation and alignment
/// on the path"; TYPE-043): drawn on each selected text on a path at the left offset, the right
/// one or midway, by the text's alignment.  A drag projects the pointer onto the path; the
/// offsets are written once at mouse-up; with kbd:[Option] the text previews on the canvas as you
/// drag (D-076: nothing is written until mouse-up).  Either way the drag is one change.
@MainActor
final class TextPathHandle: CanvasHandleLayer {
    /// How near the triangle (view points) a press takes it.
    static let radius = 7.0
    static let size = 10.0

    private(set) var dragging: TextOnPath?
    /// The arc length the triangle is dragged to (the overlay's preview).
    private(set) var draggedLength: Double?
    private var live = false
    /// The Option drag's canvas preview and its one change.
    private var edit: GestureEdit?

    init() {}

    func items(_ context: ToolContext) -> [TextOnPath] {
        let state = context.document.state
        return context.selection.selection.ids.compactMap { TextOnPath($0.opID, in: state) }
    }

    /// The triangle's tip in view points.
    static func position(_ item: TextOnPath, length: Double? = nil, viewport: Viewport) -> Point {
        viewport.toView(item.point(atLength: length ?? item.handleLength()))
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let hit = items(context).first(where: { Self.position($0, viewport: context.viewport).distance(to: e.viewPoint) <= Self.radius }) else { return false }
        dragging = hit
        draggedLength = hit.handleLength()
        live = e.modifiers.contains(.option)
        edit = live ? GestureEdit(document: context.document) : nil
        return true
    }

    /// The change a drag of `item`'s triangle to `point` (pasteboard) writes: both offsets.
    static func command(_ item: TextOnPath, to point: Point) -> any WTModel.Command {
        let offsets = item.offsets(draggedTo: item.arcLength(nearest: point))
        var values = Wiretuner_Doc_V1_TextOnPathProps()
        values.offsetStart = offsets.start
        values.offsetEnd = offsets.end
        return SetTextOnPath(node: item.node, values: values, fields: [6, 7], label: "Move Text on Path")
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        draggedLength = dragging.arcLength(nearest: e.pasteboardPoint)
        if live {
            edit?.update(Self.command(dragging, to: e.pasteboardPoint))
        }
        context.host.setNeedsOverlayDisplay()
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        if live {
            drag(e, context: context)
            edit?.commit()
        } else {
            context.commandSink.perform(Self.command(dragging, to: e.pasteboardPoint))
        }
        finish(context)
    }

    func cancel(context: ToolContext) {
        edit?.cancel()
        finish(context)
    }

    private func finish(_ context: ToolContext) {
        dragging = nil
        draggedLength = nil
        live = false
        edit = nil
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        for item in items(context) {
            let length = item.node == dragging?.node ? draggedLength : nil
            let tip = Self.position(item, length: length, viewport: viewport)
            ctx.move(to: tip.cgPoint)
            ctx.addLine(to: CGPoint(x: tip.x - Self.size / 2, y: tip.y + Self.size))
            ctx.addLine(to: CGPoint(x: tip.x + Self.size / 2, y: tip.y + Self.size))
            ctx.closePath()
            ctx.fillPath()
        }
    }
}
