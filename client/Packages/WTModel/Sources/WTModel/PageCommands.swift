import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DOC-006: the page commands (pages.adoc, "Data model" and "Client"): add, duplicate, remove with
// the straddle rule, move with or without contents, reorder, resize and rotate.  Each is one
// change; a drag coalesces through the outbox and groups into one undo step (APP-011).

/// *Add Pages…* and btn:[Add Page]: `count` pages after `after` in page order (after the last
/// page when nil), placed on the pasteboard to the right of the rightmost page's bleed rectangle
/// plus one inch, each to the right of the one before, top-aligned with the page they follow.
/// Geometry, bleed and master default to the `after` page's (the sheet's values when given).
/// "Add page" / "Add N pages".
public struct AddPages: Command {
    public var count: Int
    public var geometry: PageGeometry?
    public var bleed: Double?
    /// The master to make the pages children of; `.some(nil)` makes ordinary pages.
    public var master: OpID??
    public var after: OpID?

    /// The gap between pages that Add leaves: one inch.
    public static let gap = 72.0

    public init(count: Int = 1, geometry: PageGeometry? = nil, bleed: Double? = nil, master: OpID?? = nil, after: OpID? = nil) {
        self.count = count
        self.geometry = geometry
        self.bleed = bleed
        self.master = master
        self.after = after
    }

    public var label: String { count == 1 ? "Add page" : "Add \(count) pages" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard count >= 1, count <= 1000 else { throw PageSetupError.invalidValue("count") }
        // A single-page document never gets a second page (FONT-003); Duplicate adds through here.
        guard DocumentKind(state) != .singlePage else { throw PageSetupError.singlePageDocument }
        if let geometry, !geometry.isValid { throw PageSetupError.invalidValue("geometry") }
        if let bleed, !(bleed.isFinite && bleed >= 0 && bleed <= 720) { throw PageSetupError.invalidValue("bleed") }
        let list = PageList(state)
        let anchor = try after.map { try PageEditing.page($0, in: list) } ?? list.pages[list.pages.count - 1]
        if case .some(.some(let master)) = master, list.master(master) == nil { throw PageSetupError.notAPage(master) }
        let geometry = self.geometry ?? anchor.ownGeometry
        let bleed = self.bleed ?? anchor.ownBleed
        let master = self.master ?? anchor.master
        // Page order: between the anchor and the live page after it (after the page written for
        // a document that had none).
        let keys: [[UInt8]]
        if anchor.isSynthesized {
            let written = try PageEditing.create(anchor, builder: &builder)
            keys = try PathEditing.keys(between: written.position, and: nil, count: count)
        } else {
            let siblings = state.store.children(WellKnown.pages)
            let lo = state.store.placement(anchor.id)?.position
            let next = siblings.firstIndex(of: anchor.id).flatMap { index in siblings[(index + 1)...].first { state.isLive($0) } }
            let hi = next.flatMap { state.store.placement($0)?.position }
            keys = try PathEditing.keys(between: lo, and: hi, count: count)
        }
        let right = list.pages.map(\.bleedRect.maxX).max() ?? 0
        let effective = master.flatMap(list.master) .map { ($0.geometry, $0.bleed) } ?? (geometry, bleed)
        var x = right + Self.gap + effective.1
        for key in keys {
            let origin = Point(x: x, y: anchor.origin.y)
            builder.append(Ops.create(parent: WellKnown.pages, position: key, props: PageFields.values {
                $0.origin = PageEditing.point(origin)
                $0.geometry = geometry.stored
                $0.bleed = bleed
                if let master { $0.master.id = master.proto }
            }))
            x += effective.0.width + effective.1 * 2 + Self.gap
        }
    }
}

/// *Duplicate*: a copy of the page right after it in page order, placed like Add, with a deep
/// copy of every object on the page translated by the same distance, in one change: "Duplicate
/// page N".
public struct DuplicatePage: Command {
    public var page: OpID

    public init(_ page: OpID) {
        self.page = page
    }

