import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FX-039 (the model half): envelopes read into the scene and the menu:Modify[Envelope] commands
// (effects/path-effects.adoc, "Envelopes", "Merge semantics", "Read-time normalizations").  An
// envelope is an `envelope` node (kind 102) wrapping its contents; its outline is a SEQUENCE of
// contours in the envelope's own space, `source_bounds` the rectangle the contents map from and
// `corners` the four point element ids of the warp patch.  The scene draws it through WTRender's
// `EnvelopeWarp` (FX-038) with `EnvelopeReading.spec`.

/// Register paths of `EnvelopeProps` (envelope.proto).
public enum EnvelopeFields {
    /// `NodeProps.envelope`.
    public static let kind = WrapperKind.envelope.rawValue
    public static let common = RegisterPath([kind, 1])
    public static let contours = RegisterPath([kind, 2])
    public static let sourceBounds = RegisterPath([kind, 3])
    public static let corners = RegisterPath([kind, 4])
    public static let showMap = RegisterPath([kind, 5])

    public static func contour(_ id: OpID) -> RegisterPath { contours.element(id) }
    public static func points(_ contour: OpID) -> RegisterPath { self.contour(contour).child(3) }
    public static func anchor(_ contour: OpID, _ point: OpID) -> RegisterPath { points(contour).element(point).child(2) }

    static func values(_ build: (inout Wiretuner_Doc_V1_EnvelopeProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.envelope)
        return props
    }
}

/// Why an envelope command refused.
public enum EnvelopeError: Error, Equatable, Sendable {
    /// Nothing to put in an envelope (no editable object with bounds).
    case nothingToEnvelope
    /// A pasted envelope needs one closed contour of four or more points.
    case invalidShape
    /// A preset needs a closed outline of four or more points and four distinct corners.
    case invalidPreset
}

/// An envelope shape to create envelopes with (the Envelope toolbar's pop-up): a closed outline
/// in the unit square (0 ... 1, y down) and which of its points are the TL, TR, BR and BL
/// corners.  Presets are the user's, stored with the account preferences
/// (`EnvelopePreset.encoded`, one string per preset); `defaults` is the built-in set.
public struct EnvelopePreset: Hashable, Sendable {
    public var name: String
    /// The outline in drawing order.
    public var points: [VectorPoint]
    /// Indices into `points` of the TL, TR, BR and BL corners.
    public var corners: [Int]

    public init(name: String, points: [VectorPoint], corners: [Int]) {
        self.name = name
        self.points = points
        self.corners = corners
    }

    /// Whether the preset can make an envelope: four or more finite points, four distinct corners
    /// among them.
    public var isValid: Bool {
        points.count >= 4 && corners.count == 4 && Set(corners).count == 4 && corners.allSatisfy(points.indices.contains)
            && points.allSatisfy { $0.anchor.isFinite && $0.inHandle.isFinite && $0.outHandle.isFinite }
    }

    /// The outline placed on `rect` (the unit square scaled onto it).
    public func points(in rect: Rect) -> [VectorPoint] {
        points.map { point in
            var placed = point
            placed.anchor = Point(x: rect.minX + point.anchor.x * rect.width, y: rect.minY + point.anchor.y * rect.height)
            placed.inHandle = Vector(dx: point.inHandle.dx * rect.width, dy: point.inHandle.dy * rect.height)
            placed.outHandle = Vector(dx: point.outHandle.dx * rect.width, dy: point.outHandle.dy * rect.height)
            return placed
        }
    }

    /// An outline (drawing order) normalized to `rect` as a preset; nil when `rect` is empty.
    public init?(name: String, points: [VectorPoint], corners: [Int], normalizedTo rect: Rect) {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let normalized = points.map { point -> VectorPoint in
            var result = point
            result.anchor = Point(x: (point.anchor.x - rect.minX) / rect.width, y: (point.anchor.y - rect.minY) / rect.height)
            result.inHandle = Vector(dx: point.inHandle.dx / rect.width, dy: point.inHandle.dy / rect.height)
            result.outHandle = Vector(dx: point.outHandle.dx / rect.width, dy: point.outHandle.dy / rect.height)
            return result
        }
        self.init(name: name, points: normalized, corners: corners)
    }

