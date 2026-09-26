import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// Writes UFO packages for the reader tests.
struct UFOFixture {
    let url: URL

    init(version: Int = 3) throws {
        url = FileManager.default.temporaryDirectory.appending(component: "fixture-\(UUID().uuidString).ufo")
        try FileManager.default.createDirectory(at: url.appending(component: "glyphs"), withIntermediateDirectories: true)
        try plist(["formatVersion": version, "creator": "org.example.test"], "metainfo.plist")
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func plist(_ value: Any, _ path: String) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url.appending(path: path))
    }

    func text(_ value: String, _ path: String) throws {
        try Data(value.utf8).write(to: url.appending(path: path))
    }

    /// Writes `glyphs` (name → glif body inside `<glyph>`) and `contents.plist`.
    func glyphs(_ glyphs: [(name: String, body: String)], format: Int = 2, directory: String = "glyphs") throws {
        var contents: [String: String] = [:]
        for (offset, glyph) in glyphs.enumerated() {
            let file = "g\(offset).glif"
            contents[glyph.name] = file
            try text("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<glyph name=\"\(glyph.name)\" format=\"\(format)\">\n\(glyph.body)\n</glyph>\n",
                     "\(directory)/\(file)")
        }
        try plist(contents, "\(directory)/contents.plist")
    }
}

/// FONT-024: reading UFO 2 and 3 packages into an `ImportedFont` with anchors, mark colors,
/// features and the lib (font-export.adoc, "UFO packages").
@Suite struct UFOReaderTests {
    static let square = """
        <advance width="600"/>
        <unicode hex="0041"/>
        <anchor x="300" y="700" name="top"/>
        <outline>
          <contour>
            <point x="100" y="0" type="line"/>
            <point x="500" y="0" type="line"/>
            <point x="500" y="700" type="line"/>
            <point x="100" y="700" type="line"/>
          </contour>
        </outline>
        <lib><dict><key>public.markColor</key><string>1,0,0,1</string><key>com.example</key><integer>3</integer></dict></lib>
        """

    static let curves = """
        <advance width="500"/>
        <unicode hex="006F"/>
        <unicode hex="004F"/>
        <outline>
          <contour>
            <point x="250" y="0" type="curve" smooth="yes"/>
            <point x="388" y="0" type="offcurve"/>
            <point x="500" y="112"/>
            <point x="500" y="250" type="curve"/>
            <point x="500" y="400" type="offcurve"/>
            <point x="250" y="500" type="qcurve"/>
            <point x="100" y="500" type="offcurve"/>
            <point x="0" y="400" type="offcurve"/>
            <point x="0" y="250" type="qcurve"/>
            <point x="0" y="112" type="offcurve"/>
            <point x="112" y="0" type="offcurve"/>
          </contour>
          <contour>
            <point x="10" y="10" type="move"/>
            <point x="20" y="10" type="line"/>
            <point x="30" y="20" type="offcurve"/>
            <point x="40" y="30" type="curve"/>
          </contour>
          <contour>
            <point x="0" y="0"/>
            <point x="100" y="0"/>
            <point x="100" y="100"/>
            <point x="0" y="100"/>
          </contour>
        </outline>
        """

