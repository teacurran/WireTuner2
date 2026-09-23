import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// FX-024: blend commands (docs/_includes/effects/blends.adoc, "Blending from the menu", "Joining a
// blend to a path", "Releasing a blend", "Merge semantics", "Undo").  A blend is a `blend` node
// (kind 100) whose live children are the key objects in blend order (bottom first) plus, when
// joined, the path; the steps are never stored.

/// Register paths of `BlendProps` (blend.proto).
public enum BlendFields {
    public static let kind = WrapperKind.blend.rawValue
    public static let steps = RegisterPath([100, 2])
    public static let rangeFirst = RegisterPath([100, 3])
    public static let rangeLast = RegisterPath([100, 4])
    public static let type = RegisterPath([100, 5])
    public static let order = RegisterPath([100, 6])
    public static let path = RegisterPath([100, 7])
    public static let showPath = RegisterPath([100, 8])
    public static let rotateOnPath = RegisterPath([100, 9])
    public static let blendPoints = RegisterPath([100, 10])

    static func values(_ props: Wiretuner_Doc_V1_BlendProps) -> Wiretuner_Doc_V1_NodeProps {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.blend = props
        return values
    }
}

/// The eligibility rules of blends.adoc, "What can be blended": refusals carry the sentence the
/// user sees.
public enum BlendEligibility {
    public static let tooFew = "Select two or more objects to blend."
    public static let bitmaps = "Bitmaps cannot be blended."
    public static let text = "Convert text to paths before blending it."
    public static let groupContents = "Groups can be blended only when they hold simple paths."
    public static let composites = "Composite paths blend only with composite paths."
    public static let unsupported = "Only paths, shapes and groups of paths can be blended."

    /// The reason `nodes` (in blend order) cannot be blended, or nil when they can.
    public static func refusal(_ nodes: [OpID], in state: EngineState) -> String? {
        guard nodes.count >= 2 else { return tooFew }
        for node in nodes {
            if let reason = refusal(node, in: state) { return reason }
        }
        for (a, b) in zip(nodes, nodes.dropFirst()) {
            if let reason = pairRefusal(a, b, in: state) { return reason }
        }
        return nil
    }

    /// Why one object cannot be a key object.
    static func refusal(_ node: OpID, in state: EngineState) -> String? {
        switch state.store.kind(node) {
        case 170, 171: return bitmaps
        case 130: return text
        default: break
        }
        switch state.nodeKind(node) {
        case .path?, .rect?, .ellipse?, .polygon?:
            return nil
        case .group?:
            guard !state.props(node).group.hasClipPath else { return groupContents }
            let members = state.liveChildren(node)
            let simple = members.allSatisfy { member in
                switch state.nodeKind(member) {
                case .path?: return state.props(member).path.contours.count <= 1
                case .rect?, .ellipse?, .polygon?: return true
                default: return false
                }
            }
            return simple && !members.isEmpty ? nil : groupContents
        default:
            return unsupported
        }
    }

    /// Why two neighbours cannot blend: composite with non-composite, or incompatible fill or
    /// stroke kinds (Basic and Gradient fills blend with each other; any other kind only with
    /// itself).
    static func pairRefusal(_ a: OpID, _ b: OpID, in state: EngineState) -> String? {
        if isComposite(a, in: state) != isComposite(b, in: state) { return composites }
        let fills = (fillFamily(a, in: state), fillFamily(b, in: state))
        if let first = fills.0, let second = fills.1, first != second {
            return "A \(AttributeNames.fillKind(first).lowercased()) fill blends only with the same kind of fill."
        }
        let strokes = (strokeKind(a, in: state), strokeKind(b, in: state))
        if let first = strokes.0, let second = strokes.1, first != second {
            return "A \(AttributeNames.strokeKind(first).lowercased()) stroke blends only with the same kind of stroke."
        }
        return nil
    }

    static func isComposite(_ node: OpID, in state: EngineState) -> Bool {
        state.nodeKind(node) == .path && state.props(node).path.contours.count > 1
    }

