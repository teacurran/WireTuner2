import func Foundation.atan2
import func Foundation.cos
import func Foundation.sin
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// The Transform panel's *Fills* option turned off (transforming.adoc, "Data model"; OBJ-031): the
// object moves, its gradient and tiled fills stay put on the page.  Fills live in node space, so the
// command writes, in the same change as the `transform`, a compensating map onto each fill's own
// registers: the gradient's ATOMIC `axis` and the tiled fill's `angle`, `scale_x`, `scale_y` and
// `offset`.  For a node whose local → pasteboard map `P` becomes `P · M` (M the pasteboard-space
// transformation), a local point `x` must land where `P` put it, so the fill is mapped by
// `C = P · M⁻¹ · P⁻¹` (applied left to right, as `concatenating` reads).  Every node of a moved
// subtree gets its own `C`: a group's members keep their fills too.

/// The fill compensation of *Fills* off.
enum TransformFills {
    /// The map a fill of `node` needs when the subtree it is in moves by the pasteboard-space
    /// `matrix`.
    static func compensation(for node: OpID, moving matrix: AffineTransform, in state: EngineState) -> AffineTransform {
        let p = Objects.pasteboardTransform(of: node, in: state)
        return p.concatenating(matrix.inverse).concatenating(p.inverse)
    }

