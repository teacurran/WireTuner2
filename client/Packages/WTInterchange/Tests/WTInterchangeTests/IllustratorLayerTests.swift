// D-085: PDF-compatible Illustrator files open with their layers.  Every fixture is written here
// byte by byte: Illustrator's `/Layer` marks with their properties and a hidden layer's
// `/AltAI8` copy, Acrobat layers (optional content) with private data compressed behind
// `%AI12_CompressedData` in several `/AIPrivateData` blocks, private data alone, and the files
// whose layers cannot be trusted, which open as their PDF reads.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

@Suite struct IllustratorLayerTests {
    typealias F = PDFImportFixture

    // MARK: Fixtures

    /// Illustrator's properties for a layer.
    static func layer(_ title: String, visible: Bool = true, editable: Bool = true, printed: Bool = true, preview: Bool = true) -> String {
        "<< /Color [20224 -32768 -1] /Dimmed true /Editable \(editable) /Preview \(preview) /Printed \(printed) /Title (\(title)) /Visible \(visible) >>"
    }

    /// A native layer record: `%AI5_BeginLayer`, `Lb` with Illustrator 13's fourteen operands,
    /// `Ln`, and `%AI5_EndLayer--` after `body`.
    static func record(_ name: String, visible: Bool = true, preview: Bool = true, enabled: Bool = true, printing: Bool = true, body: String = "") -> String {
        let flag = { (value: Bool) in value ? "1" : "0" }
        return "%AI5_BeginLayer\r\(flag(visible)) \(flag(preview)) \(flag(enabled)) \(flag(printing)) 0 0 \(flag(visible)) 0 79 128 255 0 50 0 Lb\r(\(name)) Ln\r\(body)LB\r%AI5_EndLayer--\r"
    }

    /// Native data as Illustrator writes it: a header, then `records`.
    static func native(_ records: String) -> Data {
        Data("%!PS-Adobe-3.0 \r%%Creator: Adobe Illustrator(R) 13.0\r%%BoundingBox: 0 0 200 150\r%%EndComments\r%%EndProlog\r%%BeginSetup\r%%EndSetup\r\(records)%%PageTrailer\r%%Trailer\r%%EOF\r".utf8)
    }

    /// `/PieceInfo` with `data` split into `blocks` `/AIPrivateData` streams; `compressed` puts it
    /// behind `%AI12_CompressedData` as Illustrator CS and later do.
    static func pieceInfo(_ data: Data, blocks: Int = 1, compressed: Bool = false, into fixture: inout F) -> String {
        var payload = Data("%AI7_Thumbnail: 1 1 8\r%%BeginData: 3 Hex Bytes\r%FFFFFF\r%%EndData\r".utf8)
        if compressed {
            payload += Data("%AI12_CompressedData".utf8) + Zlib.compress(data)
        } else {
            payload += data
        }
        let size = (payload.count + blocks - 1) / blocks
        var entries: [String] = []
        for index in 0..<blocks {
            let slice = payload[payload.startIndex + min(index * size, payload.count)..<payload.startIndex + min((index + 1) * size, payload.count)]
            entries.append("/AIPrivateData\(index + 1) \(fixture.stream("", Data(slice), flate: index % 2 == 0)) 0 R")
        }
        return "/PieceInfo << /Illustrator << /LastModified (D:20080405) /Private << /ContainerVersion 11 /CreatorVersion 13 /NumBlock \(blocks) /RoundtripVersion 13 \(entries.joined(separator: " ")) >> >> >>"
    }

    /// A one-page Illustrator file with `/Layer` marks: "Back" (locked), "Front" (not printing,
    /// outline), "Hidden" (off, its artwork only in its `/AltAI8` copy) and "Empty".
    static func marked() -> Data {
        var f = F()
        let hidden = f.stream("", "1 0 0 rg 50 50 5 5 re f")
        let resources = """
        << /Properties << /MC0 \(layer("Back", editable: false)) /MC1 \(layer("Front", printed: false, preview: false)) /MC2 \(layer("Hidden", visible: false))
        /MC3 << /AIType /HiddenLayer /Contents \(hidden) 0 R /Resources << >> >> /MC4 \(layer("Empty")) >> >>
        """
        let content = """
        /Layer /MC0 BDC 0 0 10 10 re f q 0 0 50 50 re W n 1 1 5 5 re f Q EMC
        /Layer /MC1 BDC 20 20 10 10 re f EMC
        /Layer /MC2 BDC /AltAI8 /MC3 BDC EMC EMC
        /Layer /MC4 BDC EMC
        """
        return f.document([F.Page(content, resources: resources)])
    }

