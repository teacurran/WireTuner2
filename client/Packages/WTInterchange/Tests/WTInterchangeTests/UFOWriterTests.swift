import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// FONT-023: writing UFO 3 packages that `UFOReader` reads back (font-export.adoc, "UFO packages").
@Suite struct UFOWriterTests {
    /// The package a read UFO would export unchanged.
    static func package(_ read: UFOFont) -> UFOPackage {
        let glyphs = read.font.glyphs.enumerated().map { offset, glyph in
            UFOPackage.Glyph(name: glyph.name, codepoints: glyph.codepoints, advanceWidth: glyph.advanceWidth, contours: glyph.contours,
                             components: glyph.components.map { UFOPackage.Component(base: read.font.glyphs[$0.glyph].name, transform: $0.transform) },
                             anchors: read.anchors[offset], note: read.notes[offset], markColor: read.markColors[offset],
                             kind: read.kinds[offset] ?? .base, artwork: read.artwork[offset])
        }
        return UFOPackage(names: read.font.names, metrics: read.font.metrics, os2: read.font.os2, glyphs: glyphs, kerning: read.font.kerning,
                          features: read.features, lib: read.lib)
    }

    static func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "export-\(UUID().uuidString).ufo")
    }

    static func sample() throws -> UFOPackage {
        var names = FontSource.Names(family: "Marlowe", style: "Bold", postscript: "Marlowe-Bold", full: "Marlowe Bold", version: "2.050")
        names.copyright = "(c) <Me> & co"
        names.designer = "Me"
        let box = Contour(polygon: [Point(x: 0, y: 0), Point(x: 500, y: 0), Point(x: 500, y: 700), Point(x: 0, y: 700)])
        let bowl = Contour(segments: [CubicBezier(Point(x: 0, y: 0), Point(x: 0, y: 100), Point(x: 50.5, y: 150), Point(x: 100, y: 150)),
                                      CubicBezier(Point(x: 100, y: 150), Point(x: 150, y: 150), Point(x: 200, y: 100), Point(x: 200, y: 0)),
                                      Line(start: Point(x: 200, y: 0), end: Point(x: 0, y: 0)).elevated()],
                           closed: true)
        let open = Contour(polygon: [Point(x: 10, y: 10), Point(x: 90, y: 10)], closed: false)
        let lib = try PropertyListSerialization.data(fromPropertyList: ["com.example.keep": [1, 2], "public.glyphOrder": ["ignored"]],
                                                     format: .binary, options: 0)
        return UFOPackage(names: names, metrics: FontSource.Metrics(unitsPerEm: 2_048, ascender: 1_600, descender: -448.5, winAscent: 1_900),
                          os2: FontSource.OS2(weightClass: 700, vendorID: "TEST", bold: true, fsType: 0x0104), glyphs: [
                              .init(name: ".notdef", advanceWidth: 500, contours: [box]),
                              .init(name: "A", codepoints: [0x41], advanceWidth: 600, contours: [box, open], anchors: [.init(name: "top", x: 250, y: 700)],
                                    note: "Wide & tall", markColor: 3),
                              .init(name: "O", codepoints: [0x4F, 0x6F], advanceWidth: 600, contours: [bowl]),
                              .init(name: "acutecomb", codepoints: [0x301], advanceWidth: 0, anchors: [.init(name: "_top", x: 0, y: 500)], kind: .mark),
                              .init(name: "Aacute", codepoints: [0xC1], advanceWidth: 600,
                                    components: [.init(base: "A"), .init(base: "acutecomb", transform: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 250, ty: 700))],
                                    artwork: Data([1, 2, 3])),
                              .init(name: "f_i", advanceWidth: 600, contours: [box], kind: .ligature),
                          ], kerning: FontSource.Kerning(pairs: [.init(left: 1, right: 2, value: -80)], leftClasses: [[1, 4], [2]],
                                                         rightClasses: [[2], [9]], classValues: [.init(left: 0, right: 0, value: -30)],
                                                         leftClassNames: ["A", ""], rightClassNames: ["O"]),
                          features: "feature liga { sub f i by f_i; } liga;\n", lib: lib)
    }

    @Test func aWrittenPackageReadsBackWithEverythingItCarries() throws {
        let url = Self.temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let package = try Self.sample()
        try UFOWriter.write(package, to: url)
        let read = try UFOReader.read(at: url)
        #expect(read.formatVersion == 3 && read.font.report.isEmpty)
        #expect(read.font.glyphs.map(\.name) == package.glyphs.map(\.name))
        #expect(read.font.names == package.names && read.font.os2 == package.os2)
        #expect(read.font.metrics == package.metrics)
        let a = read.font.glyphs[1]
        #expect(a.codepoints == [0x41] && a.advanceWidth == 600 && a.contours == package.glyphs[1].contours)
        #expect(read.font.glyphs[2].contours == package.glyphs[2].contours && read.font.glyphs[2].codepoints == [0x4F, 0x6F])
        #expect(read.anchors[1] == package.glyphs[1].anchors && read.notes[1] == "Wide & tall" && read.markColors[1] == 3)
        #expect(read.kinds == [.base, .base, .base, .mark, .base, .ligature] && read.artwork[4] == Data([1, 2, 3]) && read.artwork[1] == nil)
        #expect(read.font.glyphs[4].components == [.init(glyph: 1, transform: .identity),
                                                   .init(glyph: 3, transform: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 250, ty: 700))])
        // Kerning: the pair, the class value; the empty class and the unnamed one by its first glyph.
        let kerning = read.font.kerning
        #expect(kerning.value(1, 2) == -80 && kerning.value(4, 2) == -30 && kerning.value(2, 2) == 0)
        #expect(Set(kerning.leftClassNames) == ["A", "O"] && kerning.rightClassNames == ["O"])
        #expect(read.features == package.features)
        let lib = try #require(read.lib.flatMap { try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] })
        #expect(lib["com.example.keep"] as? [Int] == [1, 2] && lib["public.glyphOrder"] == nil && lib[UFOWriter.categoriesKey] == nil)
        // Writing again over the package replaces it.
        var smaller = package
        smaller.glyphs.removeLast()
        try UFOWriter.write(smaller, to: url)
        #expect(try UFOReader.read(at: url).font.glyphs.count == 5)
    }

    @Test func readThenWriteIsStable() throws {
        let ufo = try UFOReaderTests.fixture3()
        defer { ufo.remove() }
        let once = try UFOWriter.files(Self.package(try UFOReader.read(at: ufo.url)))
        let url = Self.temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try UFOWriter.write(Self.package(try UFOReader.read(at: ufo.url)), to: url)
        let twice = try UFOWriter.files(Self.package(try UFOReader.read(at: url)))
        #expect(once.keys.sorted() == twice.keys.sorted())
        for (path, data) in once {
            #expect(twice[path] == data, "\(path)")
        }
        #expect(String(decoding: once["glyphs/contents.plist"]!, as: UTF8.self).contains("A_.glif"))
    }

    @Test func glyphFileNamesFollowTheUFO3Convention() {
        #expect(UFOWriter.fileName("a", taken: []) == "a.glif" && UFOWriter.fileName("A", taken: []) == "A_.glif")
        #expect(UFOWriter.fileName(".notdef", taken: []) == "_notdef.glif" && UFOWriter.fileName("T_H", taken: []) == "T__H_.glif")
        #expect(UFOWriter.fileName("con", taken: []) == "_con.glif" && UFOWriter.fileName("a.con", taken: []) == "a._con.glif")
        #expect(UFOWriter.fileName("a/b|c", taken: []) == "a_b_c.glif")
        #expect(UFOWriter.fileName("a", taken: ["a.glif"]) == "a000000000000001.glif")
        #expect(UFOWriter.fileName(String(repeating: "x", count: 300), taken: []).count == 255 - 15)
    }

    @Test func numbersVersionsAndText() {
        #expect(UFOWriter.number(3) == "3" && UFOWriter.number(-0.5) == "-0.5" && UFOWriter.number(1.23456) == "1.2346")
        #expect(UFOWriter.number(.nan) == "0" && UFOWriter.number(2.00001) == "2")
        #expect(UFOWriter.version("2.005") == (2, 5) && UFOWriter.version("1.5") == (1, 500) && UFOWriter.version("3") == (3, 0))
        #expect(UFOWriter.version("x.y") == (1, 0))
        #expect(UFOWriter.value(2.0) as? Int == 2 && UFOWriter.value(2.5) as? Double == 2.5)
        #expect(UFOWriter.escape("a<b>&\"\u{1}\n") == "a&lt;b&gt;&amp;&quot;\n")
        #expect(UFOWriter.kind(category: "unassigned") == nil && UFOWriter.kind(category: "component") == .component)
        for kind in FontSource.GlyphKind.allCases { #expect(UFOWriter.kind(category: UFOWriter.category(kind)) == kind) }
    }

    @Test func aFailedWriteLeavesNothingBehind() throws {
        // The parent is a file: the staging folder cannot be made.
        let file = FileManager.default.temporaryDirectory.appending(component: "plain-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try UFOWriter.write(try Self.sample(), to: file.appending(component: "x.ufo")) }
    }
}
