import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Why a path command could not build its change.  Thrown before any op is appended, so nothing
/// is performed.
public enum PathEditError: Error, Equatable, Sendable {
    case notAPath(OpID)
    case unknownContour(OpID)
    case unknownPoint(OpID)
    /// The contour already holds 32,000 live points (vector-basics.adoc, "Size limits").
    case contourFull(OpID)
    case invalidValue(String)
}

/// Where points go, in drawing order (the order a contour reads in after `reversed` and `start`).
public enum PointPlacement: Hashable, Sendable {
    /// After the last drawn point: extending the end.
    case end
    /// Before the first drawn point: extending the beginning.
    case start
    case after(OpID)
    case before(OpID)
}

/// Which end of an open contour, in drawing order.
public enum ContourEnd: Hashable, Sendable {
    case start
    case end
}

/// Shared building blocks of the path commands.
enum PathEditing {
    /// The path `node` holds, or throws when it is not a live path.
    static func path(_ node: OpID, in state: EngineState) throws -> (props: Wiretuner_Doc_V1_PathProps, path: VectorPath) {
        guard state.isLive(node), state.nodeKind(node) == .path else { throw PathEditError.notAPath(node) }
        let props = state.props(node).path
        return (props, VectorPath(props, node: node, state: state))
    }

    static func contour(_ id: OpID, of path: VectorPath) throws -> VectorContour {
        guard let contour = path.contour(id) else { throw PathEditError.unknownContour(id) }
        return contour
    }

    static func point(_ id: OpID, of contour: VectorContour) throws -> VectorPoint {
        guard let point = contour.points.first(where: { $0.id == id }) else { throw PathEditError.unknownPoint(id) }
        return point
    }

    // MARK: Values

