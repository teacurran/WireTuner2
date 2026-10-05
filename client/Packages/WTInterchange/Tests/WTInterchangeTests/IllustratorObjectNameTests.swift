// LIB-030 (D-095): object names from Illustrator files.  Illustrator writes an object's name as
// the XML ID in the art dictionary after the object in its native art; the importers read the
// artwork from the PDF or the PostScript and take the names when the native layer's objects match
// the imported layer's.  Every fixture is written here: a native-format PostScript file, an
// Illustrator EPS with its native art behind `%AI9_PrivateDataBegin`, and PDF-compatible files.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

@Suite struct IllustratorObjectNameTests {
    typealias F = PDFImportFixture
    typealias L = IllustratorLayerTests
    typealias Art = IllustratorNativeArt

    // MARK: Fixtures

    /// The art dictionary Illustrator writes after an object named by XML ID `id`.
    static func named(_ id: String) -> String {
        "%_/ArtDictionary :\r%_/XMLUID : (\(id)) ; (AI10_ArtUID) ,\r%_(0.5) /String (BBAccumRotation) ,\r%_;\r%_\r"
    }

    /// A square path `size` wide at (x, y), filled.
    static func square(_ x: Double, _ y: Double, _ size: Double = 10, paint: String = "f") -> String {
        "\(x) \(y) m \(x + size) \(y) l \(x + size) \(y + size) l \(x) \(y + size) l \(paint)\r"
    }

    /// A native-format layer "Art": a named square, an unnamed one, a named group of a named
    /// square and a stroked path, a named compound path, a named clipping group, named point text
    /// and a sublayer "Details" with a named square.
    static let art = """
    %AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(Art) Ln\r\(named("Art"))0 A\r0 g\r\(square(0, 0))\(named("Logo_x5F_mark_one"))\(square(20, 0))\
    u\r\(square(40, 0))\(named("Inner"))60 0 m 70 0 l 70 10 l S\rU\r9 () XW\r\(named("Pair"))\
    *u\r\(square(0, 20))2 22 m 8 22 l 8 28 l f\r*U\r\(named("Ring"))\
    q\r0 40 m 50 40 l 50 90 l W n\r\(square(0, 40, 100))Q\r\(named("Masked"))\
    0 To\r1 0 0 1 20 100 0 Tp\rTP\r/_Helvetica 12 Tf\r(Hello) Tx\rTO\r\(named("Greeting"))\
    %AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(Details) Ln\r\(named("Details"))\(square(0, 120, 5))\(named("Dot"))LB\r%AI5_EndLayer--\r\
    LB\r%AI5_EndLayer--\r
    """

    static func postScript(_ body: String, creator: String = "Adobe Illustrator(R) 10.0", trailer: String = "") -> Data {
        Data("%!PS-Adobe-3.0\r%%Creator: \(creator)\r%%BoundingBox: 0 0 200 150\r%%EndSetup\r\(body)%%PageTrailer\r%%Trailer\r%%EOF\r\(trailer)".utf8)
    }

    static func layerGroups(_ nodes: [ImportedNode]) -> [ImportedGroup] { L.layers(nodes) }

    /// The names of `nodes`' drawn objects, in drawing order.
    static func leafNames(_ nodes: [ImportedNode]) -> [String?] {
        nodes.flatMap(\.descendants).compactMap { node in
            if case .group = node { return nil }
            return .some(node.name)
        }
    }

    /// The group named `name` among `nodes`.
    static func group(_ name: String, in nodes: [ImportedNode]) -> ImportedGroup? {
        F.groups(nodes).first { $0.name == name }
    }

    static let expectedLeaves: [String?] = ["Logo_mark one", nil, "Inner", nil, "Ring", nil, "Greeting", "Dot"]

    // MARK: Native-format PostScript

