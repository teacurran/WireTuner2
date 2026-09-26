import Foundation
import WTCRDT
import WTModel
import WTProto

/// The review thresholds of docs/_includes/basics/preferences.adoc ("Sync"), read by the sync
/// client at reconcile time (SYNC-006).
public struct ReconcilePreferences: Sendable, Hashable {
    /// *Auto-merge below*: a merge with no overlap and fewer ops than this on both sides is silent.
    public var autoMergeBelow: Int
    /// *Ask when overlap exceeds*: more overlapping objects than this opens the whole-document review.
    public var askOverlapCount: Int
    /// *Ask when overlap share exceeds*: the same as a share (0...1) of either side's objects.
    public var askOverlapShare: Double
    /// *Always ask when anything overlaps*: the ask threshold at zero.
    public var alwaysAsk: Bool
    /// *Suggest review after*: a gap longer than this offers *Review what changed*.
    public var suggestReviewAfter: Duration
    /// A reconnect after less than this, with fewer unsent ops than *Auto-merge below*, is a
    /// dropped connection rather than offline work: it never holds the outbox (D-070).  Not a
    /// preference.
    public var briefGap: Duration
    /// The share rule asks only when at least this many objects overlap (D-070): one object in
    /// common is not "most of what both did".  Not a preference.
    public var shareMinimum: Int

    public init(autoMergeBelow: Int = 500, askOverlapCount: Int = 20, askOverlapShare: Double = 0.25,
                alwaysAsk: Bool = false, suggestReviewAfter: Duration = .seconds(12 * 3600),
                briefGap: Duration = .seconds(15 * 60), shareMinimum: Int = 5) {
        self.autoMergeBelow = autoMergeBelow
        self.askOverlapCount = askOverlapCount
        self.askOverlapShare = askOverlapShare
        self.alwaysAsk = alwaysAsk
        self.suggestReviewAfter = suggestReviewAfter
        self.briefGap = briefGap
        self.shareMinimum = shareMinimum
    }

    /// The defaults.
    public static let standard = ReconcilePreferences()

    /// These preferences under a team's floor (preferences.adoc, "Merge semantics"): the greater
    /// of the counts, share and hours, the smaller *Auto-merge below*, and *Always ask* if either
    /// asks it.
    public func floored(by team: ReconcilePreferences) -> ReconcilePreferences {
        ReconcilePreferences(autoMergeBelow: min(autoMergeBelow, team.autoMergeBelow),
                             askOverlapCount: max(askOverlapCount, team.askOverlapCount),
                             askOverlapShare: max(askOverlapShare, team.askOverlapShare),
                             alwaysAsk: alwaysAsk || team.alwaysAsk,
                             suggestReviewAfter: max(suggestReviewAfter, team.suggestReviewAfter),
                             briefGap: max(briefGap, team.briefGap),
                             shareMinimum: max(shareMinimum, team.shareMinimum))
    }
}

/// How one object was changed on both sides (docs/spec/reconcile.adoc, "Divergence measurement"),
/// most severe first; the review sheet's words are `title` (collaboration.adoc).
public enum OverlapKind: Int, Sendable, Hashable, Comparable, CaseIterable {
    case editVsDelete
    case sameRegister
    case sameText
    case moveVsMove
    case bothEdited

    public static func < (lhs: OverlapKind, rhs: OverlapKind) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .editVsDelete: "Edited and deleted"
        case .sameRegister: "Same attribute"
        case .sameText: "Same text"
        case .moveVsMove: "Both moved"
        case .bothEdited: "Both edited"
        }
    }
}

/// A document-wide setting whose remote change is always listed (reconcile.adoc, "Decision rules").
public enum DocumentSetting: String, Sendable, Hashable, CaseIterable, Codable {
    /// `SettingsProps.color` (color-management.adoc).
    case colorSettings
    /// `SettingsProps.font` or `document_kind` (font-info.adoc): overlaps every glyph touched locally.
    case fontMetrics

    public var title: String {
        switch self {
        case .colorSettings: "Color settings"
        case .fontMetrics: "Font metrics"
        }
    }
}

