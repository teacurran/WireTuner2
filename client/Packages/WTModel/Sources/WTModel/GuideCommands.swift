import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DOC-017: ruler guide commands (grid-guides.adoc, "Guides", "Merge semantics" and "Client").
// Guides are elements of the `guides` SEQUENCE of a page or a master page, positions in points
// from its top-left corner.  Each add, move, delete and release is one change.

/// Where a guide lives: a page's or a master page's `guides` sequence.
public enum GuideOwner: Hashable, Sendable {
    case page(OpID)
    case master(OpID)

    public var node: OpID {
        switch self {
        case .page(let id), .master(let id): id
        }
    }

    /// The `guides` SEQUENCE of the owner.
    public var sequence: RegisterPath {
        switch self {
        case .page: PageFields.guides
        case .master: MasterPageFields.guides
        }
    }

    /// A sparse `NodeProps` holding `guides` in the owner's kind.
    func values(_ guides: [Wiretuner_Doc_V1_Guide]) -> Wiretuner_Doc_V1_NodeProps {
        switch self {
        case .page: PageFields.values { $0.guides = guides }
        case .master: MasterPageFields.values { $0.guides = guides }
        }
    }

    /// The owner of the page or master `id` in `pages`.
    public static func of(_ id: OpID, in pages: PageList) -> GuideOwner? {
        if pages.master(id) != nil { return .master(id) }
        return pages[id].map { _ in .page(id) }
    }
}

/// Positions for the Guides sheet's *Add* (grid-guides.adoc, "Adding guides precisely").
public enum GuidePlacement {
    /// `count` guides spread evenly between `first` and `last` inclusive (one guide at `first`
    /// when count is 1).
    public static func byCount(_ count: Int, from first: Double, to last: Double) -> [Double] {
        guard count >= 1, first.isFinite, last.isFinite else { return [] }
        guard count > 1 else { return [first] }
        let step = (last - first) / Double(count - 1)
        return (0..<count).map { first + Double($0) * step }
    }

    /// Guides every `increment` from `first` up to `last` inclusive (at most 1,000).
    public static func byIncrement(_ increment: Double, from first: Double, to last: Double) -> [Double] {
        guard increment > 0, increment.isFinite, first.isFinite, last.isFinite, last >= first else { return [] }
        let count = min(Int(((last - first) / increment + 1e-9).rounded(.down)) + 1, 1000)
        return (0..<count).map { first + Double($0) * increment }
    }
}

/// Why a guide command could not build its change.
public enum GuideEditError: Error, Equatable, Sendable {
    case notAnOwner(OpID)
    case unknownGuide(OpID)
    case invalidValue(String)
}

enum GuideEditing {
    static func owner(_ id: OpID, in pages: PageList) throws -> GuideOwner {
        guard let owner = GuideOwner.of(id, in: pages) else { throw GuideEditError.notAnOwner(id) }
        return owner
    }

    static func checkLive(_ ids: [OpID], owner: GuideOwner, state: EngineState) throws {
        let live = Set(state.liveElements(owner.node, owner.sequence))
        for id in ids where !live.contains(id) { throw GuideEditError.unknownGuide(id) }
    }

    /// The `ElementInsert` of guides at `positions` along `axis`, after the owner's last guide.
    static func insert(_ owner: GuideOwner, axis: PageGuide.Axis, positions: [Double], state: EngineState) throws -> Wiretuner_Doc_V1_Op {
        let last = state.store.elementOrder(owner.node, owner.sequence).last.flatMap { state.position(owner.node, owner.sequence, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: positions.count)
        let guides = positions.map { position -> Wiretuner_Doc_V1_Guide in
            var guide = Wiretuner_Doc_V1_Guide()
            guide.axis = axis == .horizontal ? .horizontal : .vertical
            guide.position = position
            return guide
        }
        return Ops.elementInsert(owner.node, owner.sequence, positions: keys, values: owner.values(guides))
    }
}

/// Adds guides along `axis` at `positions` (points from the top-left corner) on each of `pages`
/// (pages or master pages): a ruler drag, kbd:[Option]-drag across pages, or the Guides sheet's
/// *Add* over a page range -- one `ElementInsert` per page, all in one change.  "Add guide" /
/// "Add N guides".
public struct AddGuides: Command {
    public var pages: [OpID]
    public var axis: PageGuide.Axis
    public var positions: [Double]

    public init(on pages: [OpID], axis: PageGuide.Axis, at positions: [Double]) {
        self.pages = pages
        self.axis = axis
        self.positions = positions
    }