    /// The register writes that keep every gradient and tiled fill of `root` and its live
    /// descendants in place while `root` moves by `matrix` (pasteboard space).
    static func ops(keeping root: OpID, moving matrix: AffineTransform, in state: EngineState) -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        func visit(_ node: OpID) {
            ops += self.ops(node, by: compensation(for: node, moving: matrix, in: state), in: state)
            for child in state.liveChildren(node) { visit(child) }
        }
        visit(root)
        return ops
    }

    /// The writes of one node's own fills mapped by `c` (node space).
    static func ops(_ node: OpID, by c: AffineTransform, in state: EngineState) -> [Wiretuner_Doc_V1_Op] {
        guard let kind = state.nodeKind(node), let fills = AppearanceEditing.sequence(kind, .fills),
              let appearance = NodeValues.appearance(state.props(node)) else { return [] }
        let live = Set(AppearanceEditing.rows(node, .fills, in: state))
        let bounds = localBounds(node, in: state)
        var ops: [Wiretuner_Doc_V1_Op] = []
        for fill in appearance.fills {
            guard let id = OpID(element: fill.id), live.contains(id), let (value, fields) = compensated(fill, by: c, bounds: bounds) else { continue }
            let settings = fills.element(id).child(AppearanceList.fills.settingsField)
            ops.append(Ops.set(node, fields.map { settings.appending($0) }, values: AppearanceEditing.values(kind) { $0.fills = [value] }))
        }
        return ops
    }

    /// `tree` (a copy about to be created) with every node's gradient and tiled fills mapped as
    /// if its source had moved by `matrix`: each node read through its source's transform chain.
    static func keeping(_ tree: NodeTree, moving matrix: AffineTransform, in state: EngineState) -> NodeTree {
        var tree = tree
        if let source = tree.source, let kind = state.nodeKind(source), var appearance = NodeValues.appearance(tree.props) {
            let c = compensation(for: source, moving: matrix, in: state)
            let bounds = localBounds(source, in: state)
            for index in appearance.fills.indices {
                if let (value, _) = compensated(appearance.fills[index], by: c, bounds: bounds) { appearance.fills[index] = value }
            }
            tree.props = NodeValues.replacing(appearance, of: kind, in: tree.props)
        }
        tree.children = tree.children.map { keeping($0, moving: matrix, in: state) }
        return tree
    }

    /// The node's local geometry bounds (a path's or shape's control bounds, as the renderer
    /// reads Auto size gradient geometry from), or nil when it has none.
    static func localBounds(_ node: OpID, in state: EngineState) -> Rect? {
        guard let path = Objects.localPath(node, in: state), path.isRenderable else { return nil }
        var result = Rect.null
        for contour in path.contours where contour.isRenderable {
            for segment in contour.segments {
                for point in [segment.from.anchor, segment.from.outControl, segment.to.inControl, segment.to.anchor] { result.formUnion(point) }
            }
        }
        return result.isNull ? nil : result
    }

    // MARK: Values

    /// `fill` mapped by `c` and the settings fields that changed; nil for a kind that does not
    /// move with the object (Basic, Lens, Custom, Pattern, Textured) or nothing to change.
    static func compensated(_ fill: Wiretuner_Doc_V1_Fill, by c: AffineTransform, bounds: Rect?) -> (Wiretuner_Doc_V1_Fill, [[UInt32]])? {
        guard !c.isIdentity else { return nil }
        var fill = fill
        switch fill.settings.kind {
        case .gradient:
            guard let (gradient, fields) = gradient(fill.settings.gradient, by: c, bounds: bounds) else { return nil }
            fill.settings.gradient = gradient
            return (fill, fields)
        case .tiled:
            fill.settings.tiled = tiled(fill.settings.tiled, by: c)
            return (fill, [AttributeFields.Tiled.angle, AttributeFields.Tiled.scaleX, AttributeFields.Tiled.scaleY, AttributeFields.Tiled.offset])
        default:
            return nil
        }
    }

    /// A gradient's handles mapped by `c`.  Auto size geometry (no axis, or *Auto size*) is first
    /// written out as the axis it reads as, on `bounds`, and *Auto size* becomes *Normal*, so the
    /// ramp stays where it was drawn.  Linear and Logarithmic keep their exact colours under any
    /// map (the start maps, and the end is placed so the ramp's lines of equal colour stay those
    /// the map makes); Radial and Rectangle map all three handles, exactly; Cone and Contour map
    /// their two, which is exact for moves, rotations and uniform scales.  Nil for a Contour
    /// gradient with Auto size geometry (it follows the outline, wherever the outline is) or Auto
    /// size geometry without bounds.
    static func gradient(_ stored: Wiretuner_Doc_V1_GradientFill, by c: AffineTransform, bounds: Rect?) -> (Wiretuner_Doc_V1_GradientFill, [[UInt32]])? {
        let normalized = GradientReading.normalized(stored)
        var fields = [GradientFields.axis]
        var gradient = stored
        let axis: Gradient.Axis
        if let stored = normalized.axis, normalized.behavior != .autoSize {
            axis = stored
        } else {
            guard normalized.type != .contour, let bounds else { return nil }
            axis = autoAxis(normalized.type, bounds: bounds)
            if normalized.behavior == .autoSize {
                gradient.behavior = .normal
                fields.append(GradientFields.behavior)
            }
        }
        let start = c.apply(axis.start)
        var end = c.apply(axis.end)
        var end2: Point?
        switch normalized.type {
        case .linear, .logarithmic:
            let u = axis.end - axis.start
            let unit = Vector(dx: u.dx / u.lengthSquared, dy: u.dy / u.lengthSquared)
            let inverse = c.inverse
            // The ramp's gradient vector after the map: the normal of its lines of equal colour.
            let w = Vector(dx: inverse.a * unit.dx + inverse.b * unit.dy, dy: inverse.c * unit.dx + inverse.d * unit.dy)
            end = start + Vector(dx: w.dx / w.lengthSquared, dy: w.dy / w.lengthSquared)
        case .radial, .rectangle:
            // Radial and Rectangle always read with a second end (`GradientReading.axis`, `autoAxis`).
            end2 = axis.end2.map(c.apply)
        default:
            break
        }
        gradient.axis = Wiretuner_Doc_V1_GradientAxis()
        gradient.axis.start = PathEditing.proto(start)
        gradient.axis.end = PathEditing.proto(end)
        if let end2 { gradient.axis.end2 = PathEditing.proto(end2) }
        return (gradient, fields)
    }

    /// The handles Auto size geometry reads as on `bounds` (the renderer's
    /// `Gradient.resolvedAxis(bounds:)`).
    static func autoAxis(_ type: Wiretuner_Doc_V1_GradientType, bounds: Rect) -> Gradient.Axis {
        let center = Point(x: bounds.midX, y: bounds.midY)
        switch type {
        case .cone:
            return Gradient.Axis(start: center, end: center + Vector(dx: 1, dy: 0), end2: nil)
        case .radial, .rectangle, .contour:
            return Gradient.Axis(start: center, end: center + Vector(dx: max(bounds.width / 2, 0.5), dy: 0),
                                 end2: center + Vector(dx: 0, dy: max(bounds.height / 2, 0.5)))
        default:
            let start = Point(x: bounds.minX, y: bounds.midY)
            let end = Point(x: bounds.maxX, y: bounds.midY)
            return Gradient.Axis(start: start, end: end == start ? start + Vector(dx: 1, dy: 0) : end, end2: nil)
        }
    }

    /// A tiled fill's placement -- scale, then rotation, then offset, in node space -- mapped by
    /// `c` and read back into the three registers: the scale along the tile's two axes, the angle
    /// of its first axis and the offset.  What those cannot hold is dropped: a skew keeps the tile
    /// square to its first axis, and a reflection leaves the tile unmirrored.
    static func tiled(_ stored: Wiretuner_Doc_V1_TiledFill, by c: AffineTransform) -> Wiretuner_Doc_V1_TiledFill {
        func read(_ value: Double) -> Double { value.isFinite && value > 0 ? value / 100 : 1 }
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        let placement = AffineTransform.scale(x: read(stored.scaleX), y: read(stored.scaleY))
            .concatenating(.rotation(radians: finite(stored.angle) * .pi / 180))
            .concatenating(.translation(x: finite(stored.offset.x), y: finite(stored.offset.y)))
            .concatenating(c)
        let angle = atan2(placement.b, placement.a)
        let scaleX = (placement.a * placement.a + placement.b * placement.b).squareRoot()
        let scaleY = abs(-placement.c * sin(angle) + placement.d * cos(angle))
        var tiled = stored
        tiled.angle = angle * 180 / .pi
        tiled.scaleX = scaleX * 100
        tiled.scaleY = scaleY * 100
        tiled.offset = PathEditing.proto(Point(x: placement.tx, y: placement.ty))
        return tiled
    }
}
