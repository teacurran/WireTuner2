import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// FONT-025 (model half): an `ImportedFont` (WTInterchange's OpenType reader) written into a typeface
// document (font-export.adoc, "Opening an existing font"; glyph-grid.adoc for collisions): glyphs
// with their outlines as filled paths on their canvases (y negated into stored space), composite
// glyphs as components, codepoints and advance widths; for a new document the names, metrics and
// OS/2 values into Font Info; and the kerning as pairs, classes and cells.  The import is a change
// group -- glyph batches, then the settings and kerning -- labelled "Import <file>" (with `[i/n]`
// when it takes more than one change), performed in one undo group.  Importing into an existing
// document follows the grid's collision rules: a taken name gets a numeric suffix, a taken codepoint
// is left off; both are listed in the report.

/// Planning and writing an import.
public enum FontImport {
    /// What an import will do.
    public struct Plan: Sendable {
        /// Perform these in order inside one undo group.
        public var commands: [any Command]
        /// The import report: what was renamed, left off or not read.
        public var report: [String]
        /// The name each imported glyph gets, by glyph index (nil: not imported).
        public var names: [String?]
    }

    /// Glyphs per change (each glyph takes a handful of ops, far under the 10,000-op limit).
    public static let batchSize = 300

    /// The plan for importing `font` (from `fileName`) into `state`: `newDocument` also writes the
    /// kind, Font Info and units per em.
    public static func plan(_ font: ImportedFont, fileName: String, into state: EngineState, newDocument: Bool, batchSize: Int = batchSize) -> Plan {
        let index = GlyphIndex(state)
        var taken = index.names.union(index.glyphs.map(\.storedName))
        var claimed = Set(index.glyphs.flatMap(\.storedCodepoints))
        var report = font.report
        var names: [String?] = []
        var codepoints: [[UInt32]] = []
        for glyph in font.glyphs {
            let base = GlyphNaming.isValid(glyph.name) ? glyph.name : "glyph\(names.count)"
            let name = GlyphNaming.unique(base, taken: taken)
            if name != glyph.name { report.append("\(glyph.name) was imported as \(name).") }
            taken.insert(name)
            names.append(name)
            let kept = glyph.codepoints.filter { !claimed.contains($0) }
            for dropped in glyph.codepoints where !kept.contains(dropped) {
                report.append(String(format: "U+%04X is already encoded; %@ was imported without it.", dropped, name))
            }
            claimed.formUnion(kept)
            codepoints.append(kept)
        }
        let label = "Import \(fileName)"
        var batches: [[Int]] = stride(from: 0, to: font.glyphs.count, by: max(batchSize, 1)).map {
            Array($0..<min($0 + max(batchSize, 1), font.glyphs.count))
        }
        if batches.isEmpty { batches = [[]] }
        let total = batches.count + 1
        // The settings change follows the glyph batches, so an import is always a group.
        func numbered(_ position: Int) -> String { "\(label) [\(position)/\(total)]" }
        var commands: [any Command] = batches.enumerated().map { offset, members in
            ImportGlyphs(font: font, members: members, names: names, codepoints: codepoints, label: numbered(offset + 1))
        }
        commands.append(ImportFontSettings(font: font, names: names, newDocument: newDocument, label: numbered(total)))
        return Plan(commands: commands, report: report, names: names)
    }

    /// Font space (y up) → glyph-canvas space (y down) for a component transform.
    static func canvasTransform(_ transform: WTGeometry.AffineTransform) -> WTGeometry.AffineTransform {
        WTGeometry.AffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d, tx: transform.tx, ty: -transform.ty)
    }
}