    public var label: String {
        let total = pages.count * positions.count
        return total == 1 ? "Add guide" : "Add \(total) guides"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !positions.isEmpty, positions.allSatisfy(\.isFinite) else { throw GuideEditError.invalidValue("position") }
        let list = PageList(state)
        for id in pages {
            var owner = try GuideEditing.owner(id, in: list)
            if case .page(let page) = owner, page == PageList.synthesizedID {
                owner = .page(try PageEditing.materialize(page, in: list, builder: &builder))
            }
            builder.append(try GuideEditing.insert(owner, axis: axis, positions: positions, state: state))
        }
    }
}

/// Drags a guide to `position`: writes the `position` register of every coincident element the
/// row stands for (a later write wins; a concurrent delete keeps it deleted).  "Move guide".
public struct MoveGuide: Command {
    public var owner: OpID
    public var guides: [OpID]
    public var position: Double
    public var label: String { "Move guide" }

    public init(on owner: OpID, _ guides: [OpID], to position: Double) {
        self.owner = owner
        self.guides = guides
        self.position = position
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard position.isFinite else { throw GuideEditError.invalidValue("position") }
        let owner = try GuideEditing.owner(owner, in: PageList(state))
        try GuideEditing.checkLive(guides, owner: owner, state: state)
        var guide = Wiretuner_Doc_V1_Guide()
        guide.position = position
        for id in guides {
            builder.append(Ops.set(owner.node, [owner.sequence.element(id).child(3)], values: owner.values([guide])))
        }
    }
}

/// Drags a guide onto the pasteboard, or the Guides sheet's *Delete*: `ElementDelete` of the
/// elements (restorable).  "Delete guide" / "Delete N guides".
public struct DeleteGuides: Command {
    public var owner: OpID
    public var guides: [OpID]
    public var label: String { guides.count == 1 ? "Delete guide" : "Delete \(guides.count) guides" }

    public init(on owner: OpID, _ guides: [OpID]) {
        self.owner = owner
        self.guides = guides
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let owner = try GuideEditing.owner(owner, in: PageList(state))
        try GuideEditing.checkLive(guides, owner: owner, state: state)
        guard !guides.isEmpty else { return }
        builder.append(Ops.elementDelete(owner.node, guides.map { owner.sequence.element($0) }))
    }
}

/// The Guides sheet's *Release*: deletes the guides and, for each, creates a line spanning the
/// page from bleed to bleed along the guide on `layer` (the current layer), with no stroke (it
/// previews as a hairline), in one change.  On a master page the line is master content
/// (`canvas` = the master, master coordinates).  Undo removes the path and restores the guide.
/// "Release guide" / "Release N guides".
public struct ReleaseGuides: Command {
    public var owner: OpID
    public var guides: [OpID]
    public var layer: OpID?
    public var label: String { guides.count == 1 ? "Release guide" : "Release \(guides.count) guides" }

    public init(on owner: OpID, _ guides: [OpID], layer: OpID? = nil) {
        self.owner = owner
        self.guides = guides
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let owner = try GuideEditing.owner(owner, in: list)
        try GuideEditing.checkLive(guides, owner: owner, state: state)
        let stored = Dictionary(uniqueKeysWithValues: state.props(owner.node).page.guides.map { ($0.id, $0) }
            + state.props(owner.node).masterPage.guides.map { ($0.id, $0) })
        let (rect, bleed, canvas): (Rect, Double, OpID?) = switch owner {
        case .page(let id): (list[id]!.rect, list[id]!.bleed, nil)
        case .master(let id): (list.master(id)!.rect, list.master(id)!.bleed, id)
        }
        let span = rect.insetBy(dx: -bleed, dy: -bleed)
        builder.append(Ops.elementDelete(owner.node, guides.map { owner.sequence.element($0) }))
        for id in guides {
            guard let guide = stored[id.elementID] else { continue }
            let (start, end) = guide.axis == .vertical
                ? (Point(x: rect.minX + guide.position, y: span.minY), Point(x: rect.minX + guide.position, y: span.maxY))
                : (Point(x: span.minX, y: rect.minY + guide.position), Point(x: span.maxX, y: rect.minY + guide.position))
            var line = CreatePath.line(from: start, to: end, appearance: Wiretuner_Doc_V1_AppearanceProps())
            line.label = label
            line.name = "Guide"
            line.layer = layer
            let before = builder.ops.count
            try line.execute(&builder, state: state)
            if let canvas, let created = GuideEditing.createdPath(in: builder, after: before) {
                builder.append(Ops.set(created, [CommonFields.canvas(.path)], values: NodeValues.common(kind: .path) { $0.canvas.id = canvas.proto }))
            }
        }
    }
}

extension GuideEditing {
    /// The path node the ops appended after index `start` created.
    static func createdPath(in builder: ChangeBuilder, after start: Int) -> OpID? {
        var counter = builder.startCounter
        for (index, op) in builder.ops.enumerated() {
            if index >= start, case .create(let create) = op.op, case .path? = create.props.kind {
                return OpID(counter: counter, replica: builder.replica)
            }
            counter &+= EngineState.counters(op)
        }
        return nil
    }
}

extension CommonFields {
    /// `CommonProps.canvas` of `kind`.
    static func canvas(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 5]) }
}
