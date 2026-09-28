import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Creates a live polygon or star (DRAW-011, polygons-stars.adoc "Client") centred at `center`
/// on top of the drawing layer: its local space has the centre at the origin, `transform` (a
/// translation to `center`, plus the constrain angle if any) places it, and the first vertex's
/// direction is `rotation`.
public struct CreatePolygon: Command {
    public var shape: PolygonShape
    public var center: Point
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
    public var layer: OpID?
    public var label: String { shape.star ? "Star" : "Polygon" }

    public init(_ shape: PolygonShape, center: Point, appearance: Wiretuner_Doc_V1_AppearanceProps = Appearances.standard, layer: OpID? = nil) {
        self.shape = shape
        self.center = center
        self.appearance = appearance
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard shape.radius > 0, center.isFinite else { throw PathEditError.invalidValue("radius") }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.polygon.sides = UInt32(shape.sides)
        props.polygon.star = shape.star
        props.polygon.radius = Measure.rounded(shape.radius)
        props.polygon.innerRadius = Measure.rounded(shape.innerRadius)
        props.polygon.autoInner = shape.autoInner
        props.polygon.sharpness = shape.sharpness
        props.polygon.rotation = shape.rotation
        props.polygon.valleyOffset = shape.valleyOffset
        props.polygon.common.transform = PathEditing.proto(AffineTransform.translation(Vector(dx: center.x, dy: center.y)))
        let node = builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
        for op in try PathEditing.appearanceInserts(node, kind: .polygon, appearancePath: AppearanceEditing.stackPath(.polygon)!, appearance) {
            builder.append(op)
        }
    }
}

/// Writes polygon fields (the Object panel's polygon section, the Subselect diamond and circle
/// handles): every field given is one register on each node, all in one change.
public struct SetPolygonFields: Command {
    /// The fields to write; nil leaves one alone.
    public struct Values: Hashable, Sendable {
        public var sides: Int?
        public var star: Bool?
        public var radius: Double?
        public var innerRadius: Double?
        public var autoInner: Bool?
        public var rotation: Double?
        public var valleyOffset: Double?

        public init(sides: Int? = nil, star: Bool? = nil, radius: Double? = nil, innerRadius: Double? = nil, autoInner: Bool? = nil,
                    rotation: Double? = nil, valleyOffset: Double? = nil) {
            self.sides = sides
            self.star = star
            self.radius = radius
            self.innerRadius = innerRadius
            self.autoInner = autoInner
            self.rotation = rotation
            self.valleyOffset = valleyOffset
        }
    }

    public var nodes: [OpID]
    public var values: Values
    public var label: String

    public init(_ nodes: [OpID], _ values: Values, label: String? = nil) {
        self.nodes = nodes
        self.values = values
        self.label = label ?? (nodes.count > 1 ? "Change polygon of \(nodes.count) objects" : "Change polygon")
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for value in [values.radius, values.innerRadius, values.rotation, values.valleyOffset].compactMap({ $0 }) where !value.isFinite {
            throw PathEditError.invalidValue("polygon")
        }
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        if let sides = values.sides {
            props.polygon.sides = UInt32(min(max(sides, PolygonShape.sidesRange.lowerBound), PolygonShape.sidesRange.upperBound))
            paths.append(PolygonFields.sides)
        }
        if let star = values.star {
            props.polygon.star = star
            paths.append(PolygonFields.star)
        }
        if let radius = values.radius {
            props.polygon.radius = Measure.rounded(max(radius, 0))
            paths.append(PolygonFields.radius)
        }
        if let inner = values.innerRadius {
            props.polygon.innerRadius = Measure.rounded(max(inner, 0))
            paths.append(PolygonFields.innerRadius)
        }
        if let auto = values.autoInner {
            props.polygon.autoInner = auto
            paths.append(PolygonFields.autoInner)
        }
        if let rotation = values.rotation {
            props.polygon.rotation = rotation
            paths.append(PolygonFields.rotation)
        }
        if let offset = values.valleyOffset {
            props.polygon.valleyOffset = offset
            paths.append(PolygonFields.valleyOffset)
        }
        guard !paths.isEmpty else { return }
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .polygon {
            builder.append(Ops.set(node, paths, values: props))
        }
    }
}

