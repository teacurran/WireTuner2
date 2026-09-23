import struct Foundation.Data
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Why the pasteboard's contents cannot become a tile or a nib (fill-attributes.adoc, "Tiled
/// fills"; stroke-attributes.adoc, "Calligraphic strokes").  The message is what the Object panel
/// shows.
public enum PasteInError: Error, Equatable, Sendable {
    /// Nothing {product} can paste is on the pasteboard.
    case empty
    /// A tile may not hold a bitmap image, a placed EPS file, or a tiled- or lens-filled object.
    case excluded
    /// A nib is one closed path, nothing else.
    case notOneClosedPath
    /// More artwork than a change can carry (20,000 nodes, 2 MiB per node).
    case tooLarge

    public var message: String {
        switch self {
        case .empty: "Copy some artwork first, then click Paste In."
        case .excluded: "A tile cannot contain bitmap images, placed EPS files, or objects with a tiled or lens fill."
        case .notOneClosedPath: "Paste In needs a single closed path on the clipboard."
        case .tooLarge: "There is too much artwork on the clipboard to use as a tile."
        }
    }
}

/// Detached copies of artwork (`Subtree`, fill-attributes.adoc "Data model"): capture from the
/// pasteboard's objects for btn:[Paste In], expansion back to pasteboard objects for
/// btn:[Copy Out], and the calligraphic nib's conversion to and from a closed path.
public enum Subtrees {
    /// The node limit of a `Subtree`.
    public static let maximumNodes = 20_000
    /// The encoded size limit of one node.
    public static let maximumNodeBytes = 2_097_152

    /// A tile from the pasteboard's objects: every node with its props, parents before children
    /// (`parent` indexes the list, -1 for a root), ids stripped, the roots' pasteboard transforms
    /// kept and moved so the artwork's bounds start at the origin.
    public static func tile(from payload: ClipboardPayload) throws(PasteInError) -> Wiretuner_Doc_V1_Subtree {
        guard !payload.isEmpty else { throw .empty }
        let origin = payload.bounds.map { AffineTransform.translation(x: -$0.minX, y: -$0.minY) } ?? .identity
        var subtree = Wiretuner_Doc_V1_Subtree()
        func add(_ tree: NodeTree, parent: Int32) throws(PasteInError) {
            guard tree.kind != nil, tree.kind != .layer else { throw .excluded }
            if let appearance = NodeValues.appearance(tree.props), appearance.fills.contains(where: { [.tiled, .lens].contains($0.settings.kind) }) {
                throw .excluded
            }
            guard subtree.nodes.count < maximumNodes else { throw .tooLarge }
            var node = Wiretuner_Doc_V1_SubtreeNode()
            node.parent = parent
            node.props = Data((try? tree.props.serializedBytes()) ?? [])
            guard node.props.count <= maximumNodeBytes else { throw .tooLarge }
            subtree.nodes.append(node)
            let index = Int32(subtree.nodes.count - 1)
            for child in tree.children { try add(child, parent: index) }
        }
        for var root in payload.nodes {
            root.transform = root.transform.concatenating(origin)
            try add(root, parent: -1)
        }
        return subtree
    }

    /// The tile's artwork as pasteboard objects (btn:[Copy Out]); nil for an empty tile.
    public static func payload(from subtree: Wiretuner_Doc_V1_Subtree) -> ClipboardPayload? {
        let trees = trees(subtree)
        guard !trees.isEmpty else { return nil }
        var bounds = Rect.null
        for item in SubtreeRendering.items(subtree) {
            if let rect = item.bounds { bounds = bounds.union(rect) }
        }
        return ClipboardPayload(nodes: trees, bounds: bounds.isNull ? nil : bounds)
    }

    /// The well-formed prefix of `subtree` as trees: a node whose parent is not an earlier node
    /// (or -1), or whose props do not decode, ends it.
    static func trees(_ subtree: Wiretuner_Doc_V1_Subtree) -> [NodeTree] {
        var props: [Wiretuner_Doc_V1_NodeProps] = []
        var children: [[Int]] = []
        var roots: [Int] = []
        for (index, node) in subtree.nodes.enumerated() {
            guard node.parent == -1 || (node.parent >= 0 && Int(node.parent) < index),
                  let decoded = try? Wiretuner_Doc_V1_NodeProps(serializedBytes: node.props) else { break }
            props.append(decoded)
            children.append([])
            if node.parent == -1 { roots.append(index) } else { children[Int(node.parent)].append(index) }
        }
        func tree(_ index: Int) -> NodeTree {
            NodeTree(props: props[index], children: children[index].map(tree))
        }
        return roots.map(tree)
    }

