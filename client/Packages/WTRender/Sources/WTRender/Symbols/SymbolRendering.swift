// Symbol instances (LIB-010, LIB-026; docs/_includes/library/library.adoc, "Rendering" and
// "Override resolution").  An instance draws its symbol's artwork as if it were on the canvas,
// placed so the symbol's origin lands on the instance transform's translation.  The artwork
// is resolved once per symbol, subtree version and set of overrides and cached, so a hundred
// instances of one symbol cost one build, and instances with overrides get their own sub-list:
// text replaced by the layout WTModel supplies (laid out in the master block's geometry),
// basic fill and stroke colours substituted, hidden subtrees skipped, image sources swapped.
// Overrides reach nodes at any depth of the symbol's own artwork but not into a nested
// instance, which resolves with its own overrides.  A missing symbol, or a nesting cycle, draws
// the hatched placeholder with the symbol's name.  Hit testing treats an instance as one
// object (an atomic group).

import Foundation
import WTGeometry

/// One node of a symbol's artwork, resolved to display items by WTModel.
public struct SymbolNode: Hashable, Sendable {
    public indirect enum Content: Hashable, Sendable {
        /// A leaf object as drawn (a path, an image, a text block's items grouped).
        case item(DisplayItem)
        /// A group: its own clip, opacity and appearance (its `children` are ignored) over
        /// `members`, bottom first.
        case group(GroupItem, members: [SymbolNode])
        /// An instance of another symbol inside this one.
        case instance(SymbolInstance)
    }

    public var id: NodeID
    public var content: Content

    public init(id: NodeID, content: Content) {
        self.id = id
        self.content = content
    }
}

/// A symbol's artwork in symbol space.
public struct SymbolArtwork: Hashable, Sendable {
    public var symbol: NodeID
    public var name: String
    /// The symbol subtree's version: any edit under the symbol changes it.
    public var version: UInt64
    /// `SymbolProps.origin`: instances place this point at their translation.
    public var origin: Point
    /// The symbol's children, bottom first.
    public var nodes: [SymbolNode]

    public init(symbol: NodeID, name: String, version: UInt64, origin: Point = .zero, nodes: [SymbolNode]) {
        self.symbol = symbol
        self.name = name
        self.version = version
        self.origin = origin
        self.nodes = nodes
    }
}

/// One live override of an instance (`Override`, after WTModel's read-time rules).
public enum InstanceOverride: Hashable, Sendable {
    /// The text block's items, laid out from the override's text in the master's geometry.
    case text(NodeID, [DisplayItem])
    /// The colour of the node's basic (solid) fills.
    case fill(NodeID, Color)
    /// The colour of the node's basic (solid) strokes.
    case stroke(NodeID, Color)
    /// The node's subtree is not drawn.
    case hidden(NodeID)
    /// The image draws the `assets` blob `assetID`.
    case image(NodeID, assetID: String)

    /// The master node overridden.
    public var node: NodeID {
        switch self {
        case .text(let node, _), .fill(let node, _), .stroke(let node, _), .hidden(let node), .image(let node, _):
            return node
        }
    }
}

/// One instance to draw.
public struct SymbolInstance: Hashable, Sendable {
    /// The symbol drawn; nil for a dangling reference (a placeholder).
    public var symbol: NodeID?
    /// Instance space → pasteboard (or → the enclosing symbol's space when nested).
    public var transform: AffineTransform
    public var overrides: [InstanceOverride]
    /// The instance's own attribute stack: effects apply to the instance as one shape.
    public var appearance: Appearance
    /// The name a placeholder shows (read from the deleted symbol while it exists).
    public var placeholderName: String
    /// The placeholder's rectangle in instance space; nil reads as 72 × 72 pt about the origin.
    public var placeholderRect: Rect?

    public init(symbol: NodeID?, transform: AffineTransform = .identity, overrides: [InstanceOverride] = [], appearance: Appearance = Appearance(), placeholderName: String = "", placeholderRect: Rect? = nil) {
        self.symbol = symbol
        self.transform = transform
        self.overrides = overrides
        self.appearance = appearance
        self.placeholderName = placeholderName
        self.placeholderRect = placeholderRect
    }
}

