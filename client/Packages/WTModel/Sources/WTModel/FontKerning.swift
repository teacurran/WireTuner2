import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-016: the kerning model (kerning-metrics.adoc, "Data model", "Merge semantics", "Client"):
// pairs and class memberships refer to glyphs by node, so renames never break kerning.  Lookup for
// (L, R): the live pair, else the cell of (L's left class, R's right class), else 0.  Read-time
// normalizations: duplicate pairs and cells -- the greater element id wins (a kern value is a
// setting, the latest intent wins); a glyph in two classes of one side -- the greater membership
// element id wins; pairs, members and cells whose glyph or class is gone are absent; a class
// without a side is a left class; a non-finite value is 0.

/// Which side of a pair a class applies to.
public enum KernSide: Hashable, Sendable {
    case left, right

    init(stored: Wiretuner_Doc_V1_KernSide) {
        self = stored == .right ? .right : .left
    }

    var stored: Wiretuner_Doc_V1_KernSide {
        self == .left ? .left : .right
    }
}

/// The document's kerning as read.
public struct Kerning: Hashable, Sendable {
    /// A pair kern (an exception to class kerning).
    public struct Pair: Hashable, Sendable, Identifiable {
        public var id: OpID
        public var left: OpID
        public var right: OpID
        public var value: Double
    }

    /// A kerning class.
    public struct KernClass: Hashable, Sendable, Identifiable {
        public var id: OpID
        public var storedName: String
        /// The name the feature file uses: two live classes with one name and side read `O` and
        /// `O_2` in element-id order.
        public var name: String
        public var side: KernSide
        /// The glyphs that are members after the membership rule, in membership order.
        public var members: [OpID]
        /// Every live membership element with its glyph (live glyphs only).
        public var memberships: [Membership]
    }

    /// One membership element of a class.
    public struct Membership: Hashable, Sendable {
        public var element: OpID
        public var glyph: OpID
    }

    /// One class-kerning cell.
    public struct Cell: Hashable, Sendable, Identifiable {
        public var id: OpID
        public var left: OpID
        public var right: OpID
        public var value: Double
    }

    struct GlyphPair: Hashable, Sendable {
        var left: OpID
        var right: OpID
    }

    /// Every live pair element whose glyphs are live, in sequence order.
    public let storedPairs: [Pair]
    /// Every live cell element whose classes are live and of the right sides, in order.
    public let storedCells: [Cell]
    /// The live classes in sequence order.
    public let classes: [KernClass]
    private let pairs: [GlyphPair: Pair]
    private let cells: [GlyphPair: Cell]
    private let leftClass: [OpID: OpID]
    private let rightClass: [OpID: OpID]

