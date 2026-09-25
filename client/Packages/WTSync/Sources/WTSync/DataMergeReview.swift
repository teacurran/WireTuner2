import Foundation
import WTCRDT
import WTModel
import WTProto

// The data-merge rows of the review sheet (data-merge.adoc, "Merge semantics"; DATA-020 and
// DATA-023): *two merge runs* -- two people merged records to pages after the same page -- and
// *field removed with N bindings* -- a field one side deleted that the other side's objects use.
// Both are measured with the rest of the divergence (`Divergence.measure`) and are always listed:
// neither is an object changed on both sides, so the overlap rules would never show them.

/// One person's *Merge to Pages*: the pages and top-level objects its chunks created.
public struct MergeRun: Sendable, Hashable {
    /// The chunks' label ("Merge 250 records to pages").
    public var label: String
    public var replica: UInt64
    /// The pages created, in creation order.
    public var pages: [OpID]
    /// The objects created on them whose parent the run did not create (layers' children).
    public var objects: [OpID]

    public init(label: String, replica: UInt64, pages: [OpID], objects: [OpID]) {
        self.label = label
        self.replica = replica
        self.pages = pages
        self.objects = objects
    }

    /// The run's first page id: the run with the greater one is the later run.
    var first: OpID { pages.min() ?? .zero }
}

/// The *two merge runs* entry: a local and a remote merge whose pages follow the same page.
public struct MergeRunConflict: Sendable, Hashable, Identifiable {
    /// The page both runs were placed after (the template, for a merge of one template page).
    public var page: OpID
    public var mine: MergeRun
    public var theirs: MergeRun

    public init(page: OpID, mine: MergeRun, theirs: MergeRun) {
        self.page = page
        self.mine = mine
        self.theirs = theirs
    }

    public var id: String { "merge-runs:\(page)" }

    /// The review sheet's choices.
    public enum Choice: Sendable, Hashable, CaseIterable {
        /// *Keep both, one after the other*: the later run's pages move after the earlier run's last.
        case keepBoth
        /// *Remove theirs*: the remote run's pages and objects are deleted.
        case removeTheirs
        /// *Remove mine*: the local run's pages and objects are deleted.
        case removeMine

        public var title: String {
            switch self {
            case .keepBoth: "Keep both, one after the other"
            case .removeTheirs: "Remove theirs"
            case .removeMine: "Remove mine"
            }
        }
    }

    /// The earlier and the later run (by first page id, the order the merge engine sees).
    public var ordered: (earlier: MergeRun, later: MergeRun) {
        mine.first < theirs.first ? (mine, theirs) : (theirs, mine)
    }

    /// The choice as one change against `state`; nil when it writes nothing (the runs are already
    /// in order, or the pages to remove are gone).
    public func command(_ choice: Choice, in state: EngineState) -> OpsCommand? {
        switch choice {
        case .keepBoth:
            return keepBoth(in: state)
        case .removeTheirs:
            return Self.remove(theirs, in: state)
        case .removeMine:
            return Self.remove(mine, in: state)
        }
    }

    /// Moves the later run's live pages, in their current order, between the earlier run's last
    /// page and the page after it.
    func keepBoth(in state: EngineState) -> OpsCommand? {
        let (earlier, later) = ordered
        let siblings = state.store.children(WellKnown.pages).filter { state.isLive($0) }
        let moving = siblings.filter(Set(later.pages).contains)
        let earlierPages = Set(earlier.pages)
        guard !moving.isEmpty, let last = siblings.lastIndex(where: earlierPages.contains) else { return nil }
        let after = siblings[(last + 1)...].filter { !moving.contains($0) }
        let already = Array(siblings[(last + 1)...].prefix(moving.count))
        guard already != moving else { return nil }
        var lo = state.store.placement(siblings[last])?.position
        let hi = after.first.flatMap { state.store.placement($0)?.position }
        var ops: [Wiretuner_Doc_V1_Op] = []
        for page in moving {
            guard let key = try? FractionalIndex.between(lo, hi, suffix: UInt64(truncatingIfNeeded: page.counter) &* 0x9E37_79B9_7F4A_7C15 ^ page.replica)
            else { return nil }
            ops.append(Ops.move(page, parent: WellKnown.pages, position: key))
            lo = key
        }
        return OpsCommand("Keep both merges", ops: ops)
    }

