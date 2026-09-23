import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FX-017: extrude commands (docs/_includes/effects/extrude.adoc, "Extruding", "Merge semantics",
// "Undo").  An extrusion is an `extrude` node (kind 101) wrapping the flat shape; extrusion
// registers live on the wrapper and the shape's on the child, so edits to the two never compete.

/// Why a wrapper command could not build its change.
public enum WrapperError: Error, Equatable, Sendable {
    /// Not a live blend or extrusion (nor inside one, where the command accepts members).
    case notAWrapper(OpID)
    /// Extruding an extrusion, something inside one, or something holding one (no nested
    /// extrusions).
    case nestedExtrusion(OpID)
    /// The objects cannot be blended; the reason is shown to the user.
    case notBlendable(String)
    /// A profile must be one open path of two or more points.
    case invalidProfile
}

/// Register paths of `ExtrudeProps` (extrude.proto).
public enum ExtrudeFields {
    public static let kind = WrapperKind.extrude.rawValue
    public static let length = RegisterPath([101, 2])
    public static let vanishingPoint = RegisterPath([101, 3])
    public static let z = RegisterPath([101, 4])
    public static let rotation = RegisterPath([101, 5])
    public static let surface = RegisterPath([101, 6])
    public static let surfaceKind = RegisterPath([101, 6, 1])
    public static let surfaceSteps = RegisterPath([101, 6, 2])
    public static let ambient = RegisterPath([101, 6, 3])
    public static let light1 = RegisterPath([101, 6, 4])
    public static let light2 = RegisterPath([101, 6, 5])
    public static let profile = RegisterPath([101, 7])
    public static let profileKind = RegisterPath([101, 7, 1])
    public static let profilePath = RegisterPath([101, 7, 2])
    public static let profileAngle = RegisterPath([101, 7, 3])
    public static let profileSteps = RegisterPath([101, 7, 4])
    public static let twist = RegisterPath([101, 7, 5])

    static func values(_ props: Wiretuner_Doc_V1_ExtrudeProps) -> Wiretuner_Doc_V1_NodeProps {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.extrude = props
        return values
    }

    /// A new extrusion's settings: `length`, the vanishing point, a Shaded surface lit from the
    /// top left (ambient 30, light 80) -- the working defaults the page leaves to the tool.
    public static func defaults(length: Double, vanishingPoint: Point) -> Wiretuner_Doc_V1_ExtrudeProps {
        var props = Wiretuner_Doc_V1_ExtrudeProps()
        props.length = min(max(length, 0), 32000)
        props.vanishingPoint = PathEditing.proto(vanishingPoint)
        props.surface.kind = .shaded
        props.surface.ambient = 30
        props.surface.light1.direction = .topLeft
        props.surface.light1.intensity = 80
        props.surface.light2.direction = .none
        return props
    }
}

/// Shared by the wrapper commands.
enum WrapperEditing {
    /// The live wrapper of `kind` that `node` is or lies inside (the nearest), or throws.
    static func wrapper(_ node: OpID, _ kind: WrapperKind, in state: EngineState) throws -> OpID {
        var current: OpID? = node
        var steps = 0
        while let id = current, steps < 10_000 {
            if WrapperKind.of(id, in: state) == kind, state.isEffectivelyLive(id) { return id }
            current = state.store.placement(id)?.parent
            steps += 1
        }
        throw WrapperError.notAWrapper(node)
    }

    /// The distinct wrappers `nodes` name, in the given order.
    static func wrappers(_ nodes: [OpID], _ kind: WrapperKind, in state: EngineState) throws -> [OpID] {
        var seen: Set<OpID> = []
        return try nodes.map { try wrapper($0, kind, in: state) }.filter { seen.insert($0).inserted }
    }

    /// The node's own transform (a wrapper's included).
    static func transform(_ node: OpID, in state: EngineState) -> AffineTransform {
        Objects.transform(of: node, in: state)
    }

    /// Writes `node`'s transform; nil for a kind WTModel does not write (a wrapper moved into
    /// another by a concurrent move keeps its own).
    static func setTransform(_ node: OpID, _ transform: AffineTransform, in state: EngineState) -> Wiretuner_Doc_V1_Op? {
        state.nodeKind(node).map { Objects.setTransform(node, kind: $0, transform) }
    }

    /// Moves `children` (bottom first) out of `wrapper` into its parent at the wrapper's slot,
    /// the wrapper's own transform baked into each, and deletes the wrapper.
    static func unwrap(_ wrapper: OpID, children: [OpID], state: EngineState, builder: inout ChangeBuilder) throws {
        // A live wrapper (`wrapper(_:_:in:)`) is always placed.
        let parent = Objects.parent(of: wrapper, in: state)!
        let outer = transform(wrapper, in: state)
        let keys = try Arranging.keys(next: wrapper, above: true, count: children.count, in: state)
        for (child, key) in zip(children, keys) {
            if !outer.isIdentity, let op = setTransform(child, transform(child, in: state).concatenating(outer), in: state) { builder.append(op) }
            builder.append(Ops.move(child, parent: parent, position: key))
        }
        builder.append(Ops.setDeleted(wrapper))
    }
}

/// menu:Modify[Extrude] and the Extrude tool's drag (extrude.adoc, "To extrude an object"): for
/// each selected object an `extrude` node at the object's slot with `length`, the vanishing point
/// and the default surface, and the object moved inside it -- one change labelled "Extrude".
/// Refused for an object that is, lies inside or holds an extrusion (no nested extrusions).
public struct Extrude: Command {
    public var nodes: [OpID]
    public var length: Double
    public var vanishingPoint: Point

    public init(_ nodes: [OpID], length: Double = 36, vanishingPoint: Point) {
        self.nodes = nodes
        self.length = length
        self.vanishingPoint = vanishingPoint
    }

    public var label: String { "Extrude" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            guard !ExtrudeReading.isInsideExtrusion(node, in: state), !ExtrudeReading.containsExtrusion(node, in: state) else {
                throw WrapperError.nestedExtrusion(node)
            }
            let parent = Objects.parent(of: node, in: state)!
            let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            let wrapper = builder.append(Ops.create(parent: parent, position: key,
                                                    props: ExtrudeFields.values(ExtrudeFields.defaults(length: length, vanishingPoint: vanishingPoint))))
            builder.append(Ops.move(node, parent: wrapper, position: try PathEditing.keys(between: nil, and: nil, count: 1)[0]))
        }
    }
}

