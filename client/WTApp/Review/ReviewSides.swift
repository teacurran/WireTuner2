import Foundation
import WTCRDT
import WTModel
import WTProto
import WTSync

/// Which op ids came from which side of a merge: the unsent local changes and the remote changes
/// merged since the head before the reconnect (reconcile.adoc, "Divergence measurement").
struct ChangeSides: Sendable {
    private var local: [UInt64: [ClosedRange<UInt64>]] = [:]
    private var remote: [UInt64: [ClosedRange<UInt64>]] = [:]

    init(local: [Wiretuner_Doc_V1_Change] = [], remote: [Wiretuner_Doc_V1_Change] = []) {
        self.local = Self.ranges(local)
        self.remote = Self.ranges(remote)
    }

    private static func ranges(_ changes: [Wiretuner_Doc_V1_Change]) -> [UInt64: [ClosedRange<UInt64>]] {
        var result: [UInt64: [ClosedRange<UInt64>]] = [:]
        for change in changes {
            let count = change.ops.reduce(UInt64(0)) { $0 + EngineState.counters($1) }
            guard count > 0 else { continue }
            result[change.replica, default: []].append(change.startCounter...(change.startCounter + count - 1))
        }
        return result
    }

    func isLocal(_ id: OpID) -> Bool { local[id.replica]?.contains { $0.contains(id.counter) } ?? false }
    func isRemote(_ id: OpID) -> Bool { remote[id.replica]?.contains { $0.contains(id.counter) } ?? false }
}

/// A character-level diff of one paragraph both sides edited (reconcile.adoc, *Same text*),
/// read from the merged text: every character, tombstones included, with the side that has it.
struct ParagraphDiff: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        case both, mine, theirs
    }

    struct Segment: Equatable, Sendable {
        var side: Side
        var text: String
    }

    var segments: [Segment]
    /// The paragraph as the local side had it, and as the others left it.
    var mine: String
    var theirs: String

    init(segments: [Segment], mine: String, theirs: String) {
        self.segments = segments
        self.mine = mine
        self.theirs = theirs
    }

    /// The paragraph ending at `terminator` (`.zero`: the last) of the text field.
    static func paragraph(_ text: TextSequence, terminator: OpID) -> [OpID] {
        let order = text.order
        let newline = UInt32(("\n" as Unicode.Scalar).value)
        var start = 0
        var end = order.count
        if terminator != .zero, let index = order.firstIndex(of: terminator) { end = index + 1 }
        for index in stride(from: end - 2, through: 0, by: -1) where index < order.count && text.codepoint(order[index]) == newline {
            start = index + 1
            break
        }
        return Array(order[start..<min(end, order.count)])
    }

    /// Whether the local side and the others have character `id`: a character one side inserted
    /// is only theirs, a character one side deleted is only the other's, one deleted before the
    /// merge is nobody's.  Nil for an id the text does not hold.
    static func presence(_ id: OpID, in text: TextSequence, sides: ChangeSides) -> (mine: Bool, theirs: Bool)? {
        guard text.contains(id) else { return nil }
        let deleter = text.deletedOp(id)
        let deletedLocally = deleter.map(sides.isLocal) ?? false
        let deletedRemotely = deleter.map(sides.isRemote) ?? false
        if deleter != nil, !deletedLocally, !deletedRemotely { return (false, false) }
        return (!sides.isRemote(id) && (deleter == nil || deletedRemotely), !sides.isLocal(id) && (deleter == nil || deletedLocally))
    }

    /// The character `id` as a string.
    static func character(_ id: OpID, in text: TextSequence) -> String {
        text.codepoint(id).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
    }

    /// The diff of the characters `ids` of `text`.
    init(_ text: TextSequence, ids: [OpID], sides: ChangeSides) {
        var segments: [Segment] = []
        var mine = ""
        var theirs = ""
        for id in ids {
            guard let presence = Self.presence(id, in: text, sides: sides), presence.mine || presence.theirs else { continue }
            let side: Side = presence.mine ? (presence.theirs ? .both : .mine) : .theirs
            let character = Self.character(id, in: text)
            if presence.mine { mine += character }
            if presence.theirs { theirs += character }
            if let last = segments.last, last.side == side {
                segments[segments.count - 1].text += character
            } else {
                segments.append(Segment(side: side, text: character))
            }
        }
        self.segments = segments
        self.mine = mine
        self.theirs = theirs
    }
}

/// The three states the review preview shows for one entry (reconcile.adoc, "Per object"):
/// *Merged* is the merged state; *Mine* and *Theirs* are the merged state with that side's value
/// of every conflicting property written back (register, flag and placement values from the change
/// log, so the object's registers read as that side left them).
enum ReviewSides {
    /// The replica the preview writes as (never uploaded; it only orders the preview's writes).
    static let previewReplica: UInt64 = 0x7FFF_FFFF_FFFF_FFFE

    /// The entry with the two sides swapped, so `ReviewModel.useMine` re-asserts *their* values.
    static func swapped(_ entry: ReviewEntry) -> ReviewEntry {
        var result = entry
        result.properties = entry.properties.map { conflict in
            let kept: MergeSide = switch conflict.kept {
            case .mine: .theirs
            case .theirs: .mine
            case .other: .other
            }
            return PropertyConflict(property: conflict.property, mine: conflict.theirs, theirs: conflict.mine, merged: conflict.merged, kept: kept)
        }
        return result
    }

