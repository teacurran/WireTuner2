import WTCRDT
import WTGeometry
import WTProto
import WTRender

extension AffineTransform {
    /// The inverse, or the identity for a matrix that has none (a parent chain never writes one:
    /// transforming.adoc, "commands never write one").
    var inverse: AffineTransform { inverted() ?? .identity }
}

/// Why an object command could not build its change.
public enum ObjectEditError: Error, Equatable, Sendable {
    /// The node is not a live object (a path, shape, polygon or group).
    case notAnObject(OpID)
    /// A transform that cannot be inverted (a zero scale) was asked for.
    case degenerateTransform
    case invalidValue(String)
}

/// Shared reading of objects for the object commands: kinds, placement, transform chains and the
/// lock rules (arranging.adoc, "Locking": a locked object -- or a member of a locked group, or an
/// object on a locked layer -- is not moved, transformed, deleted, restacked or reshaped).
public enum Objects {
    /// The kinds the object commands act on.  A connector is selected, styled, deleted, copied
    /// and grouped like any object, but never moved or transformed on its own: it follows the
    /// objects it joins (connectors.adoc), so `MoveObjects` and `TransformObjects` skip it.
    public static let kinds: Set<NodeKind> = [.path, .rect, .ellipse, .polygon, .group, .chart, .instance, .barcode, .connector, .placedFile, .text]

    /// The kind of the live object `node`, or throws.
    static func kind(_ node: OpID, in state: EngineState) throws -> NodeKind {
        guard state.isLive(node), let kind = state.nodeKind(node), kinds.contains(kind) else { throw ObjectEditError.notAnObject(node) }
        return kind
    }

    /// Whether `node` is a live object.
    public static func isObject(_ node: OpID, in state: EngineState) -> Bool {
        (try? kind(node, in: state)) != nil
    }

    /// The node's own transform (local → parent).
    public static func transform(of node: OpID, in state: EngineState) -> AffineTransform {
        NodeValues.common(state.props(node)).map { PathEditing.transform($0.transform) } ?? .identity
    }

    /// Parent space → pasteboard for the children of `node` (a group or layer): the transforms of
    /// `node` and its ancestors.
    public static func pasteboardTransform(ofSpace node: OpID, in state: EngineState) -> AffineTransform {
        var result = AffineTransform.identity
        var current: OpID? = node
        while let id = current, id != WellKnown.layers, id != WellKnown.document {
            result = result.concatenating(transform(of: id, in: state))
            current = state.store.placement(id)?.parent
        }
        return result
    }

    /// The object's local space → pasteboard.
    public static func pasteboardTransform(of node: OpID, in state: EngineState) -> AffineTransform {
        pasteboardTransform(ofSpace: node, in: state)
    }

    /// The object's parent space → pasteboard (the identity for a node without a parent).
    public static func parentTransform(of node: OpID, in state: EngineState) -> AffineTransform {
        pasteboardTransform(ofSpace: parent(of: node, in: state) ?? WellKnown.layers, in: state)
    }

    /// The parent of `node`.
    public static func parent(of node: OpID, in state: EngineState) -> OpID? {
        state.store.placement(node)?.parent
    }

    /// Whether `node` itself holds `locked`.
    public static func isLocked(_ node: OpID, in state: EngineState) -> Bool {
        NodeValues.common(state.props(node))?.locked ?? false
    }

    /// Whether an enclosing group of `node` is locked (Unlock on such a member is disabled).
    public static func isInLockedGroup(_ node: OpID, in state: EngineState) -> Bool {
        var current = parent(of: node, in: state)
        while let id = current, state.nodeKind(id) == .group {
            if isLocked(id, in: state) { return true }
            current = parent(of: id, in: state)
        }
        return false
    }

    /// Whether `node` cannot be edited from the canvas: it, an enclosing group or its layer is
    /// locked.
    public static func isEffectivelyLocked(_ node: OpID, in state: EngineState, layers: LayerOrder? = nil) -> Bool {
        if isLocked(node, in: state) || isInLockedGroup(node, in: state) { return true }
        let order = layers ?? LayerOrder(state)
        return order.layer(of: node, in: state).flatMap { order.layer($0)?.locked } ?? false
    }

    /// The live objects of `nodes` that may be edited, in the given order, duplicates removed.
    static func editable(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        let order = LayerOrder(state)
        var seen: Set<OpID> = []
        return nodes.filter { node in
            isObject(node, in: state) && !isEffectivelyLocked(node, in: state, layers: order) && seen.insert(node).inserted
        }
    }

    /// "Move" for one object, "Move 3 objects" for more.
    public static func label(_ verb: String, count: Int) -> String {
        count == 1 ? verb : "\(verb) \(count) objects"
    }

