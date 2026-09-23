import struct Foundation.Data
import WTCRDT
import WTProto
import WTRender

/// Resolves colour references on read (applying-color.adoc, "Resolution of a `ColorRef`";
/// tints.adoc, "Resolution of a tint swatch's color"; COLOR-006's WTModel half):
///
/// * `none` (and an unset reference) → no paint;
/// * `inline` → the colour, by the read-time rules of `ColorValues`;
/// * `swatch` → the live swatch's resolved colour, else the reference's `cached` colour, else
///   black;
/// * `tint` → the base resolved the same way, mixed toward white by `percent`.
///
/// A tint swatch resolves its base first (chains multiply their percentages); a dangling link
/// reads the link's `cached` base colour, then black; a loop (only reachable through concurrent
/// re-basing) is cut at the link whose tint node has the smallest node id, which reads its
/// `cached` base.  A resolved colour from a spot swatch, or a tint of one, carries the ink on
/// `Color.spot` (named by the base swatch); Registration resolves to `Color.registration`.
///
/// The resolver reads the swatches under the well-known `swatches` node (0:5) once; build a new
/// one after a change touching them.
public struct ColorResolver: Sendable {
    /// One swatch node as read.
    struct Entry: Sendable {
        var props: Wiretuner_Doc_V1_SwatchProps
        /// Live after the role normalization (a deleted protected swatch reads as live).
        var live: Bool
        /// The role after the duplicate-role normalization.
        var role: Wiretuner_Doc_V1_SwatchRole
    }

    /// How a swatch's colour was reached.
    public struct Chain: Hashable, Sendable {
        /// The non-tint swatch at the end, or nil when the chain ended at a dangling link or a cut.
        public var base: OpID?
        /// The product of the chain's tint percentages, 0...1 (1 for a non-tint).
        public var amount: Double
        /// The tint links walked (0 for a non-tint).
        public var depth: Int
        /// The chain ended at a parent that is not a live swatch.
        public var dangling: Bool
        /// The chain ended at a loop's cut.
        public var cut: Bool
    }

    let entries: [OpID: Entry]
    /// Every swatch node under 0:5, in sibling order (deleted ones included).
    let order: [OpID]

    public init(_ state: EngineState) {
        var entries: [OpID: Entry] = [:]
        var order: [OpID] = []
        var roles: [Wiretuner_Doc_V1_SwatchRole: OpID] = [:]
        for child in state.store.children(SwatchFields.collection) where state.store.kind(child) == SwatchFields.kind {
            let props = state.props(child).swatch
            order.append(child)
            entries[child] = Entry(props: props, live: state.isLive(child), role: .unspecified)
            if props.role != .unspecified, SwatchFields.roles.contains(props.role), roles[props.role].map({ child < $0 }) ?? true {
                roles[props.role] = child
            }
        }
        for (role, id) in roles {
            entries[id]?.role = role
            entries[id]?.live = true
        }
        self.entries = entries
        self.order = order
    }

    /// Whether `id` is a live swatch.
    public func isSwatch(_ id: OpID) -> Bool {
        entries[id]?.live == true
    }

    /// The stored props of the swatch node `id` (live or deleted).
    public func props(_ id: OpID) -> Wiretuner_Doc_V1_SwatchProps? {
        entries[id]?.props
    }

    /// The protected role of `id` after normalization, or nil for an ordinary swatch.
    public func role(_ id: OpID) -> Wiretuner_Doc_V1_SwatchRole? {
        guard let role = entries[id]?.role, role != .unspecified else { return nil }
        return role
    }

    /// The protected swatch of `role`, if the document has one.
    public func swatch(role: Wiretuner_Doc_V1_SwatchRole) -> OpID? {
        entries.first { $0.value.role == role && role != .unspecified }?.key
    }

