import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// The print pipeline's model half (PRINT-003, PRINT-004's presets, PRINT-005, PRINT-008): the
/// print snapshot of a document -- pages, output area, bleed, ink list, object screens, path
/// flatness, zero points -- and presets written back as one change.
@Suite struct PrintSnapshotTests {
    /// A closed square at (`x`, `y`) of side `side` filled with `fill`.
    @discardableResult
    static func square(_ replica: inout Replica, x: Double, y: Double = 100, side: Double = 50, fill: Wiretuner_Doc_V1_ColorRef? = nil) throws -> OpID {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        var basic = Wiretuner_Doc_V1_Fill()
        basic.settings.kind = .basic
        if let fill { basic.settings.basic.color = fill } else { basic.settings.basic.color.inline = ColorValues.stored(.black) }
        appearance.fills = [basic]
        let points = [(x, y), (x + side, y), (x + side, y + side), (x, y + side)].map { VectorPoint(anchor: Point(x: $0.0, y: $0.1)) }
        return try replica.perform(CreatePath(contours: [NewContour(closed: true, points: points)], appearance: appearance))!.createdObjects[0]
    }

    static func capture(_ state: EngineState, source: PrintSnapshot.Source = .pages, range: ClosedRange<Int>? = nil, selection: Set<NodeID>? = nil) -> PrintRequest {
        PrintSnapshot.capture(state, request: PrintSnapshot.Request(name: "Job", source: source, pageRange: range, selection: selection,
                                                                    date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!),
                              builder: DocumentDisplayListBuilder(canvas: "print"))
    }

    static func spots(_ replica: inout Replica) throws -> (orange: OpID, gold: OpID, unused: OpID) {
        try replica.perform(CreateDefaultSwatches())
        let orange = try ColorFixture.add(&replica, Color(cyan: 0, magenta: 0.6, yellow: 1, black: 0), name: "Orange", spot: true)
        let unused = try ColorFixture.add(&replica, Color(cyan: 1, magenta: 1, yellow: 0, black: 0), name: "Violet", spot: true)
        let gold = try ColorFixture.add(&replica, Color(cyan: 0, magenta: 0.2, yellow: 0.8, black: 0.2), name: "Gold", spot: true)
        let resolver = SwatchList(replica.state).resolver
        try square(&replica, x: 50, fill: resolver.reference(to: gold))
        try square(&replica, x: 150, fill: resolver.reference(to: orange))
        return (orange, gold, unused)
    }

    @Test func aNewDocumentPrintsItsPageComposite() throws {
        var a = Replica(1)
        try Self.square(&a, x: 10)
        let request = Self.capture(a.state)
        #expect(request.scene.pages.count == 1 && request.scene.pages[0].bounds == Rect(x: 0, y: 0, width: 612, height: 792))
        #expect(request.options == PrintOptions(defaultScreen: HalftoneScreen(shape: .round, angle: 45, frequency: 60), plates: PrintPlate.process))
        #expect(request.zeroPoints[1] == Point(x: 0, y: 792) && request.source == .pages)
        #expect(PrintPlan(request).count == 1)
    }

    @Test func pagesAndRanges() throws {
        var a = Replica(1)
        try a.perform(AddPages(count: 2))
        let count = PageList(a.state).pages.count
        let request = Self.capture(a.state)
        #expect(count >= 3 && request.scene.pages.count == count && PrintPlan(request).count == count)
        #expect(PrintPlan(Self.capture(a.state, range: 2...2)).count == 1)
    }

    /// The ink list holds the spot inks the artwork uses in swatch order; separations print one
    /// sheet per printed plate, and a collaborator turning a plate off changes the count.
    @Test func separationsFollowTheInkList() throws {
        var pair = Pair()
        let spots = try Self.spots(&pair.a)
        try pair.a.perform(SetPrintSettings(.separations(true)))
        pair.sync()
        let request = Self.capture(pair.a.state)
        #expect(request.options.plates.map(\.name) == ["Cyan", "Magenta", "Yellow", "Black", "Orange", "Gold"])
        #expect(request.options.plates[4].ink == .spot(NodeID(spots.orange)))
        #expect(PrintPlan(request).count == 6)
        #expect(PrintSnapshot.inks(pair.a.state, lists: request.scene.pages.map(\.displayList)) == [.cyan, .magenta, .yellow, .black, .spot(spots.orange), .spot(spots.gold)])
        // Every spot swatch without lists (the preset's rows).
        #expect(PrintSnapshot.plates(DocumentPrintSettings(pair.a.state), state: pair.a.state, lists: nil).count == 7)
        try pair.b.perform(SetPlate(.yellow, print: false, in: pair.b.state))
        pair.sync()
        #expect(PrintPlan(Self.capture(pair.a.state)).count == 5)
        try pair.a.perform(SetPlate(.spot(spots.gold), angle: 30, frequency: 120, in: pair.a.state))
        try pair.a.perform(SetPrintSettings(.spotAsProcess(true)))
        let collapsed = Self.capture(pair.a.state)
        #expect(PrintPlan(collapsed).count == 3)
        #expect(collapsed.options.plates[5].angle == 30 && collapsed.options.plates[5].frequency == 120)
    }

