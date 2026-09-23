import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// The wrapper node kinds WTModel draws and edits (blends.adoc, extrude.adoc): a node whose live
/// children are drawn through a derived drawing.  They are not `NodeKind` cases yet -- WTApp
/// switches over `NodeKind` exhaustively -- so the scene records a wrapper as a `.group` object
/// and the wrapper commands read the raw kind.
public enum WrapperKind: UInt32, Sendable, CaseIterable {
    /// `BlendProps` (FX-023).
    case blend = 100
    /// `ExtrudeProps` (FX-016).
    case extrude = 101

    /// The wrapper kind of `node`, if it is one (live or not).
    public static func of(_ node: OpID, in state: EngineState) -> WrapperKind? {
        WrapperKind(rawValue: state.store.kind(node))
    }
}

/// Reading wrappers and lowering them to WTRender's `LiveGroup` (the read-time normalizations of
/// blends.adoc and extrude.adoc).
public enum Wrappers {
    /// The wrapper's live children in the order the display list holds them: a blend's in sibling
    /// order (its key objects bottom first, and the path); an extrusion's with the child of the
    /// smallest node id first -- the one extruded -- and the others after it in sibling order,
    /// drawn flat above (extrude.adoc, "More than one live child").
    public static func drawOrder(_ node: OpID, _ kind: WrapperKind, in state: EngineState) -> [OpID] {
        let children = state.liveChildren(node)
        guard kind == .extrude, let first = children.min() else { return children }
        return [first] + children.filter { $0 != first }
    }

    /// The live group of wrapper `node` drawn over `children` (its placed children, in draw
    /// order); `path` gives a placed child's geometry for resolving blend points.
    static func live(_ kind: WrapperKind, node: OpID, children: [OpID], in state: EngineState, path: (OpID) -> VectorPath?) -> LiveGroup {
        let props = state.props(node)
        switch kind {
        case .blend: return .blend(blend(props.blend, children: children, in: state, path: path))
        case .extrude: return .extrude(extrude(props.extrude))
        }
    }

    /// `BlendProps` resolved against the placed children: the path as a child index when it is a
    /// live path child (else straight), each key object's blend point as an anchor -- the element
    /// of greatest id among those naming the object wins, and one whose contour or point is gone
    /// reads as unset.
    static func blend(_ props: Wiretuner_Doc_V1_BlendProps, children: [OpID], in state: EngineState, path: (OpID) -> VectorPath?) -> BlendSpec {
        let types: [Wiretuner_Doc_V1_BlendType: BlendSpec.BlendType] = [.horizontal: .horizontal, .vertical: .vertical]
        let pathIndex = BlendReading.path(props, children: children, in: state).flatMap { children.firstIndex(of: $0) }
        var points: [BlendPoint] = []
        for (object, point) in BlendReading.points(props) {
            guard let child = children.firstIndex(of: object), let geometry = path(object),
                  let anchor = BlendReading.anchor(geometry, contour: point.contour, point: point.point) else { continue }
            points.append(BlendPoint(child: child, contour: anchor.contour, anchor: anchor.anchor))
        }
        return BlendSpec(steps: Int(props.steps), rangeFirst: props.rangeFirst, rangeLast: props.rangeLast, type: types[props.type] ?? .normal,
                         order: props.order == .stacking ? .stacking : .positional, path: pathIndex, showPath: props.showPath,
                         rotateOnPath: props.rotateOnPath, blendPoints: points.sorted { $0.child < $1.child })
    }

    /// `ExtrudeProps` lowered; a Bevel or Static profile without a path reads as None.
    static func extrude(_ props: Wiretuner_Doc_V1_ExtrudeProps) -> ExtrudeSpec {
        let surfaces: [Wiretuner_Doc_V1_SurfaceKind: ExtrudeSpec.SurfaceKind] = [
            .flat: .flat, .wireframe: .wireframe, .mesh: .mesh, .hiddenMesh: .hiddenMesh,
        ]
        let profile = props.profile
        let hasPath = profile.hasPath && profile.path.points.count >= 2
        let kinds: [Wiretuner_Doc_V1_ProfileKind: ExtrudeSpec.ProfileKind] = [.bevel: .bevel, .static: .staticAngle]
        let kind = hasPath ? (kinds[profile.kind] ?? .none) : .none
        return ExtrudeSpec(
            length: props.length, vanishingPoint: Point(x: props.vanishingPoint.x, y: props.vanishingPoint.y), z: props.z,
            rotationX: props.rotation.x, rotationY: props.rotation.y, rotationZ: props.rotation.z,
            surface: surfaces[props.surface.kind] ?? .shaded, surfaceSteps: Int(props.surface.steps), ambient: Double(props.surface.ambient),
            light1: light(props.surface.light1), light2: light(props.surface.light2),
            profile: ExtrudeSpec.Profile(kind: kind, path: hasPath ? Appearances.display([profile.path]) : nil, angle: profile.angle,
                                         steps: Int(profile.steps), twist: profile.twist)
        )
    }

