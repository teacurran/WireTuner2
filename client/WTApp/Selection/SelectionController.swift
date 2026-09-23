import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The selection of one document window and everything that changes it: clicks and marquees
/// through REND-003's `HitTester`, the select commands, and the document's own changes
/// (selecting.adoc, "Merge semantics": a deleted object leaves the selection, the rest stay
/// selected).  The Pointer tool and the Edit menu call it; it holds no AppKit state.
@MainActor
final class SelectionController {
    let document: DocumentHandle
    let model: SelectionModel
    /// *Contact-sensitive selection* for the Pointer and Subselect tools.
    var contactSensitive: @MainActor () -> Bool
    /// *Pick distance*, view pixels.
    var pickDistance: @MainActor () -> Double
    /// The Lasso's *Contact-sensitive selection*.
    var lassoContactSensitive: @MainActor () -> Bool = { false }
    /// The window's active layer and *Edit current layer only* (layers.adoc, LIB-005/007): the hit
    /// tester skips every layer but the active one while the preference is on (and locked layers
    /// and guides always, from the display list's layer runs).
    var layerRule: @MainActor () -> (activeLayer: OpID?, currentLayerOnly: Bool) = { (nil, false) }

    /// Built on first use and after every content change; the viewport and options are set
    /// per query (they are plain values).
    private var cachedTester: HitTester?
    private(set) var hitTesterBuilds = 0

    init(
        document: DocumentHandle, model: SelectionModel = SelectionModel(),
        contactSensitive: @escaping @MainActor () -> Bool = { false },
        pickDistance: @escaping @MainActor () -> Double = { HitOptions.defaultPickDistance }
    ) {
        self.document = document
        self.model = model
        self.contactSensitive = contactSensitive
        self.pickDistance = pickDistance
        document.observe { [weak self] change in self?.documentDidChange(change) }
    }

    var selection: Selection { model.selection }

    // MARK: Following the document

    /// Any change: objects that no longer resolve leave the selection, quietly, and so do points
    /// that were deleted; the hit tester follows the change in place.
    private func documentDidChange(_ change: ContentChange) {
        if var tester = cachedTester {
            tester.update(displayList: change.after, changes: change.summary)
            cachedTester = tester
        }
        let document = document
        model.set(model.selection.filtered({ document.isSelectable($0) }, sub: { sub in
            sub.filtered(points: { document.contains($0) }, segments: { document.contains($0) })
        }))
    }

    // MARK: Hit testing

    /// A hit tester over the current display list at `viewport`.
    func hitTester(viewport: Viewport, subselect: Bool) -> HitTester {
        var tester: HitTester
        if let cachedTester {
            tester = cachedTester
            tester.viewport = viewport
        } else {
            tester = HitTester(displayList: document.displayList, viewport: viewport)
            hitTesterBuilds += 1
        }
        let rule = layerRule()
        tester.options = HitOptions(subselect: subselect, contactSensitive: contactSensitive(), pickDistanceInViewPixels: pickDistance(),
                                    activeLayer: rule.activeLayer.map(NodeID.init), editCurrentLayerOnly: rule.currentLayerOnly)
        cachedTester = tester
        return tester
    }

    /// The top-most object under `viewPoint` and, when subselecting, the point or segment hit.
    func pick(at viewPoint: Point, viewport: Viewport, subselect: Bool) -> (id: SelectionID, sub: SubSelection?)? {
        let hits = hitTester(viewport: viewport, subselect: subselect).hitTest(viewPoint: viewPoint)
        for hit in hits {
            guard let id = document.selectionID(atItemPath: hit.itemPath), document.isSelectable(id) else { continue }
            return (id, subselect ? subSelection(for: hit, in: id) : nil)
        }
        return nil
    }

    /// What a subselect click on `hit` selects inside the object `id`.
    func subSelection(for hit: HitResult, in id: SelectionID) -> SubSelection? {
        guard let object = document.object(for: id) else { return nil }
        switch hit.kind {
        case let .point(element), let .handle(element, _):
            return object.point(leafPath: hit.leafPath, element: element).map { .points([PointReference(node: id.node, $0)]) }
        case let .segment(location), let .stroke(location?):
            guard let contour = object.contour(leafPath: hit.leafPath, index: location.contour),
                  let segments = object.path?.contour(contour)?.segments, segments.indices.contains(location.segment) else { return nil }
            return .segments([SegmentReference(node: id.node, contour: contour, from: segments[location.segment].from.id)])
        default:
            return nil
        }
    }

    static func mode(for modifiers: KeyModifiers) -> SelectionMode {
        modifiers.contains(.shift) ? .toggle : .replace
    }

    /// A click (selecting.adoc, "The selection tools"): selects the object under the pointer;
    /// Shift toggles it; a plain click on an object already selected keeps the selection (so
    /// a drag can move all of it); a click on nothing deselects unless Shift is held.
    func click(at viewPoint: Point, viewport: Viewport, modifiers: KeyModifiers, subselect: Bool) {
        let mode = Self.mode(for: modifiers)
        guard let (id, sub) = pick(at: viewPoint, viewport: viewport, subselect: subselect) else {
            if mode == .replace { model.clear() }
            return
        }
        if mode == .replace, sub == nil, model.selection.contains(id) { return }
        model.apply([id], sub: sub.map { [id: $0] } ?? [:], mode: mode)
    }

    /// A marquee (view points): what it encloses, or touches when *Contact-sensitive
    /// selection* is on; subselecting, objects with anchors inside also get those anchors as
    /// their sub-selection.  Shift toggles each object picked.
    func marquee(_ viewRect: Rect, viewport: Viewport, modifiers: KeyModifiers, subselect: Bool) {
        let hits = hitTester(viewport: viewport, subselect: subselect).hitTest(marquee: viewRect)
        var picked: [SelectionID] = []
        var sub: [SelectionID: SubSelection] = [:]
        for hit in hits.reversed() {
            // Several parts of one object's drawing (a text block's runs) pick it once.
            guard let id = document.selectionID(atItemPath: hit.itemPath), document.isSelectable(id), !picked.contains(id) else { continue }
            let object = document.object(for: id)
            let anchors = hit.anchors.compactMap { object?.point(leafPath: $0.leafPath, element: $0.element) }
            if subselect, !anchors.isEmpty {
                sub[id] = .points(Set(anchors.map { PointReference(node: id.node, $0) }))
                picked.append(id)
            } else if hit.selected {
                picked.append(id)
            }
        }
        model.apply(picked, sub: sub, mode: Self.mode(for: modifiers))
    }

    // MARK: Commands

    /// menu:Edit[Select > All]: every object on the current page.
    func selectAll() {
        model.set(Selection(document.selectableIDs(intersecting: document.currentPage)))
    }

    /// menu:Edit[Select > None].
    func selectNone() { model.clear() }

    /// menu:Edit[Select > Invert Selection], on the current page.
    func invert() {
        model.set(model.selection.inverted(within: document.selectableIDs(intersecting: document.currentPage)))
    }

    var canSelectAll: Bool { !document.selectableIDs(intersecting: document.currentPage).isEmpty }

    /// The pasteboard bounds of everything selected (Fit Selection), nil when nothing is.
    var selectedBounds: Rect? {
        CanvasNavigation.union(model.ids.compactMap { document.item(for: $0)?.bounds })
    }
}
