import CryptoKit
import Foundation
import WTCRDT
import WTProto

/// What a restore to the current state will do (history.adoc, "Restoring a version"): the
/// confirmation's counts.
public struct RestoreSummary: Hashable, Sendable {
    /// Nodes present in both whose properties, place, elements, text or sets are rewritten.
    public var changed = 0
    /// Nodes created after the version that the restore deletes.
    public var deletedSinceVersion = 0
    /// Nodes deleted since the version that the restore brings back.
    public var broughtBack = 0
    /// Nodes of the version this document no longer holds at all (compacted out): not restored.
    public var unrestorable = 0

    public init() {}

    /// Whether the restore changes nothing.
    public var isEmpty: Bool { changed == 0 && deletedSinceVersion == 0 && broughtBack == 0 }

    /// "This will change 41 objects, delete 3 objects added since, and bring back 2 deleted objects."
    public var sentence: String {
        func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
        var parts: [String] = []
        if changed > 0 { parts.append("change \(count(changed, "object"))") }
        if deletedSinceVersion > 0 { parts.append("delete \(count(deletedSinceVersion, "object")) added since") }
        if broughtBack > 0 { parts.append("bring back \(count(broughtBack, "deleted object"))") }
        guard let last = parts.popLast() else { return "The document already matches this version." }
        let list = parts.isEmpty ? last : parts.joined(separator: ", ") + ", and " + last
        return "This will \(list)."
    }
}

/// Restore as the current state (COLLAB-021; history.adoc, "Merge semantics"): the difference
/// between `target` (the state at the version, built by WTSync from the local log or a fetched
/// snapshot and tail) and the current state, as one change labelled `Restore '<name>'`:
///
/// * a node live in the version and deleted now: `SetDeleted(false)`; created since: `SetDeleted(true)`;
/// * registers that differ: one `SetFields` per node (per sequence element or newline, whose
///   registers are addressed through it) with the version's values;
/// * parent or position that differ: `MoveNode`;
/// * sequence elements live in the version but deleted (or collected) now: `ElementInsert` of new
///   elements with the old values at the old position -- tombstones are never resurrected --
///   nested sequences and sets included; elements added since: `ElementDelete`; moved: `ElementMove`;
/// * text: `TextDelete` of characters not in the version, `TextInsert` of the version's missing
///   characters as new ones after their surviving neighbour (the right origin skips tombstones
///   stable at `horizon`), then `TextMark`s for formatting that differs;
/// * set members: `SetAdd` and `SetRemove`.
///
/// The `comments (0:12)` collection is skipped (COLLAB-032): restoring neither deletes threads
/// written since nor resurrects deleted comments.  A node the document no longer holds is not
/// restored (counted in `RestoreSummary.unrestorable`), so the change never names a collected
/// tombstone.  Being ordinary ops from the restoring replica, the restore merges register by
/// register with concurrent edits and is one undo step.
public struct RestoreCommand: Command {
    public let target: EngineState
    public let name: String
    /// The replica's horizon (DocumentCore.horizon): tombstones stable here are not used as
    /// insertion origins.
    public let horizon: UInt64

    public var label: String { "Restore '\(name)'" }

    public init(target: EngineState, name: String, horizon: UInt64 = 0) {
        self.target = target
        self.name = name
        self.horizon = horizon
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var diff = RestoreDiff(target: target, current: state, horizon: horizon)
        diff.emit(into: &builder)
    }

    /// The counts the confirmation shows, computed on the caller's executor (a background task:
    /// `Task.detached { RestoreCommand.summary(target:current:) }`).
    public static func summary(target: EngineState, current: EngineState, horizon: UInt64 = 0) -> RestoreSummary {
        var builder = ChangeBuilder(replica: 1, startCounter: current.clock.peek)
        var diff = RestoreDiff(target: target, current: current, horizon: horizon)
        diff.emit(into: &builder)
        return diff.summary
    }
}

/// The diff behind `RestoreCommand`.
struct RestoreDiff {
    let target: EngineState
    let current: EngineState
    let horizon: UInt64
    private(set) var summary = RestoreSummary()
    private var liveCache: [Bool: [OpID: [RegisterPath: Bool]]] = [:]