/// menu:Modify[Extrude > Remove]: the flat shape (every live child) moves back to the extrusion's
/// slot exactly as it was and the `extrude` node is deleted.  A concurrent edit of the child lands
/// on the freed child; one of the extrusion lands on the deleted node (edit vs. delete, with
/// *Restore*).  Labelled "Remove extrusion".
public struct RemoveExtrusion: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Remove extrusion" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for wrapper in try WrapperEditing.wrappers(nodes, .extrude, in: state) {
            try WrapperEditing.unwrap(wrapper, children: state.liveChildren(wrapper), state: state, builder: &builder)
        }
    }
}

/// menu:Modify[Extrude > Release]: a group of the faces as drawn (sides, front face and any flat
/// extra children, as plain filled and stroked paths) at the extrusion's slot, and the `extrude`
/// node deleted *with* its child inside, so undo or *Restore* brings the live extrusion back.
/// Labelled "Release extrusion".
public struct ReleaseExtrusion: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Release extrusion" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let wrappers = try WrapperEditing.wrappers(nodes, .extrude, in: state)
        guard !wrappers.isEmpty else { return }
        var scene = DocumentDisplayListBuilder(canvas: "release")
        let built = scene.rebuild(state)
        for wrapper in wrappers {
            let parent = Objects.parent(of: wrapper, in: state)!
            let trees = built.object(wrapper).map { Baking.trees([$0.item]) } ?? []
            let key = try Arranging.keys(next: wrapper, above: true, count: 1, in: state)[0]
            try Baking.createGroup(trees, parent: parent, position: key, state: state, builder: &builder)
            builder.append(Ops.setDeleted(wrapper))
        }
    }
}