    /// menu:Modify[Envelope > Save as Preset]: envelope `node`'s outline (its first live contour)
    /// relative to its source rectangle, with its resolved corners; nil when it has no usable
    /// outline.
    public init?(name: String, envelope node: OpID, in state: EngineState) {
        guard let contour = EnvelopeReading.contour(node, in: state) else { return nil }
        let drawn = contour.drawn
        let corners = EnvelopeReading.corners(node, in: state).compactMap { id in drawn.firstIndex { $0.id == id } }
        let stored = state.props(node).envelope.sourceBounds
        let source = Rect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
        guard corners.count == 4 else { return nil }
        self.init(name: name, points: drawn.map { VectorPoint(anchor: $0.anchor, inHandle: $0.inHandle, outHandle: $0.outHandle, kind: $0.kind) },
                  corners: corners, normalizedTo: source)
        guard isValid else { return nil }
    }

    // MARK: Built-in presets

    private static func corner(_ x: Double, _ y: Double) -> VectorPoint { VectorPoint(anchor: Point(x: x, y: y)) }

    private static func smooth(_ x: Double, _ y: Double, dx: Double, dy: Double = 0) -> VectorPoint {
        VectorPoint(anchor: Point(x: x, y: y), inHandle: Vector(dx: -dx, dy: -dy), outHandle: Vector(dx: dx, dy: dy), kind: .curve)
    }

    /// The rectangle every selection starts from.
    public static let rectangle = EnvelopePreset(name: "Rectangle", points: [corner(0, 0), corner(1, 0), corner(1, 1), corner(0, 1)], corners: [0, 1, 2, 3])
    /// The top edge raised into an arch.
    public static let arch = EnvelopePreset(name: "Arch", points: [corner(0, 0), smooth(0.5, -0.3, dx: 0.3), corner(1, 0), corner(1, 1), corner(0, 1)],
                                            corners: [0, 2, 3, 4])
    /// Every edge bowed outward.
    public static let bulge = EnvelopePreset(name: "Bulge", points: [
        corner(0, 0), smooth(0.5, -0.2, dx: 0.3), corner(1, 0), smooth(1.2, 0.5, dx: 0, dy: 0.3),
        corner(1, 1), smooth(0.5, 1.2, dx: -0.3), corner(0, 1), smooth(-0.2, 0.5, dx: 0, dy: -0.3),
    ], corners: [0, 2, 4, 6])
    /// Every edge pinched inward.
    public static let squeeze = EnvelopePreset(name: "Squeeze", points: [
        corner(0, 0), smooth(0.5, 0.2, dx: 0.3), corner(1, 0), smooth(0.8, 0.5, dx: 0, dy: 0.3),
        corner(1, 1), smooth(0.5, 0.8, dx: -0.3), corner(0, 1), smooth(0.2, 0.5, dx: 0, dy: -0.3),
    ], corners: [0, 2, 4, 6])
    /// The top and bottom edges waving like a flag.
    public static let flag = EnvelopePreset(name: "Flag", points: [
        corner(0, 0), smooth(0.33, -0.12, dx: 0.15), smooth(0.67, 0.12, dx: 0.15), corner(1, 0),
        corner(1, 1), smooth(0.67, 1.12, dx: -0.15), smooth(0.33, 0.88, dx: -0.15), corner(0, 1),
    ], corners: [0, 3, 4, 7])

    /// The default preset set (the pop-up before the user saves any).
    public static let defaults: [EnvelopePreset] = [rectangle, arch, bulge, squeeze, flag]

    // MARK: Preferences storage

    /// The preset as one preferences string: `corners|points|name` -- the four corner indices
    /// comma-separated, each point as `x,y,inX,inY,outX,outY,kind` with points separated by
    /// spaces, then the name (which may hold any character).
    public var encoded: String {
        let corners = corners.map(String.init).joined(separator: ",")
        let points = points.map { point in
            [point.anchor.x, point.anchor.y, point.inHandle.dx, point.inHandle.dy, point.outHandle.dx, point.outHandle.dy]
                .map { "\($0)" }.joined(separator: ",") + ",\(point.kind == .curve ? 1 : 0)"
        }.joined(separator: " ")
        return "\(corners)|\(points)|\(name)"
    }