    static func fixture3() throws -> UFOFixture {
        let ufo = try UFOFixture(version: 3)
        try ufo.plist(["familyName": "Marlowe", "styleName": "Bold Italic", "unitsPerEm": 2_048, "ascender": 1_600, "descender": -448,
                       "xHeight": 1_000, "capHeight": 1_400, "italicAngle": -12, "versionMajor": 2, "versionMinor": 5,
                       "copyright": "(c) Test", "openTypeNameDesigner": "Me", "openTypeNameLicense": "OFL",
                       "openTypeOS2WeightClass": 700, "openTypeOS2WidthClass": 6, "openTypeOS2VendorID": "TEST", "openTypeOS2Type": [2, 8],
                       "openTypeOS2Panose": [2, 11, 8, 3, 0, 0, 0, 0, 0, 0], "styleMapStyleName": "bold italic",
                       "openTypeHheaLineGap": 100, "openTypeOS2TypoAscender": 1_500, "openTypeOS2WinAscent": 1_900,
                       "postscriptUnderlinePosition": -150, "postscriptUnderlineThickness": 80], "fontinfo.plist")
        try ufo.glyphs([
            (".notdef", "<advance width=\"500\"/>"),
            ("A", square),
            ("O", curves),
            ("V", "<advance width=\"600\"/><unicode hex=\"0056\"/>"),
            ("Aacute", """
                <advance width="600"/><unicode hex="00C1"/>
                <outline><component base="A"/><component base="acutecomb" xOffset="300" yOffset="700" xScale="0.5" yScale="0.5"/>
                <component base="missing"/></outline>
                """),
            ("acutecomb", "<advance width=\"0\"/><anchor x=\"0\" y=\"0\" name=\"_top\"/><image fileName=\"a.png\"/><guideline x=\"1\" angle=\"0\"/>"),
        ])
        try ufo.plist([["public.default", "glyphs"], ["public.background", "glyphs.background"]], "layercontents.plist")
        try ufo.plist(["public.kern1.A": ["A", "Aacute"], "public.kern2.O": ["O", "missing"], "public.kern2.V": ["V"], "public.kern1.unused": ["O"],
                       "other": ["A"]], "groups.plist")
        try ufo.plist(["public.kern1.A": ["public.kern2.O": -30, "public.kern2.V": -60, "V": -50],
                       "A": ["V": -80, "nothere": -1], "O": ["public.kern2.V": -20], "ghost": ["public.kern2.V": -5]], "kerning.plist")
        try ufo.text("languagesystem DFLT dflt;\nfeature ss01 { sub A by V; } ss01;\n", "features.fea")
        try ufo.plist(["public.glyphOrder": ["A", "V", "A", "nothere"], "com.example.keep": ["x": 1]], "lib.plist")
        try FileManager.default.createDirectory(at: ufo.url.appending(component: "images"), withIntermediateDirectories: true)
        return ufo
    }

