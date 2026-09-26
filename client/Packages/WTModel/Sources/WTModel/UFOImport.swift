import Foundation
import WTCRDT
import WTGeometry
import WTInterchange

// FONT-024 (model half): a `UFOFont` (WTInterchange's UFO reader) written into a typeface document
// (font-export.adoc, "UFO packages"): everything `FontImport` writes for an OpenType font -- glyphs,
// outlines, components, codepoints, widths, Font Info for a new document, kerning -- plus what a UFO
// carries beyond it: anchors (y negated into glyph-canvas space; the underscore convention gives the
// role), the kind Mark for a glyph whose anchors are all `_` anchors, the mark colors, and for a new
// document the feature file text.  The whole import is one change group labelled "Import <file>
// [i/n]", performed in one undo group; the grid's collision rules and the report are FontImport's.
public enum UFOImport {
    /// Glyphs per anchors-and-colors change.
    public static let batchSize = FontImport.batchSize

    /// The plan for importing `ufo` (from `fileName`) into `state`.
    public static func plan(_ ufo: UFOFont, fileName: String, into state: EngineState, newDocument: Bool,
                            batchSize: Int = batchSize) -> FontImport.Plan {
        let base = FontImport.plan(ufo.font, fileName: fileName, into: state, newDocument: newDocument, batchSize: batchSize)
        var report = base.report
        let detailed = ufo.font.glyphs.indices.filter { !ufo.anchors[$0].isEmpty || ufo.markColors[$0] != 0 }
        let batches = stride(from: 0, to: detailed.count, by: max(batchSize, 1)).map { Array(detailed[$0..<min($0 + max(batchSize, 1), detailed.count)]) }
        let features = newDocument && !ufo.features.isEmpty ? ufo.features : ""
        if !newDocument, !ufo.features.isEmpty {
            report.append("The UFO's feature file was not added to this document's; copy what you need from features.fea.")
        }
        if ufo.lib != nil {
            report.append("The UFO's lib.plist keys are not kept (the document has no field for them yet).")
        }
        let total = base.commands.count + batches.count + (features.isEmpty ? 0 : 1)
        func label(_ position: Int) -> String { "Import \(fileName) [\(position)/\(total)]" }
        var commands: [any Command] = base.commands.enumerated().map { offset, command in
            switch command {
            case let glyphs as ImportGlyphs:
                ImportGlyphs(font: glyphs.font, members: glyphs.members, names: glyphs.names, codepoints: glyphs.codepoints, label: label(offset + 1))
            case let settings as ImportFontSettings:
                ImportFontSettings(font: settings.font, names: settings.names, newDocument: settings.newDocument, label: label(offset + 1))
            default:
                command
            }
        }
        for batch in batches {
            commands.append(ImportGlyphDetails(ufo: ufo, members: batch, names: base.names, label: label(commands.count + 1)))
        }
        if !features.isEmpty {
            commands.append(ImportFeatureText(text: features, label: label(commands.count + 1)))
        }
        return FontImport.Plan(commands: commands, report: report, names: base.names)
    }
}

/// Anchors, mark kinds and mark colors of imported glyphs (found by their planned names).
struct ImportGlyphDetails: Command {
    let ufo: UFOFont
    let members: [Int]
    let names: [String?]
    let label: String

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        for member in members {
            guard let name = names[member], let glyph = index.glyph(named: name) else { continue }
            let anchors = ufo.anchors[member].filter { AddAnchor.isValidName($0.name) && $0.x.isFinite && $0.y.isFinite }
            for anchor in anchors {
                try AddAnchor(anchor.name, at: Point(x: anchor.x, y: -anchor.y), to: glyph.id).execute(&builder, state: state)
            }
            let isMark = !anchors.isEmpty && anchors.allSatisfy { $0.name.hasPrefix("_") }
            let color = ufo.markColors[member]
            if isMark || color != 0 {
                try SetGlyphAttributes([glyph.id], kind: isMark ? .mark : nil, markColor: color == 0 ? nil : color).execute(&builder, state: state)
            }
        }
    }
}

/// A new document's feature file: the UFO's `features.fea`, after any text already there.
struct ImportFeatureText: Command {
    let text: String
    let label: String

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let last = state.store.text(WellKnown.settings, FontFields.features)?.liveChars.last ?? .zero
        builder.append(Ops.textInsert(WellKnown.settings, FontFields.features, text, left: last))
    }
}