/// One batch of imported glyphs: each glyph node, its codepoints, one filled path holding its
/// contours, and its components (resolved by the planned names, in this change or already in the
/// document).
struct ImportGlyphs: Command {
    let font: ImportedFont
    let members: [Int]
    let names: [String?]
    let codepoints: [[UInt32]]
    let label: String
    var recordsUndo: Bool { true }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !members.isEmpty else { return }
        let index = GlyphIndex(state)
        let keys = try GlyphEditing.keys(after: nil, count: members.count, state: state)
        let layer = try PathEditing.ensureLayer(&builder, state: state)
        var previous = state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
        var created: [Int: OpID] = [:]
        for (member, key) in zip(members, keys) {
            let glyph = font.glyphs[member]
            guard let name = names[member], !index.isNameTaken(name) else { continue }
            let codes = codepoints[member].filter { index.holder(of: $0) == nil }
            let kind: GlyphKind = glyph.codepoints.isEmpty && !glyph.contours.isEmpty && name.contains("_") ? .ligature : .base
            let node = GlyphEditing.create(name: name, codepoints: codes, kind: kind, advanceWidth: min(max(glyph.advanceWidth, 0), 32_767),
                                           position: key, builder: &builder)
            created[member] = node
            let contours = glyph.contours.filter { !$0.isEmpty }.map { $0.applying(.scale(x: 1, y: -1)) }
            if !contours.isEmpty {
                let position = try PathEditing.keys(between: previous, and: nil, count: 1)[0]
                previous = position
                try GlyphPaths.create(contours, parent: layer, position: position, canvas: node, builder: &builder)
            }
        }
        for member in members {
            guard let node = created[member] else { continue }
            let components = font.glyphs[member].components.compactMap { component -> (OpID, WTGeometry.AffineTransform, Data)? in
                guard font.glyphs.indices.contains(component.glyph), let name = names[component.glyph],
                      let source = created[component.glyph] ?? index.glyph(named: name)?.id else { return nil }
                return (source, FontImport.canvasTransform(component.transform), Data())
            }
            try GlyphEditing.insertComponents(into: node, components, state: state, builder: &builder)
        }
    }
}

