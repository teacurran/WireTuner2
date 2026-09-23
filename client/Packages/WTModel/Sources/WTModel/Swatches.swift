import Foundation
import WTCRDT
import WTProto
import WTRender

/// The `swatch` node kind's registers (`NodeProps.swatch` = 70, `SwatchProps`; swatches.adoc).
public enum SwatchFields {
    /// The well-known `swatches` collection (0:5) every swatch sits under.
    public static let collection = OpID.wellKnown(5)
    /// `NodeProps.swatch`.
    public static let kind: UInt32 = 70
    public static let name = RegisterPath([70, 1, 1])
    public static let value = RegisterPath([70, 2])
    public static let spot = RegisterPath([70, 3])
    public static let parent = RegisterPath([70, 4])
    public static let tintPercent = RegisterPath([70, 5])
    public static let role = RegisterPath([70, 6])
    public static let group = RegisterPath([70, 7])
    public static let library = RegisterPath([70, 8])
    public static let libraryKey = RegisterPath([70, 9])

    /// The protected roles, in the order the document template creates them.
    public static let roles: [Wiretuner_Doc_V1_SwatchRole] = [.white, .black, .registration]

    /// A sparse `NodeProps` holding the swatch values `build` sets.
    public static func values(_ build: (inout Wiretuner_Doc_V1_SwatchProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var swatch = Wiretuner_Doc_V1_SwatchProps()
        build(&swatch)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.swatch = swatch
        return props
    }

    /// The longest name a swatch stores (`CommonProps.name`).
    public static let maxName = 256
    /// The longest group, library and key a swatch stores.
    public static let maxLabel = 128
}

/// One swatch as the Swatches panel lists it (swatches.adoc; COLOR-003): the stored props and
/// everything read from them -- the display name (a tint's derived name, the duplicate-name
/// suffix), the resolved colour, the effective spot flag and role, the tint's base state.
public struct Swatch: Identifiable, Hashable, Sendable {
    public let id: OpID
    /// The stored props, as merged.
    public let props: Wiretuner_Doc_V1_SwatchProps
    /// The name the panel shows: the stored name, a tint's derived `40% Grape` when it has
    /// none, and ` (2)`, ` (3)` ... on the later-created of duplicate names.
    public let name: String
    /// `name` without the duplicate suffix: what lookups and uniqueness checks compare.
    public let plainName: String
    /// The protected role after the read-time normalizations, nil for an ordinary swatch.
    public let role: Wiretuner_Doc_V1_SwatchRole?
    /// The resolved colour (a tint's computed colour), with its ink when spot.
    public let color: Color
    /// Spot as the panel shows it (upright name): a tint's is its base's; Black and
    /// Registration are spot and White process regardless of the register.
    public let isSpot: Bool
    /// A tint's base (its `parent`), live or not; nil for a colour.
    public let base: OpID?
    /// The tint strength as read (1...100; 100 for a colour).
    public let tintPercent: Double
    /// A tint whose base is not a live swatch: it renders from the cache (the "base color
    /// removed" badge).
    public let baseRemoved: Bool
    /// Indentation in the list: 0 for a colour, 1 for a tint under it, and so on.
    public let depth: Int
    /// The group header the swatch is listed under (a tint's is its listed base's).
    public let section: String
    /// Whether the stored name is the default name of the stored colour (so a redefinition
    /// renames it when *Auto-rename colors* is on).
    public let hasDefaultName: Bool

    public var isProtected: Bool { role != nil }
    public var isTint: Bool { base != nil }
    /// The space badge (RGB, P3, Lab, OKLab; none for CMYK).
    public var badge: String? { ColorValues.badge(color.space) }
    /// The stored colour of a non-tint swatch.
    public var value: Color { ColorValues.color(props.value) }
    public var group: String { props.group }
    public var library: String { props.library }
    public var libraryKey: String { props.libraryKey }
}

/// The document's colour list as read (swatches.adoc, "Read-time normalizations"; COLOR-004's
/// ordering rule): the protected defaults first (White, Black, Registration), then every other
/// swatch in sibling order with each colour's tints listed under it, depth first.  A tint whose
/// base is not a live swatch, or whose link was cut from a loop, is listed where it stands.
/// Duplicate names show a ` (2)` suffix on the later-created swatch and resolve to the smallest
/// node id; a deleted protected swatch reads as live; of two swatches with one role, the
/// smaller id keeps it.
public struct SwatchList: Sendable {
    /// Every live swatch in panel order.
    public let swatches: [Swatch]
    /// The resolver the list was read with.
    public let resolver: ColorResolver
    private let positions: [OpID: Int]
    /// Plain names to the swatches holding them, ascending node id.
    private let names: [String: [OpID]]