    /// The preset a preferences string holds; nil for a malformed or invalid one.
    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let corners = parts[0].split(separator: ",").compactMap { Int($0) }
        var points: [VectorPoint] = []
        for chunk in parts[1].split(separator: " ") {
            let values = chunk.split(separator: ",").compactMap { Double($0) }
            guard values.count == 7 else { return nil }
            points.append(VectorPoint(anchor: Point(x: values[0], y: values[1]), inHandle: Vector(dx: values[2], dy: values[3]),
                                      outHandle: Vector(dx: values[4], dy: values[5]), kind: values[6] == 1 ? .curve : .corner))
        }
        self.init(name: String(parts[2]), points: points, corners: corners)
        guard isValid else { return nil }
    }

    /// The user's presets from the preferences list; unreadable entries are skipped, and an empty
    /// list reads as the defaults.
    public static func decode(_ list: [String]) -> [EnvelopePreset] {
        let presets = list.compactMap(EnvelopePreset.init(encoded:))
        return presets.isEmpty ? defaults : presets
    }
}

/// Reading an envelope (path-effects.adoc, "Read-time normalizations").
public enum EnvelopeReading {
    /// What the Object panel shows when the envelope cannot warp.
    public static let needsPointsMessage = "Envelope needs four points"

    /// The envelope outline as a path: its live contours in stored order.
    public static func path(_ node: OpID, in state: EngineState) -> VectorPath {
        var props = Wiretuner_Doc_V1_PathProps()
        props.contours = state.props(node).envelope.contours
        return VectorPath(props)
    }

    /// The envelope contour: the first live contour that renders; nil when there is none.
    public static func contour(_ node: OpID, in state: EngineState) -> VectorContour? {
        path(node, in: state).contours.first(where: \.isRenderable)
    }