    /// A tint strength as read: unset or zero is 100%, clamped to 1...100.
    public static func percent(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return 100 }
        return min(max(value, 1), 100)
    }

    /// The chain of the live swatch `id`.
    public func chain(_ id: OpID) -> Chain {
        walk(id).chain
    }

    /// Walks the tint chain from `id`: the chain, the colour at its end before tinting.
    private func walk(_ id: OpID) -> (chain: Chain, end: Color) {
        var path: [OpID] = [id]
        var seen: [OpID: Int] = [id: 0]
        var amount = 1.0
        var current = id
        while let entry = entries[current], entry.props.hasParent {
            amount *= Self.percent(entry.props.tintPercent) / 100
            let parent = OpID(entry.props.parent.id)
            guard isSwatch(parent) else {
                let cached = ColorValues.cachedColor(entry.props.parent.cached) ?? .black
                return (Chain(base: nil, amount: amount, depth: path.count, dangling: true, cut: false), cached)
            }
            if let start = seen[parent] {
                // A loop: cut at the smallest tint node of the cycle, which reads its cached base.
                let cut = path[start...].min()!
                let at = path.firstIndex(of: cut)!
                var amount = 1.0
                for node in path[...at] {
                    amount *= Self.percent(entries[node]!.props.tintPercent) / 100
                }
                let cached = ColorValues.cachedColor(entries[cut]!.props.parent.cached) ?? .black
                return (Chain(base: nil, amount: amount, depth: at + 1, dangling: false, cut: true), cached)
            }
            seen[parent] = path.count
            path.append(parent)
            current = parent
        }
        return (Chain(base: current, amount: amount, depth: path.count - 1, dangling: false, cut: false), baseColor(current))
    }

    /// The colour of a non-tint swatch, with its ink when it is spot or Registration.
    private func baseColor(_ id: OpID) -> Color {
        guard let entry = entries[id] else { return .black }
        switch entry.role {
        case .registration:
            return .registration
        case .unspecified where entry.props.spot:
            return ColorValues.color(entry.props.value).asSpot(SpotInk(swatch: NodeID(id), name: entry.props.common.name))
        default:
            return ColorValues.color(entry.props.value)
        }
    }

    /// The resolved colour of the live swatch `id` (a tint's computed colour), or nil when `id`
    /// is not a live swatch.
    public func color(ofSwatch id: OpID) -> Color? {
        guard isSwatch(id) else { return nil }
        let (chain, end) = walk(id)
        return chain.depth == 0 ? end : end.tinted(chain.amount)
    }

    /// The colour `ref` resolves to; nil for *None* (and an unset reference).
    public func color(_ ref: Wiretuner_Doc_V1_ColorRef) -> Color? {
        switch ref.ref {
        case .none?, nil:
            return nil
        case .inline(let stored)?:
            return ColorValues.color(stored)
        case .swatch(let swatch)?:
            return color(ofSwatch: OpID(swatch.id)) ?? ColorValues.cachedColor(swatch.cached) ?? .black
        case .tint(let tint)?:
            let base = color(ofSwatch: OpID(tint.base.id)) ?? ColorValues.cachedColor(tint.base.cached) ?? .black
            return base.tinted(Self.percent(tint.percent) / 100)
        }
    }

    /// Whether `ref` reads through its cache: a swatch or tint reference whose swatch is not live
    /// (the Object panel's *Restore "<name>"* case).
    public func isDangling(_ ref: Wiretuner_Doc_V1_ColorRef) -> Bool {
        switch ref.ref {
        case .swatch(let swatch)?: return !isSwatch(OpID(swatch.id))
        case .tint(let tint)?: return !isSwatch(OpID(tint.base.id))
        default: return false
        }
    }

    /// The swatch `ref` names (the swatch, or an unnamed tint's base), live or not.
    public static func swatch(of ref: Wiretuner_Doc_V1_ColorRef) -> OpID? {
        switch ref.ref {
        case .swatch(let swatch)?: return OpID(swatch.id)
        case .tint(let tint)?: return OpID(tint.base.id)
        default: return nil
        }
    }

    // MARK: Writing references

    /// A `NodeRef` to the swatch `id` with its resolved colour cached.
    public func nodeRef(_ id: OpID) -> Wiretuner_Doc_V1_NodeRef {
        var ref = Wiretuner_Doc_V1_NodeRef()
        ref.id = id.proto
        if let color = color(ofSwatch: id) {
            ref.cached = ColorValues.cached(color)
        }
        return ref
    }

    /// A reference to the swatch `id`, its colour cached (the cache is written with every
    /// reference and never updated afterwards).
    public func reference(to id: OpID) -> Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.swatch = nodeRef(id)
        return ref
    }

    /// An unnamed tint of the swatch `base` at `percent` (1...100), the base's colour cached.
    public func tint(of base: OpID, percent: Double) -> Wiretuner_Doc_V1_ColorRef {
        var tint = Wiretuner_Doc_V1_InlineTint()
        tint.base = nodeRef(base)
        tint.percent = Self.percent(percent)
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.tint = tint
        return ref
    }

    /// An unnamed colour.
    public static func inline(_ color: Color) -> Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.inline = ColorValues.stored(color)
        return ref
    }

    /// *None*.
    public static var none: Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.none = true
        return ref
    }
}
