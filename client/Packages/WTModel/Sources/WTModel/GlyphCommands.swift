import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-008 / FONT-012 / FONT-013: the glyph commands (glyph-grid.adoc and glyph-editing.adoc,
// "Data model"): add by codepoint, name, range or preset set, rename, set codepoints, remove,
// restore, reorder, width, side bearings and centring, kind, colour, export and note, transform,
// components (add with anchor arithmetic, move, remove, decompose) and anchors (add, move, rename,
// role, remove).  Each is one change; undo is the generic inverse (crdt-model.adoc, "Undo").

/// Why a glyph command could not build its change.
public enum GlyphEditError: Error, Equatable, Sendable {
    /// The node is not a live glyph.
    case notAGlyph(OpID)
    /// A name that does not match the glyph-name pattern.
    case invalidName(String)
    /// The name is live on another glyph (refused locally, glyph-grid.adoc).
    case nameTaken(String)
    /// The codepoint is live on another glyph.
    case codepointTaken(UInt32)
    /// A codepoint outside U+0000 ... U+10FFFF or a surrogate.
    case invalidCodepoint(UInt32)
    /// A value outside the stored range.
    case invalidValue(String)
    /// The element is not a live component or anchor of the glyph.
    case unknownElement(OpID)
    /// A component would make the glyph use itself.
    case componentLoop
    /// The command needs a typeface document.
    case notATypeface
}

/// A glyph to create.
public struct NewGlyph: Hashable, Sendable {
    /// Where a component's source comes from: an existing glyph, or one created earlier in the
    /// same command (by its index in the command's list).
    public enum Source: Hashable, Sendable {
        case glyph(OpID)
        case new(Int)
    }

    public struct NewComponent: Hashable, Sendable {
        public var source: Source
        /// nil: from anchor arithmetic when a base/mark anchor pair matches, else identity.
        public var transform: WTGeometry.AffineTransform?

        public init(source: Source, transform: WTGeometry.AffineTransform? = nil) {
            self.source = source
            self.transform = transform
        }
    }

    public var name: String
    public var codepoints: [UInt32]
    public var kind: GlyphKind
    /// nil: the default advance (500 units per 1000-unit em; 0 for a mark).
    public var advanceWidth: Double?
    public var components: [NewComponent]

    public init(name: String, codepoints: [UInt32] = [], kind: GlyphKind = .base, advanceWidth: Double? = nil, components: [NewComponent] = []) {
        self.name = name
        self.codepoints = codepoints
        self.kind = kind
        self.advanceWidth = advanceWidth
        self.components = components
    }

    /// A glyph for `scalar`, named by the AGL rules; a combining mark gets the mark kind.
    public init(scalar: UInt32) {
        let isMark = Unicode.Scalar(scalar)?.properties.generalCategory == .nonspacingMark
        self.init(name: GlyphNaming.name(for: scalar), codepoints: [scalar], kind: isMark ? .mark : .base)
    }

    /// A glyph named `name`, encoding what the name stands for (nothing for a suffixed or
    /// unknown name; a ligature for a ligature name).
    public init(named name: String) {
        let parts = GlyphNaming.ligatureParts(name)
        let isLigature = parts.count > 1 && !GlyphNaming.scalars(of: name).isEmpty
        self.init(name: name, codepoints: GlyphNaming.codepoint(of: name).map { [$0] } ?? [], kind: isLigature ? .ligature : .base)
    }
}

/// Shared checks and writes of the glyph commands.
enum GlyphEditing {
    /// The default advance width at `upm`: 500 units per 1000-unit em.
    static func defaultAdvance(upm: Int) -> Double {
        (500 * Double(upm) / 1_000).rounded()
    }

    static func glyph(_ id: OpID, in index: GlyphIndex) throws -> Glyph {
        guard let glyph = index[id] else { throw GlyphEditError.notAGlyph(id) }
        return glyph
    }

    static func validate(codepoint: UInt32) throws {
        guard codepoint <= 0x10FFFF, !(0xD800...0xDFFF).contains(codepoint) else { throw GlyphEditError.invalidCodepoint(codepoint) }
    }

    static func validate(width: Double) throws {
        guard width.isFinite, width >= 0, width <= 32_767 else { throw GlyphEditError.invalidValue("advance width") }
    }

    /// `count` positions under the glyphs node right after `after` (at the end when nil).
    static func keys(after: OpID?, count: Int, state: EngineState) throws -> [[UInt8]] {
        let siblings = state.store.children(WellKnown.glyphs)
        guard let after, let index = siblings.firstIndex(of: after) else {
            let last = siblings.last.flatMap { state.store.placement($0)?.position }
            return try PathEditing.keys(between: last, and: nil, count: count)
        }
        let lo = state.store.placement(after)?.position
        let next = siblings[(index + 1)...].first { state.isLive($0) }
        return try PathEditing.keys(between: lo, and: next.flatMap { state.store.placement($0)?.position }, count: count)
    }

    /// `CreateNode` of a glyph plus the `SetAdd` of its codepoints; returns the node id.
    @discardableResult
    static func create(name: String, codepoints: [UInt32], kind: GlyphKind, advanceWidth: Double, position: [UInt8],
                       builder: inout ChangeBuilder) -> OpID {
        let node = builder.append(Ops.create(parent: WellKnown.glyphs, position: position, props: GlyphFields.values {
            $0.name = name
            $0.advanceWidth = advanceWidth
            $0.kind = kind.stored
        }))
        if !codepoints.isEmpty {
            builder.append(Ops.setAdd(node, GlyphFields.codepoints, values: GlyphFields.codepointValues(codepoints)))
        }
        return node
    }

    /// Appends one component element after the glyph's last live component.
    static func insertComponent(into glyph: OpID, source: OpID, transform: WTGeometry.AffineTransform, cached: Data, state: EngineState,
                                builder: inout ChangeBuilder) throws {
        try insertComponents(into: glyph, [(source, transform, cached)], state: state, builder: &builder)
    }

    static func insertComponents(into glyph: OpID, _ components: [(source: OpID, transform: WTGeometry.AffineTransform, cached: Data)], state: EngineState,
                                 builder: inout ChangeBuilder) throws {
        guard !components.isEmpty else { return }
        let last = state.liveElements(glyph, GlyphFields.components).last.flatMap { state.position(glyph, GlyphFields.components, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: components.count)
        builder.append(Ops.elementInsert(glyph, GlyphFields.components, positions: keys, values: GlyphFields.values { props in
            props.components = components.map { component in
                var value = Wiretuner_Doc_V1_Component()
                value.glyph.id = component.source.proto
                value.glyph.cached = component.cached
                if !component.transform.isIdentity { value.transform = PathEditing.proto(component.transform) }
                return value
            }
        }))
    }

    /// The component transform anchor arithmetic gives when `base` has a base anchor whose
    /// attachment name matches a mark anchor of `mark`: translation = base anchor − mark anchor.
    static func attachment(base: Glyph, mark: Glyph) -> WTGeometry.AffineTransform? {
        for anchor in base.anchors where anchor.role == .base && !anchor.isDuplicate {
            if let partner = mark.anchors.first(where: { $0.role == .mark && !$0.isDuplicate && $0.attachmentName == anchor.attachmentName }) {
                return .translation(anchor.position - partner.position)
            }
        }
        return nil
    }

    /// Whether adding `source` as a component of `glyph` would close a loop.
    static func reaches(_ source: OpID, _ glyph: OpID, in index: GlyphIndex) -> Bool {
        var pending = [source]
        var seen: Set<OpID> = []
        while let current = pending.popLast() {
            if current == glyph { return true }
            guard seen.insert(current).inserted, let read = index[current] else { continue }
            pending += read.components.filter { $0.status == .resolved }.compactMap(\.source)
        }
        return false
    }

    /// The writes that move everything drawn on `glyph` by `transform` (glyph space): each
    /// top-level object's transform, each component's transform and each anchor's position.
    static func transformArtwork(of glyph: Glyph, by transform: WTGeometry.AffineTransform, state: EngineState, builder: inout ChangeBuilder) {
        for node in GlyphArtwork.objectIDs(on: glyph.id, in: state) {
            guard let kind = state.nodeKind(node) else { continue }
            let layer = Objects.parentTransform(of: node, in: state)
            // In the object's parent (layer) space: layer⁻¹ · transform · layer.
            let local = layer.inverse.concatenating(transform).concatenating(layer)
            builder.append(Objects.setTransform(node, kind: kind, Objects.transform(of: node, in: state).concatenating(local)))
        }
        for component in glyph.components {
            let moved = component.transform.concatenating(transform)
            builder.append(Ops.set(glyph.id, [GlyphFields.componentTransform(component.id)], values: GlyphFields.values {
                var value = Wiretuner_Doc_V1_Component()
                value.id = component.id.elementID
                if !moved.isIdentity { value.transform = PathEditing.proto(moved) }
                $0.components = [value]
            }))
        }
        for anchor in glyph.anchors {
            let moved = transform.apply(anchor.position)
            builder.append(setAnchorPosition(glyph.id, anchor.id, moved))
        }
    }

    static func setAnchorPosition(_ glyph: OpID, _ anchor: OpID, _ position: Point) -> Wiretuner_Doc_V1_Op {
        Ops.set(glyph, [GlyphFields.anchorPosition(anchor)], values: GlyphFields.values {
            var value = Wiretuner_Doc_V1_GlyphAnchor()
            value.id = anchor.elementID
            value.position = PathEditing.proto(position)
            $0.anchors = [value]
        })
    }

    static func setWidth(_ glyph: OpID, _ width: Double) -> Wiretuner_Doc_V1_Op {
        Ops.set(glyph, [GlyphFields.advanceWidth], values: GlyphFields.values { $0.advanceWidth = width })
    }

    static func label(_ verb: String, count: Int) -> String {
        count == 1 ? verb : "\(verb) of \(count) glyphs"
    }
}

// MARK: Adding

/// *Add Glyph* and *Add Glyphs from Range*: creates glyphs after `after` (at the end when nil),
/// in one change "Add glyph" / "Add N glyphs".  A name or codepoint live on another glyph is
/// refused -- or, with `skipExisting` (ranges and preset sets), that glyph is left out.
public struct AddGlyphs: Command {
    public var glyphs: [NewGlyph]
    public var after: OpID?
    public var skipExisting: Bool

    public init(_ glyphs: [NewGlyph], after: OpID? = nil, skipExisting: Bool = false) {
        self.glyphs = glyphs
        self.after = after
        self.skipExisting = skipExisting
    }

    /// One glyph per codepoint of `range` (the Add Glyphs from Range sheet), skipping codepoints
    /// already encoded and unassigned scalars.
    public static func range(_ range: ClosedRange<UInt32>, after: OpID? = nil) -> AddGlyphs {
        AddGlyphs(range.filter { scalar in
            Unicode.Scalar(scalar).map { $0.properties.generalCategory != .unassigned && $0.properties.generalCategory != .surrogate } ?? false
        }.map(NewGlyph.init(scalar:)), after: after, skipExisting: true)
    }

    public var label: String { glyphs.count == 1 ? "Add glyph" : "Add \(glyphs.count) glyphs" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let upm = FontInfo(state).metrics.upm
        var names = Set(index.glyphs.flatMap { [$0.name, $0.storedName] })
        var codepoints = Set(index.glyphs.flatMap(\.storedCodepoints))
        var accepted: [(offset: Int, glyph: NewGlyph)] = []
        for (offset, glyph) in glyphs.enumerated() {
            guard GlyphNaming.isValid(glyph.name) else { throw GlyphEditError.invalidName(glyph.name) }
            try glyph.codepoints.forEach(GlyphEditing.validate(codepoint:))
            if let width = glyph.advanceWidth { try GlyphEditing.validate(width: width) }
            let taken = names.contains(glyph.name) ? GlyphEditError.nameTaken(glyph.name)
                : glyph.codepoints.first(where: codepoints.contains).map(GlyphEditError.codepointTaken)
            if let taken {
                if skipExisting { continue }
                throw taken
            }
            names.insert(glyph.name)
            codepoints.formUnion(glyph.codepoints)
            accepted.append((offset, glyph))
        }
        guard !accepted.isEmpty else { return }
        let keys = try GlyphEditing.keys(after: after, count: accepted.count, state: state)
        var created: [Int: OpID] = [:]
        for ((offset, glyph), key) in zip(accepted, keys) {
            let width = glyph.advanceWidth ?? (glyph.kind == .mark ? 0 : GlyphEditing.defaultAdvance(upm: upm))
            created[offset] = GlyphEditing.create(name: glyph.name, codepoints: glyph.codepoints, kind: glyph.kind, advanceWidth: width,
                                                  position: key, builder: &builder)
        }
        // Components: sources resolve to existing glyphs or to glyphs made above; a new glyph has
        // no anchors yet, so only existing pairs can place a component by anchor arithmetic.
        for (offset, glyph) in accepted where !glyph.components.isEmpty {
            let target = created[offset]!
            let components = glyph.components.compactMap { component -> (OpID, WTGeometry.AffineTransform, Data)? in
                let source: OpID?
                switch component.source {
                case .glyph(let id): source = index[id]?.id
                case .new(let other): source = created[other]
                }
                guard let source else { return nil }
                let mark = index[source]
                let base = glyph.components.first.flatMap { first -> Glyph? in
                    if case .glyph(let id) = first.source { return index[id] }
                    return nil
                }
                let transform = component.transform ?? base.flatMap { base in mark.flatMap { GlyphEditing.attachment(base: base, mark: $0) } } ?? .identity
                return (source, transform, Data())
            }
            try GlyphEditing.insertComponents(into: target, components, state: state, builder: &builder)
        }
    }
}

/// A starting set of glyphs (typeface-documents.adoc, "Creating a typeface document").
public enum GlyphSet: Hashable, Sendable, CaseIterable {
    /// The 95 printable ASCII characters and `.notdef`.
    case basicLatin
    /// Basic Latin, the Latin-1 Supplement block with the accented letters built as components of
    /// their base letter and mark, and the seven combining marks those use.
    case latin1

    /// The combining marks the Latin-1 accented letters are built from.
    static let latin1Marks: [UInt32] = [0x0300, 0x0301, 0x0302, 0x0303, 0x0308, 0x030A, 0x0327]

    /// The glyphs of the set, in grid order.
    public var glyphs: [NewGlyph] {
        var result = [NewGlyph(name: ".notdef")] + (0x20...0x7E).map { NewGlyph(scalar: UInt32($0)) }
        guard self == .latin1 else { return result }
        let marksStart = result.count
        result += Self.latin1Marks.map(NewGlyph.init(scalar:))
        var byScalar: [UInt32: Int] = [:]
        for (index, glyph) in result.enumerated() {
            for scalar in glyph.codepoints { byScalar[scalar] = index }
        }
        _ = marksStart
        for scalar in UInt32(0xA0)...0xFF {
            var glyph = NewGlyph(scalar: scalar)
            let parts = String(Unicode.Scalar(scalar)!).decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
            if parts.count == 2, let base = byScalar[parts[0]], let mark = byScalar[parts[1]] {
                glyph.components = [NewGlyph.NewComponent(source: .new(base)), NewGlyph.NewComponent(source: .new(mark))]
            }
            byScalar[scalar] = result.count
            result.append(glyph)
        }
        return result
    }

    /// *Add the Basic Latin glyph set* and the New Typeface sheet's starting sets as one command.
    public func command(after: OpID? = nil) -> AddGlyphs {
        AddGlyphs(glyphs, after: after, skipExisting: true)
    }
}

// MARK: Naming and encoding

/// *Rename*: `SetFields(name)`, refused when the name is invalid or live on another glyph.
/// "Rename glyph".
///
/// With `inFeatureFile` the same change also rewrites the feature file's uses of the old name
/// (`RenameInFeatureFile`, the rename sheet's btn:[Rename in Feature File]; opentype-features.adoc,
/// "Feature text vs. glyph rename").
public struct RenameGlyph: Command {
    public var glyph: OpID
    public var name: String
    public var inFeatureFile: Bool
    public var label: String { "Rename glyph" }

    public init(_ glyph: OpID, to name: String, inFeatureFile: Bool = false) {
        self.glyph = glyph
        self.name = name
        self.inFeatureFile = inFeatureFile
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let current = try GlyphEditing.glyph(glyph, in: index)
        guard GlyphNaming.isValid(name) else { throw GlyphEditError.invalidName(name) }
        guard current.storedName != name || current.nameStatus != .stored else { return }
        guard !index.isNameTaken(name, except: glyph) else { throw GlyphEditError.nameTaken(name) }
        builder.append(Ops.set(glyph, [GlyphFields.name], values: GlyphFields.values { $0.name = name }))
        if inFeatureFile {
            try RenameInFeatureFile(current.name, to: name).execute(&builder, state: state)
        }
    }
}

/// The Glyph section's Unicode list: `SetAdd` / `SetRemove` on `codepoints`; adding a codepoint
/// live on another glyph is refused.  "Set Unicode".
public struct SetGlyphCodepoints: Command {
    public var glyph: OpID
    public var add: [UInt32]
    public var remove: [UInt32]
    public var label: String { "Set Unicode" }

    public init(_ glyph: OpID, add: [UInt32] = [], remove: [UInt32] = []) {
        self.glyph = glyph
        self.add = add
        self.remove = remove
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let current = try GlyphEditing.glyph(glyph, in: index)
        try add.forEach(GlyphEditing.validate(codepoint:))
        let adding = add.filter { !current.storedCodepoints.contains($0) }
        if let taken = adding.first(where: { index.holder(of: $0, except: glyph) != nil }) { throw GlyphEditError.codepointTaken(taken) }
        let removing = remove.filter(current.storedCodepoints.contains)
        if !removing.isEmpty { builder.append(Ops.setRemove(glyph, GlyphFields.codepoints, values: GlyphFields.codepointValues(removing))) }
        if !adding.isEmpty { builder.append(Ops.setAdd(glyph, GlyphFields.codepoints, values: GlyphFields.codepointValues(adding))) }
    }
}

/// The review sheet's *Move to this glyph* for a codepoint collision: `SetRemove` on the glyph
/// that keeps it and `SetAdd` on `glyph`, one change.  "Move Unicode".
public struct MoveGlyphCodepoint: Command {
    public var codepoint: UInt32
    public var glyph: OpID
    public var label: String { "Move Unicode" }

    public init(_ codepoint: UInt32, to glyph: OpID) {
        self.codepoint = codepoint
        self.glyph = glyph
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let target = try GlyphEditing.glyph(glyph, in: index)
        try GlyphEditing.validate(codepoint: codepoint)
        for holder in index.glyphs where holder.id != glyph && holder.storedCodepoints.contains(codepoint) {
            builder.append(Ops.setRemove(holder.id, GlyphFields.codepoints, values: GlyphFields.codepointValues([codepoint])))
        }
        if !target.storedCodepoints.contains(codepoint) {
            builder.append(Ops.setAdd(glyph, GlyphFields.codepoints, values: GlyphFields.codepointValues([codepoint])))
        }
    }
}

// MARK: Removing and ordering

/// *Remove*: `SetDeleted` on each glyph and every object on its canvas, one change "Remove glyph
/// *name*" / "Remove N glyphs".
public struct RemoveGlyphs: Command {
    public var glyphs: [OpID]
    private var described: String?

    public init(_ glyphs: [OpID]) {
        self.glyphs = glyphs
    }

    /// The command with its label naming the glyph from `state`.
    public init(_ glyphs: [OpID], in state: EngineState) {
        self.glyphs = glyphs
        described = glyphs.count == 1 ? GlyphIndex(state)[glyphs[0]]?.name : nil
    }

    public var label: String {
        glyphs.count == 1 ? described.map { "Remove glyph \($0)" } ?? "Remove glyph" : "Remove \(glyphs.count) glyphs"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        for id in glyphs {
            _ = try GlyphEditing.glyph(id, in: index)
            builder.append(Ops.setDeleted(id))
            for object in GlyphArtwork.objectIDs(on: id, in: state) {
                builder.append(Ops.setDeleted(object))
            }
        }
    }
}

/// *Restore glyph* (the review sheet and the live notice): `deleted = false` on the glyph, which
/// also re-attaches objects drawn on it concurrently (their `canvas` still names it).
public struct RestoreGlyph: Command {
    public var glyph: OpID
    public var label: String { "Restore glyph" }

    public init(_ glyph: OpID) {
        self.glyph = glyph
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.store.kind(glyph) == GlyphFields.kind, state.store.deleted(glyph)?.current.value == true else {
            throw GlyphEditError.notAGlyph(glyph)
        }
        builder.append(Ops.setDeleted(glyph, false))
    }
}

/// Drag-to-reorder in Custom order: `MoveNode` under the glyphs node to grid position `order`
/// (1-based, clamped).  "Move glyph".
public struct ReorderGlyph: Command {
    public var glyph: OpID
    public var order: Int
    public var label: String { "Move glyph" }

    public init(_ glyph: OpID, to order: Int) {
        self.glyph = glyph
        self.order = order
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let current = try GlyphEditing.glyph(glyph, in: index)
        var others = index.glyphs.map(\.id)
        others.removeAll { $0 == glyph }
        let target = min(max(order - 1, 0), others.count)
        guard target != current.order - 1 else { return }
        let key: (OpID) -> [UInt8]? = { state.store.placement($0)?.position }
        let position = try PathEditing.keys(between: target > 0 ? key(others[target - 1]) : nil, and: target < others.count ? key(others[target]) : nil,
                                            count: 1)[0]
        builder.append(Ops.move(glyph, parent: WellKnown.glyphs, position: position))
    }
}

// MARK: Metrics

/// *Set Width*: `SetFields(advance_width)` on each glyph.  "Set width" / "Set width of N glyphs".
public struct SetGlyphWidth: Command {
    public var glyphs: [OpID]
    public var width: Double
    public var coalescing: UndoCoalescing

    public init(_ glyphs: [OpID], to width: Double, coalescing: UndoCoalescing = .none) {
        self.glyphs = glyphs
        self.width = width
        self.coalescing = coalescing
    }

    public var label: String { GlyphEditing.label("Set width", count: glyphs.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try GlyphEditing.validate(width: width)
        let index = GlyphIndex(state)
        for id in glyphs where try GlyphEditing.glyph(id, in: index).advanceWidth != width {
            builder.append(GlyphEditing.setWidth(id, width))
        }
    }
}

/// The side bearing commands (LSB drag, the Glyph section's LSB and RSB fields, *Center in
/// Width*): the artwork, components and anchors translated horizontally and, where the RSB is
/// kept or set, the advance width written, in one change.
public struct SetGlyphBearings: Command {
    public enum Change: Hashable, Sendable {
        /// Move the artwork so the LSB is the value; `keepRSB` also grows the width by the move.
        case left(Double, keepRSB: Bool)
        /// Set the width so the RSB is the value.
        case right(Double)
        /// Equal side bearings in the current width.
        case center
        /// *Thirds in Width*: the right side bearing twice the left, in the current width.
        case thirds
    }

    public var glyphs: [OpID]
    public var change: Change
    public var coalescing: UndoCoalescing

    public init(_ glyphs: [OpID], _ change: Change, coalescing: UndoCoalescing = .none) {
        self.glyphs = glyphs
        self.change = change
        self.coalescing = coalescing
    }

    public var label: String {
        switch change {
        case .left: GlyphEditing.label("Set left side bearing", count: glyphs.count)
        case .right: GlyphEditing.label("Set right side bearing", count: glyphs.count)
        case .center: GlyphEditing.label("Center in width", count: glyphs.count)
        case .thirds: GlyphEditing.label("Thirds in width", count: glyphs.count)
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let outlines = GlyphFlattener.outlines(GlyphOutlines.sources(in: state, index: index))
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            let metrics = GlyphMetrics(advanceWidth: glyph.advanceWidth, bounds: outlines[NodeID(id)]?.bounds)
            guard metrics.bounds != nil else { continue }
            var dx = 0.0
            var width = glyph.advanceWidth
            switch change {
            case .left(let value, let keepRSB):
                guard value.isFinite else { throw GlyphEditError.invalidValue("left side bearing") }
                dx = value - metrics.leftSideBearing
                if keepRSB { width += dx }
            case .right(let value):
                guard value.isFinite else { throw GlyphEditError.invalidValue("right side bearing") }
                width = glyph.advanceWidth - metrics.rightSideBearing + value
            case .center:
                dx = ((metrics.leftSideBearing + metrics.rightSideBearing) / 2 - metrics.leftSideBearing)
            case .thirds:
                dx = ((metrics.leftSideBearing + metrics.rightSideBearing) / 3 - metrics.leftSideBearing)
            }
            try GlyphEditing.validate(width: width)
            if dx != 0 { GlyphEditing.transformArtwork(of: glyph, by: .translation(x: dx, y: 0), state: state, builder: &builder) }
            if width != glyph.advanceWidth { builder.append(GlyphEditing.setWidth(id, width)) }
        }
    }
}

/// *Transform* on glyphs: every top-level object, component and anchor of each glyph by
/// `transform` (glyph space), and with `scaleWidth` the advance width by the transform's
/// horizontal scale.  "Transform glyph" / "Transform N glyphs".
public struct TransformGlyphs: Command {
    public var glyphs: [OpID]
    public var transform: WTGeometry.AffineTransform
    public var scaleWidth: Bool

    public init(_ glyphs: [OpID], by transform: WTGeometry.AffineTransform, scaleWidth: Bool = false) {
        self.glyphs = glyphs
        self.transform = transform
        self.scaleWidth = scaleWidth
    }

    public var label: String { glyphs.count == 1 ? "Transform glyph" : "Transform \(glyphs.count) glyphs" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard transform.isFiniteTransform, transform.isInvertible else { throw ObjectEditError.degenerateTransform }
        let index = GlyphIndex(state)
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            GlyphEditing.transformArtwork(of: glyph, by: transform, state: state, builder: &builder)
            if scaleWidth {
                let width = (glyph.advanceWidth * abs(transform.a)).rounded()
                try GlyphEditing.validate(width: width)
                if width != glyph.advanceWidth { builder.append(GlyphEditing.setWidth(id, width)) }
            }
        }
    }
}

/// The Glyph section's Kind, Mark color, Export and Note fields: one change writing the fields
/// given on every glyph.  "Set glyph kind", "Set mark color", "Set export", "Set note".
public struct SetGlyphAttributes: Command {
    public var glyphs: [OpID]
    public var kind: GlyphKind?
    public var markColor: Int?
    public var export: Bool?
    public var note: String?

    public init(_ glyphs: [OpID], kind: GlyphKind? = nil, markColor: Int? = nil, export: Bool? = nil, note: String? = nil) {
        self.glyphs = glyphs
        self.kind = kind
        self.markColor = markColor
        self.export = export
        self.note = note
    }

    public var label: String {
        if kind != nil { return "Set glyph kind" }
        if markColor != nil { return "Set mark color" }
        if export != nil { return "Set export" }
        return "Set note"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let markColor, !(0...12).contains(markColor) { throw GlyphEditError.invalidValue("mark color") }
        let index = GlyphIndex(state)
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            var paths: [RegisterPath] = []
            var values = GlyphFields.values { _ in }
            if let kind, kind != glyph.kind {
                paths.append(GlyphFields.glyphKind)
                values.glyph.kind = kind.stored
            }
            if let markColor, markColor != glyph.markColor {
                paths.append(GlyphFields.markColor)
                values.glyph.markColor = UInt32(markColor)
            }
            if let export, export == glyph.skipExport {
                paths.append(GlyphFields.skipExport)
                values.glyph.skipExport = !export
            }
            if let note, note != glyph.note {
                paths.append(GlyphFields.note)
                values.glyph.common.note = String(note.prefix(8192))
            }
            if !paths.isEmpty { builder.append(Ops.set(id, paths, values: values)) }
        }
    }
}

// MARK: Components

/// *Add Component* and *Paste as Component*: a component of `source` on `glyph`, placed by
/// `transform`, or by anchor arithmetic when nil and a base/mark pair matches, else at the
/// origin.  The source's flattened outline is cached on the reference for placeholders.
/// "Add component".
public struct AddComponent: Command {
    public var glyph: OpID
    public var source: OpID
    public var transform: WTGeometry.AffineTransform?
    public var label: String { "Add component" }

    public init(_ source: OpID, to glyph: OpID, transform: WTGeometry.AffineTransform? = nil) {
        self.glyph = glyph
        self.source = source
        self.transform = transform
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let target = try GlyphEditing.glyph(glyph, in: index)
        let mark = try GlyphEditing.glyph(source, in: index)
        guard !GlyphEditing.reaches(source, glyph, in: index) else { throw GlyphEditError.componentLoop }
        let placed = transform ?? GlyphEditing.attachment(base: target, mark: mark) ?? .identity
        guard placed.isFiniteTransform else { throw GlyphEditError.invalidValue("transform") }
        let cached = GlyphOutlines.encode(GlyphFlattener.outline(of: NodeID(source), sources: GlyphOutlines.sources(in: state, index: index)).path)
        try GlyphEditing.insertComponent(into: glyph, source: source, transform: placed, cached: cached, state: state, builder: &builder)
    }
}

/// Moving or transforming a component: `SetFields(components[e].transform)`.  "Move component".
public struct SetComponentTransform: Command {
    public var glyph: OpID
    public var component: OpID
    public var transform: WTGeometry.AffineTransform
    public var coalescing: UndoCoalescing
    public var label: String { "Move component" }

    public init(_ component: OpID, of glyph: OpID, to transform: WTGeometry.AffineTransform, coalescing: UndoCoalescing = .none) {
        self.glyph = glyph
        self.component = component
        self.transform = transform
        self.coalescing = coalescing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try GlyphEditing.glyph(glyph, in: GlyphIndex(state))
        guard current.components.contains(where: { $0.id == component }) else { throw GlyphEditError.unknownElement(component) }
        guard transform.isFiniteTransform else { throw GlyphEditError.invalidValue("transform") }
        builder.append(Ops.set(glyph, [GlyphFields.componentTransform(component)], values: GlyphFields.values {
            var value = Wiretuner_Doc_V1_Component()
            value.id = component.elementID
            if !transform.isIdentity { value.transform = PathEditing.proto(transform) }
            $0.components = [value]
        }))
    }
}

/// Removes components: `ElementDelete`.  "Remove component".
public struct RemoveComponents: Command {
    public var glyph: OpID
    public var components: [OpID]
    public var label: String { components.count == 1 ? "Remove component" : "Remove \(components.count) components" }

    public init(_ components: [OpID], of glyph: OpID) {
        self.glyph = glyph
        self.components = components
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try GlyphEditing.glyph(glyph, in: GlyphIndex(state))
        for component in components where !current.components.contains(where: { $0.id == component }) {
            throw GlyphEditError.unknownElement(component)
        }
        guard !components.isEmpty else { return }
        builder.append(Ops.elementDelete(glyph, components.map(GlyphFields.component)))
    }
}

/// *Decompose* (and *Decompose All* with `components` nil): each component's element deleted
/// and one path holding its flattened outline's contours created on the glyph's canvas, on
/// the glyph's topmost layer, in one change.  Nested components flatten fully; a placeholder
/// decomposes from its cached outline.  "Decompose".
public struct DecomposeComponents: Command {
    public var glyph: OpID
    public var components: [OpID]?
    public var label: String { "Decompose" }

    public init(_ glyph: OpID, components: [OpID]? = nil) {
        self.glyph = glyph
        self.components = components
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let current = try GlyphEditing.glyph(glyph, in: index)
        let chosen = current.components.filter { components?.contains($0.id) ?? true }
        if let components, chosen.count != components.count { throw GlyphEditError.unknownElement(components.first { id in !chosen.contains { $0.id == id } }!) }
        guard !chosen.isEmpty else { return }
        let sources = GlyphOutlines.sources(in: state, index: index)
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: GlyphArtwork.objects(on: glyph, in: state).last?.layer)
        var previous = state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
        builder.append(Ops.elementDelete(glyph, chosen.map { GlyphFields.component($0.id) }))
        for component in chosen {
            let placement: GlyphComponentPlacement
            switch component.status {
            case .resolved: placement = GlyphComponentPlacement(source: .glyph(NodeID(component.source!)), transform: component.transform)
            case .dangling: placement = GlyphComponentPlacement(source: .placeholder(GlyphOutlines.decode(component.cached)), transform: component.transform)
            case .loop: continue
            }
            // One path per component holding every contour: the union winds counters the other
            // way, so the hole of an `o` stays a hole (a path per contour would fill it).
            let contours = GlyphFlattener.outline(of: GlyphSource(components: [placement]), sources: sources).path.contours.filter { !$0.isEmpty }
            guard !contours.isEmpty else { continue }
            let key = try PathEditing.keys(between: previous, and: nil, count: 1)[0]
            previous = key
            try GlyphPaths.create(contours, parent: layer, position: key, canvas: glyph, builder: &builder)
        }
    }
}