    public var label: String { "Duplicate page" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let source = try PageEditing.page(page, in: list)
        let objects = PageObjects.objects(on: source, in: state, pages: list)
        try AddPages(count: 1, geometry: source.ownGeometry, bleed: source.ownBleed, master: .some(source.master), after: page)
            .execute(&builder, state: state)
        // Where Add put the copy: right of the rightmost bleed rectangle plus the gap, top-aligned.
        let right = list.pages.map(\.bleedRect.maxX).max() ?? 0
        let offset = Vector(dx: right + AddPages.gap + source.bleed - source.origin.x, dy: 0)
        var tops: [OpID: [UInt8]] = [:]
        for (node, _) in objects {
            guard let layer = state.store.placement(node)?.parent, let kind = state.nodeKind(node) else { continue }
            let lower = tops[layer] ?? state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
            let key = try PathEditing.keys(between: lower, and: nil, count: 1)[0]
            tops[layer] = key
            let copy = try NodeCopier.create(NodeTree(node, state: state), parent: layer, position: key, schema: state.schema, builder: &builder)
            let toParent = Objects.parentTransform(of: node, in: state).inverse
            let moved = Objects.transform(of: node, in: state).concatenating(.translation(toParent.apply(offset)))
            builder.append(Objects.setTransform(copy, kind: kind, moved))
        }
    }
}

/// *Remove*: deletes the pages and every object whose bounds lie entirely inside a removed page's
/// bleed rectangle (the straddle rule: an object reaching outside stays, on the pasteboard), in
/// one change "Remove page N".  A document keeps at least one page.
public struct RemovePages: Command {
    public var pages: [OpID]
    private var numbers: [Int] = []

    public init(_ pages: [OpID]) {
        self.pages = pages
    }

    /// The command with its label numbered from `state` ("Remove page 2", "Remove 3 pages").
    public init(_ pages: [OpID], in state: EngineState) {
        self.pages = pages
        let list = PageList(state)
        numbers = pages.compactMap(list.number)
    }

    public var label: String {
        if pages.count > 1 { return "Remove \(pages.count) pages" }
        return numbers.first.map { "Remove page \($0)" } ?? "Remove page"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let targets = try Set(pages.map { try PageEditing.page($0, in: list).id })
        guard !list.isSynthesized, targets.count < list.pages.count else { throw PageSetupError.lastPage }
        let order = LayerOrder(state)
        let removed = list.pages.filter { targets.contains($0.id) }
        for page in removed {
            builder.append(Ops.setDeleted(page.id))
        }
        for node in PageObjects.topLevel(in: state) where !Objects.isEffectivelyLocked(node, in: state, layers: order) {
            guard let bounds = Objects.bounds(of: node, in: state), removed.contains(where: { $0.bleedRect.contains(bounds) }) else { continue }
            builder.append(Ops.setDeleted(node))
        }
    }
}

/// The Page tool's drag and the Document panel's thumbnail drag: moves the page's `origin` by
/// `delta` and, `withContents`, every movable object on the page by the same distance (their
/// `transform` registers), in one change "Move page".  Frame only writes `origin` alone.  The
/// page is kept on the pasteboard.
public struct MovePage: Command {
    public var page: OpID
    public var delta: Vector
    public var withContents: Bool
    public var label: String { "Move page" }

    public init(_ page: OpID, by delta: Vector, withContents: Bool = true) {
        self.page = page
        self.delta = delta
        self.withContents = withContents
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard delta.isFinite else { throw PageSetupError.invalidValue("delta") }
        let list = PageList(state)
        let page = try PageEditing.page(page, in: list)
        let origin = PageEditing.clamped(page.origin + delta, size: page.geometry.size)
        let moved = origin - page.origin
        guard moved != .zero else { return }
        let objects = withContents ? PageObjects.objects(on: page, in: state, pages: list).map(\.id) : []
        let node = try PageEditing.materialize(page.id, in: list, builder: &builder)
        builder.append(Ops.set(node, [PageFields.origin], values: PageFields.values { $0.origin = PageEditing.point(origin) }))
        if !objects.isEmpty {
            try MoveObjects(objects, by: moved).execute(&builder, state: state)
        }
    }
}

