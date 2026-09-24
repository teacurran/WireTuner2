import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-005: the Font Info commands (font-info.adoc, "Client": `setNames`, `setMetric`,
// `setUPM(_:scale:)`, `setOs2`, `setGuideSettings`, extra lines, `applyLicensePreset`).  A pane's
// edits are one change ("Font Info: Names"); the UPM scale is one change, or for a font whose
// scale exceeds the 10,000-op change limit a change group -- consecutive changes with the same
// label and a `[i/n]` marker -- which the caller performs inside one undo group.

/// A `FontNames` field.
public enum FontNameField: UInt32, Hashable, Sendable, CaseIterable {
    case family = 1, style, postscript, full, version, copyright, trademark, designer, designerURL, manufacturer, manufacturerURL, description,
         sampleText, license, licenseURL

    /// The longest value the field stores.
    var maximumLength: Int {
        switch self {
        case .family, .style, .postscript: 63
        case .full: 127
        case .version: 16
        case .copyright, .description: 4096
        case .trademark, .designerURL, .manufacturerURL, .licenseURL: 1024
        case .designer, .manufacturer, .sampleText: 255
        case .license: 65_536
        }
    }

    func set(_ value: String, in names: inout Wiretuner_Doc_V1_FontNames) {
        switch self {
        case .family: names.family = value
        case .style: names.style = value
        case .postscript: names.postscript = value
        case .full: names.full = value
        case .version: names.version = value
        case .copyright: names.copyright = value
        case .trademark: names.trademark = value
        case .designer: names.designer = value
        case .designerURL: names.designerURL = value
        case .manufacturer: names.manufacturer = value
        case .manufacturerURL: names.manufacturerURL = value
        case .description: names.description_p = value
        case .sampleText: names.sampleText = value
        case .license: names.license = value
        case .licenseURL: names.licenseURL = value
        }
    }
}

/// A scalar `FontMetrics` field (units per em is `SetUnitsPerEm`).
public enum FontMetricField: UInt32, Hashable, Sendable, CaseIterable {
    case ascender = 2, descender, xHeight, capHeight, italicAngle, underlinePosition, underlineThickness, lineGap
    case typoAscender = 13, typoDescender, typoLineGap

    func set(_ value: Double, in metrics: inout Wiretuner_Doc_V1_FontMetrics) {
        switch self {
        case .ascender: metrics.ascender = value
        case .descender: metrics.descender = value
        case .xHeight: metrics.xHeight = value
        case .capHeight: metrics.capHeight = value
        case .italicAngle: metrics.italicAngle = value
        case .underlinePosition: metrics.underlinePosition = value
        case .underlineThickness: metrics.underlineThickness = value
        case .lineGap: metrics.lineGap = value
        case .typoAscender: metrics.typoAscender = value
        case .typoDescender: metrics.typoDescender = value
        case .typoLineGap: metrics.typoLineGap = value
        }
    }

    /// Whether `value` is in the stored range.
    func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .italicAngle: return (-90...90).contains(value)
        case .underlineThickness: return value >= 0
        default: return abs(value) <= 32_767
        }
    }
}

/// Why a Font Info command could not build its change.
public enum FontEditError: Error, Equatable, Sendable {
    case invalidValue(String)
    case invalidPostScriptName(String)
    case invalidVersion(String)
    case invalidVendor(String)
    case unknownElement(OpID)
}

/// The Names pane: one change writing each field given.  "Font Info: Names".
public struct SetFontNames: Command {
    public var values: [FontNameField: String]
    public var label: String { "Font Info: Names" }

    public init(_ values: [FontNameField: String]) {
        self.values = values
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var paths: [RegisterPath] = []
        var props = FontFields.fontValues { _ in }
        for field in FontNameField.allCases {
            guard let value = values[field] else { continue }
            guard value.count <= field.maximumLength else { throw FontEditError.invalidValue("\(field)") }
            if field == .postscript, !value.isEmpty, !FontInfo.isValidPostScriptName(value) { throw FontEditError.invalidPostScriptName(value) }
            if field == .version, !value.isEmpty, !FontInfo.isValidVersion(value) { throw FontEditError.invalidVersion(value) }
            if [.designerURL, .manufacturerURL, .licenseURL].contains(field), !value.isEmpty, URL(string: value)?.scheme == nil {
                throw FontEditError.invalidValue("\(field)")
            }
            paths.append(FontFields.name(field.rawValue))
            field.set(value, in: &props.settings.font.names)
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: props))
    }

    /// *License preset: SIL Open Font License 1.1* for `copyright` holder text.
    public static func openFontLicense(copyright: String) -> SetFontNames {
        SetFontNames([
            .copyright: copyright,
            .license: "This Font Software is licensed under the SIL Open Font License, Version 1.1. This license is available with a FAQ at: https://openfontlicense.org",
            .licenseURL: "https://openfontlicense.org",
        ])
    }
}