    // MARK: Nibs

    /// A nib from the pasteboard (btn:[Paste In]): the single closed path -- a path with one
    /// closed contour, a rectangle, an ellipse or a polygon -- in nib units: its control bounds
    /// mapped onto the unit square centred on the origin.
    public static func nib(from payload: ClipboardPayload) throws(PasteInError) -> [Wiretuner_Doc_V1_Contour] {
        guard !payload.isEmpty else { throw .empty }
        guard payload.nodes.count == 1, let root = payload.nodes.first, root.children.isEmpty, let path = shapePath(root.props),
              path.contours.count == 1, let contour = path.contours.first, contour.closed, contour.isRenderable else {
            throw .notOneClosedPath
        }
        let placed = transformed(contour, by: root.transform)
        guard let bounds = VectorPath(contours: [placed]).controlBounds, bounds.width > 0, bounds.height > 0 else { throw .notOneClosedPath }
        let unit = AffineTransform.translation(x: -bounds.midX, y: -bounds.midY).concatenating(.scale(x: 1 / bounds.width, y: 1 / bounds.height))
        return [proto(transformed(placed, by: unit))]
    }

    /// The nib as a closed path on the pasteboard (btn:[Copy Out]): scaled to `width` × `height`,
    /// rotated by `angle` degrees and stroked like a new path.  With no custom nib, the ellipse.
    public static func nibPayload(_ nib: [Wiretuner_Doc_V1_Contour], width: Double, height: Double, angle: Double) -> ClipboardPayload {
        let unit: VectorContour
        if nib.count == 1, nib[0].closed, nib[0].points.count >= 2 {
            unit = VectorContour(closed: true, points: nib[0].points.map(VectorPoint.init))
        } else {
            var ellipse = Wiretuner_Doc_V1_EllipseProps()
            ellipse.size.width = 1
            ellipse.size.height = 1
            unit = transformed(ShapeGeometry.path(ellipse).contours[0], by: .translation(x: -0.5, y: -0.5))
        }
        let size = AffineTransform.scale(x: max(width, Measure.resolution), y: max(height, Measure.resolution))
        let placed = transformed(unit, by: size.concatenating(.rotation(radians: (angle.isFinite ? angle : 0) * .pi / 180)))
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.contours = [proto(placed)]
        props.path.appearance = Appearances.standard
        let tree = NodeTree(props: props)
        return ClipboardPayload(nodes: [tree], bounds: VectorPath(contours: [placed]).controlBounds)
    }

    /// The outline of a path or closed shape; nil for anything else.
    static func shapePath(_ props: Wiretuner_Doc_V1_NodeProps) -> VectorPath? {
        switch props.kind {
        case .path(let path)?: VectorPath(path)
        case .rect(let rect)?: ShapeGeometry.path(rect)
        case .ellipse(let ellipse)?: ShapeGeometry.path(ellipse)
        case .polygon(let polygon)?: ShapeGeometry.path(polygon)
        default: nil
        }
    }

    /// `contour` in drawn order with every anchor and handle mapped by `transform`.
    static func transformed(_ contour: VectorContour, by transform: AffineTransform) -> VectorContour {
        let linear = AffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
        let points = contour.drawn.map { point in
            var moved = point
            moved.anchor = transform.apply(point.anchor)
            let inHandle = linear.apply(Point(x: point.inHandle.dx, y: point.inHandle.dy))
            let outHandle = linear.apply(Point(x: point.outHandle.dx, y: point.outHandle.dy))
            moved.inHandle = Vector(dx: inHandle.x, dy: inHandle.y)
            moved.outHandle = Vector(dx: outHandle.x, dy: outHandle.y)
            moved.automatic = false
            return moved
        }
        return VectorContour(closed: contour.closed, points: points)
    }