    init(target: EngineState, current: EngineState, horizon: UInt64) {
        self.target = target
        self.current = current
        self.horizon = horizon
    }

    mutating func emit(into builder: inout ChangeBuilder) {
        let nodes = Set(target.store.nodes).union(current.store.nodes).sorted()
        for node in nodes where !Self.isComment(node, target) && !Self.isComment(node, current) {
            let inTarget = target.store.exists(node)
            let inCurrent = current.store.exists(node)
            let deletedInTarget = Self.deleted(node, target)
            let deletedNow = Self.deleted(node, current)
            if inTarget && !inCurrent {
                if !deletedInTarget { summary.unrestorable += 1 }
                continue
            }
            if !inTarget || deletedInTarget {
                if !deletedNow && current.store.isCreated(node) {
                    builder.append(Ops.setDeleted(node, true))
                    summary.deletedSinceVersion += 1
                }
                continue
            }
            var touched = false
            if deletedNow {
                builder.append(Ops.setDeleted(node, false))
                summary.broughtBack += 1
            }
            touched = placement(node, &builder) || touched
            touched = registers(node, &builder) || touched
            touched = elements(node, &builder) || touched
            touched = texts(node, &builder) || touched
            touched = sets(node, &builder) || touched
            if touched && !deletedNow { summary.changed += 1 }
        }
    }

    // MARK: Scope

    /// Whether `node` is the comments collection or lies under it.
    static func isComment(_ node: OpID, _ state: EngineState) -> Bool {
        var current: OpID? = node
        var steps = 0
        while let id = current, steps < 10_000 {
            if id == CommentFields.collection { return true }
            current = state.store.placement(id)?.parent
            steps += 1
        }
        return false
    }

    static func deleted(_ node: OpID, _ state: EngineState) -> Bool {
        state.store.deleted(node)?.current.value == true
    }

    /// Whether every sequence element and character `path` runs through is live in `state`.
    mutating func containersLive(_ node: OpID, _ path: RegisterPath, inTarget: Bool) -> Bool {
        let state = inTarget ? target : current
        var prefix: [RegisterPath.Segment] = []
        for segment in path.segments {
            prefix.append(segment)
            guard case .element = segment else { continue }
            let at = RegisterPath(segments: prefix)
            if let known = liveCache[inTarget]?[node]?[at] {
                if !known { return false }
                continue
            }
            let live = Self.isLive(node, at, in: state)
            liveCache[inTarget, default: [:]][node, default: [:]][at] = live
            if !live { return false }
        }
        return true
    }

    /// Whether the element or character at `path` (ending with its element segment) is live.
    static func isLive(_ node: OpID, _ path: RegisterPath, in state: EngineState) -> Bool {
        if let element = state.store.element(node, path) { return !element.isDeleted }
        guard case .element(let char)? = path.segments.last, let container = path.parent,
              let text = state.store.text(node, container) else { return false }
        return text.contains(char) && !text.isDeleted(char)
    }

    /// Whether the element segment ending `path` names a character (its container is a TEXT field).
    static func isChar(_ node: OpID, _ path: RegisterPath, in state: EngineState) -> Bool {
        state.store.element(node, path) == nil && path.parent.map { state.store.text(node, $0) != nil } == true
    }

    /// Live in both, containers included.
    mutating func liveInBoth(_ node: OpID, _ path: RegisterPath) -> Bool {
        containersLive(node, path, inTarget: true) && containersLive(node, path, inTarget: false)
    }

    // MARK: Placement

    private func placement(_ node: OpID, _ builder: inout ChangeBuilder) -> Bool {
        guard let wanted = target.store.placement(node), current.store.exists(wanted.parent) else { return false }
        if let now = current.store.placement(node), now.parent == wanted.parent, now.position == wanted.position { return false }
        builder.append(Ops.move(node, parent: wanted.parent, position: wanted.position))
        return true
    }

    // MARK: Registers