    @Test func settingsReachThePlan() throws {
        var a = Replica(1)
        var halftone = Wiretuner_Doc_V1_Halftone()
        halftone.shape = .diamond
        halftone.frequency = 133
        try a.perform(SetPrintSettings([.scaleMode(.variable), .scaleX(50), .scaleY(80), .offset(Point(x: 4, y: 5)), .tile(.automatic), .tileOverlap(9),
                                        .printPageBoundary(true), .mark(.crop, true), .mark(.registration, true), .mark(.separationNames, true),
                                        .mark(.fileNameDate, true), .bleed(9), .emulsionDown(true), .negative(true), .flatness(2), .textAsOutlines(true),
                                        .rasterizeDPI(300), .defaultHalftone(halftone), .screenInApp(true), .ignoreObjectHalftones(true)]))
        let options = Self.capture(a.state).options
        #expect(options.scaleMode == .variable && options.scaleX == 50 && options.scaleY == 80 && options.offset == Point(x: 4, y: 5))
        #expect(options.tile == .automatic && options.tileOverlap == 9 && options.printPageBoundary && options.marks == .all && options.bleed == 9)
        #expect(options.emulsionDown && options.negative && options.flatness == 2 && options.textAsOutlines && options.rasterizeDPI == 300)
        #expect(options.defaultScreen == HalftoneScreen(shape: .diamond, angle: 45, frequency: 133) && options.screenInApp && options.ignoreObjectHalftones)
        try a.perform(SetPrintSettings([.scaleMode(.fit), .tile(.manual)]))
        #expect(Self.capture(a.state).options.tile == .none)
        try a.perform(SetPrintSettings([.scaleMode(.uniform), .tile(.none)]))
        #expect(Self.capture(a.state).options.scaleMode == .uniform)
    }

    /// Artwork reaching only into the bleed prints; the page keeps its rectangle.
    @Test func bleedArtworkIsCaptured() throws {
        var a = Replica(1)
        try Self.square(&a, x: -8, side: 6)
        #expect(Self.capture(a.state).scene.pages[0].displayList.isEmpty)
        try a.perform(SetPrintSettings(.bleed(9)))
        let request = Self.capture(a.state)
        #expect(!request.scene.pages[0].displayList.isEmpty && request.scene.pages[0].bounds == Rect(x: 0, y: 0, width: 612, height: 792))
    }

    @Test func selectedObjectsOnlyAndHiddenLayers() throws {
        var a = Replica(1)
        let kept = try Self.square(&a, x: 10)
        let dropped = try Self.square(&a, x: 100)
        let plan = PrintPlan(Self.capture(a.state, selection: [NodeID(kept)]))
        let ids = plan.pages[0].nestedNodeIDs.values
        #expect(ids.contains(NodeID(kept)) && !ids.contains(NodeID(dropped)))
        let layer = try LayerFixture.layers(["Notes"], on: &a)[0]
        var props = ExportSnapshotTests.rect(at: 300)
        props.rect.common.name = "Hidden note"
        let hidden = try ExportSnapshotTests.create(props, on: layer, &a)
        try a.perform(SetLayerFlag([layer], .visible, false))
        #expect(!Self.capture(a.state).scene.pages[0].nestedNodeIDs.values.contains(NodeID(hidden)))
        try a.perform(SetPrintSettings(.includeHiddenLayers(true)))
        #expect(Self.capture(a.state).scene.pages[0].nestedNodeIDs.values.contains(NodeID(hidden)))
    }

    @Test func theOutputAreaIsOneSheetWithPageOutlines() throws {
        var a = Replica(1)
        try Self.square(&a, x: 10)
        let area = Rect(x: 500, y: 700, width: 300, height: 200)
        let request = Self.capture(a.state, source: .outputArea(area))
        #expect(request.scene.pages.count == 1 && request.scene.pages[0].bounds == area && request.scene.pages[0].number == nil)
        #expect(request.source == .outputArea(pageOutlines: [Rect(x: 0, y: 0, width: 612, height: 792)]))
        #expect(PrintPlan(request).sheets[0].name == "Output area")
    }