    static func mine(_ entry: ReviewEntry, merged: EngineState) -> EngineState {
        applying(ReviewModel.useMine(entry), to: merged)
    }

    static func theirs(_ entry: ReviewEntry, merged: EngineState) -> EngineState {
        applying(ReviewModel.useMine(swapped(entry)), to: merged)
    }

    /// `state` after `command`, performed as the preview replica; unchanged when there is nothing
    /// to perform or it cannot apply.
    static func applying(_ command: (any WTModel.Command)?, to state: EngineState) -> EngineState {
        guard let command else { return state }
        var core = DocumentCore(state: state, replica: previewReplica)
        _ = try? core.perform(command, recording: DocumentCore.Recording(limit: 1, now: Date()))
        return core.state
    }
}

/// *Keep both copies* (reconcile.adoc): a copy of the object as the local side had it, beside
/// the merged one, offset by *Keep both offset*, with "Copy from <user>'s offline edits, <date>"
/// in its note.  One change, "Keep both copies of <name>".
struct KeepBothCopies: WTModel.Command {
    let tree: NodeTree
    let original: OpID
    let offset: Double
    let note: String
    let name: String

    var label: String { "Keep both copies of \(name)" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let placement = state.store.placement(original) else { return }
        var copy = tree
        copy.transform = copy.transform.concatenating(.translation(x: offset, y: offset))
        Self.setNote(note, on: &copy.props)
        let above = Arranging.siblingAfter(original, in: state).flatMap { state.store.placement($0)?.position }
        let key = try FractionalIndex.between(placement.position, above, suffix: UInt64.random(in: 1...UInt64.max))
        try NodeCopier.create(copy, parent: placement.parent, position: key, schema: state.schema, builder: &builder)
    }

    /// Writes `note` into the object's common props.
    static func setNote(_ note: String, on props: inout Wiretuner_Doc_V1_NodeProps) {
        let text = String(note.prefix(8192))
        switch props.kind {
        case .path?: props.path.common.note = text
        case .rect?: props.rect.common.note = text
        case .ellipse?: props.ellipse.common.note = text
        case .polygon?: props.polygon.common.note = text
        case .group?: props.group.common.note = text
        case .text?: props.text.common.note = text
        case .image?: props.image.common.note = text
        default: break
        }
    }

    /// "Copy from Priya's offline edits, 14 March".
    static func noteText(user: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return "Copy from \(user.isEmpty ? "your" : "\(user)'s") offline edits, \(formatter.string(from: date))"
    }
}

/// The paragraph choices of a *Same text* row (reconcile.adoc): *Use mine* rewrites the merged
/// paragraph to the local text (deleting what only the others added, re-typing what they
/// deleted); *Keep both* adds the local text as a paragraph after the merged one.  *Use theirs*
/// writes nothing.
enum ParagraphChoices {
    static func useMine(node: OpID, field: RegisterPath, text: TextSequence, ids: [OpID], sides: ChangeSides, name: String) -> OpsCommand? {
        let order = text.order
        func inMine(_ id: OpID) -> Bool { ParagraphDiff.presence(id, in: text, sides: sides)?.mine ?? false }
        func neighbour(_ id: OpID, _ step: Int) -> OpID {
            guard let index = order.firstIndex(of: id), order.indices.contains(index + step) else { return .zero }
            return order[index + step]
        }
        var ops: [Wiretuner_Doc_V1_Op] = []
        var index = 0
        while index < ids.count {
            let id = ids[index]
            if !text.isDeleted(id), !inMine(id) {
                ops.append(Ops.textDelete(node, field, first: id, count: 1))
                index += 1
            } else if text.isDeleted(id), inMine(id) {
                // A run the others deleted that the local side kept: typed again in place.
                var end = index
                var run = ""
                while end < ids.count, text.isDeleted(ids[end]), inMine(ids[end]) {
                    run += ParagraphDiff.character(ids[end], in: text)
                    end += 1
                }
                ops.append(Ops.textInsert(node, field, run, left: neighbour(id, -1), right: neighbour(ids[end - 1], 1)))
                index = end
            } else {
                index += 1
            }
        }
        return ops.isEmpty ? nil : OpsCommand("Use my text for \(name)", ops: ops)
    }

    static func keepBoth(node: OpID, field: RegisterPath, text: TextSequence, ids: [OpID], sides: ChangeSides, name: String) -> OpsCommand? {
        let mine = ParagraphDiff(text, ids: ids, sides: sides).mine
        guard !mine.isEmpty, let last = ids.last else { return nil }
        let newline = UInt32(("\n" as Unicode.Scalar).value)
        let order = text.order
        let right = order.firstIndex(of: last).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil } ?? .zero
        let endsParagraph = text.codepoint(last) == newline
        let inserted = endsParagraph ? (mine.hasSuffix("\n") ? mine : mine + "\n") : "\n" + mine.trimmingCharacters(in: .newlines)
        return OpsCommand("Keep both texts of \(name)", ops: [Ops.textInsert(node, field, inserted, left: last, right: right)])
    }
}