    /// The topmost visible fill's kind with Gradient (and an unset or unknown kind) read as
    /// Basic -- the two blend together; nil without a fill.  A group reads its first member's.
    static func fillFamily(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_FillKind? {
        topmost(node, .fills, in: state).map { entry in
            switch entry.fill.settings.kind {
            case .lens, .custom, .pattern, .textured, .tiled: entry.fill.settings.kind
            default: .basic
            }
        }
    }

    /// The topmost visible stroke's kind (unset or unknown read as Basic); nil without a stroke.
    static func strokeKind(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_StrokeKind? {
        topmost(node, .strokes, in: state).map { entry in
            switch entry.stroke.settings.kind {
            case .brush, .calligraphic, .custom, .pattern: entry.stroke.settings.kind
            default: .basic
            }
        }
    }

    /// The topmost visible row of `list` of the object (a group: of its first member).
    static func topmost(_ node: OpID, _ list: AppearanceList, in state: EngineState) -> AttributeEntry? {
        let target = state.nodeKind(node) == .group ? state.liveChildren(node).first ?? node : node
        return AppearanceEditing.entries(target, in: state).last { $0.row.list == list && !$0.hidden }
    }
}

/// A key object's blend point for point-to-point blends and the blend point handles.
public struct BlendPointChoice: Hashable, Sendable {
    public var contour: OpID
    public var point: OpID

    public init(contour: OpID, point: OpID) {
        self.contour = contour
        self.point = point
    }
}

enum BlendEditing {
    /// The `ElementInsert` of blend point elements (object, contour, point) at the end of
    /// `blend`'s sequence, after `after` (the last position so far).
    static func insertPoints(_ points: [(object: OpID, choice: BlendPointChoice)], blend: OpID, after: [UInt8]?,
                             builder: inout ChangeBuilder) throws {
        guard !points.isEmpty else { return }
        var props = Wiretuner_Doc_V1_BlendProps()
        props.blendPoints = points.map { entry in
            var point = Wiretuner_Doc_V1_BlendPoint()
            point.object = entry.object.proto
            point.contour = entry.choice.contour.elementID
            point.point = entry.choice.point.elementID
            return point
        }
        let keys = try PathEditing.keys(between: after, and: nil, count: points.count)
        builder.append(Ops.elementInsert(blend, BlendFields.blendPoints, positions: keys, values: BlendFields.values(props)))
    }
}

/// menu:Modify[Combine > Blend], the Operations toolbar's btn:[Blend] and the Blend tool's drag
/// (blends.adoc): a `blend` node at the topmost object's slot -- or on top of the active layer
/// when they come from several parents -- with the objects moved in in stacking order (the bottom
/// one is the start), default steps (0: computed from the colour difference), the whole range
/// and *Rotate on path*.  With `points` (a point selected on each object) the blend is point to
/// point: those points become the blend points in the same change.  Refused with the reason when
/// the objects cannot be blended.  Labelled "Blend".
public struct Blend: Command {
    public var nodes: [OpID]
    public var points: [OpID: BlendPointChoice]
    public var layer: OpID?

    public init(_ nodes: [OpID], points: [OpID: BlendPointChoice] = [:], layer: OpID? = nil) {
        self.nodes = nodes
        self.points = points
        self.layer = layer
    }

    public var label: String { "Blend" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let members = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state)
        if let reason = BlendEligibility.refusal(members, in: state) { throw WrapperError.notBlendable(reason) }
        let parents = Set(members.compactMap { Objects.parent(of: $0, in: state) })
        let parent: OpID
        let position: [UInt8]
        if parents.count == 1, let only = parents.first {
            parent = only
            position = try Arranging.keys(next: members.last!, above: true, count: 1, in: state)[0]
        } else {
            parent = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
            position = try PathEditing.topPosition(in: parent, state: state)
        }
        var props = Wiretuner_Doc_V1_BlendProps()
        props.rangeLast = 100
        props.rotateOnPath = true
        let blend = builder.append(Ops.create(parent: parent, position: position, props: BlendFields.values(props)))
        let toBlend = Objects.pasteboardTransform(ofSpace: parent, in: state)
        let keys = try PathEditing.keys(between: nil, and: nil, count: members.count)
        for (member, key) in zip(members, keys) {
            // From another parent: keep the member where it is on the page.
            if let from = Objects.parent(of: member, in: state), from != parent {
                let flattened = Objects.transform(of: member, in: state).concatenating(Objects.pasteboardTransform(ofSpace: from, in: state))
                    .concatenating(toBlend.inverse)
                if let op = WrapperEditing.setTransform(member, flattened, in: state) { builder.append(op) }
            }
            builder.append(Ops.move(member, parent: blend, position: key))
        }
        let chosen = members.compactMap { member in points[member].map { (object: member, choice: $0) } }
        try BlendEditing.insertPoints(chosen, blend: blend, after: nil, builder: &builder)
    }
}

/// The Blend tool's drag from a member to another object (blends.adoc, "To add an object to a
/// blend"): the object moves into the blend at the end, becoming the last key object.  Refused
/// with the reason when it cannot blend with the current last key object.  Labelled "Add to
/// blend".
public struct AddToBlend: Command {
    public var blend: OpID
    public var node: OpID