    @Test func objectScreensAndPathFlatness() throws {
        var a = Replica(1)
        let path = try Self.square(&a, x: 10)
        let group = try Self.square(&a, x: 100)
        var halftone = Wiretuner_Doc_V1_Halftone()
        halftone.shape = .line
        halftone.angle = 15
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.common.halftone = halftone
        var flatness = Wiretuner_Doc_V1_NodeProps()
        flatness.path.flatness = 4
        try a.perform(OpsCommand("Screen", ops: [Ops.set(path, [RegisterPath([PathFields.kind, 1, 11])], values: props),
                                                 Ops.set(path, [PathFields.flatness], values: flatness)]))
        let screens = PrintSnapshot.objectScreens(a.state)
        #expect(screens[NodeID(path)] == ObjectScreen(shape: .line, angle: 15, frequency: nil) && screens[NodeID(group)] == nil)
        #expect(PrintSnapshot.pathFlatness(a.state) == [NodeID(path): 4])
        let request = Self.capture(a.state)
        #expect(request.objectScreens.count == 1 && request.pathFlatness.count == 1)
        #expect(PrintSnapshot.shape(.unspecified) == nil && PrintSnapshot.shape(.cross) == .cross)
    }

    // MARK: Presets

    @Test func presetsRestoreEveryPaneSettingInAnotherDocument() throws {
        var a = Replica(1)
        _ = try Self.spots(&a)
        var halftone = Wiretuner_Doc_V1_Halftone()
        halftone.shape = .ellipse
        halftone.frequency = 150
        try a.perform(SetPrintSettings([.separations(true), .bleed(18), .mark(.crop, true), .tile(.automatic), .tileOverlap(12), .negative(true),
                                        .includeHiddenLayers(true), .defaultHalftone(halftone)]))
        try a.perform(SetPlate(.magenta, print: false, angle: 70, frequency: 100, in: a.state))
        let (preset, hidden) = PrintPresets.preset(a.state)
        let dictionary = preset.dictionary(includeHiddenLayers: hidden)
        let read = try #require(PrintPreset.read(dictionary))

        var b = Replica(2)
        try b.perform(CreateDefaultSwatches())
        let orange = try ColorFixture.add(&b, Color(cyan: 0, magenta: 0.5, yellow: 1, black: 0), name: "Orange", spot: true)
        try b.perform(SetPlate(.cyan, frequency: 90, in: b.state))
        let change = try #require(try b.perform(ApplyPrintPreset(read.preset, includeHiddenLayers: read.includeHiddenLayers)))
        #expect(change.label == "Apply print preset")
        let restored = DocumentPrintSettings(b.state), original = DocumentPrintSettings(a.state)
        #expect(restored.separations && restored.bleed == 18 && restored.marks == [.crop] && restored.tile == .automatic && restored.tileOverlap == 12)
        #expect(restored.negative && restored.includeHiddenLayers && restored.defaultHalftone.shape == .ellipse && restored.defaultHalftone.frequency == 150)
        #expect(restored.plate(.magenta)?.print == false && restored.plate(.magenta)?.angle == 70 && restored.plate(.magenta)?.frequency == 100)
        #expect(restored.plate(.cyan)?.frequency == original.plate(.cyan)?.frequency ?? 0)
        #expect(restored.plate(.spot(orange))?.print == true)
        // Gold and Violet have no swatch here and are skipped.
        #expect(restored.plates.count == 5)
    }

    @Test func presetRowsEditEntriesDeleteDuplicatesAndSkipOddRows() throws {
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        pair.sync()
        try pair.a.perform(SetPlate(.black, frequency: 80, in: pair.a.state))
        try pair.b.perform(SetPlate(.black, angle: 30, in: pair.b.state))
        pair.sync()
        #expect(DocumentPrintSettings(pair.a.state).plate(.black)?.duplicates.count == 1)
        let rows = [PresetPlate(ink: .process(.black), print: true, angle: 40, frequency: 70), PresetPlate(ink: .process(.black), print: false, angle: 1, frequency: 1),
                    PresetPlate(ink: .process(.spot(NodeID(counter: 9, replica: 9))), print: true, angle: 0, frequency: 0),
                    PresetPlate(ink: .process(.cyan), print: true, angle: 400, frequency: 0), PresetPlate(ink: .spot("Nowhere"), print: true, angle: 0, frequency: 0)]
        let preset = try #require(PrintPreset.read(PrintPreset(options: PrintOptions()).dictionary(includeHiddenLayers: false))).preset
        var edited = preset
        edited.plates = rows
        try pair.a.perform(ApplyPrintPreset(edited, includeHiddenLayers: false))
        let black = try #require(DocumentPrintSettings(pair.a.state).plate(.black))
        #expect(black.duplicates.isEmpty && black.angle == 40 && black.frequency == 70 && black.print)
        #expect(DocumentPrintSettings(pair.a.state).plates.count == 1)
    }
}