/// What the divergence rules say to do (reconcile.adoc, "Decision rules").
public enum ReconcileDecision: Sendable, Hashable {
    /// No overlap, small: merge and upload; toast "Merged N changes from A, B".
    case silentMerge
    /// No overlap but large or after a long gap: merge, upload, offer *Review what changed*.
    case suggestReview
    /// 1--20 overlapping objects, or an always-listed change: hold the outbox, list each.
    case perObject
    /// A large overlap: hold the outbox, whole-document review.
    case wholeDocument

    /// Whether the outbox waits for the review.
    public var holdsOutbox: Bool { self == .perObject || self == .wholeDocument }
}

/// The measurement of docs/spec/reconcile.adoc, "Divergence measurement" (SYNC-006): which objects
/// the unsent local changes and the remote changes sequenced since the previous head touched, the
/// overlap with its kinds, and the volume.  Pure: `measure` reads the merged state (every change on
/// both sides already applied) and the changes themselves.
public struct Divergence: Sendable, Hashable {
    /// Unsent local ops, and remote ops sequenced after the previous head.
    public var localOps: Int
    public var remoteOps: Int
    /// Objects each side touched (comments, print settings and the output area left out).
    public var localObjects: Int
    public var remoteObjects: Int
    /// Remote ops per replica, for "Priya made 811 and Tom 40".
    public var remoteOpsByReplica: [UInt64: Int]
    /// Time since the previous sync.
    public var gap: Duration
    /// False when catch-up replaced the state with a snapshot, so the remote set is only the tail
    /// after it: the merge is then always offered for review.
    public var remoteComplete: Bool
    /// The overlapping objects and the always-listed setting changes, most severe first.
    public var entries: [ReviewEntry]
    /// A local and a remote *Merge to Pages* after the same page (data-merge.adoc): always listed.
    public var mergeRuns: [MergeRunConflict] = []
    /// Fields one side deleted that objects the other side wrote use (data-merge.adoc): always listed.
    public var removedFields: [FieldRemovedEntry] = []
    /// Released stale masters and duplicate releases (master-pages.adoc): always listed.
    public var releaseOverlaps: [ReleaseOverlap] = []
    /// Objects created on a glyph canvas concurrently with a units-per-em scale (font-info.adoc,
    /// "drawn while the font was rescaled"): always listed, with *Rescale mine*.
    public var rescaleRows: [RescaleEntry] = []
    /// Instances of a symbol and objects using a graphic style the other side removed
    /// (library.adoc, styles.adoc): always listed.
    public var removedTargets: [RemovedTargetEntry] = []

    /// Objects changed on both sides (setting entries not counted).
    public var overlapCount: Int { entries.lazy.filter { $0.setting == nil }.count }

    /// Whether the review has any row: an overlap, an always-listed setting, merge runs, a
    /// removed field, a release overlap or an object drawn while the font was rescaled.
    public var hasRows: Bool {
        !entries.isEmpty || !mergeRuns.isEmpty || !removedFields.isEmpty || !releaseOverlaps.isEmpty || !rescaleRows.isEmpty
            || !removedTargets.isEmpty
    }

    /// Whether a row holds the outbox without an overlap: every row but a font-metric setting
    /// entry, which is listed after offline work but merges silently when no glyph the other side
    /// touched overlaps it (font-info.adoc, "The always-list rule for font-level metrics").
    var holdsRows: Bool {
        entries.contains { $0.setting != .fontMetrics } || !mergeRuns.isEmpty || !removedFields.isEmpty
            || !releaseOverlaps.isEmpty || !rescaleRows.isEmpty || !removedTargets.isEmpty
    }

    /// The decision rules with `preferences`.
    ///
    /// D-070: a brief reconnect -- a gap under `briefGap` with fewer unsent ops than *Auto-merge
    /// below* -- merges and uploads whatever overlaps (the people were editing together a moment
    /// ago, and live editing merges the same way without asking), offering the overlap read-only
    /// through *Review what changed*; *Always ask* still asks.  After offline work the rows apply,
    /// the share rule only from `shareMinimum` overlapping objects.
    public func decision(_ preferences: ReconcilePreferences) -> ReconcileDecision {
        let overlap = overlapCount
        if hasRows && !preferences.alwaysAsk && isBrief(preferences) {
            return .suggestReview
        }
        if overlap > 0 {
            let share = max(Double(overlap) / Double(max(localObjects, 1)), Double(overlap) / Double(max(remoteObjects, 1)))
            if preferences.alwaysAsk || overlap > preferences.askOverlapCount
                || (overlap >= preferences.shareMinimum && share > preferences.askOverlapShare) {
                return .wholeDocument
            }
            return .perObject
        }
        if holdsRows {
            return .perObject
        }
        if localOps >= preferences.autoMergeBelow || remoteOps >= preferences.autoMergeBelow
            || gap > preferences.suggestReviewAfter || !remoteComplete {
            return .suggestReview
        }
        return .silentMerge
    }