/// Every symbol of a document, with each symbol's version folded together with the versions of
/// the symbols nested in it, so a nested symbol's edit reaches its hosts' cache keys.
public struct SymbolLibrary: Sendable {
    public let symbols: [NodeID: SymbolArtwork]
    /// Symbol → a hash of its own version and every nested symbol's.
    let closureVersions: [NodeID: Int]

    public init(_ artworks: [SymbolArtwork]) {
        var symbols: [NodeID: SymbolArtwork] = [:]
        for artwork in artworks {
            symbols[artwork.symbol] = artwork
        }
        self.symbols = symbols
        var nested: [NodeID: Set<NodeID>] = [:]
        func collect(_ nodes: [SymbolNode], into set: inout Set<NodeID>) {
            for node in nodes {
                switch node.content {
                case .item: break
                case .group(_, let members): collect(members, into: &set)
                case .instance(let instance):
                    if let symbol = instance.symbol { set.insert(symbol) }
                }
            }
        }
        for artwork in artworks {
            var set: Set<NodeID> = []
            collect(artwork.nodes, into: &set)
            nested[artwork.symbol] = set
        }
        var versions: [NodeID: Int] = [:]
        for symbol in symbols.keys {
            var reached: Set<NodeID> = [symbol]
            var pending = [symbol]
            while let next = pending.popLast() {
                for inner in nested[next] ?? [] where reached.insert(inner).inserted {
                    pending.append(inner)
                }
            }
            var hasher = Hasher()
            for id in reached.sorted() {
                hasher.combine(id)
                hasher.combine(symbols[id]?.version)
            }
            versions[symbol] = hasher.finalize()
        }
        closureVersions = versions
    }

    /// The instances' dependency on their symbols, for `DependencyIndex`: every master node,
    /// the symbol and the symbols nested in it lead to `instance`.
    public func addDependencies(of instance: NodeID, on symbol: NodeID, to index: inout DependencyIndex) {
        index.add(instance, dependsOn: symbol)
        guard let artwork = symbols[symbol] else {
            return
        }
        func visit(_ nodes: [SymbolNode]) {
            for node in nodes {
                index.add(symbol, dependsOn: node.id)
                switch node.content {
                case .item: break
                case .group(_, let members): visit(members)
                case .instance(let nested):
                    if let inner = nested.symbol {
                        index.add(symbol, dependsOn: inner)
                    }
                }
            }
        }
        visit(artwork.nodes)
    }
}

/// Resolves instances to display items through a cache of resolved symbol artwork.
public final class SymbolRenderer: @unchecked Sendable {
    public let typesetter: LabelTypesetter
    private let cache: RenderCache<Key, [DisplayItem]>
    private let lock = NSLock()
    private var builds = 0

    /// How many sub-lists have been built (the cache's test hook).
    public var buildCount: Int { lock.withLock { builds } }

    private struct Key: Hashable, Sendable {
        var symbol: NodeID
        var version: Int
        var overrides: [InstanceOverride]
    }

    public init(typesetter: LabelTypesetter = CoreTextLabels(), capacity: Int = 1024) {
        self.typesetter = typesetter
        cache = RenderCache(capacity: capacity)
    }

    /// `instance` as one atomic group in the space its transform maps into.
    public func item(for instance: SymbolInstance, in library: SymbolLibrary) -> DisplayItem {
        item(for: instance, in: library, visiting: [])
    }

    private func item(for instance: SymbolInstance, in library: SymbolLibrary, visiting: Set<NodeID>) -> DisplayItem {
        guard let symbol = instance.symbol, let artwork = library.symbols[symbol], !visiting.contains(symbol) else {
            let name = instance.symbol.flatMap { library.symbols[$0]?.name } ?? instance.placeholderName
            let rect = instance.placeholderRect ?? Rect(x: -36, y: -36, width: 72, height: 72)
            return HatchedPlaceholder.item(rect: rect, name: name, transform: instance.transform, typesetter: typesetter)
        }
        let items = artworkItems(artwork, overrides: instance.overrides, in: library, visiting: visiting.union([symbol]))
        let placement = AffineTransform.translation(x: -artwork.origin.x, y: -artwork.origin.y).concatenating(instance.transform)
        var group = GroupItem(children: items.map { $0.transformed(by: placement) }, appearance: instance.appearance)
        group.atomic = true
        return .group(group)
    }

