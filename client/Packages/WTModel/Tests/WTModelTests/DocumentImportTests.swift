import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import struct WTGeometry.AffineTransform

/// IO-040: a foreign file opened as a new document -- `CreateDocument(.imported(_))` writes the
/// file's pages, layers and artwork as the document's first change (creating-opening.adoc,
/// "Opening other file types").
@Suite struct DocumentImportTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func layer(_ name: String, _ nodes: [ImportedNode], transform: AffineTransform = .identity) -> ImportedNode {
        .group(ImportedGroup(children: nodes, transform: transform, name: name, role: .layer))
    }

    static func square(_ x: Double, name: String? = nil) -> ImportedNode { .path(ImportFixture.square(x, name: name)) }

    /// A two-artboard Illustrator file: Letter with a Background and an Art layer, a landscape A4
    /// with Art only, a loose path, and a note.
    static var poster: ImportedDocument {
        let a4 = PagePreset.standard.first { $0.name == "A4" }!
        return ImportedDocument(format: .illustrator, name: "Poster.ai", pages: [
            ImportedPage(size: Size(width: 612, height: 792), nodes: [layer("Background", [square(0, name: "bg")]), layer("Art", [square(20, name: "a1")])]),
            ImportedPage(name: "Back", size: Size(width: a4.height, height: a4.width),
                         nodes: [layer("Art", [square(40, name: "a2")], transform: .translation(x: 5, y: 0)), square(60, name: "loose")],
                         layers: [ImportedLayer(name: "Notes", nodes: [square(80, name: "note")])]),
        ], notes: ["A gradient mesh was filled with 50% black."])
    }

    static func open(_ document: ImportedDocument, link: ImportLink? = nil) throws -> DocumentCore {
        try DocumentCreation.newDocument(from: .imported(DocumentImport(document, link: link)), replica: 0xA, now: now)
    }

    /// The names of the objects on each layer, bottom to top.
    static func contents(_ state: EngineState) -> [String: [String]] {
        let order = LayerOrder(state)
        return Dictionary(uniqueKeysWithValues: order.layers.map { layer in
            (layer.name, order.objects(on: layer.id, in: state).map { state.props($0).path.common.name })
        })
    }

    @Test func pagesLayersAndArtworkComeFromTheFile() throws {
        let core = try Self.open(Self.poster)
        let state = core.state
        let pages = PageList(state).pages
        #expect(pages.count == 2)
        #expect(pages[0].geometry.preset == "Letter" && pages[0].geometry.orientation == .portrait)
        #expect(pages[1].geometry.preset == "A4" && pages[1].geometry.orientation == .landscape && pages[1].name == "Back")
        // In a row, top-aligned, an inch apart, centred on the pasteboard.
        #expect(pages[1].rect.minX == pages[0].rect.maxX + 72 && pages[1].rect.minY == pages[0].rect.minY)
        let block = pages[0].rect.union(pages[1].rect)
        #expect(abs(block.midX - DocumentCreation.pasteboardSide / 2) < 1e-9 && abs(block.midY - DocumentCreation.pasteboardSide / 2) < 1e-9)
        // The file's layers bottom to top in the order they appear, loose artwork on Foreground,
        // Notes last.
        #expect(LayerOrder(state).layers.map(\.name) == ["Background", "Art", "Foreground", "Notes"])
        #expect(Self.contents(state) == ["Background": ["bg"], "Art": ["a1", "a2"], "Foreground": ["loose"], "Notes": ["note"]])
        // Each object sits on its page: the second page's art is moved by its page's origin and
        // its layer's own transform.
        let order = LayerOrder(state)
        let art = order.objects(on: order.layers[1].id, in: state)
        #expect(Objects.transform(of: art[1], in: state) == AffineTransform.translation(x: 5 + pages[1].rect.minX, y: pages[1].rect.minY))
        #expect(Objects.transform(of: art[0], in: state) == AffineTransform.translation(x: pages[0].rect.minX, y: pages[0].rect.minY))
        // The template: swatches and styles, one change, not an undo step.
        #expect(!SwatchList(state).swatches.isEmpty)
        #expect(core.nextSeq == 2 && core.undoStack == UndoStack())
        #expect(CreateDocument(.imported(DocumentImport(Self.poster))).label == "Created from Poster.ai")
    }

    @Test func aDocumentThatIsOnePlacedFileKeepsItsLinkAndVectorArtworkDoesNot() throws {
        let placed = ImportedDocument(scene: ImportFixture.placed(.eps, blob: ImportFixture.eps, name: "Logo.eps"), format: .eps)
        #expect(placed.pages[0].size == Size(width: 200, height: 100) && placed.title == "Logo")
        let link = ImportLink(displayName: "Logo.eps", path: "/Users/me/Logo.eps")
        let state = try Self.open(placed, link: link).state
        let node = try #require(LayerOrder(state).layers.first.map { LayerOrder(state).objects(on: $0.id, in: state) }?.first)
        let asset = OpID(state.props(node).placedFile.source.id)
        #expect(state.props(asset).asset.link.path == "/Users/me/Logo.eps")
        // The placed file moved so its bounds' corner is the page's.
        let page = PageList(state).pages[0].rect
        #expect(Objects.transform(of: node, in: state) == AffineTransform.translation(x: page.minX - 10, y: page.minY - 20))
        // A vector document's images get no link record.
        let vector = ImportedDocument(scene: ImportFixture.vector, format: .svg)
        let vectorState = try Self.open(vector, link: link).state
        let image = vectorState.store.children(WellKnown.assets).map { vectorState.props($0).asset }
        #expect(image.allSatisfy { $0.link.kind != .localFile })
        #expect(LayerOrder(vectorState).layers.map(\.name) == ["Foreground"])
        #expect(vector.objectCount == 7 && vector.layerNames.isEmpty && vector.blobs.count == 1)
    }

    @Test func pagesWrapIntoRowsAndOversizedPagesAreClamped() {
        let wide = ImportedPage(size: Size(width: 9_000, height: 100), nodes: [])
        let huge = ImportedPage(size: Size(width: 20_000, height: 0), nodes: [])
        let source = DocumentImport(ImportedDocument(format: .pdf, name: "Big.pdf", pages: [wide, wide, huge]))
        let rects = source.pageRects
        #expect(rects[1].minX == rects[0].minX && rects[1].minY == rects[0].maxY + 72, "the second page starts a row")
        #expect(rects[2].width == PageGeometry.maximumSide && rects[2].height == 1)
        #expect(DocumentImport.geometry(width: 100, height: 200) == PageGeometry(width: 100, height: 200))
    }

    @Test func emptyLayersAreKeptAndNamelessLayersAreForeground() throws {
        let document = ImportedDocument(format: .pdf, name: "Layers.pdf", pages: [
            ImportedPage(size: Size(width: 100, height: 100), nodes: [Self.layer("Hidden", []), .group(ImportedGroup(children: [Self.square(0, name: "x")], role: .layer))]),
        ])
        #expect(document.layerNames == ["Hidden"])
        let state = try Self.open(document).state
        #expect(Self.contents(state) == ["Hidden": [], "Foreground": ["x"]])
    }

    @Test func aLargeFileIsWrittenInPartsThatAreNotUndoSteps() throws {
        let nodes = (0..<300).map { Self.square(Double($0), name: "p\($0)") }
        let command = CreateDocument(.imported(DocumentImport(ImportedDocument(format: .svg, name: "Many.svg", pages: [ImportedPage(size: Size(width: 10, height: 10), nodes: nodes)]))))
        var core = DocumentCore(state: EngineState(), replica: 0xB)
        let parts = try ChangeSplitting.split(command, in: core.state, replica: 0xB, limit: 100)
        #expect(parts.count > 1 && parts.allSatisfy { !$0.recordsUndo })
        for part in parts { _ = try core.perform(part, recording: DocumentCore.Recording(limit: 10, now: Self.now)) }
        #expect(core.undoStack == UndoStack())
        #expect(Self.contents(core.state)["Foreground"]?.count == 300)
    }

    /// A display list build reads the stacking order once for every text block's wrap
    /// (`TextWrapping.Pass`): the answers are the ones a fresh walk gives.
    @Test func aWrapPassAnswersAsAFreshWalkDoes() throws {
        var (a, node) = try TypeEditingModelTests.block("Body text that wraps around the square in front of it")
        let art = LayerOrder(a.state).layers.first!.id
        let square = try LayerFixture.object(LayerFixture.rect(on: art, x: 10, size: 20), on: &a)
        let behind = try a.perform(CreateTextBlock(.area(Rect(x: 5, y: 5, width: 40, height: 20)), text: "Quote"))!.createdObjects[0]
        try a.perform(SetTextWrap([square], enabled: true, standoff: 4))
        let state = a.state
        let fresh = [node, behind, square].map { TextWrapping.wrappingObjects(for: $0, in: state) }
        let passed = TextWrapping.withPass { [node, behind, square, node].map { TextWrapping.wrappingObjects(for: $0, in: state) } }
        #expect(passed.prefix(3).elementsEqual(fresh) && passed[3] == [square])
        #expect(TextWrapping.withPass { TextWrapping.wrappingObjects(for: OpID(counter: 999, replica: 9), in: state) }.isEmpty)
        #expect(TextWrapping.pass == nil)
    }

    /// A document that holds only the template (a memory document's page and swatches) takes the
    /// file in place of its page; one with artwork is left alone.
    @Test func anImportReplacesATemplateOnlyDocumentsPageAndLeavesArtworkAlone() throws {
        var core = DocumentTemplate.core(replica: 0xD, now: Self.now)
        _ = try core.perform(CreateDocument(), recording: DocumentCore.Recording(limit: 1, now: Self.now))
        _ = try core.perform(AddPages(count: 1), recording: DocumentCore.Recording(limit: 1, now: Self.now))
        let swatches = SwatchList(core.state).swatches.count
        _ = try core.perform(CreateDocument(.imported(DocumentImport(Self.poster))), recording: DocumentCore.Recording(limit: 1, now: Self.now))
        #expect(PageList(core.state).pages.count == 2 && PageList(core.state).pages[1].name == "Back")
        #expect(SwatchList(core.state).swatches.count == swatches, "the template is not written twice")
        var drawn = Replica(0xE)
        _ = try LayerFixture.layers(["Art"], on: &drawn)
        #expect(try drawn.perform(CreateDocument(.imported(DocumentImport(Self.poster)))) == nil)
    }

    /// Imported fills paint open contours, as PDF, PostScript and SVG do.
    @Test func anOpenFilledContourKeepsItsFill() throws {
        let open = ImportedPath(contours: [ImportedContour(start: Point(x: 0, y: 0), segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10))])],
                                fill: .solid(.black))
        let stroked = ImportedPath(contours: open.contours, stroke: ImportedStroke(paint: .solid(.black)))
        let document = ImportedDocument(format: .pdf, name: "Open.pdf", pages: [ImportedPage(size: Size(width: 20, height: 20), nodes: [.path(open), .path(stroked)])])
        let state = try Self.open(document).state
        let order = LayerOrder(state)
        let objects = order.objects(on: order.layers[0].id, in: state)
        #expect(state.props(objects[0]).path.fillWhenOpen && !state.props(objects[1]).path.fillWhenOpen)
    }
}