    public init(_ blend: OpID, _ node: OpID) {
        self.blend = blend
        self.node = node
    }

    public var label: String { "Add to blend" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let blend = try WrapperEditing.wrapper(self.blend, .blend, in: state)
        guard Objects.isObject(node, in: state), !Objects.isEffectivelyLocked(node, in: state) else { throw ObjectEditError.notAnObject(node) }
        if let reason = BlendEligibility.refusal(node, in: state) { throw WrapperError.notBlendable(reason) }
        if let last = BlendReading.keyObjects(blend, in: state).last, let reason = BlendEligibility.pairRefusal(last, node, in: state) {
            throw WrapperError.notBlendable(reason)
        }
        if let from = Objects.parent(of: node, in: state), from != blend {
            let flattened = Objects.transform(of: node, in: state).concatenating(Objects.pasteboardTransform(ofSpace: from, in: state))
                .concatenating(Objects.pasteboardTransform(ofSpace: blend, in: state).inverse)
            if let op = WrapperEditing.setTransform(node, flattened, in: state) { builder.append(op) }
        }
        builder.append(Ops.move(node, parent: blend, position: try PathEditing.topPosition(in: blend, state: state)))
    }
}

/// Dragging a blend point (blends.adoc, "To change where the blend starts"): every blend point
/// element naming the object is deleted and one naming `choice` inserted, so concurrent settings
/// leave one harmless extra that this write clears.  Labelled "Move blend point".
public struct SetBlendPoint: Command {
    public var blend: OpID
    public var object: OpID
    public var choice: BlendPointChoice

    public init(_ blend: OpID, object: OpID, choice: BlendPointChoice) {
        self.blend = blend
        self.object = object
        self.choice = choice
    }

    public var label: String { "Move blend point" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let blend = try WrapperEditing.wrapper(self.blend, .blend, in: state)
        guard BlendReading.keyObjects(blend, in: state).contains(object) else { throw ObjectEditError.notAnObject(object) }
        let elements = state.liveElements(blend, BlendFields.blendPoints)
        let stale = state.props(blend).blend.blendPoints.filter { $0.hasObject && OpID($0.object) == object }.compactMap { OpID(element: $0.id) }
        if !stale.isEmpty { builder.append(Ops.elementDelete(blend, stale.map { BlendFields.blendPoints.element($0) })) }
        let last = elements.last.flatMap { state.position(blend, BlendFields.blendPoints, $0) }
        try BlendEditing.insertPoints([(object, choice)], blend: blend, after: last, builder: &builder)
    }
}

/// Any blend option of the Object panel (*Steps*, *Range*, *Blend type*, *Blend order*, *Show
/// path*, *Rotate on path*): the registers at `fields` (`BlendFields`) of each blend from `props`.
public struct EditBlend: Command {
    public var nodes: [OpID]
    public var fields: [RegisterPath]
    public var props: Wiretuner_Doc_V1_BlendProps
    public var label: String

    public init(_ nodes: [OpID], label: String, fields: [RegisterPath], _ build: (inout Wiretuner_Doc_V1_BlendProps) -> Void) {
        self.nodes = nodes
        self.label = label
        self.fields = fields
        var props = Wiretuner_Doc_V1_BlendProps()
        build(&props)
        self.props = props
    }