    static func open(_ data: Data, _ options: PDFImportOptions = PDFImportOptions()) throws -> ImportedDocument {
        try IllustratorImporter().document(data, name: "art.ai", format: .illustrator, options: options.values, context: ImportContext())
    }

    static func layers(_ nodes: [ImportedNode]) -> [ImportedGroup] {
        nodes.compactMap { node -> ImportedGroup? in
            if case .group(let group) = node, group.role == .layer { return group }
            return nil
        }
    }

    // MARK: Layer marks

    @Test func layerMarksBecomeLayersWithTheirSettings() throws {
        let document = try Self.open(Self.marked())
        #expect(document.layerSource == .layerMarks && document.notes.isEmpty)
        let layers = Self.layers(document.pages[0].nodes)
        #expect(layers.count == document.pages[0].nodes.count)
        #expect(layers.map(\.name) == ["Back", "Front", "Hidden", "Empty"])
        #expect(layers.map(\.layerState) == [ImportedLayerState(locked: true), ImportedLayerState(printing: false, outline: true), ImportedLayerState(visible: false), .normal])
        #expect(layers.map { F.paths($0.children).count } == [2, 1, 1, 0])
        // The hidden layer's artwork comes from its copy, in page space (y down).
        let hidden = F.paths(layers[2].children)[0]
        #expect(hidden.contours[0].allPoints.map(\.y).max() == 100)
        #expect(document.layerNames == ["Back", "Front", "Hidden", "Empty"])
    }

    @Test func anImportLeavesHiddenAndEmptyLayersOut() throws {
        let scene = try IllustratorImportTests.convert(Self.marked())
        #expect(Self.layers(scene.nodes).map(\.name) == ["Back", "Front"])
        #expect(scene.notes == ["The hidden layer “Hidden” was left out; open the file to keep it."])
    }

    @Test func aPDFImportReadsIllustratorMarksUnlessTurnedOff() throws {
        let scene = try F.importPDF(Self.marked())
        #expect(Self.layers(scene.nodes).map(\.name) == ["Back", "Front"])
        let plain = try PDFImporter(illustratorLayers: false).convert(Self.marked(), name: "fixture.pdf", format: .pdf, options: ImportOptionValues(), context: ImportContext())
        #expect(Self.layers(plain.nodes).isEmpty && F.paths(plain.nodes).count == 3)
    }

    @Test func keepPageClipClipsInsideEachLayer() throws {
        let document = try Self.open(Self.marked(), PDFImportOptions(keepPageClip: true))
        let layers = Self.layers(document.pages[0].nodes)
        #expect(layers.map(\.name) == ["Back", "Front", "Hidden", "Empty"])
        guard case .group(let clip)? = layers[0].children.first else {
            Issue.record("clip inside the layer")
            return
        }
        #expect(layers[0].children.count == 1 && clip.clip != nil && layers[3].children.isEmpty)
        // Without layers the whole page is one clipping group, as before.
        let plain = try F.importPDF(F.page("0 0 10 10 re f 20 20 5 5 re f"), PDFImportOptions(keepPageClip: true))
        #expect(plain.nodes.count == 1 && F.groups(plain.nodes).first?.clip != nil)
    }

    /// Illustrator restores the artboard clip it set in one layer only after the next layer
    /// began: the clip stays inside each layer and an empty layer between them is still a layer.
    @Test func aClipThatStraddlesLayersStaysInsideThem() throws {
        var f = F()
        let resources = "<< /Properties << /MC0 \(Self.layer("A")) /MC1 \(Self.layer("Guides")) /MC2 \(Self.layer("B")) >> >>"
        let content = """
        /Layer /MC0 BDC q 0 0 100 100 re W n 0 0 10 10 re f EMC /Layer /MC1 BDC EMC
        /Layer /MC2 BDC Q q 0 0 100 100 re W n 5 5 1 1 re f EMC Q
        """
        let document = try Self.open(f.document([F.Page(content, resources: resources)]))
        #expect(document.layerSource == .layerMarks && document.notes.isEmpty)
        let layers = Self.layers(document.pages[0].nodes)
        #expect(layers.map(\.name) == ["A", "Guides", "B"] && document.pages[0].nodes.count == 3)
        #expect(layers.map { F.groups($0.children).filter { $0.clip != nil }.count } == [1, 0, 1])
    }