    @Test func aNativeFormatFileNamesItsObjectsGroupsAndText() throws {
        let scene = try IllustratorImportTests.convert(Self.postScript(Self.art))
        let layers = Self.layerGroups(scene.nodes)
        #expect(layers.map(\.name) == ["Art"])
        #expect(Self.leafNames(layers[0].children) == Self.expectedLeaves)
        let pair = try #require(Self.group("Pair", in: scene.nodes))
        #expect(F.paths(pair.children).map(\.name) == ["Inner", nil] && pair.role == .group)
        #expect(Self.group("Masked", in: scene.nodes)?.clip != nil)
        #expect(F.texts(scene.nodes).map(\.name) == ["Greeting"])
        // A sublayer is a group named after it, not a layer.
        let details = try #require(Self.group("Details", in: scene.nodes))
        #expect(details.role == .group)
        // Outlined, the text is a path of another shape: the other objects keep their names.
        let outlined = try IllustratorImportTests.convert(Self.postScript(Self.art), PDFImportOptions(text: .outlines))
        #expect(Self.leafNames(outlined.nodes).contains("Logo_mark one") && !Self.leafNames(outlined.nodes).contains("Greeting"))
    }

    @Test func theScanReadsTheNativeArt() {
        let art = Art(scanning: Self.postScript(Self.art))
        #expect(art.layers.count == 1 && art.layers[0].name == "Art")
        #expect(art.layers[0].leaves.map(\.name) == Self.expectedLeaves)
        #expect(art.layers[0].leaves.map(\.kind) == [.path, .path, .path, .path, .path, .path, .text, .path])
        #expect(art.layers[0].leaves[0].bounds == Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(art.layers[0].groups == [Art.Group(range: 2..<4, name: "Pair"), Art.Group(range: 5..<6, name: "Masked")])
        #expect(art.nameCount == 7)
    }

    @Test func whatTheScanCountsAndSkips() {
        // Palettes and non-printing art are skipped; text that shows nothing, empty compound
        // paths and groups, unpainted paths and paths without points draw nothing; a raster is
        // an image; operators the scan does not know are passed over; art outside layers is not
        // counted.
        let body = """
        foo\r\(Self.square(0, 0))\(Self.named("Loose"))\
        %AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(One) Ln\r%AI5_BeginPalette\r0 0 Pb\r%AI5_EndPalette\r\
        %AI5_Begin_NonPrinting\r\(Self.square(0, 0))%AI5_End_NonPrinting--\r\
        0 To\r(\r) Tx\rTO\r\(Self.named("Empty"))*u\r*U\r\(Self.named("None"))u\rU\r\(Self.named("Nothing"))\
        0 0 m 5 5 l n\r\(Self.named("Unpainted"))f\r\(Self.named("Pointless"))1 Bb\r0 BB\r1 Xw\r0 1 Xd\r\
        [1 0 0 1 0 0] 0 0 XI\r\(Self.named("Picture"))%_/ArtDictionary :\r%_(1) /String (Other) ,\r%_;\r\
        %_/ArtDictionary : ;\r%_/ArtDictionary :\r%_/XMLUID : () ; (AI10_ArtUID) ,\r%_;\rLB\r%AI5_EndLayer--\r\
        %AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(Two) Ln\rX=\r\(Self.square(0, 0))LB\r%AI5_EndLayer--\r
        """
        let art = Art(scanning: Self.postScript(body))
        #expect(art.layers.map(\.name) == ["One", "Two"])
        #expect(art.layers[0].leaves == [Art.Leaf(kind: .image, name: "Picture")] && art.layers[0].groups.isEmpty)
        #expect(art.layers[1].leaves.count == 1)
    }

    @Test func theScanCopesWithLooseStructure() {
        // No setup, no trailer, groups outside layers, a group closed that was never opened.
        let art = Art(scanning: Data("u\rU\rU\r%AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(Art) Ln\r\(Self.square(0, 0))U\r\(Self.named("Closed"))LB\r".utf8))
        #expect(art.layers.map(\.name) == ["Art"] && art.layers[0].leaves.count == 1 && art.layers[0].groups.isEmpty)
    }