    /// An inline contour (no element ids: arrowheads and nibs are ATOMIC values).
    static func proto(_ contour: VectorContour) -> Wiretuner_Doc_V1_Contour {
        var value = Wiretuner_Doc_V1_Contour()
        value.closed = contour.closed
        value.points = contour.points.map { point in
            var stored = Wiretuner_Doc_V1_PathPoint()
            stored.anchor = PathEditing.proto(point.anchor)
            if point.inHandle != .zero { stored.inHandle = PathEditing.proto(Point(x: point.inHandle.dx, y: point.inHandle.dy)) }
            if point.outHandle != .zero { stored.outHandle = PathEditing.proto(Point(x: point.outHandle.dx, y: point.outHandle.dy)) }
            stored.kind = point.kind.proto
            return stored
        }
        return value
    }
}

/// The display items of a `Subtree` (tile artwork, lens snapshots), in its own coordinates: each
/// path and closed shape with its attribute stack, groups with their members, transforms
/// composed.  Only the well-formed prefix renders (fill-attributes.adoc, "Read-time
/// normalizations").
public enum SubtreeRendering {
    public static func items(_ subtree: Wiretuner_Doc_V1_Subtree) -> [DisplayItem] {
        Subtrees.trees(subtree).compactMap { item($0, parent: .identity) }
    }

    static func item(_ tree: NodeTree, parent: AffineTransform) -> DisplayItem? {
        let transform = tree.transform.concatenating(parent)
        if case .group? = tree.props.kind {
            let children = tree.children.compactMap { item($0, parent: transform) }
            return children.isEmpty ? nil : .group(GroupItem(children: children))
        }
        guard let path = Subtrees.shapePath(tree.props), path.isRenderable, let appearance = NodeValues.appearance(tree.props) else { return nil }
        let evenOdd = path.evenOdd
        let display = DocumentDisplayListBuilder.display(path) { _ in true }.path
        let closed = path.contours.allSatisfy { !$0.isRenderable || $0.closed } || path.fillWhenOpen
        return .path(PathItem(path: display, appearance: Appearances.resolve(appearance, evenOdd: evenOdd, paintsFill: closed), transform: transform))
    }
}

/// Inline shapes (arrowheads, nibs) between the display list's paths and stored contours.
public enum InlineShapes {
    /// The contours of `path`: a move starts one, curves set the handles, a close that returns
    /// to the start closes it.  Quadratic segments become cubic.
    public static func contours(_ path: DisplayPath) -> [Wiretuner_Doc_V1_Contour] {
        var contours: [VectorContour] = []
        var points: [VectorPoint] = []
        func finish(closed: Bool) {
            var run = points
            if closed, run.count > 1, let first = run.first, let last = run.last, first.anchor.distance(to: last.anchor) < 1e-9 {
                run[0].inHandle = last.inHandle
                run.removeLast()
            }
            if !run.isEmpty { contours.append(VectorContour(closed: closed, points: run)) }
            points = []
        }
        func curve(_ c1: Point, _ c2: Point, _ end: Point) {
            if let last = points.indices.last { points[last].outHandle = Vector(dx: c1.x - points[last].anchor.x, dy: c1.y - points[last].anchor.y) }
            points.append(VectorPoint(anchor: end, inHandle: Vector(dx: c2.x - end.x, dy: c2.y - end.y), kind: .curve))
        }
        for element in path.elements {
            switch element {
            case .move(let point):
                finish(closed: false)
                points = [VectorPoint(anchor: point)]
            case .line(let point):
                points.append(VectorPoint(anchor: point))
            case .quadCurve(let control, let end):
                let start = points.last?.anchor ?? end
                let c1 = Point(x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y))
                let c2 = Point(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
                curve(c1, c2, end)
            case .cubicCurve(let control1, let control2, let end):
                curve(control1, control2, end)
            case .close:
                finish(closed: true)
            }
        }
        finish(closed: false)
        return contours.map(Subtrees.proto)
    }

    /// A display-list arrowhead (a built-in preset) as the stored value a stroke copies.
    public static func arrowhead(_ head: Arrowhead) -> Wiretuner_Doc_V1_Arrowhead {
        var value = Wiretuner_Doc_V1_Arrowhead()
        value.name = head.name
        value.contours = contours(head.shape)
        value.filled = head.filled
        value.pathTrim = head.pathTrim
        return value
    }
}