    /// A sparse `NodeProps` holding only `path`.
    static func values(_ build: (inout Wiretuner_Doc_V1_PathProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var path = Wiretuner_Doc_V1_PathProps()
        build(&path)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path = path
        return props
    }

    /// A sparse `NodeProps` holding one contour element.
    static func contourValues(_ contour: Wiretuner_Doc_V1_Contour) -> Wiretuner_Doc_V1_NodeProps {
        values { $0.contours = [contour] }
    }

    /// A sparse `NodeProps` holding one point element of one contour.
    static func pointValues(_ point: Wiretuner_Doc_V1_PathPoint) -> Wiretuner_Doc_V1_NodeProps {
        var contour = Wiretuner_Doc_V1_Contour()
        contour.points = [point]
        return contourValues(contour)
    }

    static func proto(_ point: Point) -> Wiretuner_Doc_V1_Point {
        var value = Wiretuner_Doc_V1_Point()
        value.x = point.x
        value.y = point.y
        return value
    }

    static func proto(_ vector: Vector) -> Wiretuner_Doc_V1_Point {
        proto(Point(x: vector.dx, y: vector.dy))
    }

    /// The stored form of a point given in drawing orientation: handles swapped on a reversed
    /// contour, because stored `in_handle` shapes the segment arriving in stored order.
    static func stored(_ point: VectorPoint, reversed: Bool) -> Wiretuner_Doc_V1_PathPoint {
        let point = reversed ? point.swapped : point
        var value = Wiretuner_Doc_V1_PathPoint()
        value.anchor = proto(point.anchor)
        if point.inHandle != .zero { value.inHandle = proto(point.inHandle) }
        if point.outHandle != .zero { value.outHandle = proto(point.outHandle) }
        value.kind = point.kind.proto
        value.automatic = point.automatic
        return value
    }

    /// The paths of a point's handle registers as seen in drawing orientation: (arriving, leaving).
    static func handlePaths(_ contour: VectorContour, _ point: OpID) -> (in: RegisterPath, out: RegisterPath) {
        let inPath = PathFields.inHandle(contour.id, point), outPath = PathFields.outHandle(contour.id, point)
        return contour.reversed ? (outPath, inPath) : (inPath, outPath)
    }

    /// `SetFields` of the drawing-orientation handles `inHandle` and/or `outHandle` of `point`.
    static func setHandles(_ node: OpID, _ contour: VectorContour, _ point: OpID, in inHandle: Vector?, out outHandle: Vector?) -> Wiretuner_Doc_V1_Op? {
        let paths = handlePaths(contour, point)
        var written: [RegisterPath] = []
        var value = Wiretuner_Doc_V1_PathPoint()
        func assign(_ handle: Vector, storedIn: Bool) {
            guard handle != .zero, handle.isFinite else { return }
            if storedIn { value.inHandle = proto(handle) } else { value.outHandle = proto(handle) }
        }
        if let inHandle {
            written.append(paths.in)
            assign(inHandle, storedIn: !contour.reversed)
        }
        if let outHandle {
            written.append(paths.out)
            assign(outHandle, storedIn: contour.reversed)
        }
        guard !written.isEmpty else { return nil }
        return Ops.set(node, written, values: pointValues(value))
    }

    // MARK: Positions

    /// `count` ascending keys strictly between `lo` and `hi` (nil: the start or end).
    static func keys(between lo: [UInt8]?, and hi: [UInt8]?, count: Int) throws -> [[UInt8]] {
        var result: [[UInt8]] = []
        var previous = lo
        for _ in 0..<count {
            let key = try FractionalIndex.between(previous, hi, suffix: UInt64.random(in: .min ... .max))
            result.append(key)
            previous = key
        }
        return result
    }

    /// Keys for `count` points placed at `placement` (drawing order) in `contour`, in the stored
    /// order the points take: ascending, for points given in drawing order and then reversed when
    /// the contour is.
    static func pointKeys(_ node: OpID, _ contour: VectorContour, _ placement: PointPlacement, count: Int, state: EngineState) throws -> [[UInt8]] {
        let sequence = PathFields.points(contour.id)
        let order = state.store.elementOrder(node, sequence)
        let drawn = contour.drawn
        // Resolve to "stored after X" or "stored before X"; with no drawn point, after the last
        // stored element (tombstones included), or anywhere when there is none.
        enum Stored { case after(OpID?), before(OpID) }
        func storedAfter(drawnAfter id: OpID) -> Stored { contour.reversed ? .before(id) : .after(id) }
        func storedBefore(drawnBefore id: OpID) -> Stored { contour.reversed ? .after(id) : .before(id) }
        let stored: Stored
        switch placement {
        case .end:
            stored = drawn.last.map { storedAfter(drawnAfter: $0.id) } ?? .after(order.last)
        case .start:
            stored = drawn.first.map { storedBefore(drawnBefore: $0.id) } ?? .after(order.last)
        case .after(let id):
            guard order.contains(id) else { throw PathEditError.unknownPoint(id) }
            stored = storedAfter(drawnAfter: id)
        case .before(let id):
            guard order.contains(id) else { throw PathEditError.unknownPoint(id) }
            stored = storedBefore(drawnBefore: id)
        }
        let key: (OpID) -> [UInt8]? = { state.position(node, sequence, $0) }
        let lo: [UInt8]?, hi: [UInt8]?
        switch stored {
        case .after(let id?):
            let index = order.firstIndex(of: id)!
            lo = key(id)
            hi = index + 1 < order.count ? key(order[index + 1]) : nil
        case .after(nil):
            (lo, hi) = (nil, nil)
        case .before(let id):
            let index = order.firstIndex(of: id)!
            lo = index > 0 ? key(order[index - 1]) : nil
            hi = key(id)
        }
        return try keys(between: lo, and: hi, count: count)
    }

    /// `ElementInsert` of `points` (drawing order and orientation) into `contour` at `placement`.
    static func insert(_ points: [VectorPoint], into contour: VectorContour, of node: OpID, at placement: PointPlacement,
                       state: EngineState) throws -> Wiretuner_Doc_V1_Op {
        guard contour.points.count + points.count <= VectorContour.maximumPoints else { throw PathEditError.contourFull(contour.id) }
        let keys = try pointKeys(node, contour, placement, count: points.count, state: state)
        let ordered = contour.reversed ? points.reversed() : points
        var value = Wiretuner_Doc_V1_Contour()
        value.points = ordered.map { stored($0, reversed: contour.reversed) }
        return Ops.elementInsert(node, PathFields.points(contour.id), positions: keys, values: contourValues(value))
    }

    /// Appends the insert of `points` to `builder`; when they go before the `start` point of an
    /// open contour, also moves `start` to the first of them, so they read at the beginning.
    static func insert(_ points: [VectorPoint], into contour: VectorContour, of node: OpID, at placement: PointPlacement,
                       state: EngineState, builder: inout ChangeBuilder) throws {
        let first = builder.append(try insert(points, into: contour, of: node, at: placement, state: state))
        guard !contour.closed, let start = contour.start, let head = contour.drawn.first?.id, head == start else { return }
        switch placement {
        case .start: break
        case .before(let id) where id == start: break
        default: return
        }
        // Element i of the insert takes counter + i, in stored order.
        let index = contour.reversed ? UInt64(points.count - 1) : 0
        var value = Wiretuner_Doc_V1_Contour()
        value.start = OpID(counter: first.counter + index, replica: first.replica).elementID
        builder.append(Ops.set(node, [PathFields.start(contour.id)], values: contourValues(value)))
    }

    // MARK: Layers

    /// The layer new objects go into: the top-most live, visible, unlocked, non-Guides layer; nil
    /// when there is none and one must be created.
    static func drawingLayer(in state: EngineState) -> OpID? {
        LayerOrder(state).drawingLayer
    }

    /// Whether new objects may go onto `layer`: a live, unlocked, non-Guides layer (a hidden
    /// active layer is allowed, layers.adoc "Showing and hiding layers").
    static func accepts(_ layer: OpID, _ order: LayerOrder) -> Bool {
        guard order.isLive(layer), let info = order.layer(layer) else { return false }
        return !info.locked && info.role == .ordinary
    }

    /// The layer to draw into -- `preferred` (the active layer) when it takes objects, else the
    /// drawing layer -- appending the creation of a "Foreground" layer (visible and printing) to
    /// `builder` when there is none.
    static func ensureLayer(_ builder: inout ChangeBuilder, state: EngineState, preferred: OpID? = nil) throws -> OpID {
        let order = LayerOrder(state)
        if let preferred, accepts(preferred, order) { return preferred }
        if let layer = order.drawingLayer { return layer }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = "Foreground"
        props.layer.visible = true
        props.layer.printing = true
        let last = state.store.children(WellKnown.layers).last.flatMap { state.store.placement($0)?.position }
        let position = try keys(between: last, and: nil, count: 1)[0]
        return builder.append(Ops.create(parent: WellKnown.layers, position: position, props: props))
    }

    /// A position above every child of `parent`.
    static func topPosition(in parent: OpID, state: EngineState) throws -> [UInt8] {
        let last = state.store.children(parent).last.flatMap { state.store.placement($0)?.position }
        return try keys(between: last, and: nil, count: 1)[0]
    }

    /// `ElementInsert`s of the fills and strokes of `appearance` into the node's attribute stack
    /// at `path` (the `AppearanceProps` field of its kind).
    static func appearanceInserts(_ node: OpID, kind: NodeKind, appearancePath: RegisterPath,
                                  _ appearance: Wiretuner_Doc_V1_AppearanceProps) throws -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        let field = appearancePath.fields.last!
        func values(_ build: (inout Wiretuner_Doc_V1_AppearanceProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
            var stack = Wiretuner_Doc_V1_AppearanceProps()
            build(&stack)
            return NodeValues.with(kind: kind, appearanceField: field, stack)
        }
        // One run of keys: the lists share a position space, so the fills sit below the strokes
        // (a new object gets its fills with its strokes above them, attribute-stack.adoc).
        let all = try keys(between: nil, and: nil, count: appearance.fills.count + appearance.strokes.count)
        if !appearance.fills.isEmpty {
            ops.append(Ops.elementInsert(node, appearancePath.child(1), positions: Array(all.prefix(appearance.fills.count)),
                                         values: values { $0.fills = appearance.fills }))
        }
        if !appearance.strokes.isEmpty {
            ops.append(Ops.elementInsert(node, appearancePath.child(2), positions: Array(all.suffix(appearance.strokes.count)),
                                         values: values { $0.strokes = appearance.strokes }))
        }
        return ops
    }

    // MARK: Geometry

    /// The transform of a stored `Transform` (unset, all zero, reads as the identity).
    static func transform(_ value: Wiretuner_Doc_V1_Transform) -> AffineTransform {
        if value.a == 0, value.b == 0, value.c == 0, value.d == 0, value.tx == 0, value.ty == 0 { return .identity }
        return AffineTransform(a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx, ty: value.ty)
    }

    static func proto(_ transform: AffineTransform) -> Wiretuner_Doc_V1_Transform {
        var value = Wiretuner_Doc_V1_Transform()
        value.a = transform.a
        value.b = transform.b
        value.c = transform.c
        value.d = transform.d
        value.tx = transform.tx
        value.ty = transform.ty
        return value
    }
}

/// Sparse `NodeProps` for the kinds WTModel writes.
enum NodeValues {
    /// `NodeProps` of `kind` with `stack` at the kind's appearance field.
    static func with(kind: NodeKind, appearanceField: UInt32, _ stack: Wiretuner_Doc_V1_AppearanceProps) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        switch kind {
        case .path: props.path.appearance = stack
        case .rect: props.rect.appearance = stack
        case .ellipse: props.ellipse.appearance = stack
        case .polygon: props.polygon.appearance = stack
        case .group: props.group.appearance = stack
        case .instance: props.instance.appearance = stack
        case .barcode: props.barcode.appearance = stack
        case .layer, .chart, .symbol: break
        }
        return props
    }