    /// A group header and the swatches listed under it.
    public struct Section: Hashable, Sendable {
        /// The group name; empty for the ungrouped list (which holds the defaults).
        public let group: String
        public let swatches: [Swatch]
    }

    public init(_ state: EngineState) {
        self.init(ColorResolver(state))
    }

    public init(_ resolver: ColorResolver) {
        self.resolver = resolver
        let live = resolver.order.filter(resolver.isSwatch)
        // The tint tree: a tint is listed under its parent when that is live and the link is
        // not a loop's cut.
        var parentOf: [OpID: OpID] = [:]
        var tints: [OpID: [OpID]] = [:]
        for id in live {
            guard let props = resolver.props(id), props.hasParent, resolver.role(id) == nil else { continue }
            let parent = OpID(props.parent.id)
            if resolver.isSwatch(parent), !Self.loops(from: id, via: parent, resolver) {
                parentOf[id] = parent
                tints[parent, default: []].append(id)
            }
        }
        let defaults = SwatchFields.roles.compactMap { resolver.swatch(role: $0) }
        let roots = defaults + live.filter { parentOf[$0] == nil && resolver.role($0) == nil }
        var ordered: [(id: OpID, depth: Int, section: String)] = []
        func visit(_ id: OpID, depth: Int, section: String) {
            ordered.append((id, depth, section))
            for tint in tints[id] ?? [] {
                visit(tint, depth: depth + 1, section: section)
            }
        }
        for root in roots {
            visit(root, depth: 0, section: resolver.role(root) == nil ? String(resolver.props(root)!.group.prefix(SwatchFields.maxLabel)) : "")
        }
        // Names: stored, else derived (a tint) or the default name (a colour).
        var plain: [OpID: String] = [:]
        func plainName(_ id: OpID, _ seen: Set<OpID> = []) -> String {
            if let name = plain[id] { return name }
            let props = resolver.props(id)!
            var name = props.common.name
            if name.isEmpty {
                if props.hasParent {
                    let parent = OpID(props.parent.id)
                    let baseName = resolver.props(parent) != nil && !seen.contains(parent) ? plainName(parent, seen.union([id])) : "Removed Color"
                    name = ColorText.tintName(percent: ColorResolver.percent(props.tintPercent), base: baseName)
                } else {
                    name = ColorText.defaultName(ColorValues.color(props.value))
                }
            }
            plain[id] = name
            return name
        }
        var names: [String: [OpID]] = [:]
        for entry in ordered {
            names[plainName(entry.id), default: []].append(entry.id)
        }
        for key in names.keys {
            names[key]!.sort()
        }
        var swatches: [Swatch] = []
        var positions: [OpID: Int] = [:]
        for entry in ordered {
            let props = resolver.props(entry.id)!
            let name = plainName(entry.id)
            let rank = names[name]!.firstIndex(of: entry.id)!
            let chain = resolver.chain(entry.id)
            let role = resolver.role(entry.id)
            let spot: Bool
            switch role {
            case .white?: spot = false
            case .black?, .registration?: spot = true
            default:
                if let base = chain.base {
                    spot = resolver.role(base).map { $0 != .white } ?? resolver.props(base)!.spot
                } else {
                    spot = false
                }
            }
            let color = resolver.color(ofSwatch: entry.id)!
            let isDefaultName = !props.hasParent && Self.isDefaultName(props.common.name, of: ColorValues.color(props.value))
            positions[entry.id] = swatches.count
            swatches.append(Swatch(
                id: entry.id, props: props, name: rank == 0 ? name : "\(name) (\(rank + 1))", plainName: name, role: role, color: color,
                isSpot: spot, base: props.hasParent ? OpID(props.parent.id) : nil,
                tintPercent: props.hasParent ? ColorResolver.percent(props.tintPercent) : 100,
                baseRemoved: props.hasParent && !resolver.isSwatch(OpID(props.parent.id)), depth: entry.depth, section: entry.section,
                hasDefaultName: isDefaultName))
        }
        self.swatches = swatches
        self.positions = positions
        self.names = names
    }

    /// Whether following `parent` links from `parent` comes back to `id`.
    private static func loops(from id: OpID, via parent: OpID, _ resolver: ColorResolver) -> Bool {
        var seen: Set<OpID> = [id]
        var current = parent
        while let props = resolver.props(current), props.hasParent, resolver.isSwatch(current) {
            guard seen.insert(current).inserted else { return false }
            current = OpID(props.parent.id)
            if current == id { return true }
        }
        return false
    }

