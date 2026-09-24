import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FONT-005: `FontInfo` defaults and normalizations and the Font Info commands, including the UPM
/// scale and its change group (font-info.adoc).
@Suite struct FontInfoTests {
    @Test func defaultsAndNormalizations() {
        let empty = FontInfo(EngineState())
        #expect(empty.metrics.upm == 1_000 && empty.metrics.ascender == 800 && empty.metrics.descender == -200)
        #expect(empty.metrics.xHeight == 500 && empty.metrics.capHeight == 700 && empty.metrics.underlinePosition == -100)
        #expect(empty.metrics.underlineThickness == 50 && empty.metrics.lineGap == 0 && empty.metrics.isValid)
        #expect(empty.metrics.typoAscender == 800 && empty.metrics.typoDescender == -200 && empty.metrics.typoLineGap == 0)
        #expect(empty.metrics.winAscent == nil && empty.metrics.winDescent == nil)
        #expect(empty.names.version == "1.000" && empty.names.postscript == "Untitled" && empty.names.full == "Untitled")
        #expect(empty.os2.weightClass == 400 && empty.os2.widthClass == 5 && empty.os2.vendorID == "WTNR" && empty.os2.embedding == .installable)
        #expect(empty.os2.panose == [UInt8](repeating: 0, count: 10) && empty.os2.fsType == 0)
        #expect(empty.guides.showBaseline && empty.guides.showLabels && empty.guides.extraLines.isEmpty && empty.guides.metricColor == nil)
        #expect(empty.features.isEmpty && !empty.omitGeneratedKern)
        var font = Wiretuner_Doc_V1_FontProps()
        font.names.family = "Marlowe Sans"
        font.names.style = "Bold Italic"
        font.names.postscript = "bad name"
        font.names.version = "2.5"
        font.metrics.upm = 2_048
        font.metrics.ascender = 100
        font.metrics.descender = 200
        font.metrics.italicAngle = -12
        font.metrics.winAscent.value = .nan
        font.metrics.winDescent.value = 250
        font.metrics.typoSeparate = true
        font.metrics.typoAscender = .infinity
        font.metrics.typoDescender = -10
        font.os2.vendorID = "ab"
        font.os2.embedding = .restricted
        font.os2.noSubsetting = true
        font.os2.bitmapEmbeddingOnly = true
        font.os2.panose = Data([2, 11, 6, 4, 2, 2, 2, 2, 2, 4])
        font.guides.hideBaseline = true
        font.guides.metricColor = Wiretuner_Doc_V1_Color()
        var line = Wiretuner_Doc_V1_MetricLine()
        line.id = OpID(counter: 5, replica: 1).elementID
        line.y = .nan
        font.guides.extraLines = [line]
        let read = FontInfo(font, features: "feature\u{0}\u{7} liga {\n\tsub f i by f_i;\n} liga;")
        #expect(read.names.postscript == "MarloweSans-BoldItalic" && read.names.storedPostscript == "bad name")
        #expect(read.names.full == "Marlowe Sans Bold Italic" && read.names.version == "1.000")
        #expect(read.metrics.upm == 2_048 && !read.metrics.isValid && read.metrics.italicAngle == -12)
        #expect(read.metrics.winAscent == nil && read.metrics.winDescent == 250)
        #expect(read.metrics.typoAscender == 0 && read.metrics.typoDescender == -10)
        #expect(read.os2.vendorID == "WTNR" && read.os2.embedding == .restricted && read.os2.fsType == 0x0302)
        #expect(read.os2.panose[1] == 11)
        #expect(!read.guides.showBaseline && read.guides.metricColor != nil && read.guides.extraLines == [.init(id: OpID(counter: 5, replica: 1), name: "Line", y: 0)])
        #expect(read.features == "feature liga {\n\tsub f i by f_i;\n} liga;")
        #expect(FontInfo.Embedding.allCases.map(\.fsType) == [0, 8, 4, 2])
        #expect(FontInfo.Embedding.allCases.map { FontInfo.Embedding($0.stored) } == FontInfo.Embedding.allCases)
        #expect(FontInfo.generatedPostScriptName(family: "", style: "") == "Untitled")
        #expect(FontInfo.generatedFullName(family: "A", style: "") == "A")
        #expect(!FontInfo.isValidVersion("1.0") && !FontInfo.isValidVersion("a.000") && FontInfo.isValidVersion("12.345"))
        #expect(!FontInfo.isValidVendor("\u{7F}abc") && FontInfo.isValidVendor("AB C"))
    }