    /// A dropped connection rather than offline work (D-070): back within `briefGap`, with fewer
    /// unsent ops than *Auto-merge below*.
    public func isBrief(_ preferences: ReconcilePreferences) -> Bool {
        gap < preferences.briefGap && localOps < preferences.autoMergeBelow
    }

    /// Measures `local` (the unsent local changes) against `remote` (the other replicas' changes
    /// sequenced after the previous head) in `state`, which holds both.
    public static func measure(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState,
                               gap: Duration = .zero, remoteComplete: Bool = true) -> Divergence {
        var scope = Scope(state: state)
        let mine = Side(local, scope: &scope)
        let theirs = Side(remote, scope: &scope)
        var entries: [ReviewEntry] = []
        var candidates = Set(mine.nodes.keys).intersection(theirs.nodes.keys)
        let anchored = theirs.deletes.isEmpty ? [] : scope.anchoredByOpenThreads()
        // A remote delete of an object an open thread is anchored to counts as a local touch
        // (comments.adoc, "Review sheet"); a delete of an ancestor as a delete of the object.
        candidates.formUnion(anchored.intersection(theirs.deletes))
        var ancestors: [OpID: OpID] = [:]
        for (side, other) in [(mine, theirs), (theirs, mine)] where !other.deletes.isEmpty {
            for node in side.nodes.keys where !candidates.contains(node) {
                if let deleted = scope.deletedAncestor(of: node, in: other.deletes) {
                    ancestors[node] = deleted
                    candidates.insert(node)
                }
            }
        }
        if theirs.settings[.fontMetrics] != nil {
            candidates.formUnion(mine.nodes.keys.filter { state.store.kind($0) == Scope.glyphKind })
        }
        for node in candidates {
            entries.append(scope.entry(node, mine: mine.nodes[node] ?? NodeTouch(), theirs: theirs.nodes[node] ?? NodeTouch(),
                                       anchored: anchored.contains(node), deletedAncestor: ancestors[node]))
        }
        for setting in DocumentSetting.allCases {
            guard let replicas = theirs.settings[setting] else { continue }
            entries.append(ReviewEntry(node: .wellKnown(1), kinds: [.sameRegister], authors: replicas.sorted(), setting: setting,
                                       actions: mine.settings[setting] == nil ? [.useTheirs] : [.useMine, .useTheirs]))
        }
        entries.sort { ($0.sortKey, $0.node) < ($1.sortKey, $1.node) }
        return Divergence(localOps: mine.ops, remoteOps: theirs.ops, localObjects: mine.nodes.count, remoteObjects: theirs.nodes.count,
                          remoteOpsByReplica: theirs.opsByReplica, gap: gap, remoteComplete: remoteComplete, entries: entries,
                          mergeRuns: DataMergeReview.conflicts(local: local, remote: remote, state: state),
                          removedFields: DataMergeReview.removedFields(local: local, remote: remote, state: state),
                          releaseOverlaps: ReleaseReview.overlaps(local: local, remote: remote, state: state),
                          rescaleRows: FontRescaleReview.rows(local: local, remote: remote, state: state),
                          removedTargets: RemovedTargetReview.rows(local: local, remote: remote, state: state))
    }
}

// MARK: - Touches

/// One text field's touched character spans, for paragraph mapping.
struct CharSpan: Hashable {
    let from: OpID
    let to: OpID
}

/// What one side did to one object.
struct NodeTouch {
    var edited = false
    var deleted: Stamped<Bool>?
    var move: (op: OpID, parent: OpID, position: [UInt8])?
    var paths: Set<RegisterPath> = []
    var setOps: Set<OpID> = []
    var elementPositions: [RegisterPath: Stamped<[UInt8]>] = [:]
    var elementDeletes: [RegisterPath: Stamped<Bool>] = [:]
    var text: [RegisterPath: [CharSpan]] = [:]
    var replicas: Set<UInt64> = []