    private mutating func registers(_ node: OpID, _ builder: inout ChangeBuilder) -> Bool {
        let wanted = Self.values(target, node)
        let now = Self.values(current, node)
        var groups: [[UInt8]: [RegisterPath]] = [:]
        for path in Set(wanted.keys).union(now.keys) where liveInBoth(node, path) {
            let value = Self.value(wanted, path)
            if value != Self.value(now, path) {
                groups[Self.container(path)?.canonical ?? [], default: []].append(path)
            }
        }
        for key in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let paths = groups[key]!.sorted()
            let values = RestoreValues.encode(paths.compactMap { path in Self.value(wanted, path).map { (path, $0) } }) {
                Self.isChar(node, $0, in: target)
            }
            builder.append(Ops.set(node, paths, values: values))
        }
        return !groups.isEmpty
    }

    /// Every register of `node` in `state`, by path (nil: written unset).
    static func values(_ state: EngineState, _ node: OpID) -> [RegisterPath: [UInt8]?] {
        var out: [RegisterPath: [UInt8]?] = [:]
        for entry in state.store.registers(node) {
            out[entry.path] = entry.register.value
        }
        return out
    }

    /// The value at `path` in `values`; nil when unset or absent.
    static func value(_ values: [RegisterPath: [UInt8]?], _ path: RegisterPath) -> [UInt8]? {
        guard let entry = values[path] else { return nil }
        return entry
    }

    /// The path up to its last element segment (the root when it has none): registers sharing it
    /// go in one `SetFields`.
    static func container(_ path: RegisterPath) -> RegisterPath? {
        guard let last = path.segments.lastIndex(where: { if case .element = $0 { return true } else { return false } }) else {
            return nil
        }
        return RegisterPath(segments: Array(path.segments[...last]))
    }

    // MARK: Sequences

    private mutating func elements(_ node: OpID, _ builder: inout ChangeBuilder) -> Bool {
        var touched = false
        for (path, element) in target.store.elements(node) where !element.isDeleted {
            guard let sequence = path.parent, liveInBoth(node, sequence), containersLive(node, path, inTarget: true) else { continue }
            if Self.isLive(node, path, in: current) {
                let position = element.position.current.value
                if current.store.element(node, path)?.position.current.value != position {
                    builder.append(Ops.elementMove(node, path, position: position))
                    touched = true
                }
            } else {
                reinsert(node, path, element, into: sequence, &builder)
                touched = true
            }
        }
        var removed: [RegisterPath] = []
        for (path, element) in current.store.elements(node) where !element.isDeleted {
            guard let sequence = path.parent, liveInBoth(node, sequence) else { continue }
            if !Self.isLive(node, path, in: target) {
                removed.append(path)
            }
        }
        if !removed.isEmpty {
            builder.append(Ops.elementDelete(node, removed))
            touched = true
        }
        return touched
    }

    /// Inserts a new element for the version's element `path` into `sequence` (the same sequence,
    /// or the matching one of a re-inserted parent), with its registers, nested elements and set
    /// members.
    private func reinsert(_ node: OpID, _ path: RegisterPath, _ element: Element, into sequence: RegisterPath, _ builder: inout ChangeBuilder) {
        let depth = path.segments.count
        let leaves = target.store.registers(node).compactMap { entry -> (RegisterPath, [UInt8])? in
            guard let value = entry.register.value, entry.path.segments.count > depth,
                  Array(entry.path.segments.prefix(depth)) == path.segments,
                  !entry.path.segments.dropFirst(depth).contains(where: { if case .element = $0 { return true } else { return false } })
            else { return nil }
            return (RegisterPath(segments: sequence.segments + [.element(.zero)] + entry.path.segments.dropFirst(depth)), value)
        }
        let values = RestoreValues.encode(leaves) { _ in false }
        let inserted = builder.append(Ops.elementInsert(node, sequence, positions: [element.position.current.value], values: values))
        let fresh = sequence.element(inserted)
        for (nested, child) in target.store.elements(node) where !child.isDeleted && nested.segments.count == depth + 2
            && Array(nested.segments.prefix(depth)) == path.segments {
            reinsert(node, nested, child, into: RegisterPath(segments: fresh.segments + [nested.segments[depth]]), &builder)
        }
        for set in target.store.setPaths(node) where Self.container(set) == path {
            let members = target.store.members(node, set)
            guard !members.isEmpty else { continue }
            let rebased = RegisterPath(segments: fresh.segments + set.segments.dropFirst(depth))
            if let values = RestoreValues.members(members, at: rebased, schema: target.schema) {
                builder.append(Ops.setAdd(node, rebased, values: values))
            }
        }
    }

    // MARK: Text

    private mutating func texts(_ node: OpID, _ builder: inout ChangeBuilder) -> Bool {
        var touched = false
        let paths = Set(target.store.textPaths(node)).union(current.store.textPaths(node))
        for path in paths.sorted() where liveInBoth(node, path) {
            touched = text(node, path, &builder) || touched
        }
        return touched
    }

    private func text(_ node: OpID, _ path: RegisterPath, _ builder: inout ChangeBuilder) -> Bool {
        let wanted = Self.text(target, node, path)
        let now = Self.text(current, node, path)
        let wantedChars = wanted.liveChars
        let wantedSet = Set(wantedChars)
        let nowChars = now.liveChars
        let nowSet = Set(nowChars)
        var touched = false
        // Characters not in the version.
        let removed = nowChars.filter { !wantedSet.contains($0) }
        for op in Self.deletes(removed, node: node, path: path) {
            builder.append(op)
            touched = true
        }
        // The version's missing characters, run by run, after their surviving neighbour.
        var final = wantedChars
        var index = 0
        var reinserted: [OpID: OpID] = [:]
        while index < wantedChars.count {
            guard !nowSet.contains(wantedChars[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < wantedChars.count, !nowSet.contains(wantedChars[end]) {
                end += 1
            }
            // The surviving neighbour is live in the current text.
            let offset = index == 0 ? 0 : now.offset(of: wantedChars[index - 1])! + 1
            var (left, right) = current.insertionOrigins(node, path, at: offset, stableSeq: horizon)
            var start = index
            while start < end {
                let stop = min(end, start + CommentEditing.chunk)
                var string = String.UnicodeScalarView()
                for char in wantedChars[start..<stop] {
                    string.append(Unicode.Scalar(wanted.codepoint(char)!)!)
                }
                let first = builder.append(Ops.textInsert(node, path, String(string), left: left, right: right))
                for offset in start..<stop {
                    let id = OpID(counter: first.counter + UInt64(offset - start), replica: first.replica)
                    final[offset] = id
                    reinserted[wantedChars[offset]] = id
                }
                left = final[stop - 1]
                start = stop
            }
            touched = true
            index = end
        }
        // Paragraph registers of re-inserted newlines.
        if !reinserted.isEmpty {
            var groups: [OpID: [(RegisterPath, [UInt8])]] = [:]
            var paths: [OpID: [RegisterPath]] = [:]
            for (register, value) in target.store.registers(node).map({ ($0.path, $0.register.value) }) {
                guard register.segments.count > path.segments.count + 1,
                      Array(register.segments.prefix(path.segments.count)) == path.segments,
                      case .element(let char) = register.segments[path.segments.count], let fresh = reinserted[char] else { continue }
                let rebased = RegisterPath(segments: path.segments + [.element(fresh)] + register.segments.dropFirst(path.segments.count + 1))
                paths[fresh, default: []].append(rebased)
                if let value { groups[fresh, default: []].append((rebased, value)) }
            }
            for fresh in paths.keys.sorted() {
                let values = RestoreValues.encode(groups[fresh] ?? []) { $0.segments.count == path.segments.count + 1 }
                builder.append(Ops.set(node, paths[fresh]!.sorted(), values: values))
            }
        }
        return marks(node, path, wanted: wanted, now: now, final: final, fresh: Set(reinserted.values), &builder) || touched
    }

    /// The TEXT field at `path` of `node`; empty when never written.
    static func text(_ state: EngineState, _ node: OpID, _ path: RegisterPath) -> TextSequence {
        state.store.text(node, path) ?? TextSequence()
    }

    static func deletes(_ ids: [OpID], node: OpID, path: RegisterPath) -> [Wiretuner_Doc_V1_Op] {
        let sorted = ids.sorted()
        var ops: [Wiretuner_Doc_V1_Op] = []
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            var count: UInt64 = 1
            while index + Int(count) < sorted.count, sorted[index + Int(count)] == OpID(counter: first.counter + count, replica: first.replica) {
                count += 1
            }
            ops.append(Ops.textDelete(node, path, first: first, count: count))
            index += Int(count)
        }
        return ops
    }

    /// The winning attributes of each live character, by character.
    static func attributes(_ text: TextSequence) -> [OpID: [MarkKey: [UInt8]]] {
        let chars = text.liveChars
        var out: [OpID: [MarkKey: [UInt8]]] = [:]
        for run in text.runs {
            var values: [MarkKey: [UInt8]] = [:]
            for attribute in run.attributes {
                values[attribute.key] = attribute.value
            }
            for offset in run.start..<(run.start + run.length) {
                out[chars[offset]] = values
            }
        }
        return out
    }

    /// `TextMark`s over `final` (the text after the restore, in the version's order) for every
    /// attribute whose value differs from the version's on some character: for each maximal run of
    /// one version value, that value, or the attribute's cleared value where the version has none.
    private func marks(_ node: OpID, _ path: RegisterPath, wanted: TextSequence, now: TextSequence, final: [OpID],
                       fresh: Set<OpID>, _ builder: inout ChangeBuilder) -> Bool {
        let wantedChars = wanted.liveChars
        let wantedValues = Self.attributes(wanted)
        let nowValues = Self.attributes(now)
        var samples: [MarkKey: [UInt8]] = [:]
        for values in Array(wantedValues.values) + Array(nowValues.values) {
            for (key, value) in values where samples[key] == nil {
                samples[key] = value
            }
        }
        var touched = false
        for key in samples.keys.sorted() {
            let target = wantedChars.map { wantedValues[$0]?[key] }
            let present = Self.nowHas(key, nowValues)
            let differs = { (index: Int) -> Bool in
                fresh.contains(final[index]) ? target[index] != nil || present : target[index] != nowValues[final[index]]?[key]
            }
            var index = 0
            while index < final.count {
                var end = index + 1
                while end < final.count, target[end] == target[index] {
                    end += 1
                }
                if (index..<end).contains(where: differs) {
                    let bytes = target[index] ?? samples[key]!
                    if var value = try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: bytes) {
                        if target[index] == nil { value = TextMarks.cleared(value) }
                        builder.append(Self.mark(node, path, value, first: final[index], last: final[end - 1]))
                        touched = true
                    }
                }
                index = end
            }
        }
        return touched
    }

    static func nowHas(_ key: MarkKey, _ values: [OpID: [MarkKey: [UInt8]]]) -> Bool {
        values.values.contains { $0[key] != nil }
    }

    static func mark(_ node: OpID, _ path: RegisterPath, _ value: Wiretuner_Doc_V1_TextMarkValue, first: OpID, last: OpID) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = path.proto
        mark.start.char = first.elementID
        mark.start.before = true
        mark.end.char = last.elementID
        mark.value = value
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }

    // MARK: Sets

    private mutating func sets(_ node: OpID, _ builder: inout ChangeBuilder) -> Bool {
        var touched = false
        let paths = Set(target.store.setPaths(node)).union(current.store.setPaths(node))
        for path in paths.sorted() where liveInBoth(node, path) {
            let wanted = Set(target.store.members(node, path))
            let now = Set(current.store.members(node, path))
            let added = wanted.subtracting(now).sorted { $0.lexicographicallyPrecedes($1) }
            let removed = now.subtracting(wanted).sorted { $0.lexicographicallyPrecedes($1) }
            if !added.isEmpty, let values = RestoreValues.members(added, at: path, schema: current.schema) {
                builder.append(Ops.setAdd(node, path, values: values))
                touched = true
            }
            if !removed.isEmpty, let values = RestoreValues.members(removed, at: path, schema: current.schema) {
                builder.append(Ops.setRemove(node, path, values: values))
                touched = true
            }
        }
        return touched
    }
}