    /// The object's geometry bounds in pasteboard space (its path's control bounds through its
    /// transform chain; a group's members'); nil when it has no geometry.
    public static func bounds(of node: OpID, in state: EngineState) -> Rect? {
        bounds(of: node, in: state, through: parentTransform(of: node, in: state))
    }

    /// `bounds(of:in:)` leaving connectors out (a connector's own bounds read its objects'
    /// bounds, and a group it is attached to may hold it).
    static func boundsWithoutConnectors(of node: OpID, in state: EngineState) -> Rect? {
        bounds(of: node, in: state, through: parentTransform(of: node, in: state), connectors: false)
    }

    private static func bounds(of node: OpID, in state: EngineState, through parentTransform: AffineTransform, connectors: Bool = true) -> Rect? {
        guard let kind = state.nodeKind(node), connectors || kind != .connector else { return nil }
        let transform = transform(of: node, in: state).concatenating(parentTransform)
        switch kind {
        case .group:
            var result = Rect.null
            for child in state.liveChildren(node) {
                if let rect = bounds(of: child, in: state, through: transform, connectors: connectors) { result = result.union(rect) }
            }
            return result.isNull ? nil : result
        case .instance:
            guard let symbol = Symbols.symbol(of: node, in: state) else { return nil }
            let origin = state.props(symbol).symbol.origin
            let placement = AffineTransform.translation(x: -origin.x, y: -origin.y).concatenating(transform)
            var result = Rect.null
            for child in state.liveChildren(symbol) {
                if let rect = bounds(of: child, in: state, through: placement, connectors: connectors) { result = result.union(rect) }
            }
            return result.isNull ? nil : result
        case .chart:
            let size = state.props(node).chart.size
            guard size.width > 0, size.height > 0 else { return nil }
            return Rect(x: 0, y: 0, width: size.width, height: size.height).applying(transform)
        case .barcode:
            guard case .success(let geometry) = BarcodeRendering.geometry(Barcodes.spec(state.props(node).barcode)) else { return nil }
            return geometry.bounds.applying(transform)
        case .connector:
            return Connectors.bounds(of: node, in: state)
        case .placedFile:
            return PlacedFiles.placedFile(state.props(node).placedFile, transform: transform).effectiveBounds.applying(transform)
        default:
            break
        }
        guard let path = localPath(node, in: state), path.isRenderable else { return nil }
        var result = Rect.null
        for contour in path.contours where contour.isRenderable {
            for segment in contour.segments {
                for point in [segment.from.anchor, segment.from.outControl, segment.to.inControl, segment.to.anchor] {
                    result.formUnion(transform.apply(point))
                }
            }
        }
        return result.isNull ? nil : result
    }

    /// The local geometry of a path, rectangle, ellipse or polygon.
    public static func localPath(_ node: OpID, in state: EngineState) -> VectorPath? {
        switch state.props(node).kind {
        case .path(let path)?: VectorPath(path, node: node, state: state)
        case .rect(let rect)?: ShapeGeometry.path(rect)
        case .ellipse(let ellipse)?: ShapeGeometry.path(ellipse)
        case .polygon(let polygon)?: ShapeGeometry.path(polygon)
        default: nil
        }
    }

    /// A `SetFields` of `transform` on `node`.
    static func setTransform(_ node: OpID, kind: NodeKind, _ transform: AffineTransform) -> Wiretuner_Doc_V1_Op {
        let value = transform.isIdentity ? Wiretuner_Doc_V1_Transform() : PathEditing.proto(transform)
        return Ops.set(node, [CommonFields.transform(kind)], values: NodeValues.with(kind: kind, transform: value))
    }
}

/// Moves objects by a pasteboard-space distance (OBJ-008, moving.adoc "Client"): composes a
/// translation onto each node's `transform` -- converted into the node's parent space, so a
/// group member moves the same distance on screen -- in one change labelled "Move" or
/// "Move N objects".  Locked objects are left where they are.
public struct MoveObjects: Command {
    public var nodes: [OpID]
    public var delta: Vector

    public init(_ nodes: [OpID], by delta: Vector) {
        self.nodes = nodes
        self.delta = delta
    }

    public var label: String { Objects.label("Move", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard delta.isFinite else { throw ObjectEditError.invalidValue("delta") }
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) != .connector {
            let kind = try Objects.kind(node, in: state)
            let toParent = Objects.parentTransform(of: node, in: state).inverse
            let moved = Objects.transform(of: node, in: state).concatenating(.translation(toParent.apply(delta)))
            builder.append(Objects.setTransform(node, kind: kind, moved))
        }
    }
}

/// What a transformation is called in labels and remembered as (transforming.adoc).
public enum TransformKind: String, Sendable, Hashable, CaseIterable {
    case move, rotate, scale, skew, reflect

