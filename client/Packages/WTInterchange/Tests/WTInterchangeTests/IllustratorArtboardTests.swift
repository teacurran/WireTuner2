// D-085's follow-ups: an Illustrator file's artboards open as pages named after them (the names
// come from the private data's document data, `ArtboardArray`), a `.pdf` Illustrator wrote -- its
// piece info with `/AIPDFPrivateData` blocks, or only its `/Layer` marks -- opens and imports with
// an Illustrator file's layers, and a plain PDF reads as it did.  Every fixture is written here.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

@Suite struct IllustratorArtboardTests {
    typealias F = PDFImportFixture
    typealias L = IllustratorLayerTests

    // MARK: Fixtures

    /// Document data as Illustrator writes it: every line behind `%_`, the artboards in an
    /// `ArtboardArray` of dictionaries, each `Name` a `/UnicodeString` given as `names`' literal
    /// (already escaped or hex) text, among other entries.
    static func documentData(_ names: [String]) -> String {
        let boards = names.map { name in
            """
            %_/Dictionary :
            %_7885 7795 /RealPoint\r%_ (RulerOrigin) ,
            %_1 /Real (PAR) ,
            %_\(name) /UnicodeString (Name) ,
            %_1 /Bool (IsArtboardDefaultName) ,
            %_/Dictionary : /NotRecorded ,
            %_12 /Real (x) ,
            %_; (PositionPoint1) ,
            %_; ,
            """
        }.joined(separator: "\r")
        return """
        %AI9_BeginDocumentData\r%_/Document :\r%_/Dictionary :\r%_1 /Int (AI9 artboard color) ,\r%_/Array :\r%_; (CropAreaArray) ,
        %_/Dictionary :\r%_/Array :\r\(boards)\r%_; (ArtboardArray) ,\r%_0 /Int (ArtboardsActive) ,\r%_; (ArtboardDocDict) ,
        %_; /NotRecorded ,\r%_;\r%AI9_EndDocumentData\r
        """
    }

    /// Illustrator's private data with `records` and `names`' artboards, as `/PieceInfo`; `pdf`
    /// names the blocks `/AIPDFPrivateData` as a `.pdf` with Illustrator editing does.
    static func pieceInfo(records: String = "", names: [String], pdf: Bool = false, into f: inout F) -> String {
        let info = L.pieceInfo(L.native(records + documentData(names)), blocks: 3, compressed: true, into: &f)
        return pdf ? info.replacingOccurrences(of: "/AIPrivateData", with: "/AIPDFPrivateData") : info
    }

    /// `count` pages, each with one "Art" layer mark, page 1 carrying the piece info.
    static func artboards(_ count: Int, names: [String], pdf: Bool = false) -> Data {
        var f = F()
        let info = pieceInfo(names: names, pdf: pdf, into: &f)
        let resources = "<< /Properties << /MC0 \(L.layer("Art")) >> >>"
        let pages = (0..<count).map { index in
            F.Page("/Layer /MC0 BDC 0 0 10 10 re f EMC", resources: resources, extra: "/MediaBox [0 0 \(200 + index * 10) 150]\(index == 0 ? " \(info)" : "")")
        }
        return f.document(pages)
    }

    /// A `.pdf` Illustrator wrote: the layer marks of `IllustratorLayerTests.marked()`'s layers
    /// "Back" and "Hidden" (off, its artwork in its `/AltAI8` copy), with piece info when `info`.
    static func illustratorPDF(info: Bool = true) -> Data {
        var f = F()
        let hidden = f.stream("", "1 0 0 rg 50 50 5 5 re f")
        let extra = info ? " " + pieceInfo(records: L.record("Back") + L.record("Hidden", visible: false), names: ["(Poster)"], pdf: true, into: &f) : ""
        let resources = """
        << /Properties << /MC0 \(L.layer("Back")) /MC1 \(L.layer("Hidden", visible: false)) /MC2 << /AIType /HiddenLayer /Contents \(hidden) 0 R /Resources << >> >> >> >>
        """
        let content = "/Layer /MC0 BDC 0 0 10 10 re f EMC /Layer /MC1 BDC /AltAI8 /MC2 BDC EMC EMC"
        return f.document([F.Page(content, resources: resources, extra: "/MediaBox [0 0 200 150]\(extra)")])
    }

