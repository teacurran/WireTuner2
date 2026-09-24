import AppKit
import WTGeometry
import WTRender

/// Handoff between the account's Macs (saving.adoc, "Handing a document off to another Mac";
/// IO-036).  The activity carries ids and a view only -- `{document_id, page_index, zoom, scroll_x,
/// scroll_y}` -- never document content; the receiving Mac opens the document by id through the
/// library (its local copy first) and applies the page and view once the document is open.  No
/// iCloud, no web fallback, not indexed for search (Core Spotlight indexes documents itself).
enum HandoffActivity {
    static let type = "com.villagecompute.wiretuner.document"

    /// Where the person is in a document: the page, the zoom and the pasteboard point at the
    /// centre of the view (the centre, not the corner, so a differently sized window on the other
    /// Mac shows the same place).
    struct Place: Equatable, Sendable {
        var documentID: String
        var pageIndex: Int
        var zoom: Double
        var center: Point
    }

    enum Key {
        static let documentID = "document_id"
        static let pageIndex = "page_index"
        static let zoom = "zoom"
        static let scrollX = "scroll_x"
        static let scrollY = "scroll_y"
    }

    static func userInfo(_ place: Place) -> [String: Any] {
        [Key.documentID: place.documentID, Key.pageIndex: place.pageIndex, Key.zoom: place.zoom, Key.scrollX: place.center.x, Key.scrollY: place.center.y]
    }

    /// The place an activity's user info names; nil without a document id.
    static func place(from userInfo: [AnyHashable: Any]?) -> Place? {
        guard let userInfo, let id = userInfo[Key.documentID] as? String, !id.isEmpty else { return nil }
        func number(_ key: String) -> Double? { (userInfo[key] as? NSNumber)?.doubleValue }
        return Place(documentID: id, pageIndex: (userInfo[Key.pageIndex] as? NSNumber)?.intValue ?? 0, zoom: number(Key.zoom) ?? 1,
                     center: Point(x: number(Key.scrollX) ?? 0, y: number(Key.scrollY) ?? 0))
    }

    /// A new activity for a document window, eligible for Handoff only.
    @MainActor
    static func make(title: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.title = title
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.needsSave = true
        return activity
    }
}

/// A document window's Handoff activity: `needsSave` on a page change and a zoom change at once,
/// and on scrolling once it has stopped for `idle`; AppKit then asks the window controller to fill
/// the user info (`updateUserActivityState(_:)`).
@MainActor
final class WindowHandoff {
    static let idle: Duration = .milliseconds(500)

    let activity: NSUserActivity
    var idle = WindowHandoff.idle
    private var lastZoom: Double?
    private var lastPage: Int?
    private var scrollIdle: Task<Void, Never>?
    /// How many times the activity was marked for saving (tests).
    private(set) var saves = 0

    init(title: String) {
        activity = HandoffActivity.make(title: title)
    }

    /// The view moved: a zoom change marks the activity now, a scroll once it settles.
    func viewDidChange(_ viewport: Viewport) {
        if let lastZoom, lastZoom != viewport.zoom {
            self.lastZoom = viewport.zoom
            scrollIdle?.cancel()
            scrollIdle = nil
            markNeedsSave()
            return
        }
        lastZoom = viewport.zoom
        scrollIdle?.cancel()
        let idle = idle
        scrollIdle = Task { [weak self] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            self?.markNeedsSave()
        }
    }

    /// The active page changed.
    func pageDidChange(_ index: Int) {
        defer { lastPage = index }
        guard lastPage != nil, lastPage != index else { return }
        markNeedsSave()
    }

    private func markNeedsSave() {
        saves += 1
        activity.needsSave = true
    }

    /// Waits for a scroll settling now (tests).
    func settle() async { await scrollIdle?.value }

    func invalidate() {
        scrollIdle?.cancel()
        activity.invalidate()
    }
}