/// Writing flattened contours back as paths.
enum GlyphPaths {
    /// The appearance of written glyph paths: one black fill (a glyph is a shape).
    static var appearance: Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        return appearance
    }

    /// A black-filled path holding `contours`, on `canvas`, at `position` under `parent`.
    @discardableResult
    static func create(_ contours: [Contour], parent: OpID, position: [UInt8], canvas: OpID?, builder: inout ChangeBuilder) throws -> OpID {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path = Wiretuner_Doc_V1_PathProps()
        if let canvas { props.path.common.canvas.id = canvas.proto }
        let node = builder.append(Ops.create(parent: parent, position: position, props: props))
        try CreatePath.appendContours(contours.map(newContour), to: node, builder: &builder)
        for op in try PathEditing.appearanceInserts(node, kind: .path, appearancePath: PathFields.appearance, appearance) {
            builder.append(op)
        }
        return node
    }

    /// A contour as path points: one point per on-curve point, handles relative to their anchor.
    static func newContour(_ contour: Contour) -> NewContour {
        let segments = contour.segments
        // Callers leave out empty contours.
        var anchors = [segments[0].p0] + segments.map(\.p3)
        var inHandles = [Vector](repeating: .zero, count: anchors.count)
        var outHandles = [Vector](repeating: .zero, count: anchors.count)
        for (offset, segment) in segments.enumerated() where !segment.isLinear() {
            outHandles[offset] = segment.p1 - segment.p0
            inHandles[offset + 1] = segment.p2 - segment.p3
        }
        if contour.isClosed, anchors.count > 1, anchors.last == anchors.first {
            // The last segment returns to the start: its in handle belongs to the first point.
            inHandles[0] = inHandles[anchors.count - 1]
            anchors.removeLast()
            inHandles.removeLast()
            outHandles.removeLast()
        }
        return NewContour(closed: contour.isClosed, points: anchors.indices.map {
            VectorPoint(anchor: anchors[$0], inHandle: inHandles[$0], outHandle: outHandles[$0])
        })
    }
}