    /// Deletes `run`'s live pages and objects.
    static func remove(_ run: MergeRun, in state: EngineState) -> OpsCommand? {
        let ops = (run.pages + run.objects).filter { state.isLive($0) }.map { Ops.setDeleted($0, true) }
        return ops.isEmpty ? nil : OpsCommand("Remove merged pages", ops: ops)
    }
}

/// The *field removed with N bindings* entry: a field deleted on one side that objects the other
/// side wrote use.  *Restore* is `RestoreField`.
public struct FieldRemovedEntry: Sendable, Hashable, Identifiable {
    public var field: OpID
    /// The field's name as last stored (readable on the deleted element).
    public var name: String
    /// Placeholders and bindings using it in the merged state.
    public var uses: Int
    /// True when the deletion was this Mac's (the uses are remote), false when it arrived.
    public var deletedLocally: Bool

    public init(field: OpID, name: String, uses: Int, deletedLocally: Bool) {
        self.field = field
        self.name = name
        self.uses = uses
        self.deletedLocally = deletedLocally
    }

    public var id: String { "field-removed:\(field)" }

    /// "Field “city” removed with 3 bindings".
    public var title: String {
        "Field \u{201C}\(name)\u{201D} removed with \(uses) \(uses == 1 ? "binding" : "bindings")"
    }

    /// *Restore*: the field comes back and every use resolves again.
    public var restore: RestoreField { RestoreField(field) }
}

/// Measuring the data-merge rows.
public enum DataMergeReview {
    /// Whether `label` is a *Merge to Pages* chunk's ("Merge 3 records to pages"; a prefix, as a
    /// scripted or simulated label carries, is allowed).
    public static func isMergeLabel(_ label: String) -> Bool {
        mergeTitle(label) != nil
    }