    var deletes: Bool { deleted?.value == true }

    mutating func delete(_ value: Bool, _ op: OpID) {
        if deleted.map({ op > $0.op }) ?? true {
            deleted = Stamped(value, op)
        }
    }
}

/// Everything one side's changes touched.
struct Side {
    var nodes: [OpID: NodeTouch] = [:]
    var ops = 0
    var opsByReplica: [UInt64: Int] = [:]
    var settings: [DocumentSetting: Set<UInt64>] = [:]
    /// Objects whose last write of `deleted` on this side is true.
    var deletes: Set<OpID> = []

    init(_ changes: [Wiretuner_Doc_V1_Change], scope: inout Scope) {
        for change in changes {
            var counter = change.startCounter
            for op in change.ops {
                let id = OpID(counter: counter, replica: change.replica)
                counter &+= EngineState.counters(op)
                if case .noop? = op.op { continue }
                ops += 1
                opsByReplica[change.replica, default: 0] += 1
                record(op, id: id, replica: change.replica, scope: &scope)
            }
        }
        deletes = Set(nodes.compactMap { $0.value.deletes ? $0.key : nil })
    }

    private mutating func touch(_ node: OpID, _ replica: UInt64, scope: inout Scope, _ body: (inout NodeTouch) -> Void) {
        guard !scope.isComment(node) else { return }
        body(&nodes[node, default: NodeTouch()])
        nodes[node]!.replicas.insert(replica)
    }

    private mutating func record(_ op: Wiretuner_Doc_V1_Op, id: OpID, replica: UInt64, scope: inout Scope) {
        switch op.op {
        case .create:
            touch(id, replica, scope: &scope) { $0.edited = true }
        case .set(let set):
            let node = OpID(set.node)
            let paths = set.paths.compactMap(RegisterPath.init).filter { classify(node, $0, replica) }
            guard !paths.isEmpty else { return }
            let paragraphs = paths.compactMap { scope.paragraph(node, $0) }
            touch(node, replica, scope: &scope) { touch in
                touch.edited = true
                touch.setOps.insert(id)
                touch.paths.formUnion(paths)
                for (field, char) in paragraphs {
                    touch.text[field, default: []].append(CharSpan(from: char, to: char))
                }
            }
        case .move(let move):
            touch(OpID(move.node), replica, scope: &scope) { touch in
                touch.edited = true
                if touch.move.map({ id > $0.op }) ?? true {
                    touch.move = (id, OpID(move.parent), Array(move.position))
                }
            }
        case .setDeleted(let flag):
            touch(OpID(flag.node), replica, scope: &scope) { $0.delete(flag.deleted, id) }
        case .elementInsert(let insert):
            touch(OpID(insert.node), replica, scope: &scope) { $0.edited = true }
        case .elementMove(let move):
            guard let path = RegisterPath(move.element) else { return }
            touch(OpID(move.node), replica, scope: &scope) { touch in
                touch.edited = true
                if touch.elementPositions[path].map({ id > $0.op }) ?? true {
                    touch.elementPositions[path] = Stamped(Array(move.position), id)
                }
            }
        case .elementDelete(let delete):
            let paths = delete.elements.compactMap(RegisterPath.init)
            touch(OpID(delete.node), replica, scope: &scope) { touch in
                touch.edited = true
                for path in paths where touch.elementDeletes[path].map({ id > $0.op }) ?? true {
                    touch.elementDeletes[path] = Stamped(delete.deleted, id)
                }
            }
        case .textInsert(let insert):
            guard let field = RegisterPath(insert.text) else { return }
            let count = UInt64(max(1, insert.chars.unicodeScalars.count))
            let last = OpID(counter: id.counter &+ count &- 1, replica: id.replica)
            touch(OpID(insert.node), replica, scope: &scope) { touch in
                touch.edited = true
                touch.text[field, default: []].append(CharSpan(from: id, to: last))
            }
        case .textDelete(let delete):
            guard let field = RegisterPath(delete.text) else { return }
            touch(OpID(delete.node), replica, scope: &scope) { touch in
                touch.edited = true
                for range in delete.ranges {
                    let first = OpID(range.first)
                    let last = OpID(counter: first.counter &+ max(1, range.count) &- 1, replica: first.replica)
                    touch.text[field, default: []].append(CharSpan(from: first, to: last))
                }
            }
        case .textMark(let mark):
            guard let field = RegisterPath(mark.text) else { return }
            touch(OpID(mark.node), replica, scope: &scope) { touch in
                touch.edited = true
                touch.text[field, default: []].append(CharSpan(from: OpID(mark.start.char), to: OpID(mark.end.char)))
            }
        case .setAdd(let add):
            touch(OpID(add.node), replica, scope: &scope) { $0.edited = true }
        case .setRemove(let remove):
            touch(OpID(remove.node), replica, scope: &scope) { $0.edited = true }
        default:
            break
        }
    }