    static func light(_ light: Wiretuner_Doc_V1_Light) -> ExtrudeSpec.Light {
        let directions: [Wiretuner_Doc_V1_LightDirection: ExtrudeSpec.LightDirection] = [
            .topLeft: .topLeft, .top: .top, .topRight: .topRight, .left: .left, .front: .front, .right: .right,
            .bottomLeft: .bottomLeft, .bottom: .bottom, .bottomRight: .bottomRight,
        ]
        return ExtrudeSpec.Light(direction: directions[light.direction] ?? .none, intensity: Double(light.intensity))
    }
}

/// Reading a blend (blends.adoc, "Read-time normalizations").
public enum BlendReading {
    /// The child the blend follows: `path` when it names a live child of the blend that is a
    /// path; nil (straight) otherwise.
    public static func path(_ props: Wiretuner_Doc_V1_BlendProps, children: [OpID], in state: EngineState) -> OpID? {
        guard props.hasPath, props.path.hasID else { return nil }
        let id = OpID(props.path.id)
        return children.contains(id) && state.nodeKind(id) == .path ? id : nil
    }

    /// The key objects of blend `node` in blend order (bottom first): its live children but the
    /// path.
    public static func keyObjects(_ node: OpID, in state: EngineState) -> [OpID] {
        let children = state.liveChildren(node)
        let path = path(state.props(node).blend, children: children, in: state)
        return children.filter { $0 != path }
    }

    /// Each object's blend point: of the elements naming one object, the one of greatest element
    /// id.
    public static func points(_ props: Wiretuner_Doc_V1_BlendProps) -> [(object: OpID, point: (contour: OpID, point: OpID))] {
        var best: [OpID: (id: OpID, contour: OpID, point: OpID)] = [:]
        for element in props.blendPoints {
            guard let id = OpID(element: element.id), element.hasObject, let contour = OpID(element: element.contour),
                  let point = OpID(element: element.point) else { continue }
            let object = OpID(element.object)
            if best[object].map({ $0.id < id }) ?? true { best[object] = (id, contour, point) }
        }
        return best.keys.sorted().map { ($0, (best[$0]!.contour, best[$0]!.point)) }
    }

    /// The anchor of `point` in `contour` of `path`, numbered as `CornerPoint`s are; nil when
    /// either is gone.
    static func anchor(_ path: VectorPath, contour: OpID, point: OpID) -> CornerPoint? {
        var index = 0
        for candidate in path.contours where candidate.isRenderable {
            if candidate.id == contour {
                return candidate.drawn.firstIndex { $0.id == point }.map { CornerPoint(contour: index, anchor: $0) }
            }
            index += 1
        }
        return nil
    }
}

/// Reading an extrusion (extrude.adoc, "Read-time normalizations").
public enum ExtrudeReading {
    /// The child extruded: the live child of the smallest node id; nil for an empty extrusion.
    public static func child(_ node: OpID, in state: EngineState) -> OpID? {
        state.liveChildren(node).min()
    }

    /// What the Object panel lists the node as: "Empty extrusion" without a live child.
    public static func title(_ node: OpID, in state: EngineState) -> String {
        child(node, in: state) == nil ? "Empty extrusion" : "Extrusion"
    }

    /// Whether `node` is an extrusion or lies inside one.
    public static func isInsideExtrusion(_ node: OpID, in state: EngineState) -> Bool {
        var current: OpID? = node
        var steps = 0
        while let id = current, steps < 10_000 {
            if WrapperKind.of(id, in: state) == .extrude { return true }
            current = state.store.placement(id)?.parent
            steps += 1
        }
        return false
    }

    /// Whether the subtree of `node` holds an extrusion.
    public static func containsExtrusion(_ node: OpID, in state: EngineState) -> Bool {
        if WrapperKind.of(node, in: state) == .extrude { return true }
        return state.liveChildren(node).contains { containsExtrusion($0, in: state) }
    }
}
