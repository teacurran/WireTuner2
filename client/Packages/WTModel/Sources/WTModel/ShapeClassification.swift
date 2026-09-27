import Synchronization
import WTCRDT
import WTGeometry
import WTProto

// Select Similar's *Shape* (selecting.adoc, "Select Similar"; IMG-030): the classes of objects,
// read through WTGeometry's `ShapeClassifier` and cached per node until its geometry changes.

extension SelectSimilar {
    /// The objects a command searches: the page's (the document's when `page` is nil) from
    /// `AttributeQuery.candidates`, locked objects and members of locked groups left out, and on a
    /// page only those whose bounds meet it; nil when `page` names no page.
    public static func candidates(page: OpID?, in state: EngineState, bounds: ((OpID) -> Rect?)? = nil) -> [OpID]? {
        let scope: AttributeQuery.Scope = page.map { .page($0) } ?? .document
        let order = LayerOrder(state)
        let candidates = AttributeQuery.candidates(scope, in: state).filter { !Objects.isEffectivelyLocked($0, in: state, layers: order) }
        guard let page else { return candidates }
        guard let rect = PageList(state)[page]?.rect else { return nil }
        let bounds = bounds ?? { AttributeQuery.bounds(of: $0, in: state) }
        return candidates.filter { bounds($0)?.intersects(rect) == true }
    }
}

/// How an object is classed without the model: groups (and the wrappers and instances drawn as
/// groups) as `group`, text blocks as `text`, images and placed files as `image`; paths and shapes
/// go to the model (`contours`), and anything else has no class.
public enum ShapeKinds {
    public enum Reading: Equatable, Sendable {
        /// Classed without the model.
        case fixed(ShapeClass)
        /// Classed by the model from its outline.
        case outline([Contour])
        /// No class.
        case none
    }

    public static func reading(_ node: OpID, in state: EngineState) -> Reading {
        switch state.nodeKind(node) {
        case .group?, .blend?, .extrude?, .envelope?, .perspective?, .instance?: return .fixed(.group)
        case .text?: return .fixed(.text)
        case .image?, .placedFile?, .svgAnimation?: return .fixed(.image)
        default:
            guard let contours = contours(of: node, in: state) else { return .none }
            return .outline(contours)
        }
    }

    /// A path's, rectangle's, ellipse's or polygon's renderable contours in pasteboard space (a
    /// non-uniform scale makes a circle an ellipse); nil for other kinds or an empty outline.
    public static func contours(of node: OpID, in state: EngineState) -> [Contour]? {
        guard let path = Objects.localPath(node, in: state) else { return nil }
        let transform = Objects.pasteboardTransform(of: node, in: state)
        let contours = path.contours.filter(\.isRenderable).map { vector in
            Contour(segments: vector.segments.map { $0.cubic.applying(transform) }, closed: vector.closed)
        }
        return contours.isEmpty ? nil : contours
    }
}

#if canImport(CoreML)
/// The bundled classifier as Select Similar's `ShapeClassifying`: every node's class, cached with
/// the geometry it was read from (the node's contours in pasteboard space), so a node is classified
/// again only once its geometry -- or an enclosing transform -- changes.  `prepare` classifies a
/// page's worth in one batch off the caller's actor; `shapeClass(of:in:)` reads the cache and
/// classifies what is missing on the spot.  Nothing is written and nothing leaves the Mac.
public final class ShapeClassification: ShapeClassifying, Sendable {
    public let classifier: ShapeClassifier
    private let cache = Mutex<[OpID: Entry]>([:])
    private let counter = Mutex(0)

    private struct Entry: Sendable {
        var geometry: [Contour]
        var shape: ShapeClass?
    }

    public init(classifier: ShapeClassifier) {
        self.classifier = classifier
    }

    /// How many outlines the model has classified (cache misses).
    public var classified: Int { counter.withLock { $0 } }

    public func shapeClass(of node: OpID, in state: EngineState) -> String? {
        classes(of: [node], in: state)[0]?.rawValue
    }

    /// The class of each of `nodes`: fixed kinds at once, cached outlines from the cache, the rest
    /// through the model in one batch (and cached).
    public func classes(of nodes: [OpID], in state: EngineState) -> [ShapeClass?] {
        var result = [ShapeClass?](repeating: nil, count: nodes.count)
        var pending: [(index: Int, node: OpID, contours: [Contour], features: ShapeFeatures?)] = []
        let known = cache.withLock { $0 }
        for (index, node) in nodes.enumerated() {
            switch ShapeKinds.reading(node, in: state) {
            case .fixed(let shape): result[index] = shape
            case .none: break
            case .outline(let contours):
                if let entry = known[node], entry.geometry == contours {
                    result[index] = entry.shape
                } else {
                    pending.append((index, node, contours, ShapeFeatures(contours)))
                }
            }
        }
        guard !pending.isEmpty else { return result }
        let batch = pending.compactMap(\.features)
        var classes = classifier.classify(batch).makeIterator()
        var entries: [OpID: Entry] = [:]
        for item in pending {
            let shape = item.features == nil ? nil : classes.next() ?? nil
            result[item.index] = shape
            entries[item.node] = Entry(geometry: item.contours, shape: shape)
        }
        cache.withLock { $0.merge(entries) { $1 } }
        counter.withLock { $0 += batch.count }
        return result
    }

    /// Classifies `nodes` off the caller's actor (the outlines read and the model run on the
    /// cooperative pool, in parallel chunks), so the `shapeClass(of:in:)` calls that follow read
    /// the cache.
    public func prepare(_ nodes: [OpID], in state: EngineState, chunk: Int = 512) async {
        let size = max(chunk, 1)
        let slices = stride(from: 0, to: nodes.count, by: size).map { Array(nodes[$0..<min($0 + size, nodes.count)]) }
        await withTaskGroup(of: Void.self) { group in
            for slice in slices {
                group.addTask(priority: .userInitiated) { _ = self.classes(of: slice, in: state) }
            }
        }
    }

    /// Forgets every cached class (the document closed).
    public func reset() {
        cache.withLock { $0 = [:] }
    }
}
#endif