    @Test func inlineLayerPropertiesAndSublayers() throws {
        var f = F()
        let content = """
        /Layer << /Title (Inline) /Visible false /Editable false >> BDC 0 0 10 10 re f /Layer << /Title (Sub) >> BDC 5 5 1 1 re f EMC EMC
        /Layer << /Name (Untitled) >> BDC EMC
        """
        let document = try Self.open(f.document([F.Page(content)]))
        let layers = Self.layers(document.pages[0].nodes)
        #expect(document.layerSource == .layerMarks)
        #expect(layers.map(\.name) == ["Inline"] && layers[0].layerState == ImportedLayerState(visible: false, locked: true))
        // A layer inside a layer is a group named after it.
        #expect(F.groups(layers[0].children).map(\.name) == ["Sub"] && F.groups(layers[0].children)[0].role == .group)
    }

    @Test func layersWithTheSameNameStayApartAndPagesShareLayers() throws {
        var f = F()
        let resources = "<< /Properties << /MC0 \(Self.layer("Art")) /MC1 \(Self.layer("Art")) >> >>"
        let page = F.Page("/Layer /MC0 BDC 0 0 10 10 re f EMC /Layer /MC1 BDC 20 20 10 10 re f EMC", resources: resources)
        let second = F.Page("/Layer /MC0 BDC 0 0 1 1 re f EMC /Layer /MC1 BDC EMC", resources: resources)
        let document = try Self.open(f.document([page, second]))
        #expect(document.layerSource == .layerMarks)
        #expect(document.pages.map { Self.layers($0.nodes).map(\.name) } == [["Art", "Art 2"], ["Art", "Art 2"]])
    }

    // MARK: Uncertain layers

    @Test func uncertainLayersOpenAsThePDFReads() throws {
        let resources = "<< /Properties << /MC0 \(Self.layer("A")) /MC1 \(Self.layer("B")) /OC1 << /Type /OCG /Name (C) >> >> >>"
        func open(_ pages: [String]) throws -> ImportedDocument {
            var f = F()
            return try Self.open(f.document(pages.map { F.Page($0, resources: resources) }))
        }
        let cases: [([String], String)] = [
            (["0 0 1 1 re f /Layer /MC0 BDC 0 0 10 10 re f EMC"], "some artwork is outside every layer"),
            (["/Layer /MC0 BDC 0 0 1 1 re f EMC /Layer /MC1 BDC 0 0 1 1 re f EMC /Layer /MC0 BDC 0 0 1 1 re f EMC"], "a layer is drawn in two places"),
            (["/Layer /MC0 BDC 0 0 1 1 re f EMC /Layer /MC1 BDC 0 0 1 1 re f EMC", "/Layer /MC1 BDC 0 0 1 1 re f EMC /Layer /MC0 BDC 0 0 1 1 re f EMC"],
             "the pages stack their layers in different orders"),
            (["/Layer /MC0 BDC 0 0 1 1 re f EMC /OC /OC1 BDC 0 0 1 1 re f EMC"], "it has both Illustrator layers and Acrobat layers"),
        ]
        for (pages, problem) in cases {
            let document = try open(pages)
            #expect(document.notes == ["Its layers could not be matched to its artwork with certainty (\(problem)), so it opens as its PDF reads."])
            #expect(document.pages.allSatisfy { Self.layers($0.nodes).allSatisfy { $0.name == "C" } })
        }
        // The last one keeps its optional content, as a plain PDF would.
        #expect(try open(cases[3].0).layerSource == .optionalContent)
        #expect(try open(cases[0].0).layerSource == ImportedLayerSource.none)
    }

    // MARK: Optional content and private data

    /// Acrobat layers "Base" (on), "Guides" (off) and "Top" (on), with private data saying
    /// "Base" is locked and "Top" is outline and not printing.
    static func acrobatLayers(blocks: Int = 10, compressed: Bool = true) -> Data {
        var f = F()
        let base = f.add("<< /Type /OCG /Name (Base) >>")
        let guides = f.add("<< /Type /OCG /Name (Guides) >>")
        let top = f.add("<< /Type /OCG /Name (Top) >>")
        let records = record("Base", enabled: false) + record("Guides", visible: false) + record("Top", preview: false, printing: false, body: record("Nested"))
        let info = pieceInfo(native(records), blocks: blocks, compressed: compressed, into: &f)
        let resources = "<< /Properties << /MC0 \(base) 0 R /MC1 \(guides) 0 R /MC2 \(top) 0 R >> >>"
        let content = "/OC /MC0 BDC 0 0 10 10 re f EMC /OC /MC1 BDC 5 5 10 10 re f EMC /OC /MC2 BDC 9 9 1 1 re f EMC"
        let catalog = "/OCProperties << /OCGs [\(base) 0 R \(guides) 0 R \(top) 0 R] /D << /OFF [\(guides) 0 R] /Order [\(top) 0 R \(guides) 0 R \(base) 0 R] >> >>"
        return f.document([F.Page(content, resources: resources, extra: "/MediaBox [0 0 200 150] \(info)")], catalog: catalog)
    }

