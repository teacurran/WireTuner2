import WTCRDT
import WTProto

/// A page's reading order (names-notes.adoc, "Reading order"; OBJ-041): what a screen reader, a
/// tagged PDF and VoiceOver read, in order.  `PageProps.reading_order` lists the objects the user
/// arranged; the order is derived, never stored whole -- the listed objects first (skipping an
/// entry whose object is deleted, unknown, decorative, not top-level or off the page, and every
/// entry after the first naming the same object), then every other object on the page in stacking
/// order.  An object is read unless it is decorative; a group without alt text is read as its
/// members in its place (`readable`).
public enum ReadingOrder {
    /// `PageProps.reading_order`.
    public static let sequence = RegisterPath([PageFields.kind, 10])

    /// The page's objects that can be listed: its top-level objects in stacking order, the
    /// decorative ones left out.
    public static func objects(on page: Page, in state: EngineState, pages: PageList) -> [OpID] {
        PageObjects.objects(on: page, in: state, pages: pages).map(\.id).filter { !isDecorative($0, in: state) }
    }

    static func isDecorative(_ node: OpID, in state: EngineState) -> Bool {
        NavigationFields.common(of: node, in: state)?.decorative == true
    }

    /// The live entries in sequence order: element id and the object named.
    public static func entries(of page: OpID, in state: EngineState) -> [(id: OpID, node: OpID?)] {
        let listed = state.props(page).page.readingOrder
        return state.liveElements(page, sequence).map { id in
            let entry = listed.first { OpID(element: $0.id) == id }
            return (id, entry.flatMap { $0.hasNode ? OpID($0.node.id) : nil })
        }
    }

    /// The top-level objects in reading order: the arranged ones, then the rest in stacking order.
    public static func order(of page: Page, in state: EngineState, pages: PageList) -> [OpID] {
        let available = objects(on: page, in: state, pages: pages)
        let allowed = Set(available)
        var seen = Set<OpID>()
        var result: [OpID] = []
        for entry in entries(of: page.id, in: state) {
            guard let node = entry.node, allowed.contains(node), seen.insert(node).inserted else { continue }
            result.append(node)
        }
        return result + available.filter { !seen.contains($0) }
    }

    /// What is read, in order: `order` with groups without alt text read as their members.
    public static func readable(of page: Page, in state: EngineState, pages: PageList) -> [OpID] {
        order(of: page, in: state, pages: pages).flatMap { node -> [OpID] in
            if state.nodeKind(node) == .group, NavigationFields.common(of: node, in: state)?.alt.isEmpty != false {
                return members(of: node, in: state)
            }
            return [node]
        }
    }

    static func members(of group: OpID, in state: EngineState) -> [OpID] {
        state.liveChildren(group).filter { Objects.isObject($0, in: state) && !isDecorative($0, in: state) }.flatMap { child -> [OpID] in
            if state.nodeKind(child) == .group, NavigationFields.common(of: child, in: state)?.alt.isEmpty != false { return members(of: child, in: state) }
            return [child]
        }
    }

    /// A sparse `NodeProps` holding `entries`.
    static func values(_ entries: [Wiretuner_Doc_V1_ReadingOrderEntry]) -> Wiretuner_Doc_V1_NodeProps {
        PageFields.values { $0.readingOrder = entries }
    }
}

/// Arranges a page's reading order as `order`, then the objects it does not name in the order
/// they read now (the sheet's drag, a click on the canvas): the
/// entries that already stand in that relative order stay, the others move (an `ElementMove` of
/// the entry, so two people moving different entries both keep their moves), and objects not
/// listed yet get entries -- one change, "Reading Order".  Objects of `order` that are not on the
/// page are ignored; nothing is written when every object already has its entry in that order.
public struct ArrangeReadingOrder: Command {
    public var page: OpID
    public var order: [OpID]
    public var label: String { "Reading Order" }

    public init(page: OpID, order: [OpID]) {
        self.page = page
        self.order = order
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let pages = PageList(state)
        guard let page = pages[page] else { throw PathEditError.notAPath(self.page) }
        let available = Set(ReadingOrder.objects(on: page, in: state, pages: pages))
        var wanted: [OpID] = []
        for node in order where available.contains(node) && !wanted.contains(node) { wanted.append(node) }
        // The objects not named keep the order they read in now, after the named ones.
        wanted += ReadingOrder.order(of: page, in: state, pages: pages).filter { !wanted.contains($0) }
        // The first entry of each object, with its position.
        var existing: [OpID: (id: OpID, position: [UInt8])] = [:]
        for entry in ReadingOrder.entries(of: page.id, in: state) {
            guard let node = entry.node, existing[node] == nil, let position = state.position(page.id, ReadingOrder.sequence, entry.id) else { continue }
            existing[node] = (entry.id, position)
        }
        let kept = Self.kept(wanted.map { existing[$0]?.position })
        var index = 0
        var lower: [UInt8]?
        while index < wanted.count {
            if kept.contains(index) {
                lower = existing[wanted[index]]!.position
                index += 1
                continue
            }
            var run: [OpID] = []
            while index < wanted.count, !kept.contains(index) {
                run.append(wanted[index])
                index += 1
            }
            let upper = index < wanted.count ? existing[wanted[index]]!.position : nil
            let keys = try PathEditing.keys(between: lower, and: upper, count: run.count)
            for (node, key) in zip(run, keys) {
                if let entry = existing[node] {
                    builder.append(Ops.elementMove(page.id, ReadingOrder.sequence.element(entry.id), position: key))
                } else {
                    let value = Wiretuner_Doc_V1_ReadingOrderEntry.with { $0.node.id = node.proto }
                    builder.append(Ops.elementInsert(page.id, ReadingOrder.sequence, positions: [key], values: ReadingOrder.values([value])))
                }
            }
            lower = keys.last
        }
    }

    /// The indices whose positions form the longest increasing run (they stay where they are).
    static func kept(_ positions: [[UInt8]?]) -> Set<Int> {
        let present = positions.indices.filter { positions[$0] != nil }
        guard !present.isEmpty else { return [] }
        var length = Array(repeating: 1, count: present.count)
        var previous = Array(repeating: -1, count: present.count)
        for i in present.indices {
            for j in 0..<i where FractionalIndex.less(positions[present[j]]!, positions[present[i]]!) && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var best = length.indices.max { length[$0] < length[$1] }!
        var result = Set<Int>()
        while best >= 0 {
            result.insert(present[best])
            best = previous[best]
        }
        return result
    }
}

/// btn:[Use Stacking Order]: every entry deleted, one change ("Use Stacking Order").
public struct ClearReadingOrder: Command {
    public var page: OpID
    public var label: String { "Use Stacking Order" }

    public init(page: OpID) {
        self.page = page
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let live = state.liveElements(page, ReadingOrder.sequence)
        guard !live.isEmpty else { return }
        builder.append(Ops.elementDelete(page, live.map { ReadingOrder.sequence.element($0) }))
    }
}
