import Foundation
import WTCRDT
import WTModel
import WTProto

/// One property of a reviewed object (docs/spec/reconcile.adoc, "The review sheet").
public enum ReviewProperty: Sendable, Hashable, Comparable {
    /// A register, by its path from `NodeProps`.
    case register(RegisterPath)
    /// The object's `deleted` flag.
    case deleted
    /// Its place in the tree (parent and position).
    case placement
    /// A sequence element's position, or its `deleted` flag.
    case elementPosition(RegisterPath)
    case elementDeleted(RegisterPath)

    private var order: (Int, RegisterPath?) {
        switch self {
        case .deleted: (0, nil)
        case .placement: (1, nil)
        case .register(let path): (2, path)
        case .elementPosition(let path): (3, path)
        case .elementDeleted(let path): (4, path)
        }
    }

    public static func < (lhs: ReviewProperty, rhs: ReviewProperty) -> Bool {
        let (a, b) = (lhs.order, rhs.order)
        if a.0 != b.0 { return a.0 < b.0 }
        guard let left = a.1, let right = b.1 else { return false }
        return left < right
    }
}

/// A property's value on one side: a register's field records (nil = unset), a flag, or a place.
public enum PropertyValue: Sendable, Hashable {
    case register([UInt8]?)
    case flag(Bool)
    case placement(parent: OpID, position: [UInt8])
}

/// Which side's write the merge kept.
public enum MergeSide: Sendable, Hashable {
    case mine
    case theirs
    /// A third write (someone else's, later) holds it.
    case other
}

/// One conflicting property: both values from the change log (the losing write is retained,
/// crdt-model.adoc "Merge rules"), the merged value, and which side it is.
public struct PropertyConflict: Sendable, Hashable {
    public var property: ReviewProperty
    public var mine: PropertyValue?
    public var theirs: PropertyValue?
    public var merged: PropertyValue?
    public var kept: MergeSide

    public init(property: ReviewProperty, mine: PropertyValue?, theirs: PropertyValue?, merged: PropertyValue?, kept: MergeSide) {
        self.property = property
        self.mine = mine
        self.theirs = theirs
        self.merged = merged
        self.kept = kept
    }
}

/// A paragraph both sides touched: the TEXT field and the newline ending it (`.zero`: the last).
public struct ParagraphRef: Sendable, Hashable {
    public var text: RegisterPath
    public var terminator: OpID

    public init(text: RegisterPath, terminator: OpID) {
        self.text = text
        self.terminator = terminator
    }
}

/// What the review sheet offers for one object (reconcile.adoc, "Per object").
public enum ReviewAction: Sendable, Hashable {
    /// Re-assert the local values as a fresh change (`ReviewModel.useMine`).
    case useMine
    /// Keep the merge; marks the row reviewed.
    case useTheirs
    /// Duplicate the object with the local state, offset by *Keep both offset* (SYNC-007, WTApp).
    case keepBoth
    /// `deleted = false` (`ReviewModel.restore`).
    case restore
}

/// One listed object, or an always-listed document setting.
public struct ReviewEntry: Sendable, Hashable, Identifiable {
    /// The object (the settings node 0:1 for a setting entry).
    public var node: OpID
    /// Every kind of overlap found, and the most severe (`kind`), which the list shows.
    public var kinds: Set<OverlapKind>
    /// The conflicting properties with mine, theirs and merged values.
    public var properties: [PropertyConflict]
    /// Paragraphs both sides touched (`same text`).
    public var paragraphs: [ParagraphRef]
    /// The replicas whose remote changes touched it (names via `ReviewModel.authors`).
    public var authors: [UInt64]
    /// A register both sides wrote whose local value lost: always listed.
    public var localWriteLost: Bool
    /// For a setting entry, which setting changed remotely.
    public var setting: DocumentSetting?
    /// Set when the object is `edit vs delete` because an ancestor was deleted.
    public var deletedAncestor: OpID?
    /// Listed only because an open comment thread is anchored to it (comments.adoc).
    public var anchoredComment: Bool
    /// Field paths each side wrote.
    public var localPaths: [RegisterPath]
    public var remotePaths: [RegisterPath]
    /// What the sheet offers.
    public var actions: [ReviewAction]