/// Sparse `NodeProps` from register paths and their stored records (docs/spec/crdt-model.adoc,
/// "Field paths and registers"): element segments are transparent -- each writes its element's
/// occurrence with the `id` first -- and a character's occurrence sits inside the TEXT field's
/// `chars` (field 1).
enum RestoreValues {
    final class Node {
        var leaf: [UInt8]?
        var fields: [UInt32: Node] = [:]
        var elements: [(OpID, Node, Bool)] = []
    }

    /// The `NodeProps` holding `entries` (paths from `NodeProps`, values as stored);
    /// `isChar(path)` says whether the element segment ending `path` is a character.
    static func encode(_ entries: [(RegisterPath, [UInt8])], isChar: (RegisterPath) -> Bool) -> Wiretuner_Doc_V1_NodeProps {
        let root = Node()
        for (path, value) in entries {
            var node = root
            var prefix: [RegisterPath.Segment] = []
            for segment in path.segments {
                prefix.append(segment)
                switch segment {
                case .field(let number):
                    if let child = node.fields[number] {
                        node = child
                    } else {
                        let child = Node()
                        node.fields[number] = child
                        node = child
                    }
                case .element(let id):
                    if let found = node.elements.first(where: { $0.0 == id }) {
                        node = found.1
                    } else {
                        let child = Node()
                        node.elements.append((id, child, isChar(RegisterPath(segments: prefix))))
                        node = child
                    }
                }
            }
            node.leaf = value
        }
        // Records as stored, placed by field number: a well-formed message by construction.
        return try! Wiretuner_Doc_V1_NodeProps(serializedBytes: encode(root))
    }

