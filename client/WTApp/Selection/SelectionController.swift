import Foundation
import WTGeometry
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
        document.observeRemovals { [weak self] removed in self?.itemsRemoved(removed) }
        document.observe { [weak self] _ in self?.documentDidChange() }
    }

    var selection: Selection { model.selection }

    // MARK: Following the document

    private func itemsRemoved(_ removed: IndexSet) {
        cachedTester = nil
        model.set(model.selection.removingItems(at: removed))
    }

    /// Any change: objects that no longer resolve leave the selection, quietly.
    private func documentDidChange() {
        cachedTester = nil
        let document = document
        model.set(model.selection.filtered { document.isSelectable($0) })
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
        tester.options = HitOptions(subselect: subselect, contactSensitive: contactSensitive(), pickDistanceInViewPixels: pickDistance())
        cachedTester = tester
        return tester
    }

    /// The top-most object under `viewPoint` and, when subselecting, the point or segment hit.
    func pick(at viewPoint: Point, viewport: Viewport, subselect: Bool) -> (id: SelectionID, sub: SubSelection?)? {
        let hits = hitTester(viewport: viewport, subselect: subselect).hitTest(viewPoint: viewPoint)
        guard let hit = hits.first(where: { document.isSelectable(.item($0.itemPath)) }) else { return nil }
        return (.item(hit.itemPath), subselect ? Self.subSelection(for: hit) : nil)
    }

    /// What a subselect click on `hit` selects inside the object.
    static func subSelection(for hit: HitResult) -> SubSelection? {
        switch hit.kind {
        case let .point(element), let .handle(element, _):
            return .points([PointReference(leafPath: hit.leafPath, element: element)])
        case let .segment(location), let .stroke(location?):
            return .segments([SegmentReference(leafPath: hit.leafPath, contour: location.contour, segment: location.segment)])
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
        for hit in hits.reversed() where document.isSelectable(.item(hit.itemPath)) {
            let id = SelectionID.item(hit.itemPath)
            if subselect, !hit.anchors.isEmpty {
                sub[id] = .points(Set(hit.anchors.map { PointReference(leafPath: $0.leafPath, element: $0.element) }))
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