    public init(_ state: EngineState, index: GlyphIndex? = nil) {
        let index = index ?? GlyphIndex(state)
        let font = state.props(WellKnown.settings).settings.font
        func glyph(_ ref: Wiretuner_Doc_V1_NodeRef, has: Bool) -> OpID? {
            guard has, ref.hasID else { return nil }
            let id = OpID(ref.id)
            return index[id] == nil ? nil : id
        }
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        storedPairs = font.pairs.compactMap { pair in
            guard let left = glyph(pair.left, has: pair.hasLeft), let right = glyph(pair.right, has: pair.hasRight) else { return nil }
            return Pair(id: OpID(sequenceElement: pair.id), left: left, right: right, value: finite(pair.value))
        }
        pairs = Dictionary(storedPairs.map { (GlyphPair(left: $0.left, right: $0.right), $0) }) { $0.id > $1.id ? $0 : $1 }
        // Classes, with the O / O_2 naming per side in element-id order.
        var classes: [KernClass] = font.classes.map { stored in
            let memberships: [Membership] = stored.members.compactMap { member in
                glyph(member.glyph, has: member.hasGlyph).map { Membership(element: OpID(sequenceElement: member.id), glyph: $0) }
            }
            return KernClass(id: OpID(sequenceElement: stored.id), storedName: stored.name, name: stored.name, side: KernSide(stored: stored.side),
                             members: [], memberships: memberships)
        }
        let named = Dictionary(grouping: classes.indices) { "\(classes[$0].side)/\(classes[$0].storedName)" }
        for (_, indices) in named where indices.count > 1 {
            for (rank, index) in indices.sorted(by: { classes[$0].id < classes[$1].id }).enumerated().dropFirst() {
                classes[index].name = "\(classes[index].storedName)_\(rank + 1)"
            }
        }
        // Membership: of the memberships of one glyph on one side, the greatest element id wins.
        var winners: [KernSide: [OpID: (element: OpID, kernClass: OpID)]] = [.left: [:], .right: [:]]
        for kernClass in classes {
            for member in kernClass.memberships where (winners[kernClass.side]![member.glyph]?.element).map({ $0 < member.element }) ?? true {
                winners[kernClass.side]![member.glyph] = (member.element, kernClass.id)
            }
        }
        for index in classes.indices {
            let side = classes[index].side
            classes[index].members = classes[index].memberships.filter { winners[side]![$0.glyph]?.element == $0.element }.map(\.glyph)
        }
        self.classes = classes
        leftClass = winners[.left]!.mapValues(\.kernClass)
        rightClass = winners[.right]!.mapValues(\.kernClass)
        let sides = Dictionary(uniqueKeysWithValues: classes.map { ($0.id, $0.side) })
        storedCells = font.classKerns.compactMap { cell in
            let left = OpID(sequenceElement: cell.left), right = OpID(sequenceElement: cell.right)
            guard sides[left] == .left, sides[right] == .right else { return nil }
            return Cell(id: OpID(sequenceElement: cell.id), left: left, right: right, value: finite(cell.value))
        }
        cells = Dictionary(storedCells.map { (GlyphPair(left: $0.left, right: $0.right), $0) }) { $0.id > $1.id ? $0 : $1 }
    }

    /// The kerning between glyphs `left` and `right`: the pair, else the class cell, else 0.
    public func value(_ left: OpID, _ right: OpID) -> Double {
        pair(left, right)?.value ?? classValue(left, right) ?? 0
    }

    /// The effective pair for (`left`, `right`).
    public func pair(_ left: OpID, _ right: OpID) -> Pair? {
        pairs[GlyphPair(left: left, right: right)]
    }

    /// The class cell's value for the glyphs' classes, when both have classes and the cell exists.
    public func classValue(_ left: OpID, _ right: OpID) -> Double? {
        guard let l = leftClass[left], let r = rightClass[right] else { return nil }
        return cells[GlyphPair(left: l, right: r)]?.value
    }

    /// The effective cell of two classes.
    public func cell(_ left: OpID, _ right: OpID) -> Cell? {
        cells[GlyphPair(left: left, right: right)]
    }

    /// The class `glyph` belongs to on `side`.
    public func kernClass(of glyph: OpID, side: KernSide) -> KernClass? {
        let id = side == .left ? leftClass[glyph] : rightClass[glyph]
        return id.flatMap { id in classes.first { $0.id == id } }
    }

    /// The class `id`.
    public func kernClass(_ id: OpID) -> KernClass? {
        classes.first { $0.id == id }
    }

    /// The effective pairs, in sequence order.
    public var effectivePairs: [Pair] {
        storedPairs.filter { pairs[GlyphPair(left: $0.left, right: $0.right)]?.id == $0.id }
    }

    /// The effective cells, in sequence order.
    public var effectiveCells: [Cell] {
        storedCells.filter { cells[GlyphPair(left: $0.left, right: $0.right)]?.id == $0.id }
    }

    /// Pair elements that lost to a duplicate (listed by the review sheet; the next set deletes
    /// them).
    public var duplicatePairs: [Pair] {
        storedPairs.filter { pairs[GlyphPair(left: $0.left, right: $0.right)]?.id != $0.id }
    }

    /// Cell elements that lost to a duplicate.
    public var duplicateCells: [Cell] {
        storedCells.filter { cells[GlyphPair(left: $0.left, right: $0.right)]?.id != $0.id }
    }