/// menu:Modify[Extrude > Reset]: rotation back to zero, the profile to None (its path, angle,
/// steps and twist cleared) and the surface to Shaded; the vanishing point, depth and position
/// stay.  Labelled "Reset extrusion".
public struct ResetExtrusion: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Reset extrusion" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_ExtrudeProps()
        props.surface.kind = .shaded
        for wrapper in try WrapperEditing.wrappers(nodes, .extrude, in: state) {
            builder.append(Ops.set(wrapper, [ExtrudeFields.rotation, ExtrudeFields.profile, ExtrudeFields.surfaceKind], values: ExtrudeFields.values(props)))
        }
    }
}

/// menu:Modify[Extrude > Share Vanishing Points] after the click: each selected extrusion's own
/// `vanishing_point` written to `point` -- no shared node, so moving one later moves only it.
/// Labelled "Share vanishing points".
public struct ShareVanishingPoints: Command {
    public var nodes: [OpID]
    public var point: Point

    public init(_ nodes: [OpID], at point: Point) {
        self.nodes = nodes
        self.point = point
    }

    public var label: String { "Share vanishing points" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_ExtrudeProps()
        props.vanishingPoint = PathEditing.proto(point)
        for wrapper in try WrapperEditing.wrappers(nodes, .extrude, in: state) {
            builder.append(Ops.set(wrapper, [ExtrudeFields.vanishingPoint], values: ExtrudeFields.values(props)))
        }
    }
}

/// Any property of the Extrude, Surface and Profile pages, and the Extrude tool's drags (depth,
/// vanishing point, rotation): the registers at `fields` (`ExtrudeFields`) of each extrusion from
/// `props`.  One change over every selected extrusion.
public struct EditExtrusion: Command {
    public var nodes: [OpID]
    public var fields: [RegisterPath]
    public var props: Wiretuner_Doc_V1_ExtrudeProps
    public var label: String

    public init(_ nodes: [OpID], label: String, fields: [RegisterPath], _ build: (inout Wiretuner_Doc_V1_ExtrudeProps) -> Void) {
        self.nodes = nodes
        self.label = label
        self.fields = fields
        var props = Wiretuner_Doc_V1_ExtrudeProps()
        build(&props)
        self.props = props
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if fields.contains(ExtrudeFields.length), !(0...32000).contains(props.length) { throw ObjectEditError.invalidValue("length") }
        for wrapper in try WrapperEditing.wrappers(nodes, .extrude, in: state) {
            builder.append(Ops.set(wrapper, fields, values: ExtrudeFields.values(props)))
        }
    }
}

/// btn:[Paste In] on the Profile page: a copy of one open path's contour as the profile (ATOMIC:
/// it replaces the old one whole; the source path can change or go without affecting it).
/// Labelled "Paste profile".
public struct PasteExtrudeProfile: Command {
    public var nodes: [OpID]
    public var contour: Wiretuner_Doc_V1_Contour

    public init(_ nodes: [OpID], contour: Wiretuner_Doc_V1_Contour) {
        self.nodes = nodes
        self.contour = contour
    }

    /// The profile a pasted path gives: its one open contour; nil for anything else.
    public static func profile(from path: Wiretuner_Doc_V1_PathProps) -> Wiretuner_Doc_V1_Contour? {
        guard path.contours.count == 1, !path.contours[0].closed, path.contours[0].points.count >= 2 else { return nil }
        return path.contours[0]
    }

    public var label: String { "Paste profile" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !contour.closed, contour.points.count >= 2 else { throw WrapperError.invalidProfile }
        var props = Wiretuner_Doc_V1_ExtrudeProps()
        props.profile.path = contour
        for wrapper in try WrapperEditing.wrappers(nodes, .extrude, in: state) {
            builder.append(Ops.set(wrapper, [ExtrudeFields.profilePath], values: ExtrudeFields.values(props)))
        }
    }
}