    /// The symbol's artwork in symbol space with `overrides` applied, from the cache.
    public func artworkItems(_ artwork: SymbolArtwork, overrides: [InstanceOverride], in library: SymbolLibrary) -> [DisplayItem] {
        artworkItems(artwork, overrides: overrides, in: library, visiting: [artwork.symbol])
    }

    private func artworkItems(_ artwork: SymbolArtwork, overrides: [InstanceOverride], in library: SymbolLibrary, visiting: Set<NodeID>) -> [DisplayItem] {
        let key = Key(symbol: artwork.symbol, version: library.closureVersions[artwork.symbol] ?? Int(truncatingIfNeeded: artwork.version), overrides: overrides)
        return cache.value(for: key) {
            lock.withLock { builds += 1 }
            var byNode: [NodeID: [InstanceOverride]] = [:]
            for override in overrides {
                byNode[override.node, default: []].append(override)
            }
            return resolve(artwork.nodes, overrides: byNode, in: library, visiting: visiting)
        }
    }

    private func resolve(_ nodes: [SymbolNode], overrides: [NodeID: [InstanceOverride]], in library: SymbolLibrary, visiting: Set<NodeID>) -> [DisplayItem] {
        var result: [DisplayItem] = []
        for node in nodes {
            let own = overrides[node.id] ?? []
            if own.contains(where: { if case .hidden = $0 { return true } else { return false } }) {
                continue
            }
            switch node.content {
            case .item(let item):
                result += SymbolRenderer.apply(own, to: item)
            case .group(var group, let members):
                group.children = resolve(members, overrides: overrides, in: library, visiting: visiting)
                result.append(.group(group))
            case .instance(let instance):
                result.append(item(for: instance, in: library, visiting: visiting))
            }
        }
        return result
    }

    /// `item` with its node's overrides: text replaces it, colours and images substitute.
    static func apply(_ overrides: [InstanceOverride], to item: DisplayItem) -> [DisplayItem] {
        var items = [item]
        for override in overrides {
            switch override {
            case .text(_, let laidOut):
                items = laidOut
            case .fill(_, let color):
                items = items.map { $0.recolored(fill: color, stroke: nil) }
            case .stroke(_, let color):
                items = items.map { $0.recolored(fill: nil, stroke: color) }
            case .image(_, let assetID):
                items = items.map { $0.replacingImage(with: assetID) }
            case .hidden:
                break
            }
        }
        return items
    }
}

extension DisplayItem {
    /// The item with its basic (solid) fills -- text included -- in `fill` and its basic
    /// strokes in `stroke`, at any depth; other paints are kept.
    func recolored(fill: Color?, stroke: Color?) -> DisplayItem {
        func recolor(_ paint: Paint, _ color: Color?) -> Paint {
            guard let color, case .solid = paint else { return paint }
            return .solid(color)
        }
        switch self {
        case .fill(var item):
            item.paint = recolor(item.paint, fill)
            return .fill(item)
        case .stroke(var item):
            item.paint = recolor(item.paint, stroke)
            return .stroke(item)
        case .path(var item):
            item.appearance.items = item.appearance.items.map { element in
                switch element {
                case .fill(var paint):
                    paint.paint = recolor(paint.paint, fill)
                    return .fill(paint)
                case .stroke(var paint):
                    paint.paint = recolor(paint.paint, stroke)
                    return .stroke(paint)
                }
            }
            return .path(item)
        case .text(var item):
            if let fill {
                item.color = fill
            }
            return .text(item)
        case .image:
            return self
        case .group(var group):
            group.children = group.children.map { $0.recolored(fill: fill, stroke: stroke) }
            return .group(group)
        }
    }

    /// Every placed image in the item drawing `assetID` instead.
    func replacingImage(with assetID: String) -> DisplayItem {
        switch self {
        case .image(var item):
            item.assetID = assetID
            return .image(item)
        case .group(var group):
            group.children = group.children.map { $0.replacingImage(with: assetID) }
            return .group(group)
        case .fill, .stroke, .path, .text:
            return self
        }
    }
}