    /// The Exceptions list: effective pairs whose glyphs both have classes, with the class value
    /// they override (0 when the cell is absent).
    public var exceptions: [(pair: Pair, classValue: Double)] {
        effectivePairs.compactMap { pair in
            guard leftClass[pair.left] != nil, rightClass[pair.right] != nil else { return nil }
            return (pair, classValue(pair.left, pair.right) ?? 0)
        }
    }

    /// Whether the document has any kerning.
    public var isEmpty: Bool { storedPairs.isEmpty && storedCells.isEmpty }

    /// Live classes sharing a stored name on one side (the review sheet's *Merge classes*).
    public var sameNamedClasses: [[KernClass]] {
        Dictionary(grouping: classes) { "\($0.side)/\($0.storedName)" }.values.filter { $0.count > 1 }
            .map { $0.sorted { $0.id < $1.id } }.sorted { $0[0].id < $1[0].id }
    }
}

/// Shared writes of the kerning commands.
enum KerningEditing {
    static let range = -32_767.0...32_767.0

    static func validate(_ value: Double) throws {
        guard value.isFinite, range.contains(value) else { throw FontEditError.invalidValue("kern value") }
    }

    static func setPairValue(_ pair: OpID, _ value: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(WellKnown.settings, [FontFields.pairValue(pair)], values: FontFields.fontValues {
            var stored = Wiretuner_Doc_V1_KernPair()
            stored.id = pair.elementID
            stored.value = value
            $0.pairs = [stored]
        })
    }

    static func setCellValue(_ cell: OpID, _ value: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(WellKnown.settings, [FontFields.classKernValue(cell)], values: FontFields.fontValues {
            var stored = Wiretuner_Doc_V1_ClassKern()
            stored.id = cell.elementID
            stored.value = value
            $0.classKerns = [stored]
        })
    }

    /// A key after the last live element of `sequence` on the settings node.
    static func appendKey(_ sequence: RegisterPath, state: EngineState, count: Int = 1) throws -> [[UInt8]] {
        let last = state.liveElements(WellKnown.settings, sequence).last.flatMap { state.position(WellKnown.settings, sequence, $0) }
        return try PathEditing.keys(between: last, and: nil, count: count)
    }

    static func glyphRef(_ glyph: OpID) -> Wiretuner_Doc_V1_NodeRef {
        var ref = Wiretuner_Doc_V1_NodeRef()
        ref.id = glyph.proto
        return ref
    }