    /// Whether a register write counts: on the settings node, print settings, the output area and
    /// view state are never listed (reconcile.adoc), nor is a data source's embedded sample (a
    /// sample is disposable, data-merge.adoc), and color and font-level writes are recorded as
    /// always-listed settings as well.
    private mutating func classify(_ node: OpID, _ path: RegisterPath, _ replica: UInt64) -> Bool {
        guard node == .wellKnown(1), path.fields.first == 2, path.fields.count > 1 else { return true }
        if path.fields.count > 2, path.fields[1] == 81, path.fields[2] == 5 {
            return false
        }
        switch path.fields[1] {
        case 30, 31, 40, 61, 83:
            return false
        case 50:
            settings[.colorSettings, default: []].insert(replica)
        case 20:
            settings[.fontMetrics, default: []].insert(replica)
        case 21 where path.fields.count == 2 || path.fields[2] == 2:
            // `FontMetrics` (or the whole `FontProps`); names, kerning and features are
            // ordinary registers (font-info.adoc, "The always-list rule for font-level metrics").
            settings[.fontMetrics, default: []].insert(replica)
        default:
            break
        }
        return true
    }
}

extension OpID {
    init(_ id: Wiretuner_Doc_V1_ElementId) {
        self.init(counter: id.counter, replica: id.replica)
    }
}

// MARK: - Reading the merged state

/// The merged state as the measurement reads it, with the answers it caches.
struct Scope {
    static let comments = OpID.wellKnown(12)
    static let commentThreadKind: UInt32 = 210
    static let glyphKind: UInt32 = 220
    /// `CommentThreadProps.anchor` and `.resolved`.
    static let anchorPath = RegisterPath([210, 2])
    static let resolvedPath = RegisterPath([210, 6])

    let state: EngineState
    private var comment: [OpID: Bool] = [:]
    private var paragraphIndexes: [PathKey: ParagraphIndex] = [:]

    struct PathKey: Hashable {
        let node: OpID
        let field: RegisterPath
    }

    init(state: EngineState) {
        self.state = state
    }

    /// Whether `node` is the comments collection or inside it (`comments (0:12)` is never listed).
    mutating func isComment(_ node: OpID) -> Bool {
        if let known = comment[node] { return known }
        var chain: [OpID] = []
        var current: OpID? = node
        var answer = false
        while let at = current {
            if let known = comment[at] {
                answer = known
                break
            }
            chain.append(at)
            if at == Self.comments || state.store.kind(at) == Self.commentThreadKind {
                answer = true
                break
            }
            current = state.store.placement(at)?.parent
        }
        for visited in chain {
            comment[visited] = answer
        }
        return answer
    }

    /// The text field and newline character a paragraph register path (TEXT field path, then the
    /// newline's element id, then `paragraph`) names, else nil.
    func paragraph(_ node: OpID, _ path: RegisterPath) -> (RegisterPath, OpID)? {
        guard let index = path.segments.firstIndex(where: { if case .element = $0 { true } else { false } }), index > 0,
              case .element(let char) = path.segments[index] else { return nil }
        let field = RegisterPath(segments: Array(path.segments[..<index]))
        guard state.text(node, field)?.contains(char) == true else { return nil }
        return (field, char)
    }

