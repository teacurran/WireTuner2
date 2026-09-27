import Foundation
import WTCRDT
import WTModel
import WTProto

// The typeface rows of the review sheet that are about claims rather than objects (FONT-029;
// glyph-grid.adoc and kerning-metrics.adoc, "Merge semantics"): two glyphs named alike or encoding
// one codepoint, two kerning classes with one name on one side, and a kerning pair created on both
// sides.  The read-time rules already decide what each replica shows (the smaller node id keeps a
// name or codepoint, the greater element id is the pair used, both classes stay), so nothing is
// lost; the rows say what happened and offer the one-change fixes.  A row is listed when the
// colliding claims came from both sides of the reconnect.

/// One collision between claims made on both sides.
public struct FontCollisionEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Two live glyphs store this name (`ids` smallest first: the first keeps it).
        case glyphName(String)
        /// Two live glyphs encode this scalar (the first keeps it).
        case codepoint(UInt32)
        /// Two live classes with this stored name on this side (oldest element id first).
        case className(String, KernSide)
        /// Two elements kern this pair of glyphs (the last, the greatest element id, is used).
        case kernPair(left: OpID, right: OpID)
    }

    public enum Choice: Sendable, Hashable, CaseIterable {
        /// *Rename…*: the sheet asks for a name (`RenameGlyph`); no change of its own.
        case rename
        /// *Remove duplicate*: removes the glyphs that lost the name, when they have no artwork.
        case removeDuplicate
        /// *Move to this glyph*: the codepoint moves from the keeper to the other glyph.
        case moveToThisGlyph
        /// *Remove from other*: the other glyph no longer claims it.
        case removeFromOther
        /// *Merge classes*: the newer class's members and cells move onto the older one.
        case mergeClasses
        /// *Keep the latest*: the used value is written and the other elements deleted.
        case keepLatest

        public var title: String {
            switch self {
            case .rename: "Rename…"
            case .removeDuplicate: "Remove duplicate"
            case .moveToThisGlyph: "Move to this glyph"
            case .removeFromOther: "Remove from other"
            case .mergeClasses: "Merge classes"
            case .keepLatest: "Keep the latest"
            }
        }
    }

    public var kind: Kind
    /// The colliding glyphs, classes or pair elements, in the order the read rule ranks them.
    public var ids: [OpID]
    /// What the sheet offers.
    public var choices: [Choice]

    public init(kind: Kind, ids: [OpID], choices: [Choice]) {
        self.kind = kind
        self.ids = ids
        self.choices = choices
    }

    public var id: String {
        switch kind {
        case .glyphName(let name): "glyph-name:\(name)"
        case .codepoint(let scalar): "codepoint:\(scalar)"
        case .className(let name, let side): "class-name:\(side):\(name)"
        case .kernPair(let left, let right): "kern-pair:\(left):\(right)"
        }
    }

    /// The row's text: "Two glyphs named eacute", "Two glyphs encode U+0041 'A'", "Two left classes
    /// named O", "Two kerning pairs for A V" (names from `index`).
    public func title(_ index: GlyphIndex) -> String {
        let count = ids.count == 2 ? "Two" : "\(ids.count)"
        switch kind {
        case .glyphName(let name):
            return "\(count) glyphs named \(name)"
        case .codepoint(let scalar):
            let character = Unicode.Scalar(scalar).map { " '\(Character($0))'" } ?? ""
            return "\(count) glyphs encode U+\(String(format: "%04X", scalar))\(character)"
        case .className(let name, let side):
            return "\(count) \(side == .left ? "left" : "right") classes named \(name)"
        case .kernPair(let left, let right):
            let names = [left, right].map { index[$0]?.name ?? "\($0)" }
            return "\(count) kerning pairs for \(names.joined(separator: " "))"
        }
    }

    /// The choice as one change, for the glyph `other` where the row needs one (the codepoint
    /// choices name the glyph that should end with it; default the second).  Nil when the choice
    /// writes nothing of its own or is not offered.
    public func command(_ choice: Choice, other: OpID? = nil, in state: EngineState) -> (any Command)? {
        guard choices.contains(choice), ids.count > 1 else { return nil }
        switch (choice, kind) {
        case (.removeDuplicate, .glyphName):
            return RemoveGlyphs(Array(ids.dropFirst()), in: state)
        case (.moveToThisGlyph, .codepoint(let scalar)):
            return MoveGlyphCodepoint(scalar, to: other ?? ids[1])
        case (.removeFromOther, .codepoint(let scalar)):
            return SetGlyphCodepoints(other ?? ids[1], remove: [scalar])
        case (.mergeClasses, .className):
            return CompositeCommand("Merge classes", ids.dropFirst().reversed().map { MergeKernClasses(keeping: ids[0], merging: $0) })
        case (.keepLatest, .kernPair(let left, let right)):
            guard let used = Kerning(state).pair(left, right) else { return nil }
            return SetKernPair(left, right, to: used.value)
        default:
            return nil
        }
    }
}