    /// Sets the pair (`left`, `right`) to `value` against `kerning`: the redundant exception
    /// (equal to the class value) is removed rather than kept, duplicates of the pair are deleted,
    /// an existing pair is written, else a pair is inserted.
    static func setPair(_ left: OpID, _ right: OpID, _ value: Double, kerning: Kerning, state: EngineState, builder: inout ChangeBuilder) throws {
        try validate(value)
        let existing = kerning.storedPairs.filter { $0.left == left && $0.right == right }
        let winner = kerning.pair(left, right)
        let losers = existing.filter { $0.id != winner?.id }
        if let classValue = kerning.classValue(left, right), classValue == value {
            if !existing.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, existing.map { FontFields.pair($0.id) })) }
            return
        }
        if !losers.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, losers.map { FontFields.pair($0.id) })) }
        if let winner {
            if winner.value != value { builder.append(setPairValue(winner.id, value)) }
            return
        }
        if kerning.classValue(left, right) == nil, value == 0 { return }
        let key = try appendKey(FontFields.pairs, state: state)
        builder.append(Ops.elementInsert(WellKnown.settings, FontFields.pairs, positions: key, values: FontFields.fontValues {
            var pair = Wiretuner_Doc_V1_KernPair()
            pair.left = glyphRef(left)
            pair.right = glyphRef(right)
            pair.value = value
            $0.pairs = [pair]
        }))
    }

    /// Sets the cell (`left`, `right`) to `value`: 0 deletes it (and its duplicates).
    static func setCell(_ left: OpID, _ right: OpID, _ value: Double, kerning: Kerning, state: EngineState, builder: inout ChangeBuilder) throws {
        try validate(value)
        guard kerning.kernClass(left)?.side == .left, kerning.kernClass(right)?.side == .right else { throw FontEditError.unknownElement(left) }
        let existing = kerning.storedCells.filter { $0.left == left && $0.right == right }
        let winner = kerning.cell(left, right)
        if value == 0 {
            if !existing.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, existing.map { FontFields.classKern($0.id) })) }
            return
        }
        let losers = existing.filter { $0.id != winner?.id }
        if !losers.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, losers.map { FontFields.classKern($0.id) })) }
        if let winner {
            if winner.value != value { builder.append(setCellValue(winner.id, value)) }
            return
        }
        let key = try appendKey(FontFields.classKerns, state: state)
        builder.append(Ops.elementInsert(WellKnown.settings, FontFields.classKerns, positions: key, values: FontFields.fontValues {
            var cell = Wiretuner_Doc_V1_ClassKern()
            cell.left = left.elementID
            cell.right = right.elementID
            cell.value = value
            $0.classKerns = [cell]
        }))
    }

    /// Inserts memberships of `glyphs` into class `kernClass` (already written or just created)
    /// and deletes their memberships in other classes of `side`.
    static func addMembers(_ glyphs: [OpID], to kernClass: OpID, side: KernSide, existing: [Kerning.Membership], kerning: Kerning,
                           state: EngineState, builder: inout ChangeBuilder) throws {
        let adding = glyphs.filter { glyph in !existing.contains { $0.glyph == glyph } || kerning.kernClass(of: glyph, side: side)?.id != kernClass }
        guard !adding.isEmpty else { return }
        for other in kerning.classes where other.side == side && other.id != kernClass {
            let moved = other.memberships.filter { adding.contains($0.glyph) }
            if !moved.isEmpty {
                builder.append(Ops.elementDelete(WellKnown.settings, moved.map { FontFields.kernClassMember(other.id, $0.element) }))
            }
        }
        let path = FontFields.kernClassMembers(kernClass)
        let last = existing.last.flatMap { state.position(WellKnown.settings, path, $0.element) }
        let keys = try PathEditing.keys(between: last, and: nil, count: adding.count)
        builder.append(Ops.elementInsert(WellKnown.settings, path, positions: keys, values: FontFields.fontValues {
            var stored = Wiretuner_Doc_V1_KernClass()
            stored.members = adding.map { glyph in
                var member = Wiretuner_Doc_V1_KernClassMember()
                member.glyph = glyphRef(glyph)
                return member
            }
            $0.classes = [stored]
        }))
    }

    static func validClassName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 63 && name.unicodeScalars.allSatisfy(GlyphNaming.isNameCharacter)
    }
}

/// Setting a pair in the Metrics window or the Kerning Classes sheet: inserts or writes the
/// pair; a value equal to the class value removes the redundant pair.  "Kern pair".
public struct SetKernPair: Command {
    public var left: OpID
    public var right: OpID
    public var value: Double
    public var coalescing: UndoCoalescing
    public var label: String { "Kern pair" }

    public init(_ left: OpID, _ right: OpID, to value: Double, coalescing: UndoCoalescing = .none) {
        self.left = left
        self.right = right
        self.value = value
        self.coalescing = coalescing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        _ = try GlyphEditing.glyph(left, in: index)
        _ = try GlyphEditing.glyph(right, in: index)
        try KerningEditing.setPair(left, right, value, kerning: Kerning(state, index: index), state: state, builder: &builder)
    }
}

/// *Remove Kerning Pair*: deletes every element of the pairs (duplicates included).  "Remove
/// kerning pair".
public struct RemoveKernPairs: Command {
    public var pairs: [(left: OpID, right: OpID)]
    public var label: String { pairs.count == 1 ? "Remove kerning pair" : "Remove \(pairs.count) kerning pairs" }