    /// The TL, TR, BR and BL corner points as element ids of the envelope contour: each stored
    /// corner, a deleted one read as the live point nearest it in stored order (the following one
    /// on a tie); nil where the register is unset, names no point of the contour or the contour
    /// has no live point (WTRender then takes the point nearest that corner of the outline).
    public static func corners(_ node: OpID, in state: EngineState) -> [OpID?] {
        let stored = state.props(node).envelope.corners
        let ids = [stored.tl, stored.tr, stored.br, stored.bl].map { OpID(element: $0) }
        guard let contour = contour(node, in: state) else { return ids.map { _ in nil } }
        let live = Set(contour.points.map(\.id))
        let order = state.store.elementOrder(node, EnvelopeFields.points(contour.id))
        return ids.map { id -> OpID? in
            guard let id else { return nil }
            if live.contains(id) { return id }
            guard let index = order.firstIndex(of: id) else { return nil }
            for distance in 1..<max(order.count, 1) {
                for candidate in [order[(index + distance) % order.count], order[(index - distance % order.count + order.count) % order.count]]
                    where live.contains(candidate) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Whether the envelope draws its contents unwarped for want of points: its contour has fewer
    /// than four live points (the Object panel says `needsPointsMessage`).
    public static func needsPoints(_ node: OpID, in state: EngineState) -> Bool {
        (contour(node, in: state)?.points.count ?? 0) < 4
    }

    /// What the Object panel lists the node as: "Empty envelope" without a live child.
    public static func title(_ node: OpID, in state: EngineState) -> String {
        state.liveChildren(node).isEmpty ? "Empty envelope" : "Envelope"
    }

    /// The outline as a `DisplayPath`, the envelope contour first and any other live contours
    /// after it (drawn with *Show Map*), with the corners as anchor positions of the first.
    static func outline(_ node: OpID, in state: EngineState) -> (path: DisplayPath, corners: [Int?]) {
        let path = path(node, in: state)
        guard let first = path.contours.first(where: \.isRenderable) else { return (DisplayPath(), [nil, nil, nil, nil]) }
        let ordered = VectorPath(contours: [first] + path.contours.filter { $0.id != first.id })
        let drawn = first.drawn
        let corners = corners(node, in: state).map { id in id.flatMap { id in drawn.firstIndex { $0.id == id } } }
        return (DocumentDisplayListBuilder.display(ordered) { _ in true }.path, corners)
    }

    /// `EnvelopeProps` of `node` resolved for WTRender: the outline and source rectangle in the
    /// envelope's space, `transform` (that space → pasteboard) placing them.
    public static func spec(_ node: OpID, transform: AffineTransform = .identity, in state: EngineState) -> EnvelopeSpec {
        let props = state.props(node).envelope
        let outline = outline(node, in: state)
        let source = Rect(x: props.sourceBounds.x, y: props.sourceBounds.y, width: props.sourceBounds.width, height: props.sourceBounds.height)
        return EnvelopeSpec(contour: outline.path, sourceBounds: source, corners: outline.corners, showMap: props.showMap, transform: transform)
    }

    /// menu:Modify[Envelope > Copy as Path]: the envelope's outline as a path node's props (its
    /// contours, and the envelope's transform chain to the pasteboard as its transform), for the
    /// clipboard.  Nil when it has no outline.
    public static func asPath(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_NodeProps? {
        let contours = path(node, in: state).contours.filter(\.isRenderable)
        guard !contours.isEmpty else { return nil }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.contours = contours.map(Subtrees.proto)
        props.path.appearance = Appearances.standard
        let transform = Objects.pasteboardTransform(of: node, in: state)
        if !transform.isIdentity { props.path.common.transform = PathEditing.proto(transform) }
        return props
    }
}

/// Shared by the commands that create an envelope.
enum EnvelopeEditing {
    /// Wraps `members` (stacking order) in a new envelope with `points` (envelope space, drawing
    /// order) as its outline, `source` as its source rectangle and the points at `corners` as
    /// its corners.  The envelope goes at the topmost member's slot, or on top of the active
    /// layer when the members come from several parents; members from another parent keep their
    /// place on the page.
    static func wrap(_ members: [OpID], points: [VectorPoint], corners: [Int], source: Rect, parent: OpID, position: [UInt8],
                     state: EngineState, builder: inout ChangeBuilder) throws {
        let envelope = builder.append(Ops.create(parent: parent, position: position, props: EnvelopeFields.values {
            $0.sourceBounds.x = source.minX
            $0.sourceBounds.y = source.minY
            $0.sourceBounds.width = source.width
            $0.sourceBounds.height = source.height
        }))
        let contour = builder.append(Ops.elementInsert(envelope, EnvelopeFields.contours, positions: try PathEditing.keys(between: nil, and: nil, count: 1),
                                                       values: EnvelopeFields.values { $0.contours = [Wiretuner_Doc_V1_Contour.with { $0.closed = true }] }))
        let first = builder.append(Ops.elementInsert(envelope, EnvelopeFields.points(contour),
                                                     positions: try PathEditing.keys(between: nil, and: nil, count: points.count),
                                                     values: EnvelopeFields.values { $0.contours = [Wiretuner_Doc_V1_Contour.with {
                                                         $0.points = points.map { PathEditing.stored($0, reversed: false) }
                                                     }] }))
        let ids = corners.map { OpID(counter: first.counter + UInt64($0), replica: first.replica).elementID }
        builder.append(Ops.set(envelope, [EnvelopeFields.corners], values: EnvelopeFields.values {
            $0.corners.tl = ids[0]
            $0.corners.tr = ids[1]
            $0.corners.br = ids[2]
            $0.corners.bl = ids[3]
        }))
        let toEnvelope = Objects.pasteboardTransform(ofSpace: parent, in: state)
        let keys = try PathEditing.keys(between: nil, and: nil, count: members.count)
        for (member, key) in zip(members, keys) {
            if let from = Objects.parent(of: member, in: state), from != parent {
                let flattened = Objects.transform(of: member, in: state).concatenating(Objects.pasteboardTransform(ofSpace: from, in: state))
                    .concatenating(toEnvelope.inverse)
                if let op = WrapperEditing.setTransform(member, flattened, in: state) { builder.append(op) }
            }
            builder.append(Ops.move(member, parent: envelope, position: key))
        }
    }

    /// Where a new envelope around `members` goes: the members' shared parent at the topmost
    /// one's slot, else the top of the active layer.
    static func slot(_ members: [OpID], layer: OpID?, state: EngineState, builder: inout ChangeBuilder) throws -> (parent: OpID, position: [UInt8]) {
        let parents = Set(members.compactMap { Objects.parent(of: $0, in: state) })
        if parents.count == 1, let only = parents.first {
            return (only, try Arranging.keys(next: members.last!, above: true, count: 1, in: state)[0])
        }
        let parent = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
        return (parent, try PathEditing.topPosition(in: parent, state: state))
    }

    /// The members' painted bounds in the space of `parent`'s children (the new envelope's):
    /// `given` -- pasteboard bounds the caller measured, the app's scene drawing text -- mapped
    /// into that space (the bounds of its corners), else what a scene without text layout draws
    /// taken into that space, else their geometry bounds mapped.
    static func bounds(_ members: [OpID], given: Rect?, parent: OpID, state: EngineState) -> Rect? {
        let toLocal = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        func local(_ rect: Rect) -> Rect { toLocal.isIdentity ? rect : rect.applying(toLocal) }
        if let given, given.width > 0, given.height > 0 { return local(given) }
        var scene = DocumentDisplayListBuilder(canvas: "envelope")
        let built = scene.rebuild(state)
        let rect = members.compactMap { member in
            built.object(member).flatMap { $0.item.transformed(by: toLocal).bounds } ?? Objects.bounds(of: member, in: state).map(local)
        }.reduce(Rect.null) { $0.union($1) }
        return rect.isNull || rect.width <= 0 || rect.height <= 0 ? nil : rect
    }
}

/// menu:Modify[Envelope > Create] and btn:[Create] on the Envelope toolbar: one `envelope` node
/// around the selected objects (moved in, in stacking order) with `preset`'s outline placed on
/// their bounds, which become the source rectangle.  `bounds` is the selection's painted bounds
/// as the canvas draws it (pasteboard); without it they are measured from a scene without text
/// layout.  Labelled "Create envelope".
public struct CreateEnvelope: Command {
    public var nodes: [OpID]
    public var preset: EnvelopePreset
    public var bounds: Rect?
    public var layer: OpID?

    public init(_ nodes: [OpID], preset: EnvelopePreset = .rectangle, bounds: Rect? = nil, layer: OpID? = nil) {
        self.nodes = nodes
        self.preset = preset
        self.bounds = bounds
        self.layer = layer
    }

    public var label: String { "Create envelope" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard preset.isValid else { throw EnvelopeError.invalidPreset }
        let members = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state)
        guard !members.isEmpty else { throw EnvelopeError.nothingToEnvelope }
        let slot = try EnvelopeEditing.slot(members, layer: layer, state: state, builder: &builder)
        guard let source = EnvelopeEditing.bounds(members, given: bounds, parent: slot.parent, state: state) else { throw EnvelopeError.nothingToEnvelope }
        try EnvelopeEditing.wrap(members, points: preset.points(in: source), corners: preset.corners, source: source, parent: slot.parent,
                                 position: slot.position, state: state, builder: &builder)
    }
}

/// menu:Modify[Envelope > Paste as Envelope]: the copied path's first closed contour (four or
/// more points) becomes the outline of a new envelope around the selected objects, placed where
/// the path was on the page; its corners are the points nearest the corners of the outline's
/// bounds, and the selection's bounds the source rectangle.  Labelled "Paste as envelope".
public struct PasteAsEnvelope: Command {
    public var nodes: [OpID]
    /// The copied path (its contours in its own space; its transform places them on the page).
    public var path: Wiretuner_Doc_V1_PathProps
    public var bounds: Rect?
    public var layer: OpID?

    public init(_ nodes: [OpID], path: Wiretuner_Doc_V1_PathProps, bounds: Rect? = nil, layer: OpID? = nil) {
        self.nodes = nodes
        self.path = path
        self.bounds = bounds
        self.layer = layer
    }

    public var label: String { "Paste as envelope" }

    /// The outline a copied path gives in pasteboard space (drawing order); nil without a closed
    /// contour of four or more points.
    public static func outline(_ path: Wiretuner_Doc_V1_PathProps) -> [VectorPoint]? {
        guard let contour = VectorPath(path).contours.first(where: { $0.closed && $0.points.count >= 4 }) else { return nil }
        let transform = PathEditing.transform(path.common.transform)
        return contour.drawn.map { point in
            VectorPoint(anchor: transform.apply(point.anchor), inHandle: transform.apply(point.inHandle), outHandle: transform.apply(point.outHandle),
                        kind: point.kind)
        }
    }

    /// The points of `points` nearest the TL, TR, BR and BL corners of their bounds, distinct.
    static func corners(_ points: [VectorPoint]) -> [Int] {
        let bounds = Rect(boundingPoints: points.map(\.anchor))
        let targets = [bounds.minPoint, Point(x: bounds.maxX, y: bounds.minY), bounds.maxPoint, Point(x: bounds.minX, y: bounds.maxY)]
        var result: [Int] = []
        for target in targets {
            let pool = points.indices.filter { !result.contains($0) }
            result.append(pool.min { points[$0].anchor.distance(to: target) < points[$1].anchor.distance(to: target) }!)
        }
        return result
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let outline = Self.outline(path), outline.allSatisfy({ $0.anchor.isFinite }) else { throw EnvelopeError.invalidShape }
        let members = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state)
        guard !members.isEmpty else { throw EnvelopeError.nothingToEnvelope }
        let slot = try EnvelopeEditing.slot(members, layer: layer, state: state, builder: &builder)
        guard let source = EnvelopeEditing.bounds(members, given: bounds, parent: slot.parent, state: state) else { throw EnvelopeError.nothingToEnvelope }
        let toLocal = Objects.pasteboardTransform(ofSpace: slot.parent, in: state).inverse
        let points = outline.map { point in
            VectorPoint(anchor: toLocal.apply(point.anchor), inHandle: toLocal.apply(point.inHandle), outHandle: toLocal.apply(point.outHandle), kind: point.kind)
        }
        try EnvelopeEditing.wrap(members, points: points, corners: Self.corners(points), source: source, parent: slot.parent, position: slot.position,
                                 state: state, builder: &builder)
    }
}

/// menu:Modify[Envelope > Show Map]: *Show Map* toggled on each selected envelope -- on for all
/// when any is off.  `show_map` is local-only view state: the change never leaves this Mac.
/// Labelled "Show map" or "Hide map".
public struct ToggleEnvelopeMap: Command {
    public var nodes: [OpID]
    public var show: Bool

    public init(_ nodes: [OpID], in state: EngineState) {
        self.nodes = nodes
        let envelopes = (try? WrapperEditing.wrappers(nodes, .envelope, in: state)) ?? []
        show = envelopes.contains { !state.props($0).envelope.showMap }
    }

    public var label: String { show ? "Show map" : "Hide map" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for envelope in try WrapperEditing.wrappers(nodes, .envelope, in: state) {
            builder.append(Ops.set(envelope, [EnvelopeFields.showMap], values: EnvelopeFields.values { $0.showMap = show }))
        }
    }
}

/// menu:Modify[Envelope > Release]: a group of the warped drawing (plain filled and stroked paths;
/// text as its glyph outlines when `textLayout` draws text) at the envelope's slot, and the
/// envelope deleted *with* its contents inside, so undo or *Restore* brings the live envelope
/// back.  Labelled "Release envelope".
public struct ReleaseEnvelope: Command {
    public var nodes: [OpID]
    /// How the scene lays out text (the document's `TextSceneLayout`; the command then runs on
    /// the main actor); nil leaves text out of the baked drawing.
    public var textLayout: TextSceneLayout?

    public init(_ nodes: [OpID], textLayout: TextSceneLayout? = nil) {
        self.nodes = nodes
        self.textLayout = textLayout
    }

    public var label: String { "Release envelope" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let envelopes = try WrapperEditing.wrappers(nodes, .envelope, in: state)
        guard !envelopes.isEmpty else { return }
        var scene = DocumentDisplayListBuilder(canvas: "release")
        scene.textLayout = textLayout
        let built = scene.rebuild(state)
        for envelope in envelopes {
            let parent = Objects.parent(of: envelope, in: state)!
            let trees = built.object(envelope).map { Baking.trees([$0.item]) } ?? []
            let key = try Arranging.keys(next: envelope, above: true, count: 1, in: state)[0]
            try Baking.createGroup(trees, parent: parent, position: key, state: state, builder: &builder)
            builder.append(Ops.setDeleted(envelope))
        }
    }
}

/// menu:Modify[Envelope > Remove]: the contents move back to the envelope's slot exactly as they
/// were (the envelope's own transform baked in) and the envelope is deleted.  A concurrent edit of
/// the contents lands on the freed objects.  Labelled "Remove envelope".
public struct RemoveEnvelope: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Remove envelope" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for envelope in try WrapperEditing.wrappers(nodes, .envelope, in: state) {
            try WrapperEditing.unwrap(envelope, children: state.liveChildren(envelope), state: state, builder: &builder)
        }
    }
}