    @Test func aUFO3IsReadWithEverythingItCarries() throws {
        let ufo = try Self.fixture3()
        defer { ufo.remove() }
        let read = try UFOReader.read(at: ufo.url)
        let font = read.font
        #expect(read.formatVersion == 3)
        #expect(font.glyphs.map(\.name) == [".notdef", "A", "V", "Aacute", "O", "acutecomb"])
        #expect(font.names.family == "Marlowe" && font.names.style == "Bold Italic" && font.names.postscript == "Marlowe-BoldItalic")
        #expect(font.names.full == "Marlowe Bold Italic" && font.names.version == "2.005" && font.names.copyright == "(c) Test")
        #expect(font.names.designer == "Me" && font.names.license == "OFL")
        #expect(font.metrics.unitsPerEm == 2_048 && font.metrics.ascender == 1_600 && font.metrics.descender == -448)
        #expect(font.metrics.italicAngle == -12 && font.metrics.lineGap == 100 && font.metrics.typoAscender == 1_500)
        #expect(font.metrics.typoDescender == -448 && font.metrics.winAscent == 1_900 && font.metrics.winDescent == nil)
        #expect(font.metrics.underlinePosition == -150 && font.metrics.underlineThickness == 80)
        #expect(font.os2.weightClass == 700 && font.os2.widthClass == 6 && font.os2.vendorID == "TEST" && font.os2.fsType == 0x104)
        #expect(font.os2.bold && font.os2.italic && font.os2.panose.first == 2)

        // Outlines within 0.01 of the source points.
        let a = font.glyphs[1]
        #expect(a.codepoints == [0x41] && a.advanceWidth == 600 && a.contours.count == 1)
        let square = a.contours[0].segments.map(\.p0)
        #expect(square == [Point(x: 100, y: 0), Point(x: 500, y: 0), Point(x: 500, y: 700), Point(x: 100, y: 700)] && a.contours[0].isClosed)
        let o = font.glyphs[4]
        #expect(o.codepoints == [0x6F, 0x4F] && o.contours.count == 3)
        let ring = o.contours[0]
        #expect(ring.isClosed && ring.segments.first?.p0 == Point(x: 250, y: 0))
        #expect(ring.segments[0].p1 == Point(x: 388, y: 0) && ring.segments[0].p2 == Point(x: 500, y: 112) && ring.segments[0].p3 == Point(x: 500, y: 250))
        // The quadratic from (500, 250) through (500, 400) to (250, 500), elevated exactly.
        let quad = ring.segments[1]
        #expect(abs(quad.p1.x - 500) < 0.01 && abs(quad.p1.y - (250 + 2.0 / 3 * 150)) < 0.01 && quad.p3 == Point(x: 250, y: 500))
        // Two controls in a qcurve: an implied on-curve point between them.
        #expect(ring.segments[2].p3 == Point(x: 50, y: 450) && ring.segments[3].p3 == Point(x: 0, y: 250))
        #expect(ring.segments.last?.p3 == Point(x: 250, y: 0))
        let open = o.contours[1]
        #expect(!open.isClosed && open.segments.count == 2 && open.segments[1].p3 == Point(x: 40, y: 30))
        let loop = o.contours[2]
        #expect(loop.isClosed && loop.segments.count == 4 && loop.segments[0].p0 == Point(x: 0, y: 50))

        // Components (the missing one left out and reported), anchors, mark colors.
        let accented = font.glyphs[3]
        #expect(accented.components.map(\.glyph) == [1, 5])
        #expect(accented.components[1].transform == AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 300, ty: 700))
        #expect(read.anchors[1] == [FontSource.Anchor(name: "top", x: 300, y: 700)] && read.anchors[5].first?.name == "_top")
        #expect(read.markColors == [0, 1, 0, 0, 0, 0])

        // Kerning: groups into classes (unused kerning groups kept), pairs, glyph-to-group pairs as singleton classes.
        let kerning = font.kerning
        #expect(kerning.leftClassNames.contains("A") && kerning.rightClassNames.contains("O") && kerning.leftClassNames.contains("unused"))
        #expect(kerning.value(1, 2) == -80 && kerning.value(1, 4) == -30 && kerning.value(3, 2) == -50 && kerning.value(4, 2) == -20)
        #expect(kerning.pairs.count == 3)

        #expect(read.features.contains("feature ss01"))
        let lib = try #require(read.lib)
        let restored = try PropertyListSerialization.propertyList(from: lib, format: nil) as? [String: Any]
        #expect(restored?["com.example.keep"] != nil && restored?["public.glyphOrder"] == nil)

        let report = font.report.joined(separator: "\n")
        for fragment in ["layer public.background", "images folder", "component missing", "background image", "guideline",
                         "pair A nothere", "pair ghost public.kern2.V"] {
            #expect(report.contains(fragment), "\(fragment)")
        }
    }