// MARK: Anchors

/// *Add Anchor*: `ElementInsert(anchors)` with the name, position and role (from the underscore
/// convention unless given).  "Add anchor".
public struct AddAnchor: Command {
    public var glyph: OpID
    public var name: String
    public var position: Point
    public var role: GlyphAnchorRole?
    public var label: String { "Add anchor" }

    public init(_ name: String, at position: Point, to glyph: OpID, role: GlyphAnchorRole? = nil) {
        self.glyph = glyph
        self.name = name
        self.position = position
        self.role = role
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 63 && name.unicodeScalars.allSatisfy(GlyphNaming.isNameCharacter)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try GlyphEditing.glyph(glyph, in: GlyphIndex(state))
        guard Self.isValidName(name) else { throw GlyphEditError.invalidName(name) }
        guard position.isFinite else { throw GlyphEditError.invalidValue("position") }
        let last = current.anchors.last.flatMap { state.position(glyph, GlyphFields.anchors, $0.id) }
        let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        builder.append(Ops.elementInsert(glyph, GlyphFields.anchors, positions: [key], values: GlyphFields.values {
            var anchor = Wiretuner_Doc_V1_GlyphAnchor()
            anchor.name = name
            anchor.position = PathEditing.proto(position)
            anchor.role = (role ?? .conventional(name)).stored
            $0.anchors = [anchor]
        }))
    }
}