    public init(node: OpID, kinds: Set<OverlapKind>, properties: [PropertyConflict] = [], paragraphs: [ParagraphRef] = [],
                authors: [UInt64] = [], localWriteLost: Bool = false, setting: DocumentSetting? = nil, deletedAncestor: OpID? = nil,
                anchoredComment: Bool = false, localPaths: [RegisterPath] = [], remotePaths: [RegisterPath] = [],
                actions: [ReviewAction] = []) {
        self.node = node
        self.kinds = kinds
        self.properties = properties
        self.paragraphs = paragraphs
        self.authors = authors
        self.localWriteLost = localWriteLost
        self.setting = setting
        self.deletedAncestor = deletedAncestor
        self.anchoredComment = anchoredComment
        self.localPaths = localPaths
        self.remotePaths = remotePaths
        self.actions = actions
    }

    public var id: String { setting.map { "setting:\($0.rawValue)" } ?? "node:\(node)" }

    /// The kind the list shows.
    public var kind: OverlapKind { kinds.min() ?? .bothEdited }

    /// Lost local writes first, then settings, then by kind.
    var sortKey: Int { (localWriteLost ? 0 : 100) + (setting == nil ? 10 : 0) + kind.rawValue }
}

/// A remote author of the merged changes.
public struct ReviewAuthor: Sendable, Hashable {
    public var replica: UInt64
    /// The display name the server attached (`SequencedChange.author`), "" when unknown.
    public var name: String
    public var ops: Int

    public init(replica: UInt64, name: String, ops: Int) {
        self.replica = replica
        self.name = name
        self.ops = ops
    }
}

/// What the review sheet (SYNC-007, WTApp) renders after a reconnect (docs/spec/reconcile.adoc,
/// "The review sheet"), or after salvage (docs/spec/offline.adoc, "Replica expiry and salvage").
public struct ReviewModel: Sendable, Hashable {
    /// How the sheet opens.
    public enum Mode: Sendable, Hashable {
        /// Already merged and uploaded; *Review what changed* opens it read-only.
        case readOnly
        /// Conflicting objects listed one by one; the outbox waits.
        case perObject
        /// Whole-document review with the three primary choices; the outbox waits.
        case wholeDocument
        /// Changes recovered from an expired session, with the dropped items named; the outbox waits.
        case recovered
    }

    /// The document-level choices (reconcile.adoc, "Whole document"; offline.adoc for salvage).
    public enum DocumentAction: Sendable, Hashable {
        /// Upload the merge as it is (*Keep the merged result*, *Done*, dismissing, or *Send*).
        case keepMerged
        /// *Save my version as a copy…*: fork, then `SyncClient.resolveReview(.discardLocalChanges)`.
        case saveCopy
        /// *Keep my changes on a branch*: the same through BranchService.
        case keepBranch
    }

    public var mode: Mode
    public var decision: ReconcileDecision
    /// Volume (reconcile.adoc): unsent local ops, remote ops, and the gap.
    public var localOps: Int
    public var remoteOps: Int
    public var gap: Duration
    public var localObjects: Int
    public var remoteObjects: Int
    public var authors: [ReviewAuthor]
    public var entries: [ReviewEntry]
    /// The *two merge runs* rows (data-merge.adoc), each with its three choices.
    public var mergeRuns: [MergeRunConflict] = []
    /// The *field removed with N bindings* rows, each with *Restore*.
    public var removedFields: [FieldRemovedEntry] = []
    /// The *released stale master* and *duplicate release* rows (master-pages.adoc).
    public var releaseOverlaps: [ReleaseOverlap] = []
    /// The "drawn while the font was rescaled" rows, each with *Rescale mine* (font-info.adoc).
    public var rescaleRows: [RescaleEntry] = []
    /// The "placed an instance of a removed symbol" and "uses a removed style" rows.
    public var removedTargets: [RemovedTargetEntry] = []
    /// For `.recovered`: what salvage re-issued and dropped.
    public var recovered: SalvageReport?
    public var documentActions: [DocumentAction]

    /// Whether the outbox waits for the user's choice.
    public var holdsOutbox: Bool { mode != .readOnly }

    /// Objects changed on both sides.
    public var overlapCount: Int { entries.lazy.filter { $0.setting == nil }.count }

    /// The review of a measured divergence.
    public init(_ divergence: Divergence, decision: ReconcileDecision, names: [UInt64: String] = [:]) {
        switch decision {
        case .silentMerge, .suggestReview: mode = .readOnly
        case .perObject: mode = .perObject
        case .wholeDocument: mode = .wholeDocument
        }
        self.decision = decision
        localOps = divergence.localOps
        remoteOps = divergence.remoteOps
        gap = divergence.gap
        localObjects = divergence.localObjects
        remoteObjects = divergence.remoteObjects
        authors = divergence.remoteOpsByReplica
            .map { ReviewAuthor(replica: $0.key, name: names[$0.key] ?? "", ops: $0.value) }
            .sorted { ($1.ops, $0.replica) < ($0.ops, $1.replica) }
        entries = divergence.entries
        mergeRuns = divergence.mergeRuns
        removedFields = divergence.removedFields
        releaseOverlaps = divergence.releaseOverlaps
        rescaleRows = divergence.rescaleRows
        removedTargets = divergence.removedTargets
        recovered = nil
        documentActions = mode == .readOnly ? [] : [.keepMerged, .saveCopy, .keepBranch]
    }