    @Test func aUFO2ReadsAnchorsFromNamedPointsAndGroupsByUse() throws {
        let ufo = try UFOFixture(version: 2)
        defer { ufo.remove() }
        try ufo.glyphs([
            ("a", """
                <advance width="500"/><unicode hex="61"/><unicode hex="zz"/>
                <outline>
                  <contour><point x="250" y="600" type="move" name="top"/></contour>
                  <contour><point x="0" y="0" type="line"/><point x="10" y="0" type="line"/><point x="10" y="0" type="line"/></contour>
                  <contour><point x="0" y="0" type="move"/></contour>
                  <component xOffset="1"/>
                </outline>
                """),
            ("b", "<advance width=\"500\"/>"),
        ], format: 1)
        try ufo.plist(["@MMK_L_a": ["a"], "@MMK_R_b": ["b", "a"]], "groups.plist")
        try ufo.plist(["@MMK_L_a": ["@MMK_R_b": -10, "b": -4], "a": ["@MMK_R_b": -3]], "kerning.plist")
        let read = try UFOReader.read(at: ufo.url)
        #expect(read.formatVersion == 2 && read.font.names.family == "Untitled" && read.font.names.style == "Regular")
        #expect(read.font.metrics.unitsPerEm == 1_000 && read.lib == nil && read.features.isEmpty)
        #expect(read.font.glyphs.map(\.name) == ["a", "b"] && read.font.glyphs[0].codepoints == [0x61])
        #expect(read.anchors[0] == [FontSource.Anchor(name: "top", x: 250, y: 600)])
        #expect(read.font.glyphs[0].contours.count == 1 && read.font.glyphs[0].components.isEmpty)
        #expect(read.font.kerning.value(0, 1) == -4 && read.font.kerning.value(0, 0) == -3 && read.font.kerning.classValues.first?.value == -10)
        #expect(read.font.kerning.leftClassNames.contains("a") && read.font.kerning.rightClassNames.contains("b"))
        let report = read.font.report.joined(separator: "\n")
        #expect(report.contains("unicode") && report.contains("without a base") && report.contains("could not be read"))
    }

    @Test func damagedPackagesAreRefused() throws {
        let missing = FileManager.default.temporaryDirectory.appending(component: "none-\(UUID().uuidString).ufo")
        #expect(throws: UFOReader.Failure.notAUFO("no metainfo.plist")) { try UFOReader.read(at: missing) }
        let four = try UFOFixture(version: 4)
        defer { four.remove() }
        #expect(throws: UFOReader.Failure.notAUFO("format version 4")) { try UFOReader.read(at: four.url) }
        let empty = try UFOFixture()
        defer { empty.remove() }
        #expect(throws: UFOReader.Failure.malformed("glyphs/contents.plist is missing")) { try UFOReader.read(at: empty.url) }
        try empty.plist(["A": "gone.glif", "B": 5], "glyphs/contents.plist")
        #expect(throws: UFOReader.Failure.malformed("the glyph file gone.glif is missing")) { try UFOReader.read(at: empty.url) }
        try empty.text("<glyph name=\"A\"><advance", "glyphs/gone.glif")
        #expect(throws: UFOReader.Failure.self) { try UFOReader.read(at: empty.url) }
        try empty.text("not a plist", "fontinfo.plist")
        #expect(throws: UFOReader.Failure.malformed("fontinfo.plist does not parse")) { try UFOReader.read(at: empty.url) }
        try empty.plist(["a", "b"], "fontinfo.plist")
        #expect(throws: UFOReader.Failure.malformed("fontinfo.plist is not a dictionary")) { try UFOReader.read(at: empty.url) }
        #expect(UFOReader.Failure.notAUFO("x").description.hasPrefix("Not a UFO") && UFOReader.Failure.malformed("y").description.contains("damaged"))
    }

    @Test func markColorsMapToTheNearestGridColor() {
        #expect(UFOReader.markColor("0,0.47,1,1") == 8 && UFOReader.markColor("1,0,0,0") == 0 && UFOReader.markColor("x") == 0)
        #expect(GlifParser.markColor(in: Data("<glyph/>".utf8)) == nil)
        #expect(GlifParser.contour([]) == nil)
    }

    @Test func anImportedUFOCompilesBackToAFont() throws {
        let ufo = try Self.fixture3()
        defer { ufo.remove() }
        let read = try UFOReader.read(at: ufo.url)
        let glyphs = read.font.glyphs.enumerated().map { offset, glyph in
            FontSource.Glyph(name: glyph.name, codepoints: glyph.codepoints, advanceWidth: glyph.advanceWidth, contours: glyph.contours,
                             anchors: read.anchors[offset])
        }
        let source = FontSource(names: read.font.names, metrics: read.font.metrics, os2: read.font.os2, glyphs: glyphs, kerning: read.font.kerning,
                                features: read.features)
        let compiled = try FontCompiler.compile(source)
        #expect(compiled.data.count > 0)
    }
}
