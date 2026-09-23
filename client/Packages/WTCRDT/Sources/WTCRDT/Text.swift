/// A Peritext anchor (docs/spec/crdt-model.adoc, "Text"): the point just before or just after one
/// character.  The zero id is the start of the text with `before` and its end with `after`.
public struct Anchor: Hashable, Sendable, CustomStringConvertible {
    public var char: OpID
    public var before: Bool

    public init(char: OpID, before: Bool) {
        self.char = char
        self.before = before
    }

    /// The start of the text.
    public static let start = Anchor(char: .zero, before: true)
    /// The end of the text.
    public static let end = Anchor(char: .zero, before: false)

    public var description: String { "\(before ? "before" : "after") \(char)" }
}

/// One formatting mark (`TextMark`, CRDT-006): a span between two anchors, its id (the op's) and
/// its `TextMarkValue` bytes exactly as the op carried them.
public struct TextMark: Hashable, Sendable {
    public let id: OpID
    public let start: Anchor
    public let end: Anchor
    public let value: [UInt8]
    /// What the mark formats (nil: the value sets no attribute, so it resolves nothing).
    public let key: MarkKey?

    public init(id: OpID, start: Anchor, end: Anchor, value: [UInt8], key: MarkKey?) {
        self.id = id
        self.start = start
        self.end = end
        self.value = value
        self.key = key
    }
}

/// The identity of a formatting attribute: the `TextMarkValue` case (its field number) and, for
/// the `feature` case, the feature's `tag` records, so marks of different tags stack while marks
/// of one attribute supersede by OpId.
public struct MarkKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let field: UInt32
    public let tag: [UInt8]

    public init(field: UInt32, tag: [UInt8] = []) {
        self.field = field
        self.tag = tag
    }

    public static func < (lhs: MarkKey, rhs: MarkKey) -> Bool {
        lhs.field != rhs.field ? lhs.field < rhs.field : lhs.tag.lexicographicallyPrecedes(rhs.tag)
    }

    public var description: String { tag.isEmpty ? "\(field)" : "\(field)/\(Bytes.hex(tag))" }
}

/// One resolved attribute of a run: the winning mark's value.
public struct TextAttribute: Hashable, Sendable {
    public let key: MarkKey
    /// The winning mark's `TextMarkValue` bytes.
    public let value: [UInt8]
    public let mark: OpID
}

/// A maximal range of live characters with the same attributes -- the same winning marks -- (CRDT-006):
/// `start` and `length` are live offsets; `attributes` ascending by key, cleared attributes left out.
public struct TextRun: Hashable, Sendable {
    public let start: Int
    public let length: Int
    public let attributes: [TextAttribute]
}

/// One MERGE_TEXT field (docs/spec/crdt-model.adoc, "Text"; CRDT-005, CRDT-006): the Fugue tree of
/// characters, their document order (tombstones included until collected), and the Peritext
/// marks anchored to them.
///
/// A `TextInsert` of _n_ characters takes _n_ counters.  Its first character goes between its
/// origins by the Fugue rule, decided from the origins alone so every replica decides alike: it is
/// the left child of `right_origin` when that character is deeper in the tree than `left_origin`
/// (the start counts as depth 0), otherwise the right child of `left_origin` (or of the start).
/// Each later character is the right child of the one before, so a typed run is one chain and two
/// concurrent runs never interleave.  Siblings order by id, ascending, and the text reads in order
/// (left children, the character, right children).  An origin that is not a character of this
/// field makes the op a no-op; a character already present is not inserted again.
///
/// wt-crdt's `TextSequence` is this type in Java.  The order is kept in blocks of at most
/// `blockLimit` characters with live counts, so an insert into a 200,000-character text touches
/// one block and an offset lookup sums block counts.
public struct TextSequence: Sendable {
    static let blockLimit = 512
    private static let root: Int32 = -1

    struct Block: Sendable {
        var id: Int
        var items: [Int32]
        var live: Int
    }