    @Test func xmlIDsDecodeToNames() {
        #expect(Art.name(fromXMLID: "Logo_x5F_mark_one") == "Logo_mark one")
        #expect(Art.name(fromXMLID: "_xD83D__xDC39_Layer_1") == "\u{1F439}Layer 1")
        #expect(Art.name(fromXMLID: "a_xZZZZ_b_x41") == "a xZZZZ b x41")
        // A repeated name's ID is made unique with `_N_`.
        #expect(Art.name(fromXMLID: "crop_top_2_") == "crop top" && Art.name(fromXMLID: "_12_") == " 12 ")
        #expect(Art.name(fromXMLID: "_x1F439_ _x110000_ _x_") == "\u{1F439}  x110000   x ")
        #expect(IllustratorArtScanner.xmlID("/ArtDictionary :\n/Dictionary :\n/XMLUID : (inner) ; (AI10_ArtUID) ,\n; (Nested) ,\n;") == nil)
        #expect(Art.namesObjects(Data("%AI5_BeginLayer /XMLUID".utf8)) == false)
    }

    @Test func binaryDataIsCutOut() {
        let data = Data("a\r%%BeginData: 4 Binary Bytes\r\u{1}(\u{2}\r%%EndData\rb".utf8)
        #expect(String(decoding: Art.withoutBinaryData(data), as: UTF8.self) == "a\r\rb")
        #expect(String(decoding: Art.withoutBinaryData(Data("a %%BeginData: 4\rxyz".utf8)), as: UTF8.self) == "a ")
        #expect(Art.withoutBinaryData(Data("plain".utf8)) == Data("plain".utf8))
        #expect(Art.withoutBinaryData(Data("a%%BeginData:".utf8)) == Data("a".utf8))
        // A raster's data follows its XI.
        #expect(String(decoding: Art.withoutBinaryData(Data("[1 0 0 1 0 0] 0 0\r%%BeginData: 2\rXI\r\u{1}\u{2}\r%%EndData\r".utf8)), as: UTF8.self) == "[1 0 0 1 0 0] 0 0\r\rXI\r")
    }

    // MARK: Illustrator EPS

    /// An Illustrator EPS: a PostScript section drawing the squares at `offset` points from the
    /// native art's, then the native art (ASCII85 and zlib) behind `%AI9_PrivateDataBegin`.
    static func eps(offset: Double = 0, sizes: [Double] = [10, 10], compressed: Bool = true) -> Data {
        let printed = "%AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(Art) Ln\r\(square(offset, offset, sizes[0]))\(square(20 + offset, offset, sizes[1]))LB\r%AI5_EndLayer--\r"
        let native = postScript("%AI5_BeginLayer\r1 1 1 1 0 0 0 79 128 255 Lb\r(Art) Ln\r\(named("Art"))\(square(0, 0))\(named("First"))\(square(20, 0))\(named("Second"))LB\r%AI5_EndLayer--\r")
        let stream = compressed ? Zlib.compress(native) : native
        let lines = ASCII85.encode(stream).split(separator: "\n").map { "%" + $0 }.joined(separator: "\r")
        let trailer = "%AI9_PrivateDataBegin\r%!PS-Adobe-3.0 EPSF-3.0\r%AI9_DataStream\r\(lines)\r%AI9_PrivateDataEnd\r"
        return postScript(printed, creator: "Adobe Illustrator(R) 10.0", trailer: trailer)
    }

    static func importEPS(_ data: Data) throws -> ImportedScene {
        try EPSImporter().convert(data, name: "art.eps", format: .eps, options: ImportOptionValues(), context: ImportContext())
    }

    @Test func anIllustratorEPSTakesTheNamesOfItsNativeArt() throws {
        for compressed in [true, false] {
            let scene = try Self.importEPS(Self.eps(offset: 300, compressed: compressed))
            #expect(Self.leafNames(scene.nodes) == ["First", "Second"])
        }
        // Objects of another size are other objects: no names.
        #expect(Self.leafNames(try Self.importEPS(Self.eps(sizes: [10, 12])).nodes) == [nil, nil])
    }

