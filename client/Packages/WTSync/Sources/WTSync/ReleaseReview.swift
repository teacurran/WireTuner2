import Foundation
import WTCRDT
import WTModel
import WTProto

// The master-page rows of the review sheet (master-pages.adoc, "Merge semantics"; DOC-013):
// *released stale master* -- a child page was released on one side while the other side wrote an
// object on that master's canvas, so the released copies miss the master edits -- and *duplicate
// release* -- both sides released the same page, so it holds two sets of copies.  A release is
// read from its change: `ReleaseChildPages` ends the label with the `[master:<id>]` tag and writes
// each page's `master` register before creating that page's copy groups.  Neither row is an object
// changed on both sides, so, like the data-merge rows, they are measured beside the overlap and
// always listed.

/// One page's release as its change recorded it.
public struct ReleasedPage: Sendable, Hashable {
    /// The released page and the master its copies came from.
    public var page: OpID
    public var master: OpID
    /// The replica that released it and the first op id of its change (the later change of two
    /// has the greater id).
    public var replica: UInt64
    public var change: OpID
    /// The copy groups the release created on the page's layers ("Released master content").
    public var groups: [OpID]

    public init(page: OpID, master: OpID, replica: UInt64, change: OpID, groups: [OpID]) {
        self.page = page
        self.master = master
        self.replica = replica
        self.change = change
        self.groups = groups
    }
}

/// A *released stale master* or *duplicate release* row.
public struct ReleaseOverlap: Sendable, Hashable, Identifiable {
    /// The two overlap kinds.
    public enum Kind: Sendable, Hashable, CaseIterable {
        case staleMaster
        case duplicateRelease

        public var title: String {
            switch self {
            case .staleMaster: "Released stale master"
            case .duplicateRelease: "Duplicate release"
            }
        }
    }

    /// The review sheet's choices.
    public enum Choice: Sendable, Hashable, CaseIterable {
        /// *Update the copies*: the copy groups are replaced by copies of the current master.
        case updateCopies
        /// *Keep my copies*: nothing is written.
        case keepCopies
        /// *Remove duplicates*: the later release's copy groups are deleted.
        case removeDuplicates

        public var title: String {
            switch self {
            case .updateCopies: "Update the copies"
            case .keepCopies: "Keep my copies"
            case .removeDuplicates: "Remove duplicates"
            }
        }
    }

    public var kind: Kind
    /// The page the row is listed under.
    public var page: OpID
    public var master: OpID
    /// The release whose copies are stale, or the later of two releases.
    public var release: ReleasedPage
    /// For a duplicate, the earlier release (kept).
    public var earlier: ReleasedPage?
    /// For a stale master, the replicas whose writes the copies miss; for a duplicate, the other
    /// release's replica.
    public var authors: [UInt64]

    public init(kind: Kind, page: OpID, master: OpID, release: ReleasedPage, earlier: ReleasedPage? = nil, authors: [UInt64] = []) {
        self.kind = kind
        self.page = page
        self.master = master
        self.release = release
        self.earlier = earlier
        self.authors = authors
    }

    public var id: String {
        switch kind {
        case .staleMaster: "released-stale-master:\(page)"
        case .duplicateRelease: "duplicate-release:\(page)"
        }
    }

    /// What the sheet offers.
    public var choices: [Choice] {
        switch kind {
        case .staleMaster: [.updateCopies, .keepCopies]
        case .duplicateRelease: [.removeDuplicates, .keepCopies]
        }
    }

    /// The choice as one change; nil when it writes nothing (*Keep my copies*, a choice the row
    /// does not offer, or copies already gone).
    public func command(_ choice: Choice, in state: EngineState) -> (any Command)? {
        guard choices.contains(choice) else { return nil }
        switch choice {
        case .updateCopies:
            return UpdateReleasedCopies(release)
        case .removeDuplicates:
            let ops = release.groups.filter { state.isLive($0) }.map { Ops.setDeleted($0, true) }
            return ops.isEmpty ? nil : OpsCommand("Remove duplicate copies", ops: ops)
        case .keepCopies:
            return nil
        }
    }
}

/// *Update the copies*: deletes a release's live copy groups and copies the master's current
/// objects onto the page again, as `ReleaseChildPages` did -- one group per layer holding master
/// objects, at the bottom of the layer, translated by the page's origin, each copy's `canvas`
/// cleared.  One change, so one undo step.
public struct UpdateReleasedCopies: Command {
    public var release: ReleasedPage
    public var label: String { "Update the copies" }

    public init(_ release: ReleasedPage) {
        self.release = release
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for group in release.groups where state.isLive(group) {
            builder.append(Ops.setDeleted(group, true))
        }
        let origin = state.props(release.page).page.origin
        var transform = Wiretuner_Doc_V1_Transform()
        transform.a = 1
        transform.d = 1
        transform.tx = origin.x
        transform.ty = origin.y
        for (layer, objects) in MasterContent.objects(of: release.master, in: state) {
            let first = state.liveChildren(layer).first.flatMap { state.store.placement($0)?.position }
            let key = try FractionalIndex.between(nil, first, suffix: builder.nextCounter)
            var group = Wiretuner_Doc_V1_NodeProps()
            group.group.common.name = "Released master content"
            group.group.common.transform = transform
            let groupID = builder.append(Ops.create(parent: layer, position: key, props: group))
            var previous: [UInt8]?
            for object in objects {
                guard let kind = state.nodeKind(object) else { continue }
                let childKey = try FractionalIndex.between(previous, nil, suffix: builder.nextCounter)
                previous = childKey
                let copy = try NodeCopier.create(NodeTree(object, state: state), parent: groupID, position: childKey, schema: state.schema,
                                                 builder: &builder)
                builder.append(Ops.set(copy, [RegisterPath([kind.rawValue, 1, 5])], values: Wiretuner_Doc_V1_NodeProps()))
            }
        }
    }
}