    public var title: String {
        switch self {
        case .move: "Move"
        case .rotate: "Rotate"
        case .scale: "Scale"
        case .skew: "Skew"
        case .reflect: "Reflect"
        }
    }
}

/// The Transform panel's options (transforming.adoc, "Client").
public struct TransformOptions: Hashable, Sendable {
    /// Scale stroke widths by `sqrt(|det|)` (leaf objects only).
    public var strokes: Bool
    /// Transform the fills with the object (off would compensate fill axes, which ATTR's gradient
    /// and tile registers do not have yet: ignored until then).
    public var fills: Bool
    /// Transform a group's members as well as the group (always true: a group's transform
    /// carries its members).
    public var contents: Bool

    public init(strokes: Bool = false, fills: Bool = true, contents: Bool = true) {
        self.strokes = strokes
        self.fills = fills
        self.contents = contents
    }
}

/// Transforms objects (OBJ-031, transforming.adoc "Client"): composes `matrix` -- a pasteboard-space
/// transformation, taken about `center` when given -- onto each node's `transform`, converted into
/// the node's parent space (`T(c) · M · T(-c)` conjugated by the parent's chain), one register
/// write per node.  *Strokes* multiplies every basic stroke width by `sqrt(|det M|)` in the same
/// change.  With `copies` > 0 the sources stay and copies are created above them with
/// `transform = T · Mᵏ` for k = 1…copies ("Rotate with 3 copies").  A matrix that cannot be
/// inverted is refused.  Locked objects are skipped.
public struct TransformObjects: Command {
    public var nodes: [OpID]
    public var matrix: AffineTransform
    public var center: Point?
    public var kind: TransformKind
    public var options: TransformOptions
    public var copies: Int

    public init(_ nodes: [OpID], matrix: AffineTransform, about center: Point? = nil, kind: TransformKind,
                options: TransformOptions = TransformOptions(), copies: Int = 0) {
        self.nodes = nodes
        self.matrix = matrix
        self.center = center
        self.kind = kind
        self.options = options
        self.copies = copies
    }

    public var label: String {
        if copies > 0 { return "\(kind.title) with \(copies) \(copies == 1 ? "copy" : "copies")" }
        return Objects.label(kind.title, count: nodes.count)
    }

    /// The pasteboard-space matrix with the centre applied.
    public var effectiveMatrix: AffineTransform {
        guard let center else { return matrix }
        return AffineTransform.translation(Vector(dx: -center.x, dy: -center.y)).concatenating(matrix)
            .concatenating(.translation(Vector(dx: center.x, dy: center.y)))
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let m = effectiveMatrix
        guard m.isInvertible, m.a.isFinite, m.b.isFinite, m.c.isFinite, m.d.isFinite, m.tx.isFinite, m.ty.isFinite else {
            throw ObjectEditError.degenerateTransform
        }
        let factor = abs(m.determinant).squareRoot()
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) != .connector {
            let kind = try Objects.kind(node, in: state)
            let toPasteboard = Objects.parentTransform(of: node, in: state)
            let inParent = toPasteboard.concatenating(m).concatenating(toPasteboard.inverse)
            let current = Objects.transform(of: node, in: state)
            if copies > 0, let parent = Objects.parent(of: node, in: state) {
                var tree = NodeTree(node, state: state)
                var step = current
                var above = state.store.placement(node)?.position
                let next = Arranging.siblingAfter(node, in: state).flatMap { state.store.placement($0)?.position }
                for _ in 0..<copies {
                    step = step.concatenating(inParent)
                    tree.transform = step
                    if options.strokes, kind != .group { tree.props = Self.scaledStrokes(tree.props, by: factor) }
                    let key = try PathEditing.keys(between: above, and: next, count: 1)[0]
                    try NodeCopier.create(tree, parent: parent, position: key, schema: state.schema, builder: &builder)
                    above = key
                }
                continue
            }
            builder.append(Objects.setTransform(node, kind: kind, current.concatenating(inParent)))
            if options.strokes, kind != .group, factor != 1 {
                for op in AppearanceEditing.scaleStrokeWidths(node, kind: kind, by: factor, state: state) { builder.append(op) }
            }
        }
    }

    /// `props` with every basic stroke width multiplied by `factor`.
    static func scaledStrokes(_ props: Wiretuner_Doc_V1_NodeProps, by factor: Double) -> Wiretuner_Doc_V1_NodeProps {
        var props = props
        func scale(_ appearance: inout Wiretuner_Doc_V1_AppearanceProps) {
            for index in appearance.strokes.indices where appearance.strokes[index].settings.kind == .basic {
                appearance.strokes[index].settings.basic.width *= factor
            }
        }
        switch props.kind {
        case .path?: scale(&props.path.appearance)
        case .rect?: scale(&props.rect.appearance)
        case .ellipse?: scale(&props.ellipse.appearance)
        case .polygon?: scale(&props.polygon.appearance)
        default: break
        }
        return props
    }
}

