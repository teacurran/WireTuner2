import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Objects on a page (document-panel.adoc, "Derived, never stored"): a top-level object on the
/// main canvas belongs to the page whose bleed rectangle contains the centre of its bounds (the
/// lowest-numbered page where bleed rectangles overlap); an object whose centre is on no page is
/// on the pasteboard.
///
/// `PageObjectIndex` answers the query for the canvas and the panels from the scene's objects
/// through a REND-003 R-tree of their centres; the page commands, which see only the state,
/// use `PageObjects.objects(on:in:)`.
public struct PageObjectIndex: Sendable {
    private let centers: RTree<NodeID>
    private let pages: PageList

    /// The index of the top-level objects of `scene` over `pages`.
    public init(scene: DocumentScene, pages: PageList) {
        self.init(objects: scene.topLevel.compactMap { id in scene.objects[id]?.bounds.map { (id, $0) } }, pages: pages)
    }

    /// The index of objects given with their pasteboard bounds.
    public init(objects: [(NodeID, Rect)], pages: PageList) {
        centers = RTree(bulkLoading: objects.compactMap { id, bounds in
            guard !bounds.isNull, bounds.center.isFinite else { return nil }
            let center = bounds.center
            return (id, Rect(x: center.x, y: center.y, width: 0, height: 0))
        })
        self.pages = pages
    }

    /// How many objects the index holds.
    public var count: Int { centers.count }

    /// The objects on `page`, in no particular order.
    public func objects(on page: Page) -> [NodeID] {
        let found = centers.query(page.bleedRect)
        // Where an earlier page's bleed rectangle overlaps this one, objects centred in the
        // overlap belong to the earlier page.
        let earlier = pages.pages.prefix { $0.number < page.number }.filter { $0.bleedRect.intersects(page.bleedRect) }
        guard !earlier.isEmpty else { return found }
        return found.filter { id in
            let center = centers.bounds(of: id)?.origin ?? Point(x: Double.nan, y: .nan)
            return !earlier.contains { $0.bleedRect.contains(center) }
        }
    }

    /// The page `object` is on; nil on the pasteboard or for an object not in the index.
    public func page(of object: NodeID) -> Page? {
        centers.bounds(of: object).flatMap { pages.page(containing: $0.origin) }
    }

    /// The objects on no page.
    public func pasteboardObjects(among objects: [NodeID]) -> [NodeID] {
        objects.filter { id in centers.bounds(of: id).map { pages.page(containing: $0.origin) == nil } ?? false }
    }
}

/// The objects-on-page query read straight from the state, for commands.
public enum PageObjects {
    /// The top-level objects of the main canvas: the live objects directly on live layers,
    /// leaving out master-page content (`CommonProps.canvas` set).
    public static func topLevel(in state: EngineState) -> [OpID] {
        state.liveChildren(WellKnown.layers).filter { state.nodeKind($0) == .layer }.flatMap { layer in
            state.liveChildren(layer).filter { node in
                guard Objects.isObject(node, in: state) else { return false }
                return NodeValues.common(state.props(node)).map { !$0.hasCanvas } ?? true
            }
        }
    }

    /// The objects on `page` with their pasteboard bounds, in stacking order.
    public static func objects(on page: Page, in state: EngineState, pages: PageList) -> [(id: OpID, bounds: Rect)] {
        topLevel(in: state).compactMap { node in
            guard let bounds = Objects.bounds(of: node, in: state), pages.page(ofBounds: bounds)?.id == page.id else { return nil }
            return (node, bounds)
        }
    }
}