    @Test func theEPSNativeArtIsDecoded() {
        #expect(IllustratorPrivateData.eps(Data("none".utf8)) == nil)
        #expect(IllustratorPrivateData.eps(Data("%AI9_DataStream\r%{}\r".utf8)) == nil)
        #expect(IllustratorPrivateData.eps(Data("%AI9_DataStream\r%\(ASCII85.encode(Data("plain".utf8)))".utf8)) == Data("plain".utf8))
    }

    @Test func ascii85Decodes() {
        let bytes = Data((0..<255).map { UInt8($0) } + [0, 0, 0, 0, 1])
        #expect(ASCII85.decode(Data(ASCII85.encode(bytes).utf8)) == bytes)
        #expect(ASCII85.decode(Data("z!!~>".utf8)) == Data([0, 0, 0, 0, 0]))
        #expect(ASCII85.decode(Data("uuuuu".utf8)) == nil)
        #expect(ASCII85.decode(Data("uuu~>".utf8)) == nil)
        #expect(ASCII85.decode(Data("uu".utf8)) == nil)
        #expect(ASCII85.decode(Data("ab{".utf8)) == nil)
    }

    // MARK: PDF-compatible files

    /// A PDF-compatible file without layer marks drawing two squares, its private data's layer
    /// "Artwork" naming them and grouping them as "Both".
    static func pdf(grouped: Bool = true, compressed: Bool = false) -> Data {
        let body = (grouped ? "u\r" : "") + square(0, 0) + named("Left") + square(20, 20, 5) + named("Right") + (grouped ? "U\r" + named("Both") : "")
        var f = F()
        let info = L.pieceInfo(L.native(L.record("Artwork", body: named("Artwork") + body)), blocks: 2, compressed: compressed, into: &f)
        return f.document([F.Page("0 0 10 10 re f 20 20 5 5 re f", extra: "/MediaBox [0 0 200 150] \(info)")])
    }

    @Test func aPDFCompatibleFileTakesItsPrivateDataNames() throws {
        for compressed in [false, true] {
            let document = try L.open(Self.pdf(compressed: compressed))
            let layer = try #require(Self.layerGroups(document.pages[0].nodes).first)
            #expect(Self.leafNames(layer.children) == ["Left", "Right"])
            #expect(F.paths(try #require(Self.group("Both", in: layer.children)).children).count == 2)
        }
        let scene = try IllustratorImportTests.convert(Self.pdf(grouped: false))
        #expect(Self.leafNames(scene.nodes) == ["Left", "Right"] && Self.group("Both", in: scene.nodes) == nil)
    }

    // MARK: Matching

    static func path(_ rect: Rect, name: String? = nil) -> ImportedNode {
        .path(ImportedPath(contours: [ImportedContour(start: Point(x: rect.minX, y: rect.minY), segments: [.line(to: Point(x: rect.maxX, y: rect.maxY))])], name: name))
    }

    static func layer(_ name: String, _ children: [ImportedNode]) -> ImportedNode {
        .group(ImportedGroup(children: children, name: name, role: .layer))
    }

    static func leaf(_ x: Double, _ y: Double, _ size: Double = 10, _ name: String? = nil) -> Art.Leaf {
        Art.Leaf(kind: .path, bounds: Rect(x: x, y: y, width: size, height: size), name: name)
    }

    static func names(_ art: Art, _ nodes: [ImportedNode]) -> [String?] {
        var nodes = nodes
        IllustratorObjectNames.apply(art, to: &nodes)
        return Self.leafNames(nodes)
    }

    /// A layer "Art" of squares at `places` (scene space, y down), 10 points wide.
    static func squares(_ places: [(Double, Double)]) -> [ImportedNode] {
        [Self.layer("Art", places.map { Self.path(Rect(x: $0.0, y: $0.1, width: 10, height: 10)) })]
    }

    static func native(_ leaves: [Art.Leaf], groups: [Art.Group] = []) -> Art {
        Art(layers: [Art.Layer(name: "Art", leaves: leaves, groups: groups)])
    }