/// Transforms selected points of one path (transforming.adoc: "A transformation of selected points
/// is not a transform: it writes point registers"): each anchor maps through `matrix` (pasteboard
/// space, about `center`), and its handles through the matrix's linear part, in the path's local
/// space.
public struct TransformPoints: Command {
    public var node: OpID
    public var points: [(contour: OpID, point: OpID)]
    public var matrix: AffineTransform
    public var center: Point?
    public var kind: TransformKind

    public init(node: OpID, points: [(contour: OpID, point: OpID)], matrix: AffineTransform, about center: Point? = nil, kind: TransformKind) {
        self.node = node
        self.points = points
        self.matrix = matrix
        self.center = center
        self.kind = kind
    }

    public var label: String { "\(kind.title) \(points.count == 1 ? "Point" : "Points")" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, path) = try PathEditing.path(node, in: state)
        guard !Objects.isEffectivelyLocked(node, in: state) else { return }
        let m = TransformObjects([], matrix: matrix, about: center, kind: kind).effectiveMatrix
        guard m.isInvertible else { throw ObjectEditError.degenerateTransform }
        let toPasteboard = Objects.pasteboardTransform(of: node, in: state)
        let local = toPasteboard.concatenating(m).concatenating(toPasteboard.inverse)
        for (contourID, pointID) in points {
            let contour = try PathEditing.contour(contourID, of: path)
            let point = try PathEditing.point(pointID, of: contour)
            var value = Wiretuner_Doc_V1_PathPoint()
            value.anchor = PathEditing.proto(local.apply(point.anchor))
            var paths = [PathFields.anchor(contourID, pointID)]
            if !point.automatic {
                paths += [PathFields.inHandle(contourID, pointID), PathFields.outHandle(contourID, pointID)]
                if point.inHandle != .zero { value.inHandle = PathEditing.proto(local.apply(point.inHandle)) }
                if point.outHandle != .zero { value.outHandle = PathEditing.proto(local.apply(point.outHandle)) }
            }
            builder.append(Ops.set(node, paths, values: PathEditing.pointValues(value)))
        }
    }
}

/// Sets objects' `locked` (OBJ-020): *Lock* and *Unlock*.  Unlock skips members of a locked group
/// (they stay locked through the group).
public struct SetLocked: Command {
    public var nodes: [OpID]
    public var locked: Bool

    public init(_ nodes: [OpID], locked: Bool) {
        self.nodes = nodes
        self.locked = locked
    }

    public var label: String { Objects.label(locked ? "Lock" : "Unlock", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes where Objects.isObject(node, in: state) {
            let kind = try Objects.kind(node, in: state)
            if !locked, Objects.isInLockedGroup(node, in: state) { continue }
            builder.append(Ops.set(node, [CommonFields.locked(kind)], values: NodeValues.common(kind: kind) { $0.locked = locked }))
        }
    }
}

/// Sets objects' name or note (names-notes.adoc; the Object panel's *Name* and *Note*): one register
/// per object.  Names are cut to 256 characters and notes to 8,192 (the schema limits).
public struct SetNameOrNote: Command {
    public enum Field: Sendable, Hashable {
        case name, note
    }

    public var nodes: [OpID]
    public var field: Field
    public var value: String

    public init(_ nodes: [OpID], _ field: Field, _ value: String) {
        self.nodes = nodes
        self.field = field
        self.value = value
    }

    public var label: String {
        let what = field == .name ? "name" : "note"
        return nodes.count == 1 ? "Change \(what)" : "Change \(what) of \(nodes.count) objects"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let limited = String(value.prefix(field == .name ? 256 : 8_192))
        for node in nodes where Objects.isObject(node, in: state) {
            let kind = try Objects.kind(node, in: state)
            let path = field == .name ? CommonFields.name(kind) : CommonFields.note(kind)
            builder.append(Ops.set(node, [path], values: NodeValues.common(kind: kind) {
                if field == .name { $0.name = limited } else { $0.note = limited }
            }))
        }
    }
}

/// Commands run as one change (a fan-out: one edit written to N nodes, object-panel.adoc "Mixed
/// selections").
public struct CompositeCommand: Command {
    public var label: String
    public var commands: [any Command]

    public init(_ label: String, _ commands: [any Command]) {
        self.label = label
        self.commands = commands
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        // Each command reads the state before the change; the ops of one never depend on those of
        // another here (they write different nodes or registers).
        for command in commands {
            try command.execute(&builder, state: state)
        }
    }
}