    private var ids: [OpID] = []
    private var handles: [OpID: Int32] = [:]
    private var codepoints: [UInt32] = []
    private var leftOrigins: [OpID] = []
    private var rightOrigins: [OpID] = []
    private var depths: [Int32] = []
    /// The greatest `TextDelete` that deleted each character, or zero while it is live.
    private var deletedBy: [OpID] = []
    private var leftChildren: [Int32: [Int32]] = [:]
    private var rightChildren: [Int32: [Int32]] = [:]
    private var blocks: [Block] = []
    private var blockOrdinals: [Int] = []
    private var blockOf: [Int32] = []
    /// The marks by id.
    public private(set) var marks: [OpID: TextMark] = [:]

    public init() {}

    /// How many characters, tombstones included.
    public var count: Int { ids.count }

    /// How many live characters.
    public var liveCount: Int { blocks.reduce(0) { $0 + $1.live } }

    /// Whether the field holds no characters and no marks.
    public var isEmpty: Bool { ids.isEmpty && marks.isEmpty }

    /// Whether `id` is a character of this field (live or a tombstone).
    public func contains(_ id: OpID) -> Bool { handles[id] != nil }

    /// The Unicode scalar of character `id`.
    public func codepoint(_ id: OpID) -> UInt32? { handles[id].map { codepoints[Int($0)] } }

    /// Whether character `id` is a tombstone.
    public func isDeleted(_ id: OpID) -> Bool { handles[id].map { deletedBy[Int($0)] != .zero } ?? false }

    /// The greatest delete of character `id`, or nil while it is live.
    public func deletedOp(_ id: OpID) -> OpID? {
        guard let handle = handles[id], deletedBy[Int(handle)] != .zero else { return nil }
        return deletedBy[Int(handle)]
    }

    /// The origins character `id` was inserted with (for a character after the first of its op,
    /// the character before it and the op's right origin).
    public func origins(_ id: OpID) -> (left: OpID, right: OpID)? {
        handles[id].map { (left: leftOrigins[Int($0)], right: rightOrigins[Int($0)]) }
    }

    // MARK: Characters

    /// Inserts `scalars` with ids `first`, `first + 1`, ... between `left` and `right` (zero: the
    /// start / the end).  Returns the ids inserted; none when an origin is unknown.  Character
    /// _i_ > 0 has origins (character _i_ - 1, `right`), which the Fugue rule always places as the
    /// right child of character _i_ - 1.
    @discardableResult
    mutating func insert(_ scalars: [UInt32], first: OpID, left: OpID, right: OpID) -> [OpID] {
        guard known(left), known(right) else { return [] }
        var inserted: [OpID] = []
        var leftOrigin = left
        for (index, scalar) in scalars.enumerated() {
            let id = OpID(counter: first.counter &+ UInt64(index), replica: first.replica)
            if handles[id] == nil {
                insertChar(id, scalar: scalar, left: leftOrigin, right: right)
                inserted.append(id)
            }
            leftOrigin = id
        }
        return inserted
    }

    private func known(_ id: OpID) -> Bool {
        id == .zero || handles[id] != nil
    }

    // The Fugue rule, from the origins alone: the left child of `right` when it is deeper than
    // `left` (the start has depth 0), else the right child of `left` (or of the start).  The
    // character records `origins` (its own, when restoring beside a collected origin) or else
    // the ones it is placed by.
    private mutating func insertChar(_ id: OpID, scalar: UInt32, left: OpID, right: OpID, origins: (OpID, OpID)? = nil) {
        let (leftOrigin, rightOrigin) = origins ?? (left, right)
        let leftDepth = left == .zero ? 0 : depths[Int(handles[left]!)]
        if right != .zero, depths[Int(handles[right]!)] > leftDepth {
            add(id, scalar: scalar, parent: handles[right]!, right: false, leftOrigin: leftOrigin, rightOrigin: rightOrigin)
        } else {
            add(id, scalar: scalar, parent: left == .zero ? Self.root : handles[left]!, right: true,
                leftOrigin: leftOrigin, rightOrigin: rightOrigin)
        }
    }