    static func openPDF(_ data: Data, name: String = "Poster.pdf") throws -> ImportedDocument {
        try ImportRegistry.standard.document(data, name: name)
    }

    // MARK: Artboard names

    @Test func artboardsOpenAsPagesNamedAfterThem() throws {
        let data = Self.artboards(3, names: ["(Cover)", "<FEFF00C9007400E9>", "(Back \\(fold\\))"])
        let document = try L.open(data)
        #expect(document.pages.map(\.name) == ["Cover", "Été", "Back (fold)"])
        #expect(document.pages.map(\.size.width) == [200, 210, 220])
        #expect(document.layerSource == .layerMarks && document.layerNames == ["Art"])
        // Opened with a page range, each page keeps its own artboard's name.
        let second = try L.open(data, PDFImportOptions(pages: ImportPageRange(pages: [2, 3])))
        #expect(second.pages.map(\.name) == ["Été", "Back (fold)"])
    }

    @Test func artboardNamesNeedOneNamePerPage() throws {
        // Fewer names than pages (or none, a file from before CS4): the pages keep no name.
        #expect(try L.open(Self.artboards(2, names: ["(Only)"])).pages.map(\.name) == [nil, nil])
        #expect(try L.open(Self.artboards(1, names: [])).pages.map(\.name) == [nil])
        // An empty name leaves that page unnamed.
        #expect(try L.open(Self.artboards(2, names: ["()", "(B)"])).pages.map(\.name) == [nil, "B"])
        // The names come through the fallback reading too.
        var f = F()
        let info = Self.pieceInfo(names: ["(Loose)"], into: &f)
        let loose = f.document([F.Page("0 0 1 1 re f /Layer /MC0 BDC 0 0 10 10 re f EMC", resources: "<< /Properties << /MC0 \(L.layer("A")) >> >>", extra: "/MediaBox [0 0 200 150] \(info)")])
        let document = try L.open(loose)
        #expect(document.notes.count == 1 && document.pages[0].name == "Loose")
    }

    @Test func theDocumentDataReaderFindsTheArtboards() {
        let names = IllustratorPrivateData.artboardNames(Data((Self.documentData(["(A)", "(Café)", "<FEFF0042>"])).utf8))
        #expect(names == ["A", "Café", "B"])
        // Latin-1 bytes that are not UTF-8 read as Latin-1.
        var latin = Data(Self.documentData(["(X)"]).utf8)
        latin.replaceSubrange(latin.range(of: Data("(X)".utf8))!, with: Data([0x28, 0xE9, 0x29]))
        #expect(IllustratorPrivateData.artboardNames(latin) == ["é"])
        // No document data, or none with artboards.
        #expect(IllustratorPrivateData.artboardNames(Data("%%EndComments\r".utf8)).isEmpty)
        #expect(IllustratorPrivateData.artboardNames(Data("%AI9_BeginDocumentData\r%_/Document :\r%_; ,\r%AI9_EndDocumentData\r".utf8)).isEmpty)
        // A cut-off section closes what is open; a line without %_ is read, other comments not.
        let open = "%AI9_BeginDocumentData\r/Dictionary :\r%_/Array :\r%comment\r%_/Dictionary :\r%_(Z) /UnicodeString (Name) ,\r%_; ,\r%_; (ArtboardArray) ,\r"
        #expect(IllustratorPrivateData.artboardNames(Data(open.utf8)) == ["Z"])
        // A dictionary without a name gives an empty one; stray operators are skipped.
        let parsed = IllustratorPrivateData.dictionary(Data("/Dictionary : 3 /Int (n) , x ; (d) , 7 /Real , ; ,".utf8))
        #expect(parsed["d"]?["n"]?.text == "3.0" && parsed["d"]?["Name"] == nil && parsed.values.count == 2)
        #expect(IllustratorDataValue.container([]).text == nil && IllustratorDataValue.scalar(Data()).values.isEmpty && IllustratorDataValue.scalar(Data())["x"] == nil)
        #expect(IllustratorPrivateData.artboards(.scalar(Data())).isEmpty)
        // An artboard without a name reads as an empty one; an empty string value is empty.
        let unnamed = "%AI9_BeginDocumentData\r%_/Array :\r%_/Dictionary :\r%_ /String (Note) ,\r%_; ,\r%_; (ArtboardArray) ,\r%AI9_EndDocumentData\r"
        #expect(IllustratorPrivateData.artboardNames(Data(unnamed.utf8)) == [""])
        #expect(IllustratorPrivateData.documentData(Data(unnamed.utf8))?["ArtboardArray"]?.values.first?["Note"]?.text == "")
    }