/// The Metrics pane (and a metric line drag): one change writing each field given, plus the
/// Windows metrics (nil: computed) and the typo switch.  "Font Info: Metrics".
public struct SetFontMetrics: Command {
    public var values: [FontMetricField: Double]
    /// `.some(nil)` sets computed.
    public var winAscent: Double??
    public var winDescent: Double??
    public var typoSeparate: Bool?
    public var coalescing: UndoCoalescing
    public var label: String { "Font Info: Metrics" }

    public init(_ values: [FontMetricField: Double] = [:], winAscent: Double?? = nil, winDescent: Double?? = nil, typoSeparate: Bool? = nil,
                coalescing: UndoCoalescing = .none) {
        self.values = values
        self.winAscent = winAscent
        self.winDescent = winDescent
        self.typoSeparate = typoSeparate
        self.coalescing = coalescing
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var paths: [RegisterPath] = []
        var props = FontFields.fontValues { _ in }
        for field in FontMetricField.allCases {
            guard let value = values[field] else { continue }
            guard field.accepts(value) else { throw FontEditError.invalidValue("\(field)") }
            paths.append(FontFields.metric(field.rawValue))
            field.set(value, in: &props.settings.font.metrics)
        }
        for (number, choice) in [(UInt32(10), winAscent), (11, winDescent)] {
            guard let choice else { continue }
            if let value = choice, !(value.isFinite && value >= 0 && value <= 65_535) { throw FontEditError.invalidValue("windows metric") }
            var metric = Wiretuner_Doc_V1_OptionalMetric()
            metric.computed = choice == nil
            metric.value = choice ?? 0
            paths.append(FontFields.metric(number))
            if number == 10 { props.settings.font.metrics.winAscent = metric } else { props.settings.font.metrics.winDescent = metric }
        }
        if let typoSeparate {
            paths.append(FontFields.metric(12))
            props.settings.font.metrics.typoSeparate = typoSeparate
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: props))
    }
}

/// The OS/2 pane.  "Font Info: OS/2".
public struct SetFontOS2: Command {
    public var weightClass: Int?
    public var widthClass: Int?
    public var vendorID: String?
    public var bold: Bool?
    public var italic: Bool?
    public var embedding: FontInfo.Embedding?
    public var noSubsetting: Bool?
    public var bitmapEmbeddingOnly: Bool?
    public var panose: [UInt8]?
    public var label: String { "Font Info: OS/2" }

    public init(weightClass: Int? = nil, widthClass: Int? = nil, vendorID: String? = nil, bold: Bool? = nil, italic: Bool? = nil,
                embedding: FontInfo.Embedding? = nil, noSubsetting: Bool? = nil, bitmapEmbeddingOnly: Bool? = nil, panose: [UInt8]? = nil) {
        self.weightClass = weightClass
        self.widthClass = widthClass
        self.vendorID = vendorID
        self.bold = bold
        self.italic = italic
        self.embedding = embedding
        self.noSubsetting = noSubsetting
        self.bitmapEmbeddingOnly = bitmapEmbeddingOnly
        self.panose = panose
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var paths: [RegisterPath] = []
        var props = FontFields.fontValues { _ in }
        func write(_ number: UInt32, _ set: (inout Wiretuner_Doc_V1_Os2Props) -> Void) {
            paths.append(FontFields.os2(number))
            set(&props.settings.font.os2)
        }
        if let weightClass {
            guard (1...1_000).contains(weightClass) else { throw FontEditError.invalidValue("weight class") }
            write(1) { $0.weightClass = UInt32(weightClass) }
        }
        if let widthClass {
            guard (1...9).contains(widthClass) else { throw FontEditError.invalidValue("width class") }
            write(2) { $0.widthClass = UInt32(widthClass) }
        }
        if let vendorID {
            guard FontInfo.isValidVendor(vendorID) else { throw FontEditError.invalidVendor(vendorID) }
            write(3) { $0.vendorID = vendorID }
        }
        if let bold { write(4) { $0.styleBold = bold } }
        if let italic { write(5) { $0.styleItalic = italic } }
        if let embedding { write(6) { $0.embedding = embedding.stored } }
        if let noSubsetting { write(7) { $0.noSubsetting = noSubsetting } }
        if let bitmapEmbeddingOnly { write(8) { $0.bitmapEmbeddingOnly = bitmapEmbeddingOnly } }
        if let panose {
            guard panose.count == 10 else { throw FontEditError.invalidValue("panose") }
            write(9) { $0.panose = Data(panose) }
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: props))
    }
}

