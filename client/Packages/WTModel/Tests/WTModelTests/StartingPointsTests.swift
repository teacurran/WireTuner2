import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-029: each built-in starting point creates a document matching its description in one
/// change (templates.adoc, "Starting a document from a template").
@Suite struct StartingPointsTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// A new document of `options`, checked to hold exactly one change that is not an undo step.
    static func document(_ options: StartingPoints.Options) throws -> DocumentCore {
        let core = try DocumentCreation.newDocument(from: .startingPoint(options), replica: 0xB, now: now)
        #expect(core.nextSeq == 2, "one change")
        #expect(core.undoStack == UndoStack(), "not an undo step")
        return core
    }

    static func styleNames(_ state: EngineState) -> [String] {
        let resolver = GraphicStyleResolver(state)
        return GraphicStyleFields.styles(in: state, resolver).compactMap { resolver.entries[$0]?.props.common.name }
    }

    @Test func blankWithItsDefaultsIsTheBuiltInTemplate() throws {
        let options = StartingPoints.defaults(for: .blank)
        let core = try Self.document(options)
        let builtIn = try DocumentCreation.newDocument(from: .builtIn, replica: 0xB, now: Self.now)
        #expect(PageList(core.state).pages.map(\.rect) == PageList(builtIn.state).pages.map(\.rect))
        #expect(CreateDocument(.startingPoint(options)).label == "Created")
        #expect(StartingPoints.isBuiltIn(options))
    }

    @Test func blankTakesTheSizeOrientationUnitsAndColorMode() throws {
        var options = StartingPoints.defaults(for: .blank)
        options.size = Size(width: 595, height: 842)
        options.preset = "A4"
        options.orientation = .landscape
        options.units = .millimeters
        options.colorMode = .rgb
        let state = try Self.document(options).state
        let pages = PageList(state)
        #expect(pages.pages.count == 1 && pages.pages[0].geometry == PageGeometry(preset: "A4", portrait: Size(width: 595, height: 842), orientation: .landscape))
        #expect(pages.settings.units == .millimeters)
        #expect(SwatchList(state).swatches.count > 200, "web-safe swatches for RGB")
    }

    @Test func printHasBleedAndPrintMarksInCMYK() throws {
        let options = StartingPoints.defaults(for: .print)
        let state = try Self.document(options).state
        let pages = PageList(state)
        #expect(pages.pages.count == 1 && pages.pages[0].bleed == StartingPoints.printBleed)
        #expect(pages.settings.units == .inches)
        let print = DocumentPrintSettings(state)
        #expect(print.marks.isSuperset(of: [.crop, .registration]) && print.bleed == StartingPoints.printBleed)
        #expect(SwatchList(state).swatches.count < 10, "the process swatches only")
        #expect(CreateDocument(.startingPoint(options)).label == "Created from Print")
    }

    @Test func screenIsAnRGBDocumentInPixels() throws {
        let state = try Self.document(StartingPoints.defaults(for: .screen)).state
        let pages = PageList(state)
        #expect(pages.pages[0].geometry.width == 1920 && pages.pages[0].geometry.height == 1080)
        #expect(pages.settings.units == .pixels && pages.settings.printerResolution == 72)
        #expect(SwatchList(state).swatches.count > 200)
    }

    @Test func stationeryHasLetterheadEnvelopeAndCardPagesWithGuides() throws {
        let state = try Self.document(StartingPoints.defaults(for: .stationery)).state
        let pages = PageList(state).pages
        #expect(pages.map(\.geometry.size) == [Size(width: 612, height: 792), StartingPoints.envelope.size, StartingPoints.businessCard.size])
        #expect(pages.allSatisfy { $0.guides.count == 4 })
    }

    @Test func publicationHasFacingPagesAMasterAndFolioText() throws {
        var options = StartingPoints.defaults(for: .publication)
        options.pageCount = 5
        let state = try Self.document(options).state
        let list = PageList(state)
        #expect(list.pages.count == 5 && list.masters.count == 1 && list.masters[0].name == StartingPoints.masterName)
        #expect(list.pages.allSatisfy { $0.master == list.masters[0].id && $0.guides.count == 4 })
        // Page 1 alone on the right; 2 and 3 a spread below it, touching.
        let first = list.pages[0].rect, second = list.pages[1].rect, third = list.pages[2].rect
        #expect(second.maxX == third.minX && second.minY == third.minY && second.minY > first.maxY && first.minX == third.minX)
        let folio = MasterContent.objects(of: list.masters[0].id, in: state).flatMap(\.objects)
        #expect(folio.count == 1 && state.nodeKind(folio[0]) == .text)
        #expect(list.settings.units == .picas)
    }

    @Test func technicalHasAFineGridAndTechnicalStrokes() throws {
        let state = try Self.document(StartingPoints.defaults(for: .technical)).state
        let settings = PageList(state).settings
        #expect(settings.units == .picas && settings.grid.size == StartingPoints.technicalGrid)
        #expect(Set(StartingPoints.technicalWeights.map(\.name)).isSubset(of: Set(Self.styleNames(state))))
        #expect(DocumentDefaults.appearance(in: state).strokes.first?.settings.basic.width == 0.5)
    }

    @Test func invalidOptionsAreRefused() {
        var options = StartingPoints.defaults(for: .publication)
        options.pageCount = 0
        #expect(throws: StartingPoints.Failure.invalidPageCount) { try StartingPoints.state(for: options) }
        options = StartingPoints.defaults(for: .print)
        options.size = Size(width: 0, height: 10)
        #expect(throws: StartingPoints.Failure.invalidSize) { try StartingPoints.state(for: options) }
    }

    @Test func everyKindHasATitleSummaryAndDefaults() {
        for kind in StartingPoints.Kind.allCases {
            #expect(!kind.title.isEmpty && !kind.summary.isEmpty && kind.id == kind.rawValue)
            #expect(StartingPoints.defaults(for: kind).kind == kind)
        }
        #expect(StartingPoints.ColorMode.allCases.map(\.title) == ["CMYK", "RGB"])
    }
}