/// The settings and kerning of an import: for a new document the kind, units per em, names,
/// metrics and OS/2 values; always the kerning between imported glyphs.
struct ImportFontSettings: Command {
    let font: ImportedFont
    let names: [String?]
    let newDocument: Bool
    let label: String

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if newDocument { writeInfo(&builder, state: state) }
        try writeKerning(&builder, state: state)
    }

    private func writeInfo(_ builder: inout ChangeBuilder, state: EngineState) {
        builder.append(Ops.set(WellKnown.settings, [FontFields.documentKind], values: FontFields.values { $0.documentKind = .typeface }))
        let n = font.names
        let fields: [(FontNameField, String)] = [
            (.family, n.family), (.style, n.style), (.postscript, n.postscript), (.full, n.full), (.version, n.version), (.copyright, n.copyright),
            (.trademark, n.trademark), (.designer, n.designer), (.designerURL, n.designerURL), (.manufacturer, n.manufacturer),
            (.manufacturerURL, n.manufacturerURL), (.description, n.description), (.sampleText, n.sampleText), (.license, n.license),
            (.licenseURL, n.licenseURL),
        ]
        // Each field alone, so one value the font stores out of range does not lose the others.
        for (field, value) in fields where !value.isEmpty {
            try? SetFontNames([field: value]).execute(&builder, state: state)
        }
        let m = font.metrics
        try? SetUnitsPerEm(min(max(m.unitsPerEm, FontInfo.upmRange.lowerBound), FontInfo.upmRange.upperBound), scale: false).execute(&builder, state: state)
        let metrics: [FontMetricField: Double] = [
            .ascender: m.ascender, .descender: m.descender, .xHeight: m.xHeight, .capHeight: m.capHeight, .italicAngle: m.italicAngle,
            .underlinePosition: m.underlinePosition, .underlineThickness: m.underlineThickness, .lineGap: m.lineGap,
            .typoAscender: m.typoAscender, .typoDescender: m.typoDescender, .typoLineGap: m.typoLineGap,
        ]
        for (field, value) in metrics.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try? SetFontMetrics([field: value]).execute(&builder, state: state)
        }
        let separate = m.typoAscender != m.ascender || m.typoDescender != m.descender || m.typoLineGap != m.lineGap
        try? SetFontMetrics(winAscent: .some(m.winAscent), winDescent: .some(m.winDescent), typoSeparate: separate).execute(&builder, state: state)
        let o = font.os2
        let embedding: FontInfo.Embedding = o.fsType & 0x0008 != 0 ? .editable : o.fsType & 0x0004 != 0 ? .previewPrint : .installable
        try? SetFontOS2(weightClass: min(max(o.weightClass, 1), 1_000), widthClass: min(max(o.widthClass, 1), 9), bold: o.bold, italic: o.italic,
                        embedding: embedding, noSubsetting: o.fsType & 0x0100 != 0, bitmapEmbeddingOnly: o.fsType & 0x0200 != 0,
                        panose: o.panose.count == 10 ? o.panose : nil).execute(&builder, state: state)
        if FontInfo.isValidVendor(o.vendorID) { try? SetFontOS2(vendorID: o.vendorID).execute(&builder, state: state) }
    }

    private func writeKerning(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        func glyph(_ member: Int) -> OpID? {
            guard names.indices.contains(member), let name = names[member] else { return nil }
            return index.glyph(named: name)?.id
        }
        let kerning = font.kerning
        let pairs = kerning.pairs.compactMap { pair -> (OpID, OpID, Int)? in
            guard let left = glyph(pair.left), let right = glyph(pair.right) else { return nil }
            return (left, right, pair.value)
        }
        if !pairs.isEmpty {
            let keys = try KerningEditing.appendKey(FontFields.pairs, state: state, count: pairs.count)
            builder.append(Ops.elementInsert(WellKnown.settings, FontFields.pairs, positions: keys, values: FontFields.fontValues {
                $0.pairs = pairs.map { left, right, value in
                    var pair = Wiretuner_Doc_V1_KernPair()
                    pair.left = KerningEditing.glyphRef(left)
                    pair.right = KerningEditing.glyphRef(right)
                    pair.value = Double(min(max(value, -32_767), 32_767))
                    return pair
                }
            }))
        }
        let classes = kerning.leftClasses.enumerated().map { (KernSide.left, $0.offset, $0.element.compactMap(glyph)) }
            + kerning.rightClasses.enumerated().map { (KernSide.right, $0.offset, $0.element.compactMap(glyph)) }
        let kept = classes.filter { !$0.2.isEmpty }
        guard !kept.isEmpty else { return }
        let keys = try KerningEditing.appendKey(FontFields.classes, state: state, count: kept.count)
        let first = builder.append(Ops.elementInsert(WellKnown.settings, FontFields.classes, positions: keys, values: FontFields.fontValues {
            $0.classes = kept.map { side, offset, _ in
                var stored = Wiretuner_Doc_V1_KernClass()
                stored.name = "\(side == .left ? "kern1" : "kern2").\(offset + 1)"
                stored.side = side.stored
                return stored
            }
        }))
        var ids: [String: OpID] = [:]
        for (position, entry) in kept.enumerated() {
            let id = OpID(counter: first.counter + UInt64(position), replica: first.replica)
            ids["\(entry.0)/\(entry.1)"] = id
            let memberKeys = try PathEditing.keys(between: nil, and: nil, count: entry.2.count)
            builder.append(Ops.elementInsert(WellKnown.settings, FontFields.kernClassMembers(id), positions: memberKeys, values: FontFields.fontValues {
                var stored = Wiretuner_Doc_V1_KernClass()
                stored.members = entry.2.map { glyph in
                    var member = Wiretuner_Doc_V1_KernClassMember()
                    member.glyph = KerningEditing.glyphRef(glyph)
                    return member
                }
                $0.classes = [stored]
            }))
        }
        let cells = kerning.classValues.compactMap { cell -> (OpID, OpID, Int)? in
            guard let left = ids["\(KernSide.left)/\(cell.left)"], let right = ids["\(KernSide.right)/\(cell.right)"] else { return nil }
            return (left, right, cell.value)
        }
        guard !cells.isEmpty else { return }
        let cellKeys = try KerningEditing.appendKey(FontFields.classKerns, state: state, count: cells.count)
        builder.append(Ops.elementInsert(WellKnown.settings, FontFields.classKerns, positions: cellKeys, values: FontFields.fontValues {
            $0.classKerns = cells.map { left, right, value in
                var cell = Wiretuner_Doc_V1_ClassKern()
                cell.left = left.elementID
                cell.right = right.elementID
                cell.value = Double(min(max(value, -32_767), 32_767))
                return cell
            }
        }))
    }
}
