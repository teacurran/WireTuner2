import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Master content on child pages (DOC-011, master-pages.adoc "Client"): the main pasteboard's
/// builder draws, on every layer, each child page's master objects on that layer below the
/// layer's own objects, translated by the page's origin (a master's coordinates are relative to
/// its top-left corner).  Each master's objects come from a builder of its own canvas
/// (`canvasNode` = the master, exactly what the master page tab draws), kept up to date with the
/// same changes; a child page's master content on one layer is one *inert* group
/// (`GroupItem.inert`): drawn, never hit, so a click over master content on a child returns the
/// child's objects or nothing.  Print and export (`outputDisplayList`) clip each page's master
/// content to the page's bleed rectangle; the screen does not.
///
/// Dirty rects: master content is not an object of the main scene, so the builder records, under
/// each child page's id, the pasteboard rectangles its master content covered before and after
/// -- only the edited master objects' rectangles when the page itself did not change -- and a
/// remote edit to a master object repaints just those tiles of every child page (REND-004).
struct MasterRendering: Sendable {
    /// Where a child page draws its master's content.
    struct Placement: Hashable, Sendable {
        var master: OpID
        var origin: Point
        var bleedRect: Rect
    }

    /// One builder per master with child pages, drawing the master's canvas.
    private(set) var builders: [OpID: DocumentDisplayListBuilder] = [:]
    /// The child pages as of the last `prepare`, in page order.
    private(set) var pages: [(page: OpID, placement: Placement)] = []
    /// Per child page, its master content's bounds before and after the last `prepare`
    /// (pasteboard), for the change summary.
    private(set) var dirty: [OpID: (old: Rect?, new: Rect?)] = [:]

    /// Whether the builders were never prepared.
    var isEmpty: Bool { builders.isEmpty && pages.isEmpty }

    /// Forgets every master scene (a rebuild).
    mutating func reset() {
        builders = [:]
        pages = []
        dirty = [:]
    }

    /// Brings the masters' scenes up to `state`.  `touched` are the nodes a change touched
    /// (rebuilt in each master's builder with their dependents); nil rebuilds every master.
    /// `host` is the pasteboard builder: its text layout, substitution and guide colour are the
    /// masters' too.  A builder of a master's own canvas draws no master content.
    mutating func prepare(_ state: EngineState, touched: Set<OpID>?, host: DocumentDisplayListBuilder) {
        dirty = [:]
        guard host.canvasNode == nil else {
            reset()
            return
        }
        let before = pages
        let beforeBounds = Dictionary(uniqueKeysWithValues: builders.map { ($0.key, Self.bounds(of: $0.value.scene)) })
        let list = PageList(state)
        pages = list.pages.compactMap { page in
            page.master.map { (page.id, Placement(master: $0, origin: page.origin, bleedRect: page.bleedRect)) }
        }
        var summaries: [OpID: ChangeSummary] = [:]
        var next: [OpID: DocumentDisplayListBuilder] = [:]
        for master in Set(pages.map(\.placement.master)) {
            if var builder = builders[master], let touched {
                Self.configure(&builder, from: host)
                if !touched.isEmpty {
                    summaries[master] = builder.invalidate(touched, state: state).1
                }
                next[master] = builder
            } else {
                var builder = DocumentDisplayListBuilder(canvas: CanvasID("\(host.canvas.rawValue)/master/\(master.counter):\(master.replica)"))
                builder.canvasNode = master
                Self.configure(&builder, from: host)
                builder.rebuild(state)
                next[master] = builder
            }
        }
        builders = next
        // What each child page's master content covered, before and after.
        let old = Dictionary(before.map { ($0.page, $0.placement) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(pages.map { ($0.page, $0.placement) }, uniquingKeysWith: { a, _ in a })
        for page in Set(old.keys).union(new.keys) {
            let was = old[page], now = new[page]
            let wasRect = was.flatMap { placement -> Rect? in
                beforeBounds[placement.master].flatMap { $0 }.map { $0.offset(by: Vector(dx: placement.origin.x, dy: placement.origin.y)) }
            }
            let nowRect = now.flatMap { placement -> Rect? in
                builders[placement.master].flatMap { Self.bounds(of: $0.scene) }.map { $0.offset(by: Vector(dx: placement.origin.x, dy: placement.origin.y)) }
            }
            if was != now || touched == nil {
                if wasRect != nil || nowRect != nil { dirty[page] = (wasRect, nowRect) }
            } else if let placement = now, let summary = summaries[placement.master], !summary.bounds.isEmpty {
                var changedOld = Rect.null, changedNew = Rect.null
                for change in summary.bounds.values {
                    if let rect = change.old?.paintedRect { changedOld = changedOld.union(rect) }
                    if let rect = change.new?.paintedRect { changedNew = changedNew.union(rect) }
                }
                let shift = { (rect: Rect) -> Rect? in rect.isNull ? nil : rect.offset(by: Vector(dx: placement.origin.x, dy: placement.origin.y)) }
                dirty[page] = (shift(changedOld), shift(changedNew))
            }
        }
    }

    /// The master builders draw what the host draws with.
    private static func configure(_ builder: inout DocumentDisplayListBuilder, from host: DocumentDisplayListBuilder) {
        builder.textLayout = host.textLayout
        builder.substitution = host.substitution
        builder.guideColor = host.guideColor
    }

    /// The union of a master scene's top-level objects' bounds (master coordinates).
    static func bounds(of scene: DocumentScene) -> Rect? {
        var result = Rect.null
        for id in scene.topLevel {
            if let rect = scene.objects[id]?.bounds { result = result.union(rect) }
        }
        return result.isNull ? nil : result
    }

    /// The master content of every child page on `layer`, in page order: one inert group per page
    /// holding that page's master objects on the layer, translated by its origin (and, for
    /// `output`, clipped to its bleed rectangle).
    func items(on layer: OpID, output: Bool) -> [DisplayItem] {
        pages.compactMap { page, placement in
            guard let scene = builders[placement.master]?.scene else { return nil }
            let shift = AffineTransform.translation(x: placement.origin.x, y: placement.origin.y)
            let children = scene.topLevel.compactMap { id -> DisplayItem? in
                guard let object = scene.objects[id], object.layer == layer else { return nil }
                return object.item.transformed(by: shift)
            }
            guard !children.isEmpty else { return nil }
            var group = GroupItem(children: children)
            group.inert = true
            if output { group.clip = DisplayPath(rect: placement.bleedRect) }
            return .group(group)
        }
    }
}