    @Test func pathsMatchBySizeAndPlace() {
        let scene = Self.squares([(0, 140), (20, 120)])
        #expect(Self.names(Self.native([Self.leaf(0, 0, 10, "A"), Self.leaf(20, 20, 10, "B")]), scene) == ["A", "B"])
        // y down in the native art.
        #expect(Self.names(Self.native([Self.leaf(0, 0, 10, "A"), Self.leaf(20, -20, 10, "B")]), scene) == ["A", "B"])
        // No two paths agree on an offset.
        #expect(Self.names(Self.native([Self.leaf(0, 0, 10, "A"), Self.leaf(25, 3, 10, "B")]), scene) == [nil, nil])
        #expect(Self.names(Self.native([Self.leaf(0, 0, 10, "A")]), scene) == [nil, nil])
        // A piece the PDF adds, or a native path it leaves out, does not shift the names.
        let pieces = Self.squares([(0, 140), (0, 140), (20, 120), (40, 100)])
        #expect(Self.names(Self.native([Self.leaf(0, 0, 10, "A"), Self.leaf(70, 70, 10, "Gone"), Self.leaf(20, 20, 10, "B"), Self.leaf(40, 40, 10, "C")]), pieces) == ["A", nil, "B", "C"])
        // Native twins (the same box) of different names: in order when the import draws them
        // all, else which one it drew cannot be told.
        let twins = Self.native([Self.leaf(0, 0, 10, "A"), Self.leaf(0, 0, 10, "Twin"), Self.leaf(20, 20, 10, "B")])
        #expect(Self.names(twins, Self.squares([(0, 140), (0, 140), (20, 120)])) == ["A", "Twin", "B"])
        #expect(Self.names(twins, scene) == [nil, "B"])
        let alike = Self.native([Self.leaf(0, 0, 10, "A"), Self.leaf(0, 0, 10, "A"), Self.leaf(20, 20, 10, "B")])
        #expect(Self.names(alike, scene) == ["A", "B"])
        // Twins in different groups are told apart by group too; a box that is not finite has no place.
        let grouped = Self.native([Self.leaf(0, 0), Self.leaf(0, 0), Self.leaf(20, 20, 10, "B"), Art.Leaf(kind: .path, bounds: .null, name: "Nowhere")],
                                  groups: [Art.Group(range: 0..<1, name: "One"), Art.Group(range: 1..<2, name: "Two")])
        #expect(Self.names(grouped, scene) == [nil, "B"])
        // Another size at the place, a layer without names, no such layer: nothing.
        #expect(Self.names(Self.native([Self.leaf(0, 0, 12, "A"), Self.leaf(20, 20, 12, "B")]), scene) == [nil, nil])
        #expect(Self.names(Self.native([Self.leaf(0, 0), Self.leaf(20, 20)]), scene) == [nil, nil])
        #expect(Self.names(Art(layers: [Art.Layer(name: "Other", leaves: [Self.leaf(0, 0, 10, "A"), Self.leaf(20, 20, 10, "B")])]), scene) == [nil, nil])
        // Many paths of one size do not vote; empty paths have no place.
        let crowd = (0..<9).map { Self.leaf(Double($0) * 20, 0) }
        #expect(Self.names(Self.native(crowd + [Self.leaf(0, 0, 10, "A")]), Self.squares([(0, 140)])) == [nil])
        #expect(Self.names(Self.native([Self.leaf(0, 0, 10, "A")]), [Self.layer("Art", [.path(ImportedPath(contours: []))])]) == [nil])
    }

