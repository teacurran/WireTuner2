import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// FONT-023 (model half): a typeface document written as a UFO 3 package and read back
/// (font-export.adoc, "UFO packages").
@Suite struct UFOExportTests {
    static func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "doc-\(UUID().uuidString).ufo")
    }

    /// The drawn fixture plus a note, a mark color, anchors, a ligature, feature text and a
    /// glyph that is not exported but used as a component.
    static func document(_ a: inout Replica) throws -> [String: OpID] {
        var g = try FontGenerationTests.drawn(&a)
        try a.perform(AddGlyphs([NewGlyph(name: "f_i", kind: .ligature), NewGlyph(name: "hidden")]))
        g = Dictionary(uniqueKeysWithValues: GlyphIndex(a.state).glyphs.map { ($0.name, $0.id) })
        try TypefaceFixture.box(0, -700, 600, 700, on: g["f_i"]!, in: &a)
        try TypefaceFixture.box(0, -100, 50, 100, on: g["hidden"]!, in: &a)
        try a.perform(AddComponent(g["hidden"]!, to: g["B"]!))
        try a.perform(SetGlyphAttributes([g["hidden"]!], export: false))
        try a.perform(SetGlyphAttributes([g["A"]!], markColor: 4, note: "Check the apex"))
        try a.perform(AddAnchor("top", at: Point(x: 300, y: -700), to: g["A"]!))
        try a.perform(AddAnchor("_top", at: Point(x: 150, y: -700), to: g["gravecomb"]!))
        try a.perform(OpsCommand("Features", ops: [Ops.textInsert(WellKnown.settings, FontFields.features, "feature ss01 { sub A by B; } ss01;\n")]))
        return g
    }

    static func open(_ url: URL, into replica: inout Replica) throws {
        let ufo = try UFOReader.read(at: url)
        try UFOImportTests.perform(UFOImport.plan(ufo, fileName: url.lastPathComponent, into: replica.state, newDocument: true), on: &replica)
    }

    @Test func aFlattenedExportCarriesTheFont() throws {
        var a = Replica(0xA)
        _ = try Self.document(&a)
        let url = Self.temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try UFOExport.write(a.state, to: url)
        #expect(report.isEmpty)
        let read = try UFOReader.read(at: url)
        let names = read.font.glyphs.map(\.name)
        #expect(names.first == ".notdef" && names.suffix(2) == ["NULL", "CR"] && !names.contains("hidden"))
        let glyph = { (name: String) in names.firstIndex(of: name)! }
        // Components that point into the package stay components; the hidden one is drawn in.
        let agrave = read.font.glyphs[glyph("Agrave")]
        #expect(agrave.components.map(\.glyph) == [glyph("A"), glyph("gravecomb")] && agrave.contours.isEmpty)
        #expect(read.font.glyphs[glyph("B")].components.isEmpty && read.font.glyphs[glyph("B")].contours.count == 1)
        let boxA = read.font.glyphs[glyph("A")]
        #expect(boxA.contours.count == 1 && boxA.contours[0].bounds == Rect(x: 0, y: 0, width: 600, height: 700))
        #expect(read.anchors[glyph("A")] == [.init(name: "top", x: 300, y: 700)] && read.notes[glyph("A")] == "Check the apex")
        #expect(read.markColors[glyph("A")] == 4 && read.kinds[glyph("gravecomb")] == .mark && read.kinds[glyph("f_i")] == .ligature)
        #expect(read.kinds[glyph("A")] == .base)
        let kerning = read.font.kerning
        #expect(kerning.leftClassNames == ["A"] && kerning.rightClassNames == ["O"])
        #expect(kerning.value(glyph("A"), glyph("V")) == -80 && kerning.value(glyph("Agrave"), glyph("O")) == -30)
        // The user's features, then the generated ones.
        #expect(read.features.hasPrefix("languagesystem DFLT dflt;\nfeature ss01"))
        #expect(read.features.contains(FeatureGenerator.marker) && read.features.contains("@kern1.A") && read.features.contains("sub f i by f_i;"))
        #expect(read.lib == nil)
        // Without the generated features or the standard glyphs, and only some glyphs.
        let small = UFOExport.package(a.state, options: UFOExportOptions(addStandardGlyphs: false, generatedFeatures: false, glyphs: [TypefaceFixture.glyph("Agrave", in: a)]))
        #expect(small.package.features == "feature ss01 { sub A by B; } ss01;\n")
        #expect(small.package.glyphs.map(\.name) == [".notdef", "Agrave"])
        // Agrave's components are not in the package: drawn in.
        #expect(small.package.glyphs[1].components.isEmpty && small.package.glyphs[1].contours.count >= 1)
    }

    @Test func exportImportExportIsByteIdentical() throws {
        var a = Replica(0xA)
        _ = try Self.document(&a)
        let first = try UFOWriter.files(UFOExport.package(a.state).package)
        let url = Self.temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try UFOExport.write(a.state, to: url)
        var b = Replica(0xB)
        try Self.open(url, into: &b)
        let index = GlyphIndex(b.state)
        #expect(index.glyph(named: "A")?.note == "Check the apex" && index.glyph(named: "gravecomb")?.kind == .mark)
        #expect(Kerning(b.state).classes.map(\.name) == ["A", "O"])
        // The generated part is not imported into the feature text.
        #expect(FontInfo(b.state).features == "languagesystem DFLT dflt;\nfeature ss01 { sub A by B; } ss01;\n")
        let second = try UFOWriter.files(UFOExport.package(b.state).package)
        #expect(first.keys.sorted() == second.keys.sorted())
        for (path, data) in first {
            #expect(second[path] == data, "\(path): \(String(decoding: data, as: UTF8.self)) vs \(String(decoding: second[path] ?? Data(), as: UTF8.self))")
        }
    }

    @Test func libKeysAnImportedUFOCarriedAreWrittenBack() throws {
        var a = Replica(0xA)
        var ufo = UFOImportTests.ufo()
        ufo.lib = try PropertyListSerialization.data(fromPropertyList: ["com.example.keep": "yes"], format: .binary, options: 0)
        try UFOImportTests.perform(UFOImport.plan(ufo, fileName: "M.ufo", into: a.state, newDocument: true), on: &a)
        let package = UFOExport.package(a.state).package
        let data = try #require(try UFOWriter.files(package)["lib.plist"])
        let lib = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(lib["com.example.keep"] as? String == "yes" && (lib["public.glyphOrder"] as? [String])?.first == ".notdef")
        #expect(UFOImport.userText("a\n\(FeatureGenerator.marker)\nb") == "a\n" && UFOImport.userText("plain") == "plain")
    }

    @Test func anAsDrawnExportKeepsStrokesOnReimport() throws {
        var a = Replica(0xA)
        let g = try Self.document(&a)
        let url = Self.temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try UFOExport.write(a.state, to: url, options: UFOExportOptions(artwork: .asDrawn))
        #expect(report.count == 1 && report[0].contains("Strokes were written as outlines in V"))
        let read = try UFOReader.read(at: url)
        let names = read.font.glyphs.map(\.name)
        // The stroke is written as its outline; the artwork rides in the lib.
        let v = names.firstIndex(of: "V")!
        #expect(!read.font.glyphs[v].contours.isEmpty && read.artwork[v] != nil && read.artwork[names.firstIndex(of: "C")!] == nil)
        // The ring as drawn: two contours, overlaps and directions untouched; B's hidden component drawn in.
        #expect(read.font.glyphs[names.firstIndex(of: "O")!].contours.count == 2)
        #expect(read.font.glyphs[names.firstIndex(of: "B")!].contours.count == 1)
        var b = Replica(0xB)
        try Self.open(url, into: &b)
        let index = GlyphIndex(b.state)
        let sources = GlyphOutlines.sources(in: b.state, index: index)
        let stroked = try #require(sources[NodeID(index.glyph(named: "V")!.id)])
        #expect(stroked.shapes.count == 1 && !stroked.shapes[0].strokes.isEmpty && !stroked.shapes[0].filled)
        let ring = try #require(sources[NodeID(index.glyph(named: "O")!.id)])
        #expect(ring.shapes.count == 1 && ring.shapes[0].fillRule == .evenOdd)
        // Same outline as the source document's.
        let before = try #require(GlyphOutlines.metrics(of: g["V"]!, in: a.state)?.bounds)
        let after = try #require(GlyphOutlines.metrics(of: index.glyph(named: "V")!.id, in: b.state)?.bounds)
        #expect(before == after)
    }

    @Test func normalizationHelpers() throws {
        // Classes by name, unnamed ones after (by position), cells renumbered, a cell naming a
        // missing class dropped.
        let kerning = FontSource.Kerning(leftClasses: [[1], [2], [3]], rightClasses: [[4], [5]],
                                         classValues: [.init(left: 0, right: 1, value: -1), .init(left: 2, right: 0, value: -2), .init(left: 5, right: 0, value: -3)],
                                         leftClassNames: ["b", "", "a"], rightClassNames: ["z"])
        let sorted = UFOExport.sortedClasses(kerning)
        #expect(sorted.leftClasses == [[3], [1], [2]] && sorted.leftClassNames == ["a", "b", ""])
        #expect(sorted.rightClasses == [[4], [5]] && sorted.rightClassNames == ["z", ""])
        #expect(sorted.classValues == [.init(left: 0, right: 0, value: -2), .init(left: 1, right: 1, value: -1)])
        // Start points: the lowest, then leftmost on-curve point; open and empty contours as they are.
        let square = Contour(polygon: [Point(x: 10, y: 10), Point(x: 0, y: 10), Point(x: 0, y: 0), Point(x: 10, y: 0)])
        #expect(UFOExport.startingAtLowerLeft(square).startPoint == Point(x: 0, y: 0))
        let unclosed = Contour(segments: Array(square.segments.dropLast()), closed: true)
        #expect(UFOExport.startingAtLowerLeft(unclosed).startPoint == Point(x: 0, y: 0) && UFOExport.startingAtLowerLeft(unclosed).segments.count == 4)
        let open = Contour(polygon: [Point(x: 5, y: 5), Point(x: 0, y: 0)], closed: false)
        #expect(UFOExport.startingAtLowerLeft(open) == open && UFOExport.startingAtLowerLeft(Contour(segments: [], closed: true)).isEmpty)
        #expect(GlyphKind(imported: .component) == .component && FontGeneration.kind(.component) == .component)
    }

    @Test func severalStrokedGlyphsAreCountedInTheReport() throws {
        var a = Replica(0xA)
        let g = try Self.document(&a)
        let stroke = try a.perform(CreatePath(contours: [NewContour(points: PathFixture.points([(0, 0), (100, -100)]))],
                                              appearance: Appearances.standard))!.createdObjects[0]
        try TypefaceFixture.place(stroke, on: g["W"]!, in: &a)
        #expect(UFOExport.package(a.state, options: UFOExportOptions(artwork: .asDrawn)).report.first?.contains("in 2 glyphs") == true)
    }
}