    public init(_ pairs: [(left: OpID, right: OpID)]) {
        self.pairs = pairs
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kerning = Kerning(state)
        let elements = kerning.storedPairs.filter { stored in pairs.contains { $0.left == stored.left && $0.right == stored.right } }
        guard !elements.isEmpty else { return }
        builder.append(Ops.elementDelete(WellKnown.settings, elements.map { FontFields.pair($0.id) }))
    }
}

/// A class-kerning matrix cell: inserts or writes it; 0 deletes it.  "Kern classes".
public struct SetClassKern: Command {
    public var left: OpID
    public var right: OpID
    public var value: Double
    public var coalescing: UndoCoalescing
    public var label: String { "Kern classes" }

    public init(_ left: OpID, _ right: OpID, to value: Double, coalescing: UndoCoalescing = .none) {
        self.left = left
        self.right = right
        self.value = value
        self.coalescing = coalescing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try KerningEditing.setCell(left, right, value, kerning: Kerning(state), state: state, builder: &builder)
    }
}

/// *New Class*: a class with `name` and `side` and its members (moved out of other classes of
/// that side), in one change.  "Create kerning class".
public struct CreateKernClass: Command {
    public var name: String
    public var side: KernSide
    public var members: [OpID]
    public var label: String { "Create kerning class" }

    public init(_ name: String, side: KernSide, members: [OpID] = []) {
        self.name = name
        self.side = side
        self.members = members
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard KerningEditing.validClassName(name) else { throw GlyphEditError.invalidName(name) }
        let index = GlyphIndex(state)
        try members.forEach { _ = try GlyphEditing.glyph($0, in: index) }
        let key = try KerningEditing.appendKey(FontFields.classes, state: state)
        let id = builder.append(Ops.elementInsert(WellKnown.settings, FontFields.classes, positions: key, values: FontFields.fontValues {
            var stored = Wiretuner_Doc_V1_KernClass()
            stored.name = name
            stored.side = side.stored
            $0.classes = [stored]
        }))
        try KerningEditing.addMembers(members, to: id, side: side, existing: [], kerning: Kerning(state, index: index), state: state, builder: &builder)
    }
}

/// Class edits: rename, add members (moving them from other classes of the side), remove
/// members, remove the class with every cell naming it.
public struct EditKernClass: Command {
    public enum Edit: Hashable, Sendable {
        case rename(String)
        case addMembers([OpID])
        case removeMembers([OpID])
        case remove
    }

    public var kernClass: OpID
    public var edit: Edit

    public init(_ kernClass: OpID, _ edit: Edit) {
        self.kernClass = kernClass
        self.edit = edit
    }

    public var label: String {
        switch edit {
        case .rename: "Rename kerning class"
        case .addMembers: "Add to kerning class"
        case .removeMembers: "Remove from kerning class"
        case .remove: "Remove kerning class"
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let kerning = Kerning(state, index: index)
        guard let current = kerning.kernClass(kernClass) else { throw FontEditError.unknownElement(kernClass) }
        switch edit {
        case .rename(let name):
            guard KerningEditing.validClassName(name) else { throw GlyphEditError.invalidName(name) }
            builder.append(Ops.set(WellKnown.settings, [FontFields.kernClassName(kernClass)], values: FontFields.fontValues {
                var stored = Wiretuner_Doc_V1_KernClass()
                stored.id = kernClass.elementID
                stored.name = name
                $0.classes = [stored]
            }))
        case .addMembers(let glyphs):
            try glyphs.forEach { _ = try GlyphEditing.glyph($0, in: index) }
            try KerningEditing.addMembers(glyphs, to: kernClass, side: current.side, existing: current.memberships, kerning: kerning, state: state,
                                          builder: &builder)
        case .removeMembers(let glyphs):
            let removed = current.memberships.filter { glyphs.contains($0.glyph) }
            guard !removed.isEmpty else { return }
            builder.append(Ops.elementDelete(WellKnown.settings, removed.map { FontFields.kernClassMember(kernClass, $0.element) }))
        case .remove:
            builder.append(Ops.elementDelete(WellKnown.settings, [FontFields.kernClass(kernClass)]))
            let cells = kerning.storedCells.filter { $0.left == kernClass || $0.right == kernClass }
            if !cells.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, cells.map { FontFields.classKern($0.id) })) }
        }
    }
}