    private mutating func add(
        _ id: OpID, scalar: UInt32, parent: Int32, right: Bool, leftOrigin: OpID, rightOrigin: OpID
    ) {
        let handle = Int32(ids.count)
        ids.append(id)
        handles[id] = handle
        codepoints.append(scalar)
        leftOrigins.append(leftOrigin)
        rightOrigins.append(rightOrigin)
        depths.append(parent == Self.root ? 1 : depths[Int(parent)] + 1)
        deletedBy.append(.zero)
        blockOf.append(-1)
        var siblings = (right ? rightChildren[parent] : leftChildren[parent]) ?? []
        let index = Self.insertionIndex(siblings, id, ids)
        let point: Point
        if index > 0 {
            point = .after(subtreeEnd(siblings[index - 1]))
        } else if right {
            point = parent == Self.root ? .start : .after(parent)
        } else if !siblings.isEmpty {
            point = .before(subtreeStart(siblings[0]))
        } else {
            point = .before(parent)
        }
        siblings.insert(handle, at: index)
        if right {
            rightChildren[parent] = siblings
        } else {
            leftChildren[parent] = siblings
        }
        place(handle, point)
    }

    private static func insertionIndex(_ siblings: [Int32], _ id: OpID, _ ids: [OpID]) -> Int {
        var low = 0
        var high = siblings.count
        while low < high {
            let mid = (low + high) / 2
            if ids[Int(siblings[mid])] < id { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func subtreeEnd(_ handle: Int32) -> Int32 {
        var current = handle
        while let last = rightChildren[current]?.last {
            current = last
        }
        return current
    }

    private func subtreeStart(_ handle: Int32) -> Int32 {
        var current = handle
        while let first = leftChildren[current]?.first {
            current = first
        }
        return current
    }

    private enum Point {
        case start
        case after(Int32)
        case before(Int32)
    }

    private func locate(_ handle: Int32) -> (block: Int, index: Int) {
        let block = blockOrdinals[Int(blockOf[Int(handle)])]
        return (block, blocks[block].items.firstIndex(of: handle)!)
    }

    private mutating func place(_ handle: Int32, _ point: Point) {
        let block: Int
        let index: Int
        switch point {
        case .start:
            if blocks.isEmpty {
                blocks.append(Block(id: 0, items: [], live: 0))
                blockOrdinals = [0]
            }
            (block, index) = (0, 0)
        case .after(let other):
            let at = locate(other)
            (block, index) = (at.block, at.index + 1)
        case .before(let other):
            (block, index) = locate(other)
        }
        blocks[block].items.insert(handle, at: index)
        blocks[block].live += 1
        blockOf[Int(handle)] = Int32(blocks[block].id)
        if blocks[block].items.count > Self.blockLimit {
            split(block)
        }
    }

    private mutating func split(_ block: Int) {
        let half = blocks[block].items.count / 2
        let moved = Array(blocks[block].items[half...])
        blocks[block].items.removeSubrange(half...)
        let movedLive = moved.reduce(0) { $0 + (deletedBy[Int($1)] == .zero ? 1 : 0) }
        blocks[block].live -= movedLive
        let id = blockOrdinals.count
        blocks.insert(Block(id: id, items: moved, live: movedLive), at: block + 1)
        blockOrdinals.append(0)
        for handle in moved {
            blockOf[Int(handle)] = Int32(id)
        }
        for ordinal in (block + 1)..<blocks.count {
            blockOrdinals[blocks[ordinal].id] = ordinal
        }
    }

    /// Deletes character `id` with `op`; returns whether it was live.  Deleting a tombstone again
    /// only keeps the greatest delete.
    @discardableResult
    mutating func delete(_ id: OpID, op: OpID) -> Bool {
        guard let handle = handles[id] else { return false }
        let current = deletedBy[Int(handle)]
        if current == .zero {
            deletedBy[Int(handle)] = op
            blocks[blockOrdinals[Int(blockOf[Int(handle)])]].live -= 1
            return true
        }
        if op > current {
            deletedBy[Int(handle)] = op
        }
        return false
    }

    /// The characters of this field among the ids `first`, `first + 1`, ... (`count` of them, not
    /// past the largest counter), in id order: a `TextDelete` range.  A range longer than the
    /// field is matched against the field's characters instead of enumerated.
    func ids(from first: OpID, count: UInt64) -> [OpID] {
        let span = min(count, UInt64.max - first.counter)
        if span <= UInt64(ids.count) {
            return (0..<span).map { OpID(counter: first.counter + $0, replica: first.replica) }.filter { handles[$0] != nil }
        }
        return ids.filter { $0.replica == first.replica && $0.counter >= first.counter && $0.counter - first.counter < span }
            .sorted()
    }

    // MARK: Read-out

    /// Every character id in document order, tombstones included.
    public var order: [OpID] {
        blocks.flatMap { $0.items.map { ids[Int($0)] } }
    }

    /// The live character ids in document order.
    public var liveChars: [OpID] {
        blocks.flatMap { $0.items.filter { deletedBy[Int($0)] == .zero }.map { ids[Int($0)] } }
    }

    /// The live characters as a string (the plain-string read-out).
    public var string: String {
        var scalars = String.UnicodeScalarView()
        for block in blocks {
            for handle in block.items where deletedBy[Int(handle)] == .zero {
                scalars.append(Unicode.Scalar(codepoints[Int(handle)]) ?? "\u{FFFD}")
            }
        }
        return String(scalars)
    }

    /// The live offset of character `id`: how many live characters precede it (for a tombstone,
    /// where it would be).  Nil for an unknown id.
    public func offset(of id: OpID) -> Int? {
        guard let handle = handles[id] else { return nil }
        let (block, index) = locate(handle)
        var offset = blocks[..<block].reduce(0) { $0 + $1.live }
        for other in blocks[block].items[..<index] where deletedBy[Int(other)] == .zero {
            offset += 1
        }
        return offset
    }

    /// The live character at live offset `offset`, or nil when out of range.
    public func char(at offset: Int) -> OpID? {
        guard offset >= 0 else { return nil }
        var remaining = offset
        for block in blocks {
            guard remaining < block.live else {
                remaining -= block.live
                continue
            }
            for handle in block.items where deletedBy[Int(handle)] == .zero {
                if remaining == 0 { return ids[Int(handle)] }
                remaining -= 1
            }
        }
        return nil
    }

    /// The character after `id` in document order, tombstones included; zero at the end.
    public func successor(of id: OpID) -> OpID {
        guard let handle = handles[id] else { return .zero }
        var (block, index) = locate(handle)
        index += 1
        while block < blocks.count {
            if index < blocks[block].items.count {
                return ids[Int(blocks[block].items[index])]
            }
            block += 1
            index = 0
        }
        return .zero
    }

    /// The origins a client gives a `TextInsert` at live offset `offset`: the live character
    /// before it (zero at the start) and that character's successor, tombstones included (zero at
    /// the end).
    public func insertionOrigins(at offset: Int) -> (left: OpID, right: OpID) {
        let left = offset > 0 ? char(at: offset - 1) ?? .zero : .zero
        if left == .zero {
            return (left: .zero, right: blocks.first { !$0.items.isEmpty }.map { ids[Int($0.items[0])] } ?? .zero)
        }
        return (left: left, right: successor(of: left))
    }

    /// `insertionOrigins(at:)` for a replica that knows a stable point: the right origin skips
    /// tombstones deleted by a `stable` op, which a replica that collected there no longer holds
    /// (crdt-model.adoc, "Garbage collection").
    public func insertionOrigins(at offset: Int, skippingStable stable: (OpID) -> Bool) -> (left: OpID, right: OpID) {
        var (left, right) = insertionOrigins(at: offset)
        while let deleted = deletedOp(right), stable(deleted) {
            right = successor(of: right)
        }
        return (left: left, right: right)
    }

    /// The document-order index of every character, by id.
    func orderIndex() -> [OpID: Int] {
        var index: [OpID: Int] = [:]
        index.reserveCapacity(ids.count)
        var position = 0
        for block in blocks {
            for handle in block.items {
                index[ids[Int(handle)]] = position
                position += 1
            }
        }
        return index
    }

    // MARK: Marks

    /// Records a mark; false when its id is already recorded or an anchor names an unknown
    /// character.
    @discardableResult
    mutating func mark(_ mark: TextMark) -> Bool {
        guard marks[mark.id] == nil, known(mark.start), known(mark.end) else { return false }
        marks[mark.id] = mark
        return true
    }

    func known(_ anchor: Anchor) -> Bool {
        known(anchor.char)
    }

    /// The marks, ascending by id.
    public var sortedMarks: [TextMark] { marks.values.sorted { $0.id < $1.id } }

    /// The document-order positions a mark covers (first...last), or nil when it covers nothing: a
    /// character is covered when it lies between the start and end anchors, each anchor sitting
    /// just before or just after its character; the zero id is the start with `before` and the end
    /// with `after`.
    static func covered(_ mark: TextMark, _ index: [OpID: Int], count: Int) -> ClosedRange<Int>? {
        let first: Int
        if mark.start.char == .zero {
            first = mark.start.before ? 0 : count
        } else {
            first = index[mark.start.char]! + (mark.start.before ? 0 : 1)
        }
        let last: Int
        if mark.end.char == .zero {
            last = mark.end.before ? -1 : count - 1
        } else {
            last = index[mark.end.char]! - (mark.end.before ? 1 : 0)
        }
        return first <= last ? first...last : nil
    }

    /// The winning mark of each attribute for every character, as boundaries: at each position
    /// where the winners change, the winners from there on (sweep over the marks' covered ranges;
    /// the greatest OpId covering a character wins its attribute).
    func winners(_ index: [OpID: Int], only key: MarkKey? = nil) -> [(position: Int, winners: [MarkKey: TextMark])] {
        var events: [Int: [(add: Bool, mark: TextMark)]] = [:]
        for mark in marks.values {
            guard let markKey = mark.key, key == nil || markKey == key,
                  let range = Self.covered(mark, index, count: ids.count) else { continue }
            events[range.lowerBound, default: []].append((add: true, mark: mark))
            events[range.upperBound + 1, default: []].append((add: false, mark: mark))
        }
        var active: [MarkKey: [TextMark]] = [:]
        var out: [(position: Int, winners: [MarkKey: TextMark])] = []
        for position in events.keys.sorted() {
            for event in events[position]! {
                let markKey = event.mark.key!
                if event.add {
                    active[markKey, default: []].append(event.mark)
                } else {
                    active[markKey]!.removeAll { $0.id == event.mark.id }
                }
            }
            var winners: [MarkKey: TextMark] = [:]
            for (markKey, marks) in active {
                if let best = marks.max(by: { $0.id < $1.id }) {
                    winners[markKey] = best
                }
            }
            out.append((position: position, winners: winners))
        }
        return out
    }

    /// The attributed runs (CRDT-006): maximal ranges of live characters with the same winning
    /// marks, each attribute the greatest-OpId mark of its key covering the characters, cleared
    /// values (a case holding its default) left out.
    public var runs: [TextRun] {
        let index = orderIndex()
        let boundaries = winners(index)
        var live: [Bool] = []
        live.reserveCapacity(ids.count)
        for block in blocks {
            for handle in block.items {
                live.append(deletedBy[Int(handle)] == .zero)
            }
        }
        var runs: [TextRun] = []
        var offset = 0
        var current: [TextAttribute] = []
        var length = 0
        var boundary = 0
        var winners: [MarkKey: TextMark] = [:]
        for position in 0..<live.count {
            while boundary < boundaries.count && boundaries[boundary].position <= position {
                winners = boundaries[boundary].winners
                boundary += 1
            }
            guard live[position] else { continue }
            let attributes = Self.attributes(winners)
            if length > 0 && attributes != current {
                runs.append(TextRun(start: offset, length: length, attributes: current))
                offset += length
                length = 0
            }
            current = attributes
            length += 1
        }
        if length > 0 {
            runs.append(TextRun(start: offset, length: length, attributes: current))
        }
        return runs
    }

    static func attributes(_ winners: [MarkKey: TextMark]) -> [TextAttribute] {
        winners.values.filter { !MarkValue.isCleared($0.value, key: $0.key!) }
            .map { TextAttribute(key: $0.key!, value: $0.value, mark: $0.id) }
            .sorted { $0.key < $1.key }
    }

    /// The winning mark of `key` for each of `chars`, by id (absent: none covers it).
    func winners(of key: MarkKey, for chars: [OpID]) -> [OpID: TextMark] {
        let index = orderIndex()
        let boundaries = winners(index, only: key)
        var out: [OpID: TextMark] = [:]
        for char in chars {
            guard let position = index[char] else { continue }
            var found: TextMark?
            for boundary in boundaries where boundary.position <= position {
                found = boundary.winners[key]
            }
            out[char] = found
        }
        return out
    }

    /// The attributes of each of `chars` (cleared values left out), by id.
    func attributes(of chars: [OpID]) -> [OpID: [TextAttribute]] {
        let index = orderIndex()
        let boundaries = winners(index)
        var out: [OpID: [TextAttribute]] = [:]
        for char in chars {
            guard let position = index[char] else { continue }
            var winners: [MarkKey: TextMark] = [:]
            for boundary in boundaries where boundary.position <= position {
                winners = boundary.winners
            }
            out[char] = Self.attributes(winners)
        }
        return out
    }

    // MARK: Garbage collection

    /// The tombstones garbage collection can drop (CRDT-010): each character deleted by a
    /// `stable` op that no mark anchors and that has no character left below it in the Fugue tree,
    /// so dropping it moves and re-orders nothing and changes no depth -- the tree stays the one
    /// the remaining characters' origins build.  A character's children always come after it, so
    /// one pass from the newest decides them all.
    func collectable(_ stable: (OpID) -> Bool) -> Set<OpID> {
        var anchored: Set<OpID> = []
        for mark in marks.values {
            anchored.insert(mark.start.char)
            anchored.insert(mark.end.char)
        }
        var gone = [Bool](repeating: false, count: ids.count)
        var out: Set<OpID> = []
        for handle in stride(from: ids.count - 1, through: 0, by: -1) {
            let deleted = deletedBy[handle]
            guard deleted != .zero, stable(deleted), !anchored.contains(ids[handle]) else { continue }
            let below = (leftChildren[Int32(handle)] ?? []) + (rightChildren[Int32(handle)] ?? [])
            guard below.allSatisfy({ gone[Int($0)] }) else { continue }
            gone[handle] = true
            out.insert(ids[handle])
        }
        return out
    }

    /// This field without the characters `gone`, rebuilt as a snapshot restores it.
    func removing(_ gone: Set<OpID>) -> TextSequence {
        let chars = ids.indices.compactMap { handle -> RestoredChar? in
            gone.contains(ids[handle]) ? nil : RestoredChar(
                id: ids[handle], scalar: codepoints[handle], left: leftOrigins[handle], right: rightOrigins[handle],
                deleted: deletedBy[handle] == .zero ? nil : deletedBy[handle])
        }
        return Self.restore(chars: chars, marks: Array(marks.values))
    }

    // MARK: Restoring

    /// Rebuilds a field from its characters (id, scalar, origins, greatest delete) and marks, as a
    /// snapshot holds them.  The tree is a function of the characters' origins alone, so they are
    /// inserted in id order (a character's origins always have smaller counters), with any whose
    /// origins are still missing retried until none progress.  Then the first character (by id)
    /// with exactly one origin missing -- one garbage collection dropped, which was never its
    /// parent since only childless characters are dropped -- hangs from the other origin as it did
    /// (the left child of its right origin, else the right child of its left origin), and the
    /// retries resume.  (Only a character with two character origins can lose one that way: a
    /// character whose other origin is the start or the end hangs from its character origin, which
    /// therefore has a child and is never dropped.)  Any other character whose origins do not
    /// appear is dropped, as the op that made it would have been a no-op.
    static func restore(chars: [RestoredChar], marks: [TextMark]) -> TextSequence {
        var text = TextSequence()
        var pending = chars.sorted { $0.id < $1.id }
        while !pending.isEmpty {
            var progress = true
            while progress && !pending.isEmpty {
                progress = false
                var waiting: [RestoredChar] = []
                for char in pending where text.handles[char.id] == nil {
                    guard text.known(char.left), text.known(char.right) else {
                        waiting.append(char)
                        continue
                    }
                    text.restore(char, left: char.left, right: char.right)
                    progress = true
                }
                pending = waiting
            }
            guard let index = pending.firstIndex(where: {
                $0.left != .zero && $0.right != .zero && text.known($0.left) != text.known($0.right)
            }) else { break }
            let char = pending.remove(at: index)
            text.restore(char, left: text.known(char.left) ? char.left : .zero, right: text.known(char.right) ? char.right : .zero)
        }
        for mark in marks {
            text.mark(mark)
        }
        return text
    }

    private mutating func restore(_ char: RestoredChar, left: OpID, right: OpID) {
        insertChar(char.id, scalar: char.scalar, left: left, right: right, origins: (char.left, char.right))
        if let deleted = char.deleted {
            delete(char.id, op: deleted)
        }
    }
}

/// One character as a snapshot records it.
struct RestoredChar {
    let id: OpID
    let scalar: UInt32
    let left: OpID
    let right: OpID
    let deleted: OpID?
}

/// Reading a `TextMarkValue`: which attribute it sets and whether it clears it.
enum MarkValue {
    /// The attribute `value` sets: its last record's field number, plus the embedded `tag`
    /// records (field 1) when that field is `featureField`; nil when it sets none or does not
    /// parse.
    static func key(_ value: [UInt8], featureField: UInt32?) -> MarkKey? {
        guard let message = WireMessage.parse(value), let field = message.lastField else { return nil }
        guard field == featureField else { return MarkKey(field: field) }
        return MarkKey(field: field, tag: message.message(field)?.records(1) ?? [])
    }

    /// Whether `value`'s attribute holds its default -- a zero varint or fixed value, or an empty
    /// length-delimited payload (for a `feature`, nothing but its tag) -- which reads as the
    /// attribute cleared (the inverse of a mark over unformatted text writes one).
    static func isCleared(_ value: [UInt8], key: MarkKey) -> Bool {
        guard let message = WireMessage.parse(value), var payload = message.lastRecordPayload else { return false }
        if !key.tag.isEmpty && payload.starts(with: key.tag) {
            payload.removeFirst(key.tag.count)
        }
        return payload.allSatisfy { $0 == 0 }
    }

    /// A value clearing the attribute of `value` (same case, default payload; a `feature` value
    /// keeps its tag).
    static func cleared(_ value: [UInt8], key: MarkKey) -> [UInt8] {
        guard let message = WireMessage.parse(value), let wireType = message.lastWireType else { return [] }
        var out = WireWriter()
        switch wireType {
        case WireMessage.varint: out.varintField(key.field, 0, always: true)
        case WireMessage.fixed64: out.tag(key.field, WireMessage.fixed64); out.raw([UInt8](repeating: 0, count: 8))
        case WireMessage.fixed32: out.tag(key.field, WireMessage.fixed32); out.raw([UInt8](repeating: 0, count: 4))
        default: out.lenField(key.field, key.tag)
        }
        return out.bytes
    }
}