    /// The nodes an open (unresolved, not deleted) comment thread is anchored to.
    func anchoredByOpenThreads() -> Set<OpID> {
        var anchored: Set<OpID> = []
        for thread in state.store.children(Self.comments) where state.store.kind(thread) == Self.commentThreadKind {
            guard state.store.deleted(thread)?.current.value != true,
                  let value = state.store.register(thread, Self.anchorPath)?.value,
                  let props = try? Wiretuner_Doc_V1_CommentThreadProps(serializedBytes: value), props.hasAnchor else { continue }
            if let resolved = state.store.register(thread, Self.resolvedPath)?.value,
               (try? Wiretuner_Doc_V1_CommentThreadProps(serializedBytes: resolved))?.resolved == true {
                continue
            }
            anchored.insert(OpID(props.anchor.id))
        }
        return anchored
    }

    /// The nearest ancestor of `node` in `deleted`, if any.
    func deletedAncestor(of node: OpID, in deleted: Set<OpID>) -> OpID? {
        var current = state.store.placement(node)?.parent
        var steps = 0
        while let at = current, steps < 256 {
            if deleted.contains(at) { return at }
            current = state.store.placement(at)?.parent
            steps += 1
        }
        return nil
    }

    private mutating func paragraphs(_ node: OpID, _ field: RegisterPath, _ spans: [CharSpan]) -> [Int] {
        let key = PathKey(node: node, field: field)
        if paragraphIndexes[key] == nil {
            paragraphIndexes[key] = ParagraphIndex(state.text(node, field) ?? TextSequence())
        }
        let index = paragraphIndexes[key]!
        var out: Set<Int> = []
        for span in spans {
            if let range = index.ordinals(span) {
                out.formUnion(range)
            }
        }
        return out.sorted()
    }

    /// The review entry of an object changed on both sides.
    mutating func entry(_ node: OpID, mine: NodeTouch, theirs: NodeTouch, anchored: Bool, deletedAncestor: OpID?) -> ReviewEntry {
        var kinds: Set<OverlapKind> = []
        var properties: [PropertyConflict] = []
        let merged = state.store.deleted(node)?.current
        if (mine.deletes && theirs.edited) || (theirs.deletes && (mine.edited || anchored)) || deletedAncestor != nil {
            kinds.insert(.editVsDelete)
        }
        if (mine.deleted != nil && theirs.deleted != nil) || (kinds.contains(.editVsDelete) && deletedAncestor == nil) {
            properties.append(PropertyConflict(property: .deleted, mine: mine.deleted.map { .flag($0.value) },
                                               theirs: theirs.deleted.map { .flag($0.value) }, merged: merged.map { .flag($0.value) },
                                               kept: Self.side(merged?.op, mine.deleted?.op, theirs.deleted?.op)))
            if let a = mine.deleted, let b = theirs.deleted, a.value != b.value {
                kinds.insert(.sameRegister)
            }
        }
        var lost = false
        let registers = registerConflicts(node, mine, theirs)
        if !registers.isEmpty {
            kinds.insert(.sameRegister)
            properties += registers.map(\.conflict)
            lost = registers.contains(where: \.lost)
        }
        for (path, write) in mine.elementPositions {
            guard let other = theirs.elementPositions[path] else { continue }
            kinds.insert(.sameRegister)
            let current = state.store.element(node, path)?.position.current
            properties.append(PropertyConflict(property: .elementPosition(path), mine: .register(write.value), theirs: .register(other.value),
                                               merged: current.map { .register($0.value) }, kept: Self.side(current?.op, write.op, other.op)))
        }
        for (path, write) in mine.elementDeletes {
            guard let other = theirs.elementDeletes[path], other.value != write.value else { continue }
            kinds.insert(.sameRegister)
            let current = state.store.element(node, path)?.deleted?.current
            properties.append(PropertyConflict(property: .elementDeleted(path), mine: .flag(write.value), theirs: .flag(other.value),
                                               merged: current.map { .flag($0.value) }, kept: Self.side(current?.op, write.op, other.op)))
        }
        if let a = mine.move, let b = theirs.move {
            kinds.insert(.moveVsMove)
            let current = state.store.placement(node)
            properties.append(PropertyConflict(property: .placement, mine: .placement(parent: a.parent, position: a.position),
                                               theirs: .placement(parent: b.parent, position: b.position),
                                               merged: current.map { .placement(parent: $0.parent, position: $0.position) },
                                               kept: Self.side(current?.op, a.op, b.op)))
        }
        var paragraphs: [ParagraphRef] = []
        for (field, spans) in mine.text {
            guard let others = theirs.text[field] else { continue }
            let ours = self.paragraphs(node, field, spans)
            let shared = Set(self.paragraphs(node, field, others)).intersection(ours)
            guard !shared.isEmpty else { continue }
            kinds.insert(.sameText)
            let index = paragraphIndexes[PathKey(node: node, field: field)]!
            paragraphs += shared.sorted().map { ParagraphRef(text: field, terminator: index.terminators[$0]) }
        }
        if kinds.isEmpty {
            kinds.insert(.bothEdited)
        }
        properties.sort { $0.property < $1.property }
        let deleted = merged?.value == true
        let actions: [ReviewAction] = kinds.contains(.editVsDelete)
            ? (deleted ? [.restore, .useTheirs] : [.useMine, .useTheirs])
            : [.useMine, .useTheirs, .keepBoth]
        return ReviewEntry(node: node, kinds: kinds, properties: properties, paragraphs: paragraphs,
                           authors: theirs.replicas.sorted(), localWriteLost: lost, deletedAncestor: deletedAncestor,
                           anchoredComment: anchored && !mine.edited && mine.deleted == nil,
                           localPaths: mine.paths.sorted(), remotePaths: theirs.paths.sorted(), actions: actions)
    }