    /// *Steps*, 1 ... 1000.
    public static func steps(_ nodes: [OpID], _ steps: Int) -> EditBlend {
        EditBlend(nodes, label: "Change steps", fields: [BlendFields.steps]) { $0.steps = UInt32(clamping: steps) }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if fields.contains(BlendFields.steps), !(1...1000).contains(props.steps) { throw ObjectEditError.invalidValue("steps") }
        for field in [BlendFields.rangeFirst, BlendFields.rangeLast] where fields.contains(field) {
            let value = field == BlendFields.rangeFirst ? props.rangeFirst : props.rangeLast
            guard (0...100).contains(value) else { throw ObjectEditError.invalidValue("range") }
        }
        guard !fields.contains(BlendFields.blendPoints), !fields.contains(BlendFields.path) else { throw ObjectEditError.invalidValue("fields") }
        for blend in try WrapperEditing.wrappers(nodes, .blend, in: state) {
            builder.append(Ops.set(blend, fields, values: BlendFields.values(props)))
        }
    }
}

/// menu:Modify[Combine > Join Blend to Path] and the Blend tool's kbd:[Option]-drag: the path
/// moves into the blend (kept where it is on the page) and becomes its `path`, with *Rotate on
/// path* on.  Labelled "Join blend to path".
public struct JoinBlendToPath: Command {
    public var blend: OpID
    public var path: OpID

    public init(_ blend: OpID, path: OpID) {
        self.blend = blend
        self.path = path
    }

    public var label: String { "Join blend to path" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let blend = try WrapperEditing.wrapper(self.blend, .blend, in: state)
        guard state.isLive(path), state.nodeKind(path) == .path, !Objects.isEffectivelyLocked(path, in: state) else { throw PathEditError.notAPath(path) }
        if let from = Objects.parent(of: path, in: state), from != blend {
            let flattened = Objects.transform(of: path, in: state).concatenating(Objects.pasteboardTransform(ofSpace: from, in: state))
                .concatenating(Objects.pasteboardTransform(ofSpace: blend, in: state).inverse)
            if let op = WrapperEditing.setTransform(path, flattened, in: state) { builder.append(op) }
            builder.append(Ops.move(path, parent: blend, position: try PathEditing.topPosition(in: blend, state: state)))
        }
        var props = Wiretuner_Doc_V1_BlendProps()
        props.path.id = path.proto
        props.rotateOnPath = true
        builder.append(Ops.set(blend, [BlendFields.path, BlendFields.rotateOnPath], values: BlendFields.values(props)))
    }
}

/// menu:Modify[Split] on a joined blend: the path moves out directly above the blend, intact, and
/// `path` is cleared.  Labelled "Split".
public struct SplitBlend: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Split" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for blend in try WrapperEditing.wrappers(nodes, .blend, in: state) {
            guard let path = BlendReading.path(state.props(blend).blend, children: state.liveChildren(blend), in: state),
                  let parent = Objects.parent(of: blend, in: state) else { continue }
            let outer = WrapperEditing.transform(blend, in: state)
            if !outer.isIdentity, let op = WrapperEditing.setTransform(path, Objects.transform(of: path, in: state).concatenating(outer), in: state) {
                builder.append(op)
            }
            builder.append(Ops.move(path, parent: parent, position: try Arranging.keys(next: blend, above: true, count: 1, in: state)[0]))
            builder.append(Ops.set(blend, [BlendFields.path], values: BlendFields.values(Wiretuner_Doc_V1_BlendProps())))
        }
    }
}