    /// `NodeProps` of `kind` whose common props `build` fills.
    static func common(kind: NodeKind, _ build: (inout Wiretuner_Doc_V1_CommonProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var common = Wiretuner_Doc_V1_CommonProps()
        build(&common)
        var props = Wiretuner_Doc_V1_NodeProps()
        switch kind {
        case .path: props.path.common = common
        case .rect: props.rect.common = common
        case .ellipse: props.ellipse.common = common
        case .polygon: props.polygon.common = common
        case .group: props.group.common = common
        case .layer: props.layer.common = common
        case .chart: props.chart.common = common
        case .symbol: props.symbol.common = common
        case .instance: props.instance.common = common
        case .barcode: props.barcode.common = common
        }
        return props
    }

    /// `NodeProps` of `kind` with `transform` in its common props.
    static func with(kind: NodeKind, transform: Wiretuner_Doc_V1_Transform) -> Wiretuner_Doc_V1_NodeProps {
        common(kind: kind) { $0.transform = transform }
    }

    /// The common props of any kind WTModel reads.
    static func common(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_CommonProps? {
        switch props.kind {
        case .path(let path)?: path.common
        case .rect(let rect)?: rect.common
        case .ellipse(let ellipse)?: ellipse.common
        case .polygon(let polygon)?: polygon.common
        case .group(let group)?: group.common
        case .layer(let layer)?: layer.common
        case .chart(let chart)?: chart.common
        case .symbol(let symbol)?: symbol.common
        case .instance(let instance)?: instance.common
        case .barcode(let barcode)?: barcode.common
        default: nil
        }
    }

    /// The attribute stack of any kind with one.
    static func appearance(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_AppearanceProps? {
        switch props.kind {
        case .path(let path)?: path.appearance
        case .rect(let rect)?: rect.appearance
        case .ellipse(let ellipse)?: ellipse.appearance
        case .polygon(let polygon)?: polygon.appearance
        case .group(let group)?: group.appearance
        case .instance(let instance)?: instance.appearance
        case .barcode(let barcode)?: barcode.appearance
        default: nil
        }
    }

    /// `props` with the attribute stack of its `kind` replaced by `appearance` (kinds without
    /// one are returned unchanged).
    static func replacing(_ appearance: Wiretuner_Doc_V1_AppearanceProps, of kind: NodeKind, in props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_NodeProps {
        var props = props
        switch kind {
        case .path: props.path.appearance = appearance
        case .rect: props.rect.appearance = appearance
        case .ellipse: props.ellipse.appearance = appearance
        case .polygon: props.polygon.appearance = appearance
        case .group: props.group.appearance = appearance
        case .instance: props.instance.appearance = appearance
        case .barcode: props.barcode.appearance = appearance
        case .layer, .chart, .symbol: break
        }
        return props
    }

    /// The appearance field number of a kind with one.
    static func appearanceField(_ kind: NodeKind) -> UInt32? {
        switch kind {
        case .path: 3
        case .rect: 4
        case .ellipse: 3
        case .polygon: 10
        case .group: 6
        case .instance: 4
        case .barcode: 7
        case .layer, .chart, .symbol: nil
        }
    }
}
