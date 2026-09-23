// IMG-010: Illustrator import.  PDF-compatible files (as WireTuner's own Illustrator exporter and
// Illustrator 9 and later write them) come back with their layers; legacy PostScript files
// (AI 3 to 8 syntax, written here by hand) are read by the operator subset, and a file that leaves
// the subset is placed as EPS with a notice.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct IllustratorImportTests {
    static func convert(_ data: Data, _ options: PDFImportOptions = PDFImportOptions()) throws -> ImportedScene {
        try IllustratorImporter().convert(data, name: "art.ai", format: .illustrator, options: options.values, context: ImportContext())
    }

    static let legacy = """
    %!PS-Adobe-3.0
    %%Creator: Adobe Illustrator(R) 8.0
    %%BoundingBox: 0 0 199 149
    %%HiResBoundingBox: 0 0 200 150
    %%BeginProlog
    /foo { 1 2 } def
    %%EndProlog
    %%BeginSetup
    Adobe_Illustrator_AI5 begin
    %AI5_BeginPalette
    0 0 Pb
    %AI5_EndPalette
    %%EndSetup
    %AI5_BeginLayer
    1 1 1 1 0 0 0 79 128 255 Lb
    (Background) Ln
    0 A
    0 g 0 G 1 w 0 j 0 J 4 M []0 d
    0 0 m 100 0 l 100 50 L 0 50 L f
    u
    1 0 0 0 k 10 10 m 20 30 30 30 40 10 c 50 0 60 0 70 5 C 70 20 80 20 v 80 30 90 20 V 95 25 100 10 y 110 5 120 5 Y s
    0 1 0 0 K 3 w 1 j 2 J [2 1]0 d 0 0 m 10 10 l S
    U
    *u
    0 0 m 50 0 l 50 50 l 0 50 l f
    10 10 m 40 10 l 40 40 l 10 40 l f
    *U
    *u
    *U
    q
    0 0 m 30 0 l 30 30 l W n
    0.2 g 0 0 m 100 0 l 100 100 l f
    Q
    0 0 0 1 (Spot) 0.5 x 0 0 m 1 1 l F
    0 0 0 1 (Spot) 0 X 0 0 m 1 1 l b
    1 0 0 Xa 0 1 0 XA 0 0 m 1 1 l B
    0 0 0 0 1 0 0 (RGB) 0 1 Xx 0 0 0 1 0 0 0 (C) 0 0 XX 0 0 m 1 1 l N
    1 XR 0 0 m 5 5 l n 0 0 m 5 5 l H 0 0 m 5 5 l h N
    0 0 m 5 5 l W f
    q 0 0 m 5 5 l W F 0 0 m 1 1 l W n Q
    1 Bb 0 BB
    LB
    %AI5_EndLayer--
    %AI5_BeginLayer
    1 1 1 1 0 0 1 79 128 255 Lb
    (Art) Ln
    0 To
    1 0 0 1 20 100 0 Tp
    TP
    0 Tr
    /_Helvetica 12 10 -2 Tf
    14 Tl
    (Hello) Tx
    ( there) Tx
    T*
    (World\\rAgain) Tx
    () Tx
    TO
    0 To
    0.8 0.6 -0.6 0.8 150 50 0 Tp
    TP
    /Times-Roman 10 Tf
    (Turned) Tj
    TO
    0 To TO
    [1 0 0 1 10 140] 0 0 2 2 2 2 8 1 1 0 0 1 XI
    %AI5_BeginRaster
    %FF00FF00
    %AI5_EndRaster
    [1 0 0 1 10 140] 0 0 2 2 2 2 3 1 1 0 0 1 XI
    %AI5_BeginRaster
    %AI5_EndRaster
    [1 0 0 1 0 0] 0 0 XI
    %AI5_BeginRaster
    %AI5_EndRaster
    U U Q LB
    LB
    %AI5_EndLayer--
    %%PageTrailer
    gsave annotatepage grestore showpage
    %%Trailer
    """

    @Test func legacyFilesAreReadByTheOperatorSubset() throws {
        let scene = try Self.convert(Data(Self.legacy.utf8))
        #expect(scene.kind == .vector)
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 200, height: 150))
        let layers = PDFImportFixture.groups(scene.nodes).filter { $0.role == .layer }
        #expect(layers.map(\.name) == ["Background", "Art"])
        let background = layers[0]
        let paths = PDFImportFixture.paths(background.children)
        // The first rectangle, y flipped.
        #expect(paths[0].contours[0].start == Point(x: 0, y: 150))
        #expect(paths[0].contours[0].closed)
        #expect(paths[0].fill == .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: 1)))
        // Every curve form in the group.
        let curves = paths[1]
        #expect(curves.contours[0].segments.count == 6)
        #expect(curves.stroke != nil && curves.fill == .none && curves.contours[0].closed)
        let stroke = try #require(paths[2].stroke)
        #expect(stroke.style.width == 3 && stroke.style.join == .round && stroke.style.cap == .square && stroke.style.dash == [2, 1])
        #expect(stroke.paint == .solid(Color(cyan: 0, magenta: 1, yellow: 0, black: 0)))
        // The compound path is one path of two contours; the clip group clips.
        #expect(paths[3].contours.count == 2)
        let clip = try #require(PDFImportFixture.groups(background.children).first { $0.clip != nil })
        #expect(clip.children.count == 1)
        #expect(paths.contains { $0.fill == .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5)) })
        #expect(paths.contains { $0.fill == .solid(Color(red: 1, green: 0, blue: 0)) && $0.stroke?.paint == .solid(Color(red: 0, green: 1, blue: 0)) })
        #expect(paths.contains { $0.fillRule == .evenOdd })
        #expect(scene.notes.contains("Gradients in legacy Illustrator files were imported as their fallback fills."))
        let texts = PDFImportFixture.texts(layers[1].children)
        #expect(texts.map(\.string) == ["Hello thereWorldAgain", "Turned"])
        #expect(texts[0].runs.map(\.origin) == [Point(x: 20, y: 50), Point(x: 20, y: 64), Point(x: 20, y: 78)])
        #expect(texts[0].runs[0].fontName == "Helvetica" && texts[0].runs[0].fontSize == 12)
        #expect(!texts[1].transform.isIdentity)
        let images = PDFImportFixture.images(layers[1].children)
        #expect(images.count == 1)
        #expect(scene.notes.contains("A raster image in the file could not be read and was left out."))
        #expect(images[0].pixels.width == 2 && images[0].pixels.height == 2)
        #expect(images[0].transform.apply(Point(x: 0, y: 0)).distance(to: Point(x: 10, y: 10)) < 1e-9)
    }

    @Test func legacyTextCanBeOutlined() throws {
        let scene = try Self.convert(Data(Self.legacy.utf8), PDFImportOptions(text: .outlines))
        #expect(scene.texts.isEmpty)
        let layers = PDFImportFixture.groups(scene.nodes).filter { $0.role == .layer }
        let outlines = PDFImportFixture.paths(layers[1].children)
        #expect(outlines.count == 2)
        #expect(outlines[0].contours.count > 10)
    }

    @Test func legacyFilesWithoutSetupOrBoundsStillRead() throws {
        let plain = "%!PS-Adobe-2.0\n%%Creator: Adobe Illustrator 3\n0 g 0 0 m 10 0 l 10 10 l f\n%%EOF\n0 0 m 5 5 l f"
        let scene = try Self.convert(Data(plain.utf8))
        #expect(scene.bounds == Rect(x: 0, y: 0, width: 612, height: 792))
        #expect(scene.scenePaths.count == 1)
        #expect(scene.scenePaths[0].contours[0].start == Point(x: 0, y: 792))
        let unterminated = try Self.convert(Data("%!PS-Adobe-2.0\n0 0 m 1 1 l f u 0 0 m 1 1 l f".utf8))
        #expect(unterminated.nodes.count == 2)
    }

    @Test func unknownOperatorsPlaceTheFileAsEPS() throws {
        let file = "%!PS-Adobe-3.0\n%%BoundingBox: 10 20 110 70\n%%EndSetup\n0 0 m 10 10 l f\n1 2 moveto gsave\n"
        let scene = try Self.convert(Data(file.utf8))
        #expect(scene.kind == .placed)
        guard case .placed(let placed) = scene.nodes.first else {
            Issue.record("placed")
            return
        }
        #expect(placed.kind == .eps)
        #expect(placed.bounds == Rect(x: 0, y: 0, width: 100, height: 50))
        #expect(placed.blob.data == Data(file.utf8))
        #expect(scene.notes == ["“art.ai” was placed as EPS because it uses the PostScript operator “moveto”, which the Illustrator reader does not interpret."])
        let descriptor = try IllustratorImporter().probe(Data(file.utf8), name: "art.ai", format: .illustrator)
        #expect(descriptor.placed && descriptor.naturalSize == Rect(x: 0, y: 0, width: 100, height: 50))
        let readable = try IllustratorImporter().probe(Data(Self.legacy.utf8), name: "art.ai", format: .illustrator)
        #expect(!readable.placed)
    }

    @Test func otherDataIsRefused() {
        #expect(throws: ImportError.unreadable(name: "art.ai", reason: "it is neither a PDF-compatible nor a PostScript Illustrator file.")) {
            try Self.convert(Data("hello".utf8))
        }
        #expect(throws: ImportError.self) {
            try IllustratorImporter().probe(Data("hello".utf8), name: "art.ai", format: .illustrator)
        }
    }

    // MARK: PDF-compatible files

    @Test func pdfCompatibleFilesKeepLayers() throws {
        let background = NodeID(counter: 1, replica: 1)
        let art = NodeID(counter: 2, replica: 1)
        let items: [DisplayItem] = [
            .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Corpus.yellow))])])),
            .group(GroupItem(children: [Corpus.path(Corpus.ellipse(20, 20, 60, 40), [Corpus.fill(.solid(Corpus.blue))]), Corpus.text("Label")])),
        ]
        let scene = Corpus.scene([Corpus.page(items, nodes: [background, art])], nodes: [background: ExportNodeInfo(name: "Paper", isLayer: true), art: ExportNodeInfo(name: "Drawing", isLayer: true)])
        let data = try IllustratorExporter().data(scene: scene, options: IllustratorOptions()).data
        let imported = try Self.convert(data)
        let layers = PDFImportFixture.groups(imported.nodes).filter { $0.role == .layer }
        #expect(layers.map(\.name) == ["Paper", "Drawing"])
        #expect(imported.texts == ["Label"])
        let descriptor = try IllustratorImporter().probe(data, name: "art.ai", format: .illustrator)
        #expect(descriptor.pageCount == 1 && descriptor.format == .illustrator)
        #expect(IllustratorImporter().formats == [.illustrator])
        #expect(IllustratorImporter().optionsSchema(for: .illustrator) == PDFImportOptions.schema)
    }

    @Test func gradientMeshesAreHalfBlack() throws {
        let data = PDFImportFixture.page("/M sh", resources: "<< /Shading << /M << /ShadingType 6 /ColorSpace /DeviceRGB >> >> >>")
        let scene = try Self.convert(data)
        #expect(scene.scenePaths.first?.fill == .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: 0.5)))
        let pdf = try PDFImportFixture.importPDF(data)
        #expect(pdf.scenePaths.first?.fill == .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: 0.1)))
    }
}
