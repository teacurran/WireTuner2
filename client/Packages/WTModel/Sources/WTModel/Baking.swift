import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin

/// Turns what a live drawing draws into ordinary nodes: the release commands of blends (FX-024),
/// extrusions (FX-017) and brush strokes (ATTR-008) bake the rendered result into a group of
/// plain paths.  The drawing is expanded by WTInterchange's `Flattener` -- the same expansion
/// vector export uses, so a released object and a live one export alike -- to filled and stroked
/// paths with solid colours or linear and radial gradients.  Spot identity is not carried (steps
/// become process colours, as the blend page says releasing does); regions the flattener can only
/// rasterize (lenses, sampled paints, raster effects) are left out.
enum Baking {
    /// The plain paths `items` draw (pasteboard space), back to front, as path and group trees.
    static func trees(_ items: [DisplayItem]) -> [NodeTree] {
        let bounds = items.compactMap(\.bounds).reduce(Rect.null) { $0.union($1) }
        guard !bounds.isNull else { return [] }
        let page = ExportPage(bounds: bounds.expanded(by: 2), displayList: DisplayList(canvas: "bake", items: items))
        let flat = Flattener(target: [.transparency, .gradients, .strokes]).flatten(page, scene: ExportScene(pages: [page])).page
        return flat.nodes.flatMap(tree)
    }

    /// A flat node as trees: a path as a path node, a group's children as a group (a lone child
    /// as itself).
    static func tree(_ node: FlatNode) -> [NodeTree] {
        switch node {
        case .path(let path):
            return [NodeTree(props: props(path))]
        case .group(let group):
            let children = group.children.flatMap(tree)
            guard children.count > 1 else { return children }
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .group
            return [NodeTree(props: props, children: children)]
        default:
            return []
        }
    }

    /// A flat path as a path node: its contours in its own space, its transform, and one Basic or
    /// Gradient fill or one Basic stroke.
    static func props(_ path: FlatPath) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.contours = InlineShapes.contours(path.path)
        if !path.transform.isIdentity { props.path.common.transform = PathEditing.proto(path.transform) }
        switch path.style {
        case .fill(let rule):
            props.path.evenOdd = rule == .evenOdd
            var fill = Wiretuner_Doc_V1_Fill()
            switch path.paint {
            case .color(let color):
                fill.settings.kind = .basic
                fill.settings.basic.color = ColorResolver.inline(color)
                fill.settings.basic.overprint = path.overprint
            case .gradient(let gradient):
                fill.settings.kind = .gradient
                fill.settings.gradient = Self.gradient(gradient)
                fill.settings.gradient.overprint = path.overprint
            }
            props.path.appearance.fills = [fill]
        case .stroke(let style):
            var stroke = Wiretuner_Doc_V1_Stroke()
            stroke.settings.kind = .basic
            if case .color(let color) = path.paint {
                stroke.settings.basic.color = ColorResolver.inline(color)
            } else if case .gradient(let gradient) = path.paint, let first = gradient.gradient.sortedStops.first {
                stroke.settings.basic.color = ColorResolver.inline(first.color)
            }
            stroke.settings.basic.width = style.width
            stroke.settings.basic.miterLimit = style.miterLimit
            stroke.settings.basic.cap = Appearances.proto(style.cap)
            stroke.settings.basic.join = Appearances.proto(style.join)
            if !style.dash.isEmpty { stroke.settings.basic.dash.lengths = style.dash }
            stroke.settings.basic.overprint = path.overprint
            props.path.appearance.strokes = [stroke]
        }
        return props
    }

    /// A flattened gradient as a stored one: its stops as inline colours, its geometry as the
    /// axis (a radial frame's centre and the images of its unit axes).
    static func gradient(_ flat: FlatGradient) -> Wiretuner_Doc_V1_GradientFill {
        var gradient = Wiretuner_Doc_V1_GradientFill()
        let types: [Gradient.Kind: Wiretuner_Doc_V1_GradientType] = [.logarithmic: .logarithmic, .radial: .radial]
        gradient.type = types[flat.gradient.kind] ?? .linear
        let behaviors: [Gradient.Behavior: Wiretuner_Doc_V1_GradientBehavior] = [.repeat: .repeat, .reflect: .reflect]
        gradient.behavior = behaviors[flat.gradient.behavior] ?? .normal
        gradient.repeatCount = UInt32(clamping: flat.gradient.repeatCount)
        switch flat.shape {
        case .axial(let start, let end):
            gradient.axis.start = PathEditing.proto(start)
            gradient.axis.end = PathEditing.proto(end)
        case .radial(let frame):
            gradient.axis.start = PathEditing.proto(frame.apply(Point(x: 0, y: 0)))
            gradient.axis.end = PathEditing.proto(frame.apply(Point(x: 1, y: 0)))
            gradient.axis.end2 = PathEditing.proto(frame.apply(Point(x: 0, y: 1)))
        }
        gradient.stops = flat.gradient.sortedStops.map { stop in
            var value = Wiretuner_Doc_V1_GradientStop()
            value.offset = stop.offset
            value.color = ColorResolver.inline(stop.color)
            return value
        }
        return gradient
    }

    /// Creates `trees` as one new group under `parent` at `position`, the group's transform taking
    /// pasteboard coordinates into the parent's space; returns the group's id.
    @discardableResult
    static func createGroup(_ trees: [NodeTree], parent: OpID, position: [UInt8], state: EngineState, builder: inout ChangeBuilder) throws -> OpID {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.kind = .group
        let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        if !toParent.isIdentity { props.group.common.transform = PathEditing.proto(toParent) }
        return try NodeCopier.create(NodeTree(props: props, children: trees), parent: parent, position: position, schema: state.schema, builder: &builder)
    }
}

extension Appearances {
    static func proto(_ cap: LineCap) -> Wiretuner_Doc_V1_LineCap {
        switch cap {
        case .round: .round
        case .square: .square
        case .butt: .butt
        }
    }

    static func proto(_ join: LineJoin) -> Wiretuner_Doc_V1_LineJoin {
        switch join {
        case .round: .round
        case .bevel: .bevel
        case .miter: .miter
        }
    }
}