    @Test func acrobatLayersTakeLockPrintAndOutlineFromThePrivateData() throws {
        for compressed in [true, false] {
            let document = try Self.open(Self.acrobatLayers(compressed: compressed))
            #expect(document.layerSource == .optionalContent)
            let layers = Self.layers(document.pages[0].nodes)
            #expect(layers.map(\.name) == ["Base", "Guides", "Top"])
            #expect(layers.map(\.layerState) == [ImportedLayerState(locked: true), ImportedLayerState(visible: false), ImportedLayerState(printing: false, outline: true)])
        }
        // Without private data the groups' visibility still comes from the configuration.
        var f = F()
        let off = f.add("<< /Type /OCG /Name (Off) >>")
        let on = f.add("<< /Type /OCG /Name (On) >>")
        // A membership dictionary is visible when any of its groups is; /BaseState /OFF hides
        // every group not listed as on.
        let resources = "<< /Properties << /A \(off) 0 R /M << /Type /OCMD /OCGs [\(on) 0 R \(off) 0 R] >> >> >>"
        let page = F.Page("/OC /A BDC 0 0 1 1 re f EMC /OC /M BDC 0 0 1 1 re f EMC", resources: resources)
        let base = try Self.open(f.document([page], catalog: "/OCProperties << /OCGs [\(off) 0 R \(on) 0 R] /D << /BaseState /OFF /ON [\(on) 0 R] >> >>"))
        #expect(base.layerSource == .optionalContent)
        #expect(Self.layers(base.pages[0].nodes).map(\.name) == ["Off", "On"])
        #expect(Self.layers(base.pages[0].nodes).map(\.layerState) == [ImportedLayerState(visible: false), .normal])
    }

    @Test func aPDFsHiddenOptionalContentOpensHiddenAndIsLeftOutOfAnImport() throws {
        var f = F()
        let off = f.add("<< /Type /OCG /Name (Draft marks) >>")
        let on = f.add("<< /Type /OCG /Name (Art) >>")
        let resources = "<< /Properties << /A \(off) 0 R /B \(on) 0 R >> >>"
        let data = f.document([F.Page("/OC /B BDC 0 0 10 10 re f EMC /OC /A BDC 0 0 5 5 re f EMC", resources: resources)],
                              catalog: "/OCProperties << /OCGs [\(off) 0 R \(on) 0 R] /D << /OFF [\(off) 0 R] >> >>")
        let document = try ImportRegistry.standard.document(data, name: "Plan.pdf")
        #expect(Self.layers(document.pages[0].nodes).map(\.layerState.visible) == [true, false])
        #expect(document.layerSource == nil)
        let scene = try F.importPDF(data)
        #expect(Self.layers(scene.nodes).map(\.name) == ["Art"])
        #expect(scene.notes == ["The hidden layer “Draft marks” was left out; open the file to keep it."])
    }

    /// A file with no layer marks and private data with `records`.
    static func unmarked(_ records: String) -> Data {
        var f = F()
        let info = pieceInfo(native(records), into: &f)
        return f.document([F.Page("0 0 10 10 re f 20 20 5 5 re f", extra: "/MediaBox [0 0 200 150] \(info)")])
    }

    @Test func aFileWithoutMarksTakesItsOneLayerFromThePrivateData() throws {
        let data = Self.unmarked(Self.record("Artwork", enabled: false, body: Self.record("Sublayer")))
        let document = try Self.open(data)
        #expect(document.layerSource == .privateData)
        let layers = Self.layers(document.pages[0].nodes)
        #expect(layers.map(\.name) == ["Artwork"] && layers[0].layerState == ImportedLayerState(locked: true) && F.paths(layers[0].children).count == 2)
        // Imported, the artwork is a group named after the layer.
        let scene = try IllustratorImportTests.convert(data)
        #expect(Self.layers(scene.nodes).map(\.name) == ["Artwork"] && scene.nodes.count == 1)
    }