    /// Whether `name` is `color`'s default name, or one with a `-N` suffix.
    public static func isDefaultName(_ name: String, of color: Color) -> Bool {
        let base = ColorText.defaultName(color)
        guard name.hasPrefix(base) else { return false }
        let rest = name.dropFirst(base.count)
        return rest.isEmpty || (rest.first == "-" && rest.count > 1 && rest.dropFirst().allSatisfy(\.isNumber))
    }

    /// The live swatch `id`.
    public subscript(id: OpID) -> Swatch? {
        positions[id].map { swatches[$0] }
    }

    /// The swatch a name lookup resolves to (importers, scripts): the smallest node id holding
    /// the plain name `name`.
    public func named(_ name: String) -> Swatch? {
        names[name]?.first.flatMap { self[$0] }
    }

    /// Whether a live swatch other than `except` holds the plain name `name`.
    public func isTaken(_ name: String, except: OpID? = nil) -> Bool {
        (names[name] ?? []).contains { $0 != except }
    }

    /// The swatches in sections: the ungrouped list first (it holds the defaults), then each
    /// group in the order its first swatch appears.  A section is never empty.
    public var sections: [Section] {
        var order: [String] = []
        var members: [String: [Swatch]] = [:]
        for swatch in swatches {
            if members[swatch.section] == nil { order.append(swatch.section) }
            members[swatch.section, default: []].append(swatch)
        }
        return (order.filter(\.isEmpty) + order.filter { !$0.isEmpty }).map { Section(group: $0, swatches: members[$0]!) }
    }

    /// The group names in use, in list order.
    public var groups: [String] {
        sections.map(\.group).filter { !$0.isEmpty }
    }

    /// Every live tint listed under `id`, depth first (not `id` itself).
    public func tints(of id: OpID) -> [OpID] {
        guard let start = positions[id] else { return [] }
        let depth = swatches[start].depth
        return swatches[(start + 1)...].prefix { $0.depth > depth }.map(\.id)
    }

    /// The sibling-order neighbours of the swatch node `id` in the swatches collection.
    static func neighbours(_ id: OpID, in state: EngineState) -> (before: [UInt8]?, after: [UInt8]?) {
        let children = state.store.children(SwatchFields.collection)
        let next = children.firstIndex(of: id).map { $0 + 1 } ?? children.endIndex
        let after = children[next...].first.flatMap { state.store.placement($0)?.position }
        return (state.store.placement(id)?.position, after)
    }
}

/// A removed swatch *Restore Deleted Colors…* can bring back (swatches.adoc, "Removing colors").
public struct DeletedSwatch: Identifiable, Hashable, Sendable {
    public let id: OpID
    public let name: String
    /// The colour it had (a tint's computed from its cached base when the base is gone too).
    public let color: Color
    /// When it was removed (the wall time of the change that wrote its `deleted`).
    public let removed: Date
}

extension SwatchList {
    /// How long removed swatches stay listed for restoring.
    public static let restoreWindow: TimeInterval = 30 * 24 * 3600

    /// The removed swatches of `state` removed within `restoreWindow` of `now`, most recent first.
    public static func deleted(_ state: EngineState, now: Date = Date()) -> [DeletedSwatch] {
        let resolver = ColorResolver(state)
        return resolver.order.compactMap { id -> DeletedSwatch? in
            guard !resolver.isSwatch(id), let props = resolver.props(id) else { return nil }
            let removed = Date(timeIntervalSince1970: TimeInterval(state.store.deletedTime(id)) / 1000)
            guard now.timeIntervalSince(removed) <= restoreWindow else { return nil }
            var color = ColorValues.color(props.value)
            if props.hasParent {
                let base = resolver.color(ofSwatch: OpID(props.parent.id)) ?? ColorValues.cachedColor(props.parent.cached) ?? .black
                color = base.tinted(ColorResolver.percent(props.tintPercent) / 100)
            }
            let name = props.common.name.isEmpty
                ? (props.hasParent ? ColorText.tintName(percent: ColorResolver.percent(props.tintPercent), base: resolver.props(OpID(props.parent.id))?.common.name ?? "Removed Color")
                    : ColorText.defaultName(color))
                : props.common.name
            return DeletedSwatch(id: id, name: name, color: color, removed: removed)
        }
        .sorted { ($1.removed, $0.id) < ($0.removed, $1.id) }
    }
}