/// The metric guide settings (which lines show) and the extra lines.  "Font Info: Guides".
public struct SetMetricGuides: Command {
    public enum Line: UInt32, Hashable, Sendable, CaseIterable {
        case baseline = 1, xHeight, capHeight, ascender, descender, sideBearings, emBox, labels
    }

    public enum Edit: Hashable, Sendable {
        case show(Line, Bool)
        case addLine(name: String, y: Double)
        case editLine(OpID, name: String?, y: Double?)
        case removeLine(OpID)
    }

    public var edits: [Edit]
    public var label: String { "Font Info: Guides" }

    public init(_ edits: [Edit]) {
        self.edits = edits
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = FontInfo(state).guides
        for edit in edits {
            switch edit {
            case .show(let line, let shown):
                var props = FontFields.fontValues { _ in }
                switch line {
                case .baseline: props.settings.font.guides.hideBaseline = !shown
                case .xHeight: props.settings.font.guides.hideXHeight = !shown
                case .capHeight: props.settings.font.guides.hideCapHeight = !shown
                case .ascender: props.settings.font.guides.hideAscender = !shown
                case .descender: props.settings.font.guides.hideDescender = !shown
                case .sideBearings: props.settings.font.guides.hideSideBearings = !shown
                case .emBox: props.settings.font.guides.hideEmBox = !shown
                case .labels: props.settings.font.guides.hideLabels = !shown
                }
                builder.append(Ops.set(WellKnown.settings, [FontFields.guides(line.rawValue)], values: props))
            case .addLine(let name, let y):
                guard y.isFinite, name.count <= 63 else { throw FontEditError.invalidValue("line") }
                let last = current.extraLines.last.flatMap { state.position(WellKnown.settings, FontFields.extraLines, $0.id) }
                let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
                builder.append(Ops.elementInsert(WellKnown.settings, FontFields.extraLines, positions: [key], values: FontFields.fontValues {
                    var line = Wiretuner_Doc_V1_MetricLine()
                    line.name = name
                    line.y = y
                    $0.guides.extraLines = [line]
                }))
            case .editLine(let id, let name, let y):
                guard current.extraLines.contains(where: { $0.id == id }) else { throw FontEditError.unknownElement(id) }
                var paths: [RegisterPath] = []
                var line = Wiretuner_Doc_V1_MetricLine()
                line.id = id.elementID
                if let name {
                    guard name.count <= 63 else { throw FontEditError.invalidValue("line") }
                    paths.append(FontFields.extraLine(id).child(2))
                    line.name = name
                }
                if let y {
                    guard y.isFinite else { throw FontEditError.invalidValue("line") }
                    paths.append(FontFields.extraLineY(id))
                    line.y = y
                }
                guard !paths.isEmpty else { continue }
                builder.append(Ops.set(WellKnown.settings, paths, values: FontFields.fontValues { $0.guides.extraLines = [line] }))
            case .removeLine(let id):
                guard current.extraLines.contains(where: { $0.id == id }) else { throw FontEditError.unknownElement(id) }
                builder.append(Ops.elementDelete(WellKnown.settings, [FontFields.extraLine(id)]))
            }
        }
    }
}

/// The Features pane's three generate switches.  "Font Info: Features".
public struct SetGeneratedFeatures: Command {
    public var kern: Bool?
    public var mark: Bool?
    public var liga: Bool?
    public var label: String { "Font Info: Features" }

    public init(kern: Bool? = nil, mark: Bool? = nil, liga: Bool? = nil) {
        self.kern = kern
        self.mark = mark
        self.liga = liga
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var paths: [RegisterPath] = []
        var props = FontFields.fontValues { _ in }
        if let kern {
            paths.append(FontFields.omitGeneratedKern)
            props.settings.font.omitGeneratedKern = !kern
        }
        if let mark {
            paths.append(FontFields.omitGeneratedMark)
            props.settings.font.omitGeneratedMark = !mark
        }
        if let liga {
            paths.append(FontFields.omitGeneratedLiga)
            props.settings.font.omitGeneratedLiga = !liga
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: props))
    }
}