    /// The review of a salvage (offline.adoc): send, or keep the whole set as a branch.
    public init(recovered report: SalvageReport) {
        mode = .recovered
        decision = .perObject
        localOps = report.reissuedOps
        remoteOps = 0
        gap = .zero
        localObjects = 0
        remoteObjects = 0
        authors = []
        entries = []
        recovered = report
        documentActions = [.keepMerged, .keepBranch]
    }

    /// The toast after a merge: "Merged 811 changes from Priya, Tom".
    public var toast: String {
        let names = authors.map { $0.name.isEmpty ? "someone" : $0.name }
        var unique: [String] = []
        for name in names where !unique.contains(name) {
            unique.append(name)
        }
        let who = unique.isEmpty ? "" : " from " + unique.joined(separator: ", ")
        return remoteOps == 1 ? "Merged 1 change\(who)" : "Merged \(remoteOps) changes\(who)"
    }

    /// The header line: "You made 2,314 changes offline (14 h). Meanwhile Priya made 811 and Tom 40."
    public var summary: String {
        let hours = Int(gap.components.seconds / 3600)
        let when = hours > 0 ? " (\(hours) h)" : ""
        var text = "You made \(localOps.formatted()) \(localOps == 1 ? "change" : "changes") offline\(when)."
        if !authors.isEmpty {
            let parts = authors.map { "\($0.name.isEmpty ? "someone" : $0.name) made \($0.ops.formatted())" }
            let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            text += " Meanwhile \(list)."
        }
        return text
    }

    // MARK: Choices as changes

    /// *Use mine*: a change re-asserting every local value the merge did not keep (a fresh op, so
    /// it wins by Lamport order); nil when the merge already holds them all.
    public static func useMine(_ entry: ReviewEntry) -> OpsCommand? {
        var ops: [Wiretuner_Doc_V1_Op] = []
        for conflict in entry.properties where conflict.kept != .mine {
            switch (conflict.property, conflict.mine) {
            case (.register(let path), .register(let value)?):
                ops.append(Ops.set(entry.node, [path], values: SparseProps.wrap(path, value)))
            case (.deleted, .flag(let flag)?):
                ops.append(Ops.setDeleted(entry.node, flag))
            case (.placement, .placement(let parent, let position)?):
                ops.append(Ops.move(entry.node, parent: parent, position: position))
            case (.elementPosition(let path), .register(let position?)?):
                ops.append(Ops.elementMove(entry.node, path, position: position))
            case (.elementDeleted(let path), .flag(let flag)?):
                ops.append(Ops.elementDelete(entry.node, [path], deleted: flag))
            default:
                break
            }
        }
        return ops.isEmpty ? nil : OpsCommand("Use My Version", ops: ops)
    }

    /// *Restore* for `edit vs delete`: `deleted = false` (the edits are already on the object).
    public static func restore(_ entry: ReviewEntry) -> OpsCommand {
        OpsCommand("Restore", ops: [Ops.setDeleted(entry.node, false)])
    }
}

/// Sparse `NodeProps` holding one register's value, as a `SetFields` carries it.
enum SparseProps {
    /// The value's field records wrapped in the messages its path's field numbers name (element
    /// segments are transparent: the sequence field's one occurrence is the element).
    /// A nil value (unset) is empty props: a path with no value clears its register.
    static func wrap(_ path: RegisterPath, _ value: [UInt8]?) -> Wiretuner_Doc_V1_NodeProps {
        guard var bytes = value else { return Wiretuner_Doc_V1_NodeProps() }
        for field in path.fields.dropLast().reversed() {
            bytes = BulkFrames.varintBytes(UInt64(field) << 3 | 2) + BulkFrames.varintBytes(UInt64(bytes.count)) + bytes
        }
        // A register holds well-formed field records, so the wrapped message always decodes.
        // swiftlint:disable:next force_try
        return try! Wiretuner_Doc_V1_NodeProps(serializedBytes: bytes)
    }
}

extension BulkFrames {
    /// The protobuf varint encoding of `value`.
    static func varintBytes(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        return bytes + [UInt8(value)]
    }
}