/// menu:Modify[Ungroup] on a blend (release, blends.adoc "Releasing a blend"): the key objects and
/// the path move out to the blend's slot, and between each pair of key objects a group of that
/// span's steps, baked as plain paths from what the blend draws now; the blend node is deleted.
/// A concurrent edit to a key object lands on the freed object (the baked steps do not follow
/// it); undo brings the live blend back.  Labelled "Ungroup".
public struct ReleaseBlend: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Ungroup" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let blends = try WrapperEditing.wrappers(nodes, .blend, in: state)
        guard !blends.isEmpty else { return }
        var scene = DocumentDisplayListBuilder(canvas: "release")
        let built = scene.rebuild(state)
        for blend in blends {
            let parent = Objects.parent(of: blend, in: state)!
            let children = state.liveChildren(blend)
            let path = BlendReading.path(state.props(blend).blend, children: children, in: state)
            let keys = children.filter { $0 != path }
            let spans = built.object(blend).map { BlendBaking.steps(of: $0, keys: keys, path: path, built: built) } ?? []
            // Bottom to top: key 0, span 1, key 1, span 2 ... then the path on top.
            var order: [Either] = []
            for (index, key) in keys.enumerated() {
                if index > 0, index - 1 < spans.count, !spans[index - 1].isEmpty { order.append(.steps(spans[index - 1])) }
                order.append(.node(key))
            }
            if let path { order.append(.node(path)) }
            let outer = WrapperEditing.transform(blend, in: state)
            let positions = try Arranging.keys(next: blend, above: true, count: order.count, in: state)
            for (entry, position) in zip(order, positions) {
                switch entry {
                case .node(let child):
                    if !outer.isIdentity, let op = WrapperEditing.setTransform(child, Objects.transform(of: child, in: state).concatenating(outer), in: state) {
                        builder.append(op)
                    }
                    builder.append(Ops.move(child, parent: parent, position: position))
                case .steps(let trees):
                    try Baking.createGroup(trees, parent: parent, position: position, state: state, builder: &builder)
                }
            }
            builder.append(Ops.setDeleted(blend))
        }
    }

    private enum Either {
        case node(OpID)
        case steps([NodeTree])
    }
}

/// Separating a blend's baked drawing into its spans of steps.  The flattener expands the whole
/// blend -- key objects and steps, in drawing order: the path (when shown), key 0, the steps of
/// span 1, key 1, ... -- so each key object's share is measured by expanding it alone and each
/// span's by expanding a one-step blend of its two ends; the number of steps is what remains.
/// When the shares do not add up (a key object the interpolation skips) no steps are baked.
enum BlendBaking {
    static func steps(of blend: SceneObject, keys: [OpID], path: OpID?, built: DocumentScene) -> [[NodeTree]] {
        guard case .group(let group) = blend.item, case .blend(let spec) = group.live else { return [] }
        func child(_ id: OpID?) -> (index: Int, item: DisplayItem)? {
            guard let id, let object = built.object(id), Array(object.itemPath.dropLast()) == blend.itemPath, let index = object.itemPath.last,
                  group.children.indices.contains(index) else { return nil }
            return (index, group.children[index])
        }
        // Key objects that draw nothing are not children of the drawing.
        let placed = keys.compactMap(child)
        guard placed.count >= 2 else { return [] }
        let all = flat([blend.item])
        let keyCounts = placed.map { flat([$0.item]).count }
        let pathChild = child(path)
        let pathCount = pathChild.flatMap { spec.showPath ? flat([$0.item]).count : nil } ?? 0
        var perStep: [Int] = []
        for index in 1..<placed.count {
            let (a, b) = (placed[index - 1], placed[index])
            let points = spec.blendPoints.compactMap { point -> BlendPoint? in
                if point.child == a.index { return BlendPoint(child: 0, contour: point.contour, anchor: point.anchor) }
                if point.child == b.index { return BlendPoint(child: 1, contour: point.contour, anchor: point.anchor) }
                return nil
            }
            let one = BlendSpec(steps: 1, rangeFirst: 0, rangeLast: 100, type: spec.type, order: spec.order, blendPoints: points)
            perStep.append(flat([.group(GroupItem(children: [a.item, b.item], live: .blend(one)))]).count - keyCounts[index - 1] - keyCounts[index])
        }
        let stepNodes = all.count - pathCount - keyCounts.reduce(0, +)
        let unit = perStep.reduce(0, +)
        guard unit > 0, stepNodes > 0, stepNodes % unit == 0 else { return [] }
        let count = stepNodes / unit
        var index = pathCount + keyCounts[0]
        var spans: [[NodeTree]] = []
        for (span, size) in perStep.enumerated() {
            spans.append(all[index..<(index + size * count)].flatMap(Baking.tree))
            index += size * count + keyCounts[span + 1]
        }
        return spans
    }

    /// `items` expanded to flat nodes.
    static func flat(_ items: [DisplayItem]) -> [FlatNode] {
        let bounds = items.compactMap(\.bounds).reduce(Rect.null) { $0.union($1) }
        guard !bounds.isNull else { return [] }
        let page = ExportPage(bounds: bounds.expanded(by: 2), displayList: DisplayList(canvas: "bake", items: items))
        return Flattener(target: [.transparency, .gradients, .strokes]).flatten(page, scene: ExportScene(pages: [page])).page.nodes
    }
}