    @Test func namesMetricsOS2AndGuides() throws {
        var a = Replica(0xA)
        try TypefaceFixture.typeface(&a, set: nil)
        #expect(try a.perform(SetFontNames([.family: "Quill", .postscript: "Quill-Book", .designerURL: "https://example.com"]))?.label == "Font Info: Names")
        var font = FontInfo(a.state)
        #expect(font.names.family == "Quill" && font.names.postscript == "Quill-Book" && font.names.designerURL == "https://example.com")
        for field in FontNameField.allCases {
            let url = [FontNameField.designerURL, .manufacturerURL, .licenseURL].contains(field)
            try a.perform(SetFontNames([field: field == .version ? "2.000" : url ? "https://example.org" : field.rawValue % 3 == 0 ? "" : "x"]))
        }
        #expect(throws: FontEditError.invalidPostScriptName("a b")) { try a.perform(SetFontNames([.postscript: "a b"])) }
        #expect(throws: FontEditError.invalidVersion("2")) { try a.perform(SetFontNames([.version: "2"])) }
        #expect(throws: FontEditError.invalidValue("licenseURL")) { try a.perform(SetFontNames([.licenseURL: "not a url"])) }
        #expect(throws: FontEditError.invalidValue("family")) { try a.perform(SetFontNames([.family: String(repeating: "a", count: 64)])) }
        #expect(try a.perform(SetFontNames([:])) == nil)
        try a.perform(SetFontNames.openFontLicense(copyright: "Copyright 2026 Quill"))
        #expect(FontInfo(a.state).names.licenseURL == "https://openfontlicense.org")
        #expect(try a.perform(SetFontMetrics([.xHeight: 520, .capHeight: 710], winAscent: .some(900), winDescent: .some(nil), typoSeparate: true))?
            .label == "Font Info: Metrics")
        font = FontInfo(a.state)
        #expect(font.metrics.xHeight == 520 && font.metrics.winAscent == 900 && font.metrics.winDescent == nil && font.metrics.typoSeparate)
        for field in FontMetricField.allCases { try a.perform(SetFontMetrics([field: 5])) }
        #expect(throws: FontEditError.invalidValue("italicAngle")) { try a.perform(SetFontMetrics([.italicAngle: 91])) }
        #expect(throws: FontEditError.invalidValue("underlineThickness")) { try a.perform(SetFontMetrics([.underlineThickness: -1])) }
        #expect(throws: FontEditError.invalidValue("ascender")) { try a.perform(SetFontMetrics([.ascender: .nan])) }
        #expect(throws: FontEditError.invalidValue("windows metric")) { try a.perform(SetFontMetrics(winAscent: .some(-1))) }
        #expect(try a.perform(SetFontMetrics()) == nil)
        #expect(try a.perform(SetFontOS2(weightClass: 700, widthClass: 3, vendorID: "QULL", bold: true, italic: true, embedding: .editable,
                                          noSubsetting: true, bitmapEmbeddingOnly: false, panose: [UInt8](repeating: 1, count: 10)))?.label == "Font Info: OS/2")
        font = FontInfo(a.state)
        #expect(font.os2.weightClass == 700 && font.os2.widthClass == 3 && font.os2.vendorID == "QULL" && font.os2.bold && font.os2.fsType == 0x0108)
        #expect(throws: FontEditError.invalidValue("weight class")) { try a.perform(SetFontOS2(weightClass: 0)) }
        #expect(throws: FontEditError.invalidValue("width class")) { try a.perform(SetFontOS2(widthClass: 10)) }
        #expect(throws: FontEditError.invalidVendor("TOOLONG")) { try a.perform(SetFontOS2(vendorID: "TOOLONG")) }
        #expect(throws: FontEditError.invalidValue("panose")) { try a.perform(SetFontOS2(panose: [1])) }
        #expect(try a.perform(SetFontOS2()) == nil)
        #expect(try a.perform(SetMetricGuides(SetMetricGuides.Line.allCases.map { .show($0, false) } + [.addLine(name: "Overshoot", y: 510)]))?
            .label == "Font Info: Guides")
        font = FontInfo(a.state)
        #expect(!font.guides.showBaseline && !font.guides.showXHeight && !font.guides.showCapHeight && !font.guides.showAscender)
        #expect(!font.guides.showDescender && !font.guides.showSideBearings && !font.guides.showEmBox && !font.guides.showLabels)
        let line = try #require(font.guides.extraLines.first)
        #expect(line.name == "Overshoot" && line.y == 510)
        try a.perform(SetMetricGuides([.editLine(line.id, name: "O", y: 515)]))
        #expect(FontInfo(a.state).guides.extraLines == [.init(id: line.id, name: "O", y: 515)])
        #expect(try a.perform(SetMetricGuides([.editLine(line.id, name: nil, y: nil)])) == nil)
        #expect(throws: FontEditError.invalidValue("line")) { try a.perform(SetMetricGuides([.editLine(line.id, name: nil, y: .nan)])) }
        #expect(throws: FontEditError.invalidValue("line")) { try a.perform(SetMetricGuides([.editLine(line.id, name: String(repeating: "x", count: 64), y: nil)])) }
        #expect(throws: FontEditError.invalidValue("line")) { try a.perform(SetMetricGuides([.addLine(name: "x", y: .infinity)])) }
        try a.perform(SetMetricGuides([.removeLine(line.id)]))
        #expect(FontInfo(a.state).guides.extraLines.isEmpty)
        #expect(throws: FontEditError.unknownElement(line.id)) { try a.perform(SetMetricGuides([.removeLine(line.id)])) }
        #expect(throws: FontEditError.unknownElement(line.id)) { try a.perform(SetMetricGuides([.editLine(line.id, name: "x", y: nil)])) }
        #expect(try a.perform(SetGeneratedFeatures(kern: false, mark: false, liga: false))?.label == "Font Info: Features")
        font = FontInfo(a.state)
        #expect(font.omitGeneratedKern && font.omitGeneratedMark && font.omitGeneratedLiga)
        #expect(try a.perform(SetGeneratedFeatures()) == nil)
    }

    /// A typeface with an `A` (a box and an anchor), a `B` using `A` as a component at x = 100, a
    /// guide on `A`, an extra metric line and a kern pair.
    static func scalable(_ a: inout Replica) throws -> (glyphA: OpID, glyphB: OpID, box: OpID) {
        try TypefaceFixture.typeface(&a, set: nil)
        try a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let glyphA = TypefaceFixture.glyph("A", in: a)
        let glyphB = TypefaceFixture.glyph("B", in: a)
        let box = try TypefaceFixture.box(10, -700, 400, 700, on: glyphA, in: &a)
        try a.perform(AddAnchor("top", at: Point(x: 200, y: -700), to: glyphA))
        try a.perform(AddComponent(glyphA, to: glyphB, transform: .translation(x: 100, y: 0)))
        try a.perform(OpsCommand("Guide", ops: [Ops.elementInsert(glyphA, GlyphFields.guides, positions: [[0x80]], values: GlyphFields.values {
            var guide = Wiretuner_Doc_V1_Guide()
            guide.position = 300
            $0.guides = [guide]
        })]))
        try a.perform(SetMetricGuides([.addLine(name: "Overshoot", y: 510)]))
        try a.perform(SetKernPair(glyphA, glyphB, to: -40))
        try a.perform(SetFontMetrics(winAscent: .some(900), typoSeparate: true))
        return (glyphA, glyphB, box)
    }

    @Test func scaleUPMRescalesEverythingAndUndoRestores() throws {
        var a = Replica(0xA)
        let (glyphA, glyphB, box) = try Self.scalable(&a)
        let change = try #require(try a.perform(SetUnitsPerEm(2_000, scale: true)))
        #expect(change.label == "Scale to 2000 UPM")
        let font = FontInfo(a.state)
        #expect(font.metrics.upm == 2_000 && font.metrics.ascender == 1_600 && font.metrics.descender == -400 && font.metrics.xHeight == 1_000)
        #expect(font.metrics.winAscent == 1_800 && font.guides.extraLines[0].y == 1_020)
        let index = GlyphIndex(a.state)
        #expect(index[glyphA]?.advanceWidth == 1_000 && index[glyphA]?.anchors[0].position == Point(x: 400, y: -1_400))
        #expect(index[glyphA]?.guides[0].position == 600 && index[glyphB]?.components[0].transform == .translation(x: 200, y: 0))
        #expect(Objects.bounds(of: box, in: a.state) == Rect(x: 20, y: -1_400, width: 800, height: 1_400))
        #expect(GlyphOutlines.metrics(of: glyphB, in: a.state)?.bounds == Rect(x: 220, y: -1_400, width: 800, height: 1_400))
        #expect(Kerning(a.state).value(glyphA, glyphB) == -80)
        a.undo()
        #expect(FontInfo(a.state).metrics.upm == 1_000 && Objects.bounds(of: box, in: a.state) == Rect(x: 10, y: -700, width: 400, height: 700))
        #expect(GlyphIndex(a.state)[glyphA]?.anchors[0].position == Point(x: 200, y: -700) && Kerning(a.state).value(glyphA, glyphB) == -40)
        // Without scaling only the UPM changes.
        let plain = try #require(try a.perform(SetUnitsPerEm(2_048, scale: false)))
        #expect(plain.label == "Set UPM to 2048" && plain.ops.count == 1)
        #expect(throws: FontEditError.invalidValue("units per em")) { try a.perform(SetUnitsPerEm(10, scale: true)) }
        #expect(try SetUnitsPerEm(2_048, scale: true).ops(in: a.state).count == 1)
    }

    @Test func scaleUPMSplitsIntoAChangeGroupAndUndoesAsOneStep() throws {
        var a = Replica(0xA)
        _ = try Self.scalable(&a)
        let command = SetUnitsPerEm(500, scale: true)
        let parts = try command.changes(in: a.state, limit: 5)
        let total = try command.ops(in: a.state).count
        #expect(parts.count == (total + 4) / 5 && parts[0].label == "Scale to 500 UPM [1/\(parts.count)]")
        #expect(try command.changes(in: a.state).count == 1)
        // The group performs as consecutive changes in one undo step.
        let recording = DocumentCore.Recording(group: 7, limit: 100, now: Replica.now)
        for part in parts { _ = try a.core.perform(part, recording: recording) }
        #expect(FontInfo(a.state).metrics.upm == 500 && FontInfo(a.state).metrics.ascender == 400)
        #expect(a.core.undoStack.undo.last?.label == parts[0].label)
        a.undo()
        #expect(FontInfo(a.state).metrics.upm == 1_000 && FontInfo(a.state).metrics.ascender == 800)
    }
}
