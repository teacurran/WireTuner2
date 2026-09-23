import Foundation
import WTCRDT
import WTProto

/// Drags swatches by their names to a new place in the list (swatches.adoc, "Managing the
/// list"; COLOR-004): each moves directly after `after` (to the head of the list when nil), in
/// the order given.  Tints move with their base without a write (they list under it wherever
/// they stand); the protected defaults stay at the top and are not moved.
public struct MoveSwatches: Command {
    public var swatches: [OpID]
    public var after: OpID?

    public init(_ swatches: [OpID], after: OpID?) {
        self.swatches = swatches
        self.after = after
    }

    public var label: String { "Move \(Swatches.count(swatches.count))" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        var moving: [OpID] = []
        for id in swatches where !moving.contains(id) && id != after {
            guard try !Swatches.live(id, list).isProtected else { continue }
            moving.append(id)
        }
        guard !moving.isEmpty else { return }
        let children = state.store.children(SwatchFields.collection)
        let lo = after.flatMap { state.store.placement($0)?.position }
        let start = after.flatMap { children.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let hi = children[start...].first { !moving.contains($0) }.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: lo, and: hi, count: moving.count)
        for (id, key) in zip(moving, keys) {
            builder.append(Ops.move(id, parent: SwatchFields.collection, position: key))
        }
    }
}

/// *Sort Color List by Name* (COLOR-004): the defaults first, then every colour by name --
/// numerically, then alphabetically, ignoring case -- each followed by its tints, sorted the
/// same way.  Positions are *canonical*: a fixed ladder derived from the rank alone, with no
/// random suffix, so two concurrent sorts of one list write identical keys and the merged list
/// is sorted.  A swatch already at its key is not moved.
public struct SortSwatches: Command {
    public init() {}

    public var label: String { "Sort colors" }

    /// The canonical position of rank `rank` (0-based): a length byte `0x10 + n`, then `rank`
    /// in `n` base-254 digits written as bytes 1...254.  Keys of more digits sort after keys of
    /// fewer, never end in `0x00`, and leave room between them for later inserts.
    public static func canonicalKey(rank: Int) -> [UInt8] {
        var digits: [UInt8] = []
        var value = max(rank, 0)
        repeat {
            digits.insert(UInt8(1 + value % 254), at: 0)
            value /= 254
        } while value > 0
        return [UInt8(0x10 + digits.count)] + digits
    }

    /// Whether `a` sorts before `b` by name (numeric runs as numbers, case ignored), then id.
    static func precedes(_ a: Swatch, _ b: Swatch) -> Bool {
        switch a.plainName.compare(b.plainName, options: [.numeric, .caseInsensitive], range: nil, locale: nil) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id < b.id
        }
    }

    /// The sorted order of `list`.
    public static func order(_ list: SwatchList) -> [OpID] {
        var children: [OpID?: [Swatch]] = [:]
        var ancestors: [OpID] = []
        for swatch in list.swatches {
            ancestors = Array(ancestors.prefix(swatch.depth))
            children[swatch.depth == 0 ? nil : ancestors.last, default: []].append(swatch)
            ancestors.append(swatch.id)
        }
        var result: [OpID] = []
        func visit(_ swatch: Swatch) {
            result.append(swatch.id)
            for tint in (children[swatch.id] ?? []).sorted(by: precedes) {
                visit(tint)
            }
        }
        let roots = children[nil] ?? []
        for root in roots.filter(\.isProtected) + roots.filter({ !$0.isProtected }).sorted(by: precedes) {
            visit(root)
        }
        return result
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (rank, id) in Self.order(SwatchList(state)).enumerated() {
            let key = Self.canonicalKey(rank: rank)
            guard state.store.placement(id)?.position != key else { continue }
            builder.append(Ops.move(id, parent: SwatchFields.collection, position: key))
        }
    }
}