/// *Remove All Kerning*: every pair and cell deleted, one change.  "Remove all kerning".
public struct RemoveAllKerning: Command {
    public var label: String { "Remove all kerning" }

    public init() {}

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let pairs = state.liveElements(WellKnown.settings, FontFields.pairs)
        let cells = state.liveElements(WellKnown.settings, FontFields.classKerns)
        if !pairs.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, pairs.map(FontFields.pair))) }
        if !cells.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, cells.map(FontFields.classKern))) }
    }
}

/// The review sheet's *Merge classes*: every membership and every cell of `newer` moved onto
/// `older` (older cells kept where both are set), then `newer` deleted, one change.  "Merge
/// classes".
public struct MergeKernClasses: Command {
    public var older: OpID
    public var newer: OpID
    public var label: String { "Merge classes" }

    public init(keeping older: OpID, merging newer: OpID) {
        self.older = older
        self.newer = newer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kerning = Kerning(state)
        guard let keep = kerning.kernClass(older) else { throw FontEditError.unknownElement(older) }
        guard let merged = kerning.kernClass(newer), merged.side == keep.side, older != newer else { throw FontEditError.unknownElement(newer) }
        let incoming = merged.memberships.map(\.glyph).filter { glyph in !keep.memberships.contains { $0.glyph == glyph } }
        if !incoming.isEmpty {
            let path = FontFields.kernClassMembers(older)
            let last = keep.memberships.last.flatMap { state.position(WellKnown.settings, path, $0.element) }
            let keys = try PathEditing.keys(between: last, and: nil, count: incoming.count)
            builder.append(Ops.elementInsert(WellKnown.settings, path, positions: keys, values: FontFields.fontValues {
                var stored = Wiretuner_Doc_V1_KernClass()
                stored.members = incoming.map { glyph in
                    var member = Wiretuner_Doc_V1_KernClassMember()
                    member.glyph = KerningEditing.glyphRef(glyph)
                    return member
                }
                $0.classes = [stored]
            }))
        }
        for cell in kerning.effectiveCells where cell.left == newer || cell.right == newer {
            let left = cell.left == newer ? older : cell.left
            let right = cell.right == newer ? older : cell.right
            if kerning.cell(left, right) == nil {
                let key = try KerningEditing.appendKey(FontFields.classKerns, state: state)
                builder.append(Ops.elementInsert(WellKnown.settings, FontFields.classKerns, positions: key, values: FontFields.fontValues {
                    var stored = Wiretuner_Doc_V1_ClassKern()
                    stored.left = left.elementID
                    stored.right = right.elementID
                    stored.value = cell.value
                    $0.classKerns = [stored]
                }))
            }
        }
        try EditKernClass(newer, .remove).execute(&builder, state: state)
    }
}

/// Applies Auto Kern's result (FONT-021 computes it): one change setting each pair, "Auto kern
/// N cells".
public struct ApplyAutoKern: Command {
    public var values: [(left: OpID, right: OpID, value: Double)]
    public var label: String { "Auto kern \(values.count) cells" }

    public init(_ values: [(left: OpID, right: OpID, value: Double)]) {
        self.values = values
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let kerning = Kerning(state, index: index)
        // Pairs inserted by this change are not in `kerning`; the list names each pair once.
        var seen: Set<[OpID]> = []
        for entry in values where seen.insert([entry.left, entry.right]).inserted {
            _ = try GlyphEditing.glyph(entry.left, in: index)
            _ = try GlyphEditing.glyph(entry.right, in: index)
            try KerningEditing.setPair(entry.left, entry.right, entry.value.rounded(), kerning: kerning, state: state, builder: &builder)
        }
    }
}