    private static func encode(_ node: Node) -> [UInt8] {
        var out: [UInt8] = []
        for number in node.fields.keys.sorted() {
            let child = node.fields[number]!
            if let leaf = child.leaf {
                out += leaf
            } else if !child.elements.isEmpty {
                for (id, element, char) in child.elements {
                    let payload = Wire.field(1, Wire.elementID(id)) + encode(element)
                    out += char ? Wire.field(number, Wire.field(1, payload)) : Wire.field(number, payload)
                }
            } else {
                out += Wire.field(number, encode(child))
            }
        }
        return out
    }

    /// Sparse `NodeProps` holding `members` of the SET field at `path`; nil when the merge table
    /// does not know the field.
    static func members(_ members: [[UInt8]], at path: RegisterPath, schema: Schema) -> Wiretuner_Doc_V1_NodeProps? {
        guard let row = ColorUses.leaf(path, schema: schema), case .field(let number)? = path.segments.last else { return nil }
        var records: [UInt8] = []
        for member in members {
            records += record(member, number: number, type: row.type)
        }
        return encode([(path, records)]) { _ in false }
    }

    /// The protobuf record holding a canonical set member (crdt-model.adoc, "Sets").
    static func record(_ member: [UInt8], number: UInt32, type: String) -> [UInt8] {
        func u64(_ offset: Int) -> UInt64 { member[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        switch type {
        case "message":
            var id = Wire.varint(1 << 3) + Wire.varint(u64(0))
            id += Wire.varint(2 << 3 | 1)
            withUnsafeBytes(of: u64(8).littleEndian) { id += $0 }
            return Wire.field(number, id)
        case "string", "bytes":
            return Wire.field(number, member)
        default:
            if member.count == 8 && ["fixed64", "sfixed64", "double"].contains(type) {
                return Wire.varint(UInt64(number) << 3 | 1) + member
            }
            if member.count == 4 {
                return Wire.varint(UInt64(number) << 3 | 5) + member
            }
            return Wire.varint(UInt64(number) << 3) + Wire.varint(u64(0))
        }
    }
}

/// The content of a state as a person sees it, for comparing a restored document with its version
/// (COLLAB-021): every node that is not deleted -- kind, parent and position, register values, live
/// sequence elements in order with their positions and registers, set members, and each text's live
/// characters with their formatting -- with element and character ids replaced by their place, and
/// every op id, tombstone and comment left out.  A restore re-inserts elements and characters under
/// fresh ids and writes registers under new op ids, so the state hash of the restored document never
/// equals the version's; this hash does when nothing else changed (history.adoc, "Client", as built).
public enum RestoreContent {
    public static func hash(_ state: EngineState) -> [UInt8] {
        var hasher = SHA256()
        for entry in nodes(state).values.flatMap({ $0 }).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            hasher.update(data: Wire.field(1, entry))
        }
        return Array(hasher.finalize())
    }

    /// Each shown node's content entries (the hash's input), by node.
    static func nodes(_ state: EngineState) -> [OpID: [[UInt8]]] {
        var out: [OpID: [[UInt8]]] = [:]
        for node in state.store.nodes where !RestoreDiff.isComment(node, state) && !RestoreDiff.deleted(node, state) {
            out[node] = entries(node, state)
        }
        return out
    }

    static func entries(_ node: OpID, _ state: EngineState) -> [[UInt8]] {
        var entries: [[UInt8]] = []
        var places: [RegisterPath: Int] = [:]
        func normalized(_ path: RegisterPath) -> [UInt8]? {
            var out: [UInt8] = []
            var prefix: [RegisterPath.Segment] = []
            for segment in path.segments {
                prefix.append(segment)
                switch segment {
                case .field(let number):
                    out += [1] + Wire.varint(UInt64(number))
                case .element(let id):
                    let at = RegisterPath(segments: prefix)
                    guard RestoreDiff.isLive(node, at, in: state) else { return nil }
                    if places[at] == nil { places[at] = place(node, at, id, state) }
                    out += [2] + Wire.varint(UInt64(places[at]!))
                }
            }
            return out
        }
        var head = Wire.elementID(node) + Wire.varint(UInt64(state.store.kind(node)))
        if let placement = state.store.placement(node) {
            head += Wire.elementID(placement.parent) + Wire.field(1, placement.position)
        }
        entries.append([0] + head)
        for (path, register) in state.store.registers(node) {
            guard let value = register.value, let at = normalized(path) else { continue }
            entries.append([1] + Wire.elementID(node) + Wire.field(1, at) + value)
        }
        for (path, element) in state.store.elements(node) where !element.isDeleted {
            guard let at = normalized(path) else { continue }
            entries.append([2] + Wire.elementID(node) + Wire.field(1, at) + element.position.current.value)
        }
        for path in state.store.setPaths(node) {
            guard let at = normalized(path) else { continue }
            for member in state.store.members(node, path) {
                entries.append([3] + Wire.elementID(node) + Wire.field(1, at) + Wire.field(2, member))
            }
        }
        for path in state.store.textPaths(node) {
            // A text with no live character reads like one never written.
            guard let at = normalized(path), let text = state.store.text(node, path), text.liveCount > 0 else { continue }
            var encoded = [4] + Wire.elementID(node) + Wire.field(1, at)
            for scalar in text.liveChars.compactMap(text.codepoint) {
                encoded += Wire.varint(UInt64(scalar))
            }
            // Runs of equal values, however many marks make them up.
            var merged: [(start: Int, length: Int, values: [[UInt8]])] = []
            for run in text.runs {
                let values = run.attributes.map(\.value)
                if let last = merged.last, last.values == values, last.start + last.length == run.start {
                    merged[merged.count - 1].length += run.length
                } else {
                    merged.append((run.start, run.length, values))
                }
            }
            for run in merged where !run.values.isEmpty {
                encoded += Wire.varint(UInt64(run.start)) + Wire.varint(UInt64(run.length))
                for value in run.values {
                    encoded += Wire.field(3, value)
                }
            }
            entries.append(encoded)
        }
        return entries
    }

    /// The place of the element or character ending `path` among the live ones of its container.
    /// The live element or character `id` (the path ending with it)'s place in its container.
    static func place(_ node: OpID, _ path: RegisterPath, _ id: OpID, _ state: EngineState) -> Int {
        let container = path.parent!
        if state.store.element(node, path) != nil {
            return state.liveElements(node, container).firstIndex(of: id)!
        }
        return state.store.text(node, container)!.offset(of: id)!
    }
}