/// Measuring the rows.
public enum FontCollisionReview {
    /// What one side claimed: glyphs it created or renamed, glyphs it gave codepoints, and the
    /// class and pair elements it created or renamed.
    struct Claims {
        var named: Set<OpID> = []
        var encoded: Set<OpID> = []
        var elements: Set<OpID> = []

        init(_ changes: [Wiretuner_Doc_V1_Change]) {
            let name = GlyphFields.name
            let codepoints = GlyphFields.codepoints
            for change in changes {
                for (op, id) in zip(change.ops, change.opIDs) {
                    switch op.op {
                    case .create(let create)?:
                        guard case .glyph(let glyph)? = create.props.kind else { continue }
                        named.insert(id)
                        if !glyph.codepoints.isEmpty { encoded.insert(id) }
                    case .set(let set)?:
                        let paths = set.paths.compactMap(RegisterPath.init)
                        if paths.contains(name) { named.insert(OpID(set.node)) }
                        for path in paths {
                            // A class renamed: `classes.<element>.name`.
                            if path.segments.count > 3, RegisterPath(segments: Array(path.segments.prefix(3))) == FontFields.classes,
                               case .element(let element) = path.segments[3] {
                                elements.insert(element)
                            }
                        }
                    case .setAdd(let add)?:
                        if RegisterPath(add.set) == codepoints { encoded.insert(OpID(add.node)) }
                    case .elementInsert(let insert)?:
                        let sequence = RegisterPath(insert.sequence)
                        guard sequence == FontFields.classes || sequence == FontFields.pairs else { continue }
                        for offset in 0..<max(1, insert.positions.count) {
                            elements.insert(OpID(counter: id.counter + UInt64(offset), replica: id.replica))
                        }
                    default:
                        continue
                    }
                }
            }
        }
    }

    /// The collisions in `state` whose claims came from both `local` and `remote`, in the order
    /// names, codepoints, classes, pairs.
    public static func rows(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState) -> [FontCollisionEntry] {
        let mine = Claims(local)
        let theirs = Claims(remote)
        guard !(mine.named.isEmpty && mine.encoded.isEmpty && mine.elements.isEmpty)
                && !(theirs.named.isEmpty && theirs.encoded.isEmpty && theirs.elements.isEmpty) else { return [] }
        func both(_ ids: [OpID], _ claims: KeyPath<Claims, Set<OpID>>) -> Bool {
            !mine[keyPath: claims].isDisjoint(with: ids) && !theirs[keyPath: claims].isDisjoint(with: ids)
        }
        var rows: [FontCollisionEntry] = []
        let index = GlyphIndex(state)
        for (name, ids) in index.nameCollisions.sorted(by: { $0.key < $1.key }) where both(ids, \.named) {
            let empty = ids.dropFirst().allSatisfy { GlyphArtwork.objectIDs(on: $0, in: state).isEmpty && (index[$0]?.components.isEmpty ?? true) }
            rows.append(FontCollisionEntry(kind: .glyphName(name), ids: ids, choices: empty ? [.removeDuplicate, .rename] : [.rename]))
        }
        for (scalar, ids) in index.codepointCollisions.sorted(by: { $0.key < $1.key }) where both(ids, \.encoded) {
            rows.append(FontCollisionEntry(kind: .codepoint(scalar), ids: ids, choices: [.moveToThisGlyph, .removeFromOther]))
        }
        let kerning = Kerning(state, index: index)
        for group in kerning.sameNamedClasses where both(group.map(\.id), \.elements) {
            rows.append(FontCollisionEntry(kind: .className(group[0].storedName, group[0].side), ids: group.map(\.id), choices: [.mergeClasses]))
        }
        let pairs = Dictionary(grouping: kerning.storedPairs) { [$0.left, $0.right] }
        for (key, group) in pairs.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) where group.count > 1 && both(group.map(\.id), \.elements) {
            rows.append(FontCollisionEntry(kind: .kernPair(left: key[0], right: key[1]), ids: group.map(\.id).sorted(), choices: [.keepLatest]))
        }
        return rows
    }
}
