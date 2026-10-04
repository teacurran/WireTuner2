import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The small pictures in the Layers panel's object rows (layers.adoc, "Objects in the Layers
/// panel"; LIB-031): each object's display item drawn on white at the row's size.  Only rows the
/// outline lays out ask for one; a picture is drawn off the main thread, a few rows at a time,
/// and kept with the display item it was drawn from, so a row whose object did not change keeps
/// its picture and a changed one -- however the change arrived -- is drawn again alone.  Rows
/// that scroll away before their turn are never drawn.
@MainActor
final class LayersThumbnails {
    /// The picture's side in points.
    nonisolated static let side: CGFloat = 18
    /// Pixels per point the pictures are drawn at.
    nonisolated static let scale: Double = 2
    /// The most pictures kept; the oldest go first.
    static let capacity = 1_000
    /// The most rows drawn by one background job.
    static let batch = 16

    /// A picture and what it was drawn from.
    struct Entry {
        let item: DisplayItem
        /// Nil for an object that paints nothing.
        let image: CGImage?
    }

    /// What a picture is drawn from: the object's display item as placed, and its painted
    /// bounds.  Nil when the object is not drawn (a hidden layer, a deleted object).
    var source: @MainActor (OpID) -> (item: DisplayItem, bounds: Rect)? = { _ in nil }
    /// A picture arrived: the row showing `node`, if any, takes it.
    var ready: @MainActor (OpID) -> Void = { _ in }

    private var entries: [OpID: Entry] = [:]
    /// The order pictures were stored in, for dropping the oldest.
    private var stored: [OpID] = []
    /// Rows waiting for a picture, in the order they asked.
    private var waiting: [OpID] = []
    private var waitingSet: Set<OpID> = []
    private var job: Task<Void, Never>?

    /// How many pictures have been drawn (tests: only the rows on screen, and only changed ones).
    private(set) var drawn = 0
    /// How many times each object's picture has been drawn.
    private(set) var draws: [OpID: Int] = [:]
    /// Whether rows are waiting or a job is drawing.
    var isBusy: Bool { job != nil || !waiting.isEmpty }
    var count: Int { entries.count }

    /// The picture for `node`'s row: the stored one -- current, or stale while its successor is
    /// drawn -- and a request for a new one when the object's drawing changed.
    func image(for node: OpID) -> CGImage? {
        let entry = entries[node]
        let current = source(node)
        if let current, entry?.item == current.item { return entry?.image }
        if current == nil {
            entries[node] = nil
            return nil
        }
        want(node)
        return entry?.image
    }

    /// Whether `node`'s stored picture was drawn from its current drawing.
    func isCurrent(_ node: OpID) -> Bool {
        guard let entry = entries[node], let current = source(node) else { return false }
        return entry.item == current.item
    }

    /// `node`'s row went off screen (or shows another object now): its turn is given up.
    func forget(_ node: OpID) {
        guard waitingSet.remove(node) != nil else { return }
        waiting.removeAll { $0 == node }
    }

    /// Drops every picture (another document).
    func reset() {
        job?.cancel()
        job = nil
        entries = [:]
        draws = [:]
        stored = []
        waiting = []
        waitingSet = []
    }

    private func want(_ node: OpID) {
        guard waitingSet.insert(node).inserted else { return }
        waiting.append(node)
        pump()
    }

    /// Starts a background job for the next rows waiting, unless one is running.
    private func pump() {
        guard job == nil, !waiting.isEmpty else { return }
        let nodes = Array(waiting.prefix(Self.batch))
        waiting.removeFirst(nodes.count)
        waitingSet.subtract(nodes)
        let work = nodes.compactMap { node in source(node).map { (node, $0.item, $0.bounds) } }
        job = Task { [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                work.map { node, item, bounds in (node, item, Self.render(item, bounds: bounds)) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.job = nil
            for (node, item, image) in images { self.store(node, Entry(item: item, image: image)) }
            self.pump()
        }
    }

    private func store(_ node: OpID, _ entry: Entry) {
        drawn += 1
        draws[node, default: 0] += 1
        if entries.updateValue(entry, forKey: node) == nil { stored.append(node) }
        if stored.count > Self.capacity {
            let dropped = stored.prefix(stored.count - Self.capacity)
            for old in dropped { entries[old] = nil }
            stored.removeFirst(dropped.count)
        }
        ready(node)
    }

    /// `item` drawn on white, fitted into the picture's square with a point of margin.  A very
    /// large object is drawn at the smallest zoom and scaled down by the row.
    nonisolated static func render(_ item: DisplayItem, bounds: Rect) -> CGImage? {
        let fit = Double(side - 2) * scale
        let longer = max(bounds.width, bounds.height, 0.001)
        let zoom = Viewport.clampedZoom(fit / longer)
        let width = min(max(bounds.width * zoom, 1), 1_024)
        let height = min(max(bounds.height * zoom, 1), 1_024)
        let viewport = Viewport(scrollOrigin: bounds.origin, zoom: zoom, size: Size(width: width, height: height))
        return CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: "layers.thumbnail", items: [item]), viewport: viewport)
    }

    /// `image` as the row shows it: fitted into the square, keeping its proportions.
    static func picture(_ image: CGImage?) -> NSImage? {
        guard let image else { return nil }
        let longer = CGFloat(max(image.width, image.height, 1))
        let fit = side - 2
        let size = NSSize(width: CGFloat(image.width) / longer * fit, height: CGFloat(image.height) / longer * fit)
        return NSImage(cgImage: image, size: size)
    }
}