    // MARK: PDFs Illustrator wrote

    @Test func aPDFIllustratorWroteOpensWithItsLayersAndArtboard() throws {
        let document = try Self.openPDF(Self.illustratorPDF())
        #expect(document.format == .pdf && document.layerSource == .layerMarks && document.notes.isEmpty)
        let layers = L.layers(document.pages[0].nodes)
        #expect(layers.map(\.name) == ["Back", "Hidden"] && layers.map(\.layerState.visible) == [true, false])
        #expect(F.paths(layers[1].children).count == 1)
        #expect(document.pages[0].name == "Poster")
        #expect(IllustratorPrivateData.isIllustrator(try PDFImporter.document(Self.illustratorPDF(), name: "p.pdf")))
    }

    @Test func aPDFWithOnlyIllustratorsLayerMarksOpensWithThem() throws {
        let document = try Self.openPDF(Self.illustratorPDF(info: false))
        #expect(document.layerSource == .layerMarks)
        #expect(L.layers(document.pages[0].nodes).map(\.name) == ["Back", "Hidden"] && document.pages[0].name == nil)
        #expect(!IllustratorPrivateData.isIllustrator(try PDFImporter.document(Self.illustratorPDF(info: false), name: "p.pdf")))
    }

    @Test func importingAPDFIllustratorWroteLeavesHiddenLayersOut() throws {
        for info in [true, false] {
            let scene = try F.importPDF(Self.illustratorPDF(info: info))
            #expect(L.layers(scene.nodes).map(\.name) == ["Back"])
            #expect(scene.notes == ["The hidden layer “Hidden” was left out; open the file to keep it."])
        }
    }

    @Test func aPDFIllustratorWroteWithoutMarksTakesItsOneLayer() throws {
        var f = F()
        let info = Self.pieceInfo(records: L.record("Artwork", enabled: false), names: ["(Board)"], pdf: true, into: &f)
        let data = f.document([F.Page("0 0 10 10 re f", extra: "/MediaBox [0 0 200 150] \(info)")])
        let document = try Self.openPDF(data)
        #expect(document.layerSource == .privateData && document.pages[0].name == "Board")
        #expect(L.layers(document.pages[0].nodes).map(\.layerState) == [ImportedLayerState(locked: true)])
        #expect(L.layers(try F.importPDF(data).nodes).map(\.name) == ["Artwork"])
    }

    @Test func anUncertainPDFIllustratorWroteOpensAsItsPDFReads() throws {
        var f = F()
        let info = Self.pieceInfo(names: ["(A)"], pdf: true, into: &f)
        let data = f.document([F.Page("0 0 1 1 re f /Layer /MC0 BDC 0 0 10 10 re f EMC", resources: "<< /Properties << /MC0 \(L.layer("A")) >> >>", extra: "/MediaBox [0 0 200 150] \(info)")])
        let document = try Self.openPDF(data)
        #expect(document.notes == ["Its layers could not be matched to its artwork with certainty (some artwork is outside every layer), so it opens as its PDF reads."])
        #expect(L.layers(document.pages[0].nodes).isEmpty && document.layerSource == ImportedLayerSource.none)
    }

    @Test func aPlainPDFReadsAsBefore() throws {
        let document = try Self.openPDF(F.page("0 0 10 10 re f"))
        #expect(document.layerSource == nil && document.pages[0].name == nil && L.layers(document.pages[0].nodes).isEmpty)
        // Turned off, Illustrator's marks are not read.
        let plain = try PDFImporter(illustratorLayers: false).document(Self.illustratorPDF(), name: "p.pdf", format: .pdf, options: ImportOptionValues(), context: ImportContext())
        #expect(plain.layerSource == nil && L.layers(plain.pages[0].nodes).isEmpty && F.paths(plain.pages[0].nodes).count == 1)
    }
}