    /// The *Merge to Pages* part of `label`, nil when it is not a merge chunk's.
    static func mergeTitle(_ label: String) -> Substring? {
        label.range(of: #"Merge [0-9]+ records? to pages$"#, options: .regularExpression).map { label[$0] }
    }

    /// The merge runs in `changes`: consecutive merge chunks of one replica under one label.
    public static func runs(_ changes: [Wiretuner_Doc_V1_Change]) -> [MergeRun] {
        var runs: [MergeRun] = []
        var open: [UInt64: Int] = [:]
        for change in changes {
            guard let title = mergeTitle(change.label) else {
                open[change.replica] = nil
                continue
            }
            var created: Set<OpID> = []
            var pages: [OpID] = []
            var objects: [OpID] = []
            for (op, id) in zip(change.ops, change.opIDs) {
                guard case .create(let create)? = op.op else { continue }
                created.insert(id)
                if case .page? = create.props.kind {
                    pages.append(id)
                } else if !created.contains(OpID(create.parent)) {
                    objects.append(id)
                }
            }
            if let index = open[change.replica], runs[index].label == title {
                runs[index].pages += pages
                runs[index].objects += objects
            } else {
                open[change.replica] = runs.count
                runs.append(MergeRun(label: String(title), replica: change.replica, pages: pages, objects: objects))
            }
        }
        return runs.filter { !$0.pages.isEmpty }
    }

    /// Local and remote runs placed after the same page, one entry per page.
    public static func conflicts(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState) -> [MergeRunConflict] {
        let mine = runs(local)
        let theirs = runs(remote)
        guard !mine.isEmpty, !theirs.isEmpty else { return [] }
        let order = state.store.children(WellKnown.pages)
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let merged = Set((mine + theirs).flatMap(\.pages))
        func predecessor(_ run: MergeRun) -> OpID? {
            guard let start = run.pages.compactMap({ index[$0] }).min() else { return nil }
            return order[..<start].last { !merged.contains($0) }
        }
        func grouped(_ runs: [MergeRun]) -> [OpID: MergeRun] {
            var out: [OpID: MergeRun] = [:]
            for run in runs {
                guard let page = predecessor(run) else { continue }
                if var existing = out[page] {
                    existing.pages += run.pages
                    existing.objects += run.objects
                    out[page] = existing
                } else {
                    out[page] = run
                }
            }
            return out
        }
        let ours = grouped(mine)
        let others = grouped(theirs)
        return ours.keys.filter { others[$0] != nil }.sorted().map { MergeRunConflict(page: $0, mine: ours[$0]!, theirs: others[$0]!) }
    }

    /// Fields deleted on one side whose uses in the merged state include objects the other side
    /// created or wrote.
    public static func removedFields(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState) -> [FieldRemovedEntry] {
        let localDeletes = fieldDeletes(local)
        let remoteDeletes = fieldDeletes(remote)
        guard !localDeletes.isEmpty || !remoteDeletes.isEmpty else { return [] }
        let model = DataModel(state)
        let counts = model.uses(in: state)
        var out: [FieldRemovedEntry] = []
        for (deletes, others, locally) in [(localDeletes, touched(remote), true), (remoteDeletes, touched(local), false)] {
            for field in deletes.sorted() where model.field(field) == nil && (counts[field] ?? 0) > 0 {
                guard others.contains(where: { uses(of: field, node: $0, model: model, state: state) }) else { continue }
                out.append(FieldRemovedEntry(field: field, name: name(of: field, in: state), uses: counts[field] ?? 0, deletedLocally: locally))
            }
        }
        return out.sorted { $0.field < $1.field }
    }

    /// The field elements `changes` left deleted (the last write of each).
    static func fieldDeletes(_ changes: [Wiretuner_Doc_V1_Change]) -> Set<OpID> {
        var last: [OpID: Bool] = [:]
        for change in changes {
            for op in change.ops {
                guard case .elementDelete(let delete)? = op.op, OpID(delete.node) == WellKnown.settings else { continue }
                for element in delete.elements {
                    guard let path = RegisterPath(element), path.segments.count == DataFieldsPaths.fields.segments.count + 1,
                          path.segments.starts(with: DataFieldsPaths.fields.segments),
                          case .element(let id)? = path.segments.last else { continue }
                    last[id] = delete.deleted
                }
            }
        }
        return Set(last.compactMap { $0.value ? $0.key : nil })
    }

    /// The nodes `changes` created or wrote (not the settings node).
    static func touched(_ changes: [Wiretuner_Doc_V1_Change]) -> Set<OpID> {
        var nodes: Set<OpID> = []
        for change in changes {
            for (op, id) in zip(change.ops, change.opIDs) {
                switch op.op {
                case .create: nodes.insert(id)
                case .set(let set): nodes.insert(OpID(set.node))
                case .textInsert(let insert): nodes.insert(OpID(insert.node))
                case .textMark(let mark): nodes.insert(OpID(mark.node))
                default: break
                }
            }
        }
        nodes.remove(WellKnown.settings)
        return nodes
    }

    /// Whether `node` (live) binds `field` or holds a placeholder of it.
    static func uses(of field: OpID, node: OpID, model: DataModel, state: EngineState) -> Bool {
        guard state.isLive(node) else { return false }
        if model.binding(of: node, in: state)?.field == field { return true }
        guard let text = TextNode(node, in: state) else { return false }
        return model.placeholders(in: text).contains { $0.field == field }
    }

    /// The name the deleted field element still holds.
    static func name(of field: OpID, in state: EngineState) -> String {
        let path = DataFieldsPaths.name(field)
        guard let bytes = state.store.register(WellKnown.settings, path)?.value else { return "" }
        return SparseProps.wrap(path, bytes).settings.dataFields.first?.name ?? ""
    }
}