/// The page list and *Move Page…*: moves a page to page number `number` (1-based, clamped) with a
/// `MoveNode` under `pages`, "Move page N".
public struct ReorderPage: Command {
    public var page: OpID
    public var number: Int
    public var label: String { "Move page \(number)" }

    public init(_ page: OpID, to number: Int) {
        self.page = page
        self.number = number
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let current = try PageEditing.page(page, in: list)
        guard !current.isSynthesized else { return }
        var others = list.pages.map(\.id)
        others.removeAll { $0 == page }
        let target = min(max(number - 1, 0), others.count)
        guard target != current.number - 1 else { return }
        let key: (OpID) -> [UInt8]? = { state.store.placement($0)?.position }
        let lo = target > 0 ? key(others[target - 1]) : nil
        let hi = target < others.count ? key(others[target]) : nil
        let position = try PathEditing.keys(between: lo, and: hi, count: 1)[0]
        builder.append(Ops.move(page, parent: WellKnown.pages, position: position))
    }
}

/// The Page tool's rotate zone: turns each page a quarter turn (portrait ↔ landscape, width and
/// height swapped around the top-left corner), "Rotate page".  Children of a master refuse.
public struct RotatePages: Command {
    public var pages: [OpID]
    public var label: String { pages.count == 1 ? "Rotate page" : "Rotate \(pages.count) pages" }

    public init(_ pages: [OpID]) {
        self.pages = pages
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        for id in pages {
            let page = try PageEditing.page(id, in: list)
            guard !page.isChild else { throw PageSetupError.childOfMaster(id) }
            let turned = page.geometry.oriented(page.geometry.orientation == .portrait ? .landscape : .portrait)
            try SetPageGeometry([id], to: turned).execute(&builder, state: state)
        }
    }
}

/// The *Modify Page* sheet: one change writing whichever of geometry, bleed and master changed,
/// "Modify page".
public struct ModifyPage: Command {
    public var page: OpID
    public var geometry: PageGeometry?
    public var bleed: Double?
    /// `.some(nil)` detaches from the master.
    public var master: OpID??
    public var label: String { "Modify page" }

    public init(_ page: OpID, geometry: PageGeometry? = nil, bleed: Double? = nil, master: OpID?? = nil) {
        self.page = page
        self.geometry = geometry
        self.bleed = bleed
        self.master = master
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let current = try PageEditing.page(page, in: list)
        if let geometry, !geometry.isValid { throw PageSetupError.invalidValue("geometry") }
        if let bleed, !(bleed.isFinite && bleed >= 0 && bleed <= 720) { throw PageSetupError.invalidValue("bleed") }
        if case .some(.some(let master)) = master, list.master(master) == nil { throw PageSetupError.notAPage(master) }
        var paths: [RegisterPath] = []
        var values = PageFields.values { _ in }
        if let geometry, geometry != current.ownGeometry {
            paths.append(PageFields.geometry)
            values.page.geometry = geometry.stored
        }
        if let bleed, bleed != current.ownBleed {
            paths.append(PageFields.bleed)
            values.page.bleed = bleed
        }
        if let master, master != current.master {
            paths.append(PageFields.master)
            if let master { values.page.master.id = master.proto }
        }
        guard !paths.isEmpty else { return }
        let node = try PageEditing.materialize(current.id, in: list, builder: &builder)
        builder.append(Ops.set(node, paths, values: values))
    }
}

extension PageEditing {
    /// The pasteboard's side: 222 inches.
    static let pasteboardSide = 15_984.0

    /// `origin` moved so a page of `size` lies on the pasteboard (a page larger than it is pinned
    /// to the origin).
    static func clamped(_ origin: Point, size: Size) -> Point {
        Point(x: min(max(origin.x, 0), max(pasteboardSide - size.width, 0)), y: min(max(origin.y, 0), max(pasteboardSide - size.height, 0)))
    }

}