/// Measuring the master-page rows.
public enum ReleaseReview {
    /// The page releases in `changes`, in order: in a change whose label carries the master tag,
    /// each `SetFields` writing a page's `master` starts that page, and the objects created on a
    /// layer after it (not inside something the change created) are its copy groups.
    public static func releases(_ changes: [Wiretuner_Doc_V1_Change]) -> [ReleasedPage] {
        var out: [ReleasedPage] = []
        for change in changes {
            guard let master = MasterContent.releasedMaster(fromLabel: change.label) else { continue }
            let ids = change.opIDs
            guard let first = ids.first else { continue }
            var created: Set<OpID> = []
            var current: Int?
            for (op, id) in zip(change.ops, ids) {
                switch op.op {
                case .set(let set) where set.paths.compactMap(RegisterPath.init).contains(PageFields.master):
                    current = out.count
                    out.append(ReleasedPage(page: OpID(set.node), master: master, replica: change.replica, change: first, groups: []))
                case .create(let create):
                    created.insert(id)
                    if let index = current, !created.contains(OpID(create.parent)) {
                        out[index].groups.append(id)
                    }
                default:
                    break
                }
            }
        }
        return out
    }

    /// The rows: each release on one side whose master had an object on its canvas written by the
    /// other side (one row per page, whichever side released it), and each page both sides released.
    public static func overlaps(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState) -> [ReleaseOverlap] {
        let mine = releases(local)
        let theirs = releases(remote)
        guard !mine.isEmpty || !theirs.isEmpty else { return [] }
        var rows: [ReleaseOverlap] = []
        var stale: Set<OpID> = []
        for (ours, others) in [(mine, remote), (theirs, local)] where !ours.isEmpty {
            let writers = canvasWriters(others, state: state)
            for release in ours where !stale.contains(release.page) {
                guard let authors = writers[release.master] else { continue }
                stale.insert(release.page)
                rows.append(ReleaseOverlap(kind: .staleMaster, page: release.page, master: release.master, release: release,
                                           authors: authors.sorted()))
            }
        }
        for ours in mine {
            guard let other = theirs.first(where: { $0.page == ours.page }) else { continue }
            let (earlier, later) = ours.change < other.change ? (ours, other) : (other, ours)
            rows.append(ReleaseOverlap(kind: .duplicateRelease, page: ours.page, master: later.master, release: later, earlier: earlier,
                                       authors: [other.replica]))
        }
        return rows.sorted { ($0.page, $0.kind == .staleMaster ? 0 : 1) < ($1.page, $1.kind == .staleMaster ? 0 : 1) }
    }

    /// For each master, the replicas in `changes` that wrote an object on its canvas (the object
    /// itself or anything inside it), read through the merged state.
    static func canvasWriters(_ changes: [Wiretuner_Doc_V1_Change], state: EngineState) -> [OpID: Set<UInt64>] {
        var out: [OpID: Set<UInt64>] = [:]
        var canvas: [OpID: OpID?] = [:]
        for change in changes {
            for (op, id) in zip(change.ops, change.opIDs) {
                guard let node = target(op, id), let master = masterCanvas(of: node, state: state, cache: &canvas) else { continue }
                out[master, default: []].insert(change.replica)
            }
        }
        return out
    }

    /// The node an op writes.
    static func target(_ op: Wiretuner_Doc_V1_Op, _ id: OpID) -> OpID? {
        switch op.op {
        case .create: id
        case .set(let set): OpID(set.node)
        case .move(let move): OpID(move.node)
        case .setDeleted(let flag): OpID(flag.node)
        case .elementInsert(let insert): OpID(insert.node)
        case .elementMove(let move): OpID(move.node)
        case .elementDelete(let delete): OpID(delete.node)
        case .textInsert(let insert): OpID(insert.node)
        case .textDelete(let delete): OpID(delete.node)
        case .textMark(let mark): OpID(mark.node)
        default: nil
        }
    }

    /// The master whose canvas holds `node` or one of its ancestors below the layer, if any.
    static func masterCanvas(of node: OpID, state: EngineState, cache: inout [OpID: OpID?]) -> OpID? {
        if let known = cache[node] { return known }
        var answer: OpID?
        var chain: [OpID] = []
        var current: OpID? = node
        while let at = current, chain.count < 256 {
            if let known = cache[at] {
                answer = known
                break
            }
            chain.append(at)
            if let common = NavigationFields.common(of: at, in: state), common.hasCanvas {
                answer = OpID(common.canvas.id)
                break
            }
            current = state.store.placement(at)?.parent
        }
        for visited in chain {
            cache[visited] = answer
        }
        return answer
    }
}