    @Test func textAndImagesMatchBetweenPaths() {
        let placed = ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: Data([1]), uti: "com.adobe.encapsulated-postscript"), bounds: Rect(x: 0, y: 0, width: 1, height: 1))
        let image = ImportedImage(pixels: ImportedPixels(blob: ImportedBlob(data: Data([0]), uti: "public.png"), width: 1, height: 1, mode: .rgb, bitsPerChannel: 8, hasAlpha: false))
        let a = Self.path(Rect(x: 0, y: 140, width: 10, height: 10))
        let b = Self.path(Rect(x: 20, y: 120, width: 10, height: 10))
        let nodes = [Self.layer("Art", []), Self.layer("Art 2", [.text(ImportedText(runs: [])), a, .image(image), .placed(placed), b, .text(ImportedText(runs: []))]), .path(ImportedPath(contours: []))]
        let art = Art(layers: [Art.Layer(name: "Art", leaves: [Self.leaf(0, 0, 10, "Unused")]),
                               Art.Layer(name: "Art", leaves: [Art.Leaf(kind: .text, name: "T"), Self.leaf(0, 0), Art.Leaf(kind: .image, name: "I"), Art.Leaf(kind: .image, name: "P"),
                                                               Self.leaf(20, 20), Art.Leaf(kind: .image, name: "Not text")])])
        #expect(Self.names(art, nodes) == ["T", nil, "I", "P", nil, nil, nil])
    }

    @Test func groupsNameTheirMatchedRun() {
        let scene = Self.squares([(0, 140), (20, 120), (40, 100)])
        func groups(_ art: Art) -> [String] {
            var nodes = scene
            IllustratorObjectNames.apply(art, to: &nodes)
            return F.groups(nodes).filter { $0.role == .group }.compactMap(\.name)
        }
        let leaves = [Self.leaf(0, 0), Self.leaf(20, 20), Self.leaf(40, 40)]
        #expect(groups(Self.native(leaves, groups: [Art.Group(range: 0..<2, name: "Pair"), Art.Group(range: 0..<3, name: "All")])) == ["All", "Pair"])
        // A piece the PDF adds inside a group joins it.
        var pieces = Self.squares([(0, 140), (0, 140), (20, 120), (40, 100)])
        IllustratorObjectNames.apply(Self.native(leaves, groups: [Art.Group(range: 0..<2, name: "Pair")]), to: &pieces)
        #expect(F.paths(Self.group("Pair", in: pieces)?.children ?? []).count == 3)
        // A group with an object that did not match is left unnamed.
        let missing = [Self.leaf(0, 0), Self.leaf(20, 20), Self.leaf(90, 90)]
        #expect(groups(Self.native(missing, groups: [Art.Group(range: 1..<3, name: "Partial")])) == [])
    }

    @Test func namedGroupsFindOrWrapTheirObjects() {
        let a = Self.path(Rect(x: 0, y: 0, width: 1, height: 1))
        let unnamed = ImportedNode.group(ImportedGroup(children: [a, a]))
        let titled = ImportedNode.group(ImportedGroup(children: [a], name: "Taken"))
        var nodes: [ImportedNode] = [unnamed, a, titled, .group(ImportedGroup(children: []))]
        // An unnamed group of exactly those objects is named.
        #expect(IllustratorObjectNames.nameGroup(Art.Group(range: 0..<2, name: "G"), in: &nodes, start: 0))
        #expect(Self.group("G", in: nodes)?.children.count == 2)
        // Inside a group, a run is wrapped.
        #expect(IllustratorObjectNames.nameGroup(Art.Group(range: 1..<2, name: "Inner"), in: &nodes, start: 0))
        #expect(Self.group("G", in: nodes)?.children.count == 2 && Self.group("Inner", in: nodes)?.children.count == 1)
        // A named group is wrapped; a run across siblings is wrapped.
        #expect(IllustratorObjectNames.nameGroup(Art.Group(range: 3..<4, name: "Outer"), in: &nodes, start: 0))
        #expect(Self.group("Outer", in: nodes)?.children.first?.name == "Taken")
        #expect(IllustratorObjectNames.nameGroup(Art.Group(range: 2..<4, name: "Run"), in: &nodes, start: 0))
        #expect(Self.group("Run", in: nodes)?.children.count == 2)
        // Objects that are not one run are left alone.
        #expect(!IllustratorObjectNames.nameGroup(Art.Group(range: 1..<3, name: "Split"), in: &nodes, start: 0))
        #expect(!IllustratorObjectNames.nameGroup(Art.Group(range: 9..<10, name: "Beyond"), in: &nodes, start: 0))
    }
}