/// `setUPM(_:scale:)`: writes the units per em and, with `scale`, rescales everything measured
/// in font units by s = new ÷ old: every scaled metric, every top-level object on every glyph
/// canvas (its transform post-multiplied by the scale about the glyph origin, so concurrent point
/// edits in object space survive), every component's placement, every glyph's advance width,
/// anchor and guide positions, every extra metric line and every kern value.  "Scale to N UPM" /
/// "Set UPM to N".
public struct SetUnitsPerEm: Command {
    public var upm: Int
    public var scale: Bool

    /// The op limit of one change (crdt-model.adoc).
    public static let opLimit = 10_000

    public init(_ upm: Int, scale: Bool) {
        self.upm = upm
        self.scale = scale
    }

    public var label: String { scale ? "Scale to \(upm) UPM" : "Set UPM to \(upm)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for op in try ops(in: state) {
            builder.append(op)
        }
    }

    /// The whole change's ops (they refer to no node the change creates, so they can be split).
    public func ops(in state: EngineState) throws -> [Wiretuner_Doc_V1_Op] {
        guard FontInfo.upmRange.contains(upm) else { throw FontEditError.invalidValue("units per em") }
        let font = FontInfo(state)
        let old = font.metrics.upm
        var ops = [Ops.set(WellKnown.settings, [FontFields.metric(1)], values: FontFields.fontValues { $0.metrics.upm = UInt32(upm) })]
        guard scale, upm != old else { return ops }
        let s = Double(upm) / Double(old)
        let m = font.metrics
        var metrics: [FontMetricField: Double] = [
            .ascender: m.ascender * s, .descender: m.descender * s, .xHeight: m.xHeight * s, .capHeight: m.capHeight * s,
            .underlinePosition: m.underlinePosition * s, .underlineThickness: m.underlineThickness * s, .lineGap: m.lineGap * s,
        ]
        if m.typoSeparate {
            metrics[.typoAscender] = m.typoAscender * s
            metrics[.typoDescender] = m.typoDescender * s
            metrics[.typoLineGap] = m.typoLineGap * s
        }
        var builder = ChangeBuilder(replica: 1, startCounter: 1)
        try SetFontMetrics(metrics, winAscent: m.winAscent.map { .some($0 * s) }, winDescent: m.winDescent.map { .some($0 * s) })
            .execute(&builder, state: state)
        for line in font.guides.extraLines {
            try SetMetricGuides([.editLine(line.id, name: nil, y: line.y * s)]).execute(&builder, state: state)
        }
        let index = GlyphIndex(state)
        let scaling = AffineTransform.scale(s)
        for glyph in index.glyphs {
            var moved = glyph
            // Component placements scale their offsets only: the source glyph scales itself.
            moved.components = []
            GlyphEditing.transformArtwork(of: moved, by: scaling, state: state, builder: &builder)
            for component in glyph.components {
                var placed = component.transform
                placed.tx *= s
                placed.ty *= s
                try SetComponentTransform(component.id, of: glyph.id, to: placed).execute(&builder, state: state)
            }
            builder.append(GlyphEditing.setWidth(glyph.id, min((glyph.advanceWidth * s).rounded(), 32_767)))
            for guide in glyph.guides {
                for id in guide.ids {
                    builder.append(Ops.set(glyph.id, [GlyphFields.guidePosition(id)], values: GlyphFields.values {
                        var value = Wiretuner_Doc_V1_Guide()
                        value.id = id.elementID
                        value.position = guide.position * s
                        $0.guides = [value]
                    }))
                }
            }
        }
        let kerning = Kerning(state, index: index)
        for pair in kerning.storedPairs {
            builder.append(KerningEditing.setPairValue(pair.id, min(max(pair.value * s, -32_767), 32_767)))
        }
        for cell in kerning.storedCells {
            builder.append(KerningEditing.setCellValue(cell.id, min(max(cell.value * s, -32_767), 32_767)))
        }
        ops += builder.ops
        return ops
    }

    /// The command as the changes to perform in one undo group: itself when it fits one change,
    /// else consecutive parts of at most `opLimit` ops labelled "Scale to N UPM [i/n]".
    public func changes(in state: EngineState, limit: Int = SetUnitsPerEm.opLimit) throws -> [any Command] {
        let ops = try ops(in: state)
        guard ops.count > limit else { return [self] }
        let parts = stride(from: 0, to: ops.count, by: limit).map { Array(ops[$0..<min($0 + limit, ops.count)]) }
        return parts.enumerated().map { index, part in OpsCommand("\(label) [\(index + 1)/\(parts.count)]", ops: part) }
    }
}