/// Anchor edits: move (`position`, coalescing during a drag), rename, set role, remove.
public struct EditAnchor: Command {
    public enum Edit: Hashable, Sendable {
        case move(Point)
        case rename(String)
        case role(GlyphAnchorRole)
        case remove
    }

    public var glyph: OpID
    public var anchor: OpID
    public var edit: Edit
    public var coalescing: UndoCoalescing

    public init(_ anchor: OpID, of glyph: OpID, _ edit: Edit, coalescing: UndoCoalescing = .none) {
        self.glyph = glyph
        self.anchor = anchor
        self.edit = edit
        self.coalescing = coalescing
    }

    public var label: String {
        switch edit {
        case .move: "Move anchor"
        case .rename: "Rename anchor"
        case .role: "Set anchor role"
        case .remove: "Remove anchor"
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try GlyphEditing.glyph(glyph, in: GlyphIndex(state))
        guard current.anchors.contains(where: { $0.id == anchor }) else { throw GlyphEditError.unknownElement(anchor) }
        switch edit {
        case .move(let position):
            guard position.isFinite else { throw GlyphEditError.invalidValue("position") }
            builder.append(GlyphEditing.setAnchorPosition(glyph, anchor, position))
        case .rename(let name):
            guard AddAnchor.isValidName(name) else { throw GlyphEditError.invalidName(name) }
            builder.append(Ops.set(glyph, [GlyphFields.anchorName(anchor)], values: GlyphFields.values {
                var value = Wiretuner_Doc_V1_GlyphAnchor()
                value.id = anchor.elementID
                value.name = name
                $0.anchors = [value]
            }))
        case .role(let role):
            builder.append(Ops.set(glyph, [GlyphFields.anchorRole(anchor)], values: GlyphFields.values {
                var value = Wiretuner_Doc_V1_GlyphAnchor()
                value.id = anchor.elementID
                value.role = role.stored
                $0.anchors = [value]
            }))
        case .remove:
            builder.append(Ops.elementDelete(glyph, [GlyphFields.anchor(anchor)]))
        }
    }
}