    /// Which side the current write is.
    static func side(_ current: OpID?, _ mine: OpID?, _ theirs: OpID?) -> MergeSide {
        guard let current else { return .other }
        if current == mine { return .mine }
        if current == theirs { return .theirs }
        return .other
    }

    struct RegisterConflict {
        let conflict: PropertyConflict
        let lost: Bool
    }

    /// Every register of `node` both sides wrote (a field path of one covering one of the other),
    /// with the newest local and remote writes from the change log, the merged value and whether
    /// the local write lost to a different value.
    func registerConflicts(_ node: OpID, _ mine: NodeTouch, _ theirs: NodeTouch) -> [RegisterConflict] {
        guard !mine.paths.isEmpty, !theirs.paths.isEmpty else { return [] }
        let shared = mine.paths.filter { path in theirs.paths.contains { Self.overlap(path, $0) } }
        guard !shared.isEmpty else { return [] }
        var out: [RegisterConflict] = []
        for (path, register) in state.store.registers(node) where shared.contains(where: { path.segments.starts(with: $0.segments) }) {
            let writes = state.store.writes(node, path)
            guard let local = writes.filter({ mine.setOps.contains($0.op) }).max(by: { $0.op < $1.op }),
                  let remote = writes.filter({ theirs.setOps.contains($0.op) }).max(by: { $0.op < $1.op }) else { continue }
            let kept = Self.side(register.op, local.op, remote.op)
            out.append(RegisterConflict(
                conflict: PropertyConflict(property: .register(path), mine: .register(local.value), theirs: .register(remote.value),
                                           merged: .register(register.value), kept: kept),
                lost: kept != .mine && local.value != register.value))
        }
        return out
    }

    /// Whether one path is the other or a prefix of it (a STRUCT write covers its fields).
    static func overlap(_ a: RegisterPath, _ b: RegisterPath) -> Bool {
        a.segments.starts(with: b.segments) || b.segments.starts(with: a.segments)
    }
}

/// Paragraph ordinals of one TEXT field: each character, tombstones included, belongs to the
/// paragraph its next newline (itself, for a newline) terminates; the last paragraph has none.
struct ParagraphIndex {
    let ordinal: [OpID: Int]
    /// The newline ending each paragraph, `.zero` for the last.
    let terminators: [OpID]

    init(_ text: TextSequence) {
        var ordinal: [OpID: Int] = [:]
        var terminators: [OpID] = []
        for char in text.order {
            ordinal[char] = terminators.count
            if text.codepoint(char) == 0x0A {
                terminators.append(char)
            }
        }
        terminators.append(.zero)
        self.ordinal = ordinal
        self.terminators = terminators
    }

    /// The paragraphs a span covers: from its first character's to its last's (the zero id is the
    /// text's start as a first character and its end as a last one); an unknown end is ignored.
    func ordinals(_ span: CharSpan) -> ClosedRange<Int>? {
        let first = span.from == .zero ? 0 : ordinal[span.from]
        let last = span.to == .zero ? terminators.count - 1 : ordinal[span.to]
        guard let low = first ?? last, let high = last ?? first else { return nil }
        return min(low, high)...max(low, high)
    }
}
