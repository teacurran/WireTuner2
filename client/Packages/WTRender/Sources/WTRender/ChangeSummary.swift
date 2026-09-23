// What an applied change touched, as the renderer sees it (REND-004; docs/spec/client.adoc,
// "Concurrency": every change, local or remote, produces a `ChangeSummary` -- touched nodes,
// touched fields, dirty rect -- that the renderer, the panels and the presence overlay
// subscribe to).
//
// WTRender cannot import the merge engine, so node ids and field paths are its own small
// mirrors of WTCRDT's `OpID` and `RegisterPath`; WTModel builds summaries from the engine's
// applied ops and the display list's bounds before and after.

import WTGeometry

/// A document node's id: the `OpID` that created it (Lamport counter, then replica).
public struct NodeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var counter: UInt64
    public var replica: UInt64

    public init(counter: UInt64, replica: UInt64) {
        self.counter = counter
        self.replica = replica
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        (lhs.counter, lhs.replica) < (rhs.counter, rhs.replica)
    }

    /// `counter:replica`, as the spec writes ids.
    public var description: String { "\(counter):\(replica)" }
}

/// The address of a field inside a node, outermost first: field numbers from `NodeProps` down,
/// with an element id directly after a SEQUENCE field (crdt-model.adoc, "Field paths and
/// registers").
public struct FieldPath: Hashable, Sendable, CustomStringConvertible {
    public enum Segment: Hashable, Sendable {
        case field(UInt32)
        case element(NodeID)
    }

    public var segments: [Segment]

    public init(_ segments: [Segment]) {
        self.segments = segments
    }

    /// A path of field numbers only.
    public init(fields: UInt32...) {
        self.init(fields.map { .field($0) })
    }

    /// Whether `other` lies at or under this path.
    public func contains(_ other: FieldPath) -> Bool {
        other.segments.count >= segments.count && Array(other.segments.prefix(segments.count)) == segments
    }

    public var description: String {
        segments.map { segment in
            switch segment {
            case .field(let number): return "\(number)"
            case .element(let id): return "<\(id)>"
            }
        }.joined(separator: ".")
    }
}

/// Where a node paints on one canvas.
public struct NodeBounds: Hashable, Sendable {
    public var canvas: CanvasID
    /// The node's own painted bounds (fills, strokes, arrowheads), pasteboard space.
    public var rect: Rect
    /// The bounds grown by the node's effects (shadows, glows, blurs), when it has any.  Raster
    /// and vector effects paint outside the geometry, so invalidation uses this when present.
    public var effectRect: Rect?

    public init(canvas: CanvasID, rect: Rect, effectRect: Rect? = nil) {
        self.canvas = canvas
        self.rect = rect
        self.effectRect = effectRect
    }

    /// Everything the node can paint: the effect-expanded bounds joined with its own.
    public var paintedRect: Rect {
        effectRect.map { $0.union(rect) } ?? rect
    }
}

/// A node's bounds before and after a change: nil before for a node the change created (or
/// revealed), nil after for one it deleted (or hid).
public struct BoundsChange: Hashable, Sendable {
    public var old: NodeBounds?
    public var new: NodeBounds?

    public init(old: NodeBounds?, new: NodeBounds?) {
        self.old = old
        self.new = new
    }
}

/// Whether a change was made here or arrived from the server.
public enum ChangeOrigin: Hashable, Sendable {
    /// A command on this client: repainted at once.
    case local
    /// A merged remote change: coalesced with the rest of its burst within one frame.
    case remote
}

/// What one applied change (or a coalesced burst of them) touched.
public struct ChangeSummary: Hashable, Sendable {
    public var origin: ChangeOrigin
    /// Every node the change wrote, created or deleted.
    public private(set) var touchedNodes: Set<NodeID>
    /// The fields written, per node.
    public private(set) var touchedFields: [NodeID: Set<FieldPath>]
    /// Painted bounds before and after, per node whose drawing may have changed.  A node absent
    /// here changed nothing visible (a name, a lock), or the summary's producer could not tell,
    /// in which case the mapper looks it up in the display lists it is given.
    public private(set) var bounds: [NodeID: BoundsChange]
    /// Whether the change reordered, added or removed display items (z order, parenting,
    /// visibility), which shifts item indices: hit testing rebuilds its index then.
    public var isStructural: Bool

    public init(origin: ChangeOrigin = .local, isStructural: Bool = false) {
        self.origin = origin
        touchedNodes = []
        touchedFields = [:]
        bounds = [:]
        self.isStructural = isStructural
    }

    /// Nothing touched.
    public var isEmpty: Bool { touchedNodes.isEmpty && !isStructural }

    /// Records that `node` was written, at `fields` (none: the node as a whole).
    public mutating func touch(_ node: NodeID, fields: [FieldPath] = []) {
        touchedNodes.insert(node)
        if !fields.isEmpty {
            touchedFields[node, default: []].formUnion(fields)
        }
    }

    /// Records `node`'s painted bounds before and after the change (and touches it).  A node
    /// recorded twice keeps the earliest `old` and the latest `new`, which is what a burst
    /// repaints: where it was before the burst and where it is after.
    public mutating func record(_ node: NodeID, old: NodeBounds?, new: NodeBounds?, fields: [FieldPath] = []) {
        touch(node, fields: fields)
        if let existing = bounds[node] {
            bounds[node] = BoundsChange(old: existing.old, new: new)
        } else {
            bounds[node] = BoundsChange(old: old, new: new)
        }
    }

    /// This summary followed by `later`: a burst coalesced into one.
    public mutating func merge(_ later: ChangeSummary) {
        if later.origin == .local {
            origin = .local
        }
        isStructural = isStructural || later.isStructural
        touchedNodes.formUnion(later.touchedNodes)
        for (node, fields) in later.touchedFields {
            touchedFields[node, default: []].formUnion(fields)
        }
        for (node, change) in later.bounds {
            if let existing = bounds[node] {
                bounds[node] = BoundsChange(old: existing.old, new: change.new)
            } else {
                bounds[node] = change
            }
        }
    }

    /// This summary followed by `later`.
    public func merging(_ later: ChangeSummary) -> ChangeSummary {
        var result = self
        result.merge(later)
        return result
    }

    /// Whether `node`'s field at `path` (or anything under it) was written.
    public func touched(_ node: NodeID, field path: FieldPath) -> Bool {
        touchedFields[node]?.contains { path.contains($0) || $0.contains(path) } ?? false
    }
}