    @Test func aFileWithoutMarksAndSeveralLayersOpensOnOneLayer() throws {
        for data in [Self.unmarked(Self.record("A") + Self.record("B")), F.page("0 0 10 10 re f")] {
            let document = try Self.open(data)
            #expect(document.layerSource == ImportedLayerSource.none)
            #expect(Self.layers(document.pages[0].nodes).isEmpty && F.paths(document.pages[0].nodes).count >= 1)
            #expect(Self.layers(try IllustratorImportTests.convert(data).nodes).isEmpty)
        }
    }

    @Test func aPostScriptFileReportsItsLayers() throws {
        #expect(try Self.open(Data(IllustratorImportTests.legacy.utf8)).layerSource == .postScript)
        let bare = "%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 8.0\n%%BoundingBox: 0 0 10 10\n%%EndProlog\n0 0 m 10 0 l 10 10 l f\n%%Trailer\n"
        #expect(try Self.open(Data(bare.utf8)).layerSource == ImportedLayerSource.none)
    }

    // MARK: The private data reader

    @Test func thePrivateDataReaderReadsTheLayerTable() throws {
        let data = Self.native(Self.record("One", visible: false, preview: false) + Self.record("Two", enabled: false, printing: false, body: Self.record("Inner")))
        let layers = IllustratorPrivateData.layers(data)
        #expect(layers.map(\.name) == ["One", "Two", "Inner"] && layers.map(\.depth) == [0, 0, 1])
        #expect(layers.map(\.state) == [ImportedLayerState(visible: false, outline: true), ImportedLayerState(locked: true, printing: false), .normal])
        // A record without a name is "Layer"; one without flags is skipped; so is a short Lb.
        let odd = Data("%AI5_BeginLayer\r1 1 1 1 0 0 1 0 0 0 0 Lb\r0 A\r%AI5_EndLayer--\r%AI5_BeginLayer\r1 1 Lb\r(Short) Ln\r%AI5_EndLayer--\r%AI5_BeginLayer\r(X) Ln\r%AI5_EndLayer--\r%AI5_BeginLayer\r1 1 1 1 Lb".utf8)
        #expect(IllustratorPrivateData.layers(odd).map(\.name) == ["Layer", "Layer"])
        #expect(IllustratorPrivateData.layers(Data("%AI5_EndLayer--\r".utf8)).isEmpty)
        #expect(IllustratorPrivateData.layers(Data("%AI5_BeginLayer\r1 1 1 1 Lb\r Ln\r".utf8)).map(\.name) == ["Layer"])
    }

    @Test func thePrivateDataIsJoinedAndInflated() throws {
        let data = Self.native(Self.record("Solo"))
        #expect(IllustratorPrivateData.native(Data("head".utf8) + Data("%AI12_CompressedData".utf8) + Zlib.compress(data) + Data("trailing".utf8)) == Data("head".utf8) + data)
        #expect(IllustratorPrivateData.native(data) == data)
        // Zstandard data, a stream that is not zlib, or one that inflates past the limit: unread.
        #expect(IllustratorPrivateData.native(Data("%AI24_ZStandard_Data(\u{28})".utf8)) == nil)
        #expect(IllustratorPrivateData.native(Data("%AI12_CompressedDatanot zlib".utf8)) == nil)
        let zeros = Zlib.compress(Data(count: 300_000))
        #expect(IllustratorPrivateData.inflate(zeros, limit: 100_000) == nil)
        #expect(IllustratorPrivateData.inflate(zeros)?.count == 300_000)
        #expect(IllustratorPrivateData.inflate(Data([0x78, 0x9C, 0xFF, 0xFF, 0xFF])) == nil)
        let truncated = Zlib.compress(data)
        #expect(IllustratorPrivateData.inflate(truncated.prefix(truncated.count / 2))?.isEmpty == false)
        // A page without private data, or whose blocks are not streams.
        var f = F()
        let pdf = f.document([F.Page("", extra: "/MediaBox [0 0 10 10] /PieceInfo << /Illustrator << /Private << /AIPrivateData1 (x) >> >> >>")])
        let document = try PDFImporter.document(pdf, name: "x.ai")
        #expect(IllustratorPrivateData.data(page: PDFImportDict(ref: document.page(at: 1)!.dictionary!)) == nil)
        #expect(IllustratorImporter.nativeLayers(IllustratorImporter.nativeData(try PDFImporter.document(F.page(""), name: "y.ai"))).isEmpty)
    }
}