/// The Object panel's ellipse row (DRAW-061, rectangles-ellipses-lines.adoc "Arcs"): writes the
/// start angle, end angle and open flag -- each its own register, only those given -- on every
/// selected editable ellipse.  Angles are stored modulo 360 and rounded to hundredths of a degree;
/// a non-finite angle is refused.  One change "Change arc" / "Change arc of N objects".
public struct SetEllipseArc: Command {
    public var nodes: [OpID]
    public var start: Double?
    public var end: Double?
    public var open: Bool?
    public var label: String

    public init(_ nodes: [OpID], start: Double? = nil, end: Double? = nil, open: Bool? = nil, label: String? = nil) {
        self.nodes = nodes
        self.start = start
        self.end = end
        self.open = open
        self.label = label ?? (nodes.count > 1 ? "Change arc of \(nodes.count) objects" : "Change arc")
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for value in [start, end].compactMap({ $0 }) where !value.isFinite {
            throw PathEditError.invalidValue("arc")
        }
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        if let start {
            props.ellipse.startAngle = (EllipseArc.normalized(start) * 100).rounded() / 100
            paths.append(EllipseFields.startAngle)
        }
        if let end {
            props.ellipse.endAngle = (EllipseArc.normalized(end) * 100).rounded() / 100
            paths.append(EllipseFields.endAngle)
        }
        if let open {
            props.ellipse.open = open
            paths.append(EllipseFields.open)
        }
        guard !paths.isEmpty else { return }
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .ellipse {
            builder.append(Ops.set(node, paths, values: props))
        }
    }
}

/// A rectangle corner.
public enum Corner: Sendable, Hashable, CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft

    var path: RegisterPath {
        switch self {
        case .topLeft: ShapeFields.topLeft
        case .topRight: ShapeFields.topRight
        case .bottomRight: ShapeFields.bottomRight
        case .bottomLeft: ShapeFields.bottomLeft
        }
    }
}

/// Writes rectangles' corner radii (DRAW-009: the Object panel's *Radius*, *Uniform* and four
/// corners, the Subselect radius handles).  `radius` goes to `corners` (every corner when nil,
/// which is what *Uniform* on writes); `uniform` writes the Uniform register.  One register per
/// corner per rectangle, one change "Change corner radius" / "… of N objects".
public struct SetCornerRadius: Command {
    public var nodes: [OpID]
    public var radius: Double?
    public var corners: [Corner]
    public var uniform: Bool?

    public init(_ nodes: [OpID], radius: Double?, corners: [Corner] = Corner.allCases, uniform: Bool? = nil) {
        self.nodes = nodes
        self.radius = radius
        self.corners = corners
        self.uniform = uniform
    }

    public var label: String { nodes.count > 1 ? "Change corner radius of \(nodes.count) objects" : "Change corner radius" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let radius { guard radius >= 0, radius.isFinite else { throw PathEditError.invalidValue("radius") } }
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        if let radius {
            let value = Measure.rounded(radius)
            for corner in corners {
                switch corner {
                case .topLeft: props.rect.corners.topLeft = value
                case .topRight: props.rect.corners.topRight = value
                case .bottomRight: props.rect.corners.bottomRight = value
                case .bottomLeft: props.rect.corners.bottomLeft = value
                }
                paths.append(corner.path)
            }
        }
        if let uniform {
            props.rect.corners.uniform = uniform
            paths.append(ShapeFields.uniform)
        }
        guard !paths.isEmpty else { return }
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .rect {
            builder.append(Ops.set(node, paths, values: props))
        }
    }
}

/// Writes shapes' size (the Object panel's W and H for a rectangle or ellipse: `size` is ATOMIC,
/// so both dimensions go together), fanned out over several shapes.
public struct SetShapesSize: Command {
    public var nodes: [OpID]
    public var width: Double?
    public var height: Double?

    public init(_ nodes: [OpID], width: Double? = nil, height: Double? = nil) {
        self.nodes = nodes
        self.width = width
        self.height = height
    }

    public var label: String { nodes.count > 1 ? "Resize \(nodes.count) objects" : "Resize" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            guard let kind = state.nodeKind(node), kind == .rect || kind == .ellipse else { continue }
            let props = state.props(node)
            let current = kind == .rect ? props.rect.size : props.ellipse.size
            try SetShapeSize(node: node, size: Size(width: width.map(Measure.rounded) ?? current.width, height: height.map(Measure.rounded) ?? current.height))
                .execute(&builder, state: state)
        }
    }
}
