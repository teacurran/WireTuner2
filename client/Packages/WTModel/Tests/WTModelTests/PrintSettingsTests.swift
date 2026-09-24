import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// PRINT-002: the print settings commands, the plate list's read-time rules and the local-only
/// NSPrintInfo archive (printing.adoc, "Merge semantics").
@Suite struct PrintSettingsTests {
    static func pair(_ setup: (inout Replica) throws -> Void = { _ in }) throws -> Pair {
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        try setup(&pair.a)
        pair.sync()
        return pair
    }

    @Test func newDocumentsReadTheDefaults() {
        let settings = DocumentPrintSettings(EngineState())
        #expect(!settings.separations && settings.scaleMode == .uniform && settings.scaleX == 100 && settings.scaleY == 100)
        #expect(settings.tile == .none && settings.tileOverlap == 0 && settings.bleed == 0 && settings.marks.isEmpty)
        #expect(settings.plates.isEmpty && settings.printInfo == nil && settings.offset == .zero)
    }

    @Test func everySettingWritesOneLabelledChangeAndUndoes() throws {
        var a = Replica(1)
        var halftone = Wiretuner_Doc_V1_Halftone()
        halftone.shape = .ellipse
        halftone.frequency = 133
        let cases: [(PrintSetting, String)] = [
            (.separations(true), "Turn on separations"), (.scaleMode(.variable), "Change scaling"), (.scaleX(50), "Change scale"),
            (.scaleY(200), "Change scale"), (.offset(Point(x: 9, y: -3)), "Change offset"), (.tile(.automatic), "Change tiling"),
            (.tileOverlap(36), "Change tile overlap"), (.printPageBoundary(true), "Turn on page boundary"),
            (.mark(.crop, true), "Turn on crop marks"), (.mark(.registration, true), "Turn on registration marks"),
            (.mark(.separationNames, true), "Turn on separation names"), (.mark(.fileNameDate, true), "Turn on file name and date"),
            (.bleed(9), "Change bleed"), (.emulsionDown(true), "Turn on emulsion down"), (.negative(true), "Turn on negative"),
            (.includeHiddenLayers(true), "Turn on hidden layers"), (.flatness(3), "Change flatness"),
            (.textAsOutlines(true), "Turn on text as outlines"), (.rasterizeDPI(300), "Change rasterize resolution"),
            (.spotAsProcess(true), "Turn on spot colors as process"), (.defaultHalftone(halftone), "Change halftone screen"),
            (.screenInApp(true), "Turn on screening in app"), (.ignoreObjectHalftones(true), "Turn on ignore object screens"),
        ]
        for (setting, label) in cases {
            let command = SetPrintSettings(setting)
            #expect(command.label == label)
            let change = try #require(try a.perform(command))
            #expect(change.label == label && change.ops.count == 1)
        }
        let s = DocumentPrintSettings(a.state)
        #expect(s.separations && s.scaleMode == .variable && s.scaleX == 50 && s.scaleY == 200 && s.offset == Point(x: 9, y: -3))
        #expect(s.tile == .automatic && s.tileOverlap == 36 && s.printPageBoundary && s.marks == Set(DocumentPrintSettings.Mark.allCases))
        #expect(s.bleed == 9 && s.emulsionDown && s.negative && s.includeHiddenLayers && s.flatness == 3 && s.textAsOutlines)
        #expect(s.rasterizeDPI == 300 && s.spotAsProcess && s.defaultHalftone == halftone && s.screenInApp && s.ignoreObjectHalftones)
        // Undo of the bleed change restores the prior (unset) register.
        for _ in 0..<11 { a.undo() }
        #expect(DocumentPrintSettings(a.state).bleed == 0 && DocumentPrintSettings(a.state).marks.count == 4)
        #expect(!DocumentPrintSettings(a.state).emulsionDown)
        // Turning off.
        #expect(SetPrintSettings(.separations(false)).label == "Turn off separations")
        // A preset writes several registers in one change.
        let preset = try #require(try a.perform(SetPrintSettings([.bleed(18), .mark(.crop, false), .scaleMode(.fit)])))
        #expect(preset.label == "Apply print preset" && preset.ops.count == 1 && preset.ops[0].set.paths.count == 3)
        #expect(SetPrintSettings([.bleed(1)], label: "x").label == "Change bleed")
        #expect(try a.perform(SetPrintSettings([])) == nil)
        #expect(DocumentPrintSettings(a.state).scaleMode == .fit && !DocumentPrintSettings(a.state).marks.contains(.crop))
    }

    @Test func outOfRangeValuesAreRefused() {
        var a = Replica(1)
        var badScreen = Wiretuner_Doc_V1_Halftone()
        badScreen.frequency = 700
        let refused: [PrintSetting] = [.scaleX(0), .scaleY(2001), .offset(Point(x: .nan, y: 0)), .tileOverlap(-1), .bleed(721), .flatness(101),
                                       .rasterizeDPI(50), .rasterizeDPI(.infinity), .defaultHalftone(badScreen)]
        for setting in refused {
            #expect(throws: PrintSettingsError.self) { try a.perform(SetPrintSettings(setting)) }
        }
        #expect(throws: Never.self) { try a.perform(SetPrintSettings(.rasterizeDPI(0))) }
    }

    @Test func readTimeNormalizations() throws {
        var a = Replica(1)
        // Values another client wrote out of range (or never wrote) read as the defaults.
        try a.perform(OpsCommand("Raw", ops: [Ops.set(WellKnown.settings, [PrintFields.field(3), PrintFields.field(4), PrintFields.field(7),
                                                                           PrintFields.field(10), PrintFields.field(2), PrintFields.field(6)],
                                                      values: PrintFields.values {
                                                          $0.scaleX = 5000
                                                          $0.scaleY = 0.5
                                                          $0.tileOverlap = -4
                                                          $0.bleed = -9
                                                          $0.scaleMode = .fit
                                                          $0.tile = .manual
                                                      })]))
        let s = DocumentPrintSettings(a.state)
        #expect(s.scaleX == 100 && s.scaleY == 100 && s.tileOverlap == 0 && s.bleed == 0 && s.tile == .none)
        try a.perform(SetPrintSettings(.scaleMode(.uniform)))
        #expect(DocumentPrintSettings(a.state).tile == .manual)
    }

    @Test func platesAreCreatedOnFirstTouchAndEditedAfter() throws {
        var a = Replica(1)
        try a.perform(CreateDefaultSwatches())
        let spot = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape", spot: true)
        let process = try ColorFixture.add(&a, ColorFixture.plum, name: "Plum")
        let off = SetPlate(.magenta, print: false, in: a.state)
        #expect(off.label == "Turn off Magenta plate")
        let created = try #require(try a.perform(off))
        #expect(created.ops.count == 1 && created.ops[0].elementInsert.values.settings.print.plates.count == 1)
        var magenta = try #require(DocumentPrintSettings(a.state).plate(.magenta))
        #expect(!magenta.print && magenta.angle == 75 && !magenta.angleWritten && magenta.frequency == 0)
        let screen = try #require(try a.perform(SetPlate(.magenta, angle: 30, frequency: 150, in: a.state)))
        #expect(screen.label == "Change Magenta plate screen" && screen.ops.count == 1 && screen.ops[0].set.paths.count == 2)
        magenta = try #require(DocumentPrintSettings(a.state).plate(.magenta))
        #expect(magenta.angle == 30 && magenta.angleWritten && magenta.frequency == 150 && !magenta.print)
        #expect(try a.perform(SetPlate(.magenta, in: a.state)) == nil)
        // A first touch of a screen writes print true.
        try a.perform(SetPlate(.spot(spot), frequency: 85, in: a.state))
        let grape = try #require(DocumentPrintSettings(a.state).plate(.spot(spot)))
        #expect(grape.print && grape.frequency == 85 && grape.angle == 45)
        #expect(SetPlate(.spot(spot), print: true, in: a.state).label == "Turn on Grape plate")
        for ink in [PrintInk.cyan, .yellow, .black] { try a.perform(SetPlate(ink, print: true, in: a.state)) }
        #expect(DocumentPrintSettings(a.state).plates.map(\.ink) == [.cyan, .magenta, .yellow, .black, .spot(spot)])
        #expect([PrintInk.cyan, .yellow, .black].map { $0.name(in: a.state) } == ["Cyan", "Yellow", "Black"])
        #expect([PrintInk.cyan, .yellow].map(\.defaultAngle) == [15, 0])
        // Refusals: a process swatch, a missing node, bad values.
        #expect(throws: PrintSettingsError.notAnInk) { try a.perform(SetPlate(.spot(process), print: true, in: a.state)) }
        #expect(throws: PrintSettingsError.notAnInk) { try a.perform(SetPlate(.spot(.wellKnown(99)), print: true, in: a.state)) }
        #expect(PrintInk.spot(.wellKnown(99)).name(in: a.state) == "spot")
        #expect(throws: PrintSettingsError.invalidValue("angle")) { try a.perform(SetPlate(.cyan, angle: 400, in: a.state)) }
        #expect(throws: PrintSettingsError.invalidValue("frequency")) { try a.perform(SetPlate(.cyan, frequency: -1, in: a.state)) }
        // Undo removes the entry again.
        a.undo()
        a.undo()
        a.undo()
        #expect(DocumentPrintSettings(a.state).plate(.cyan) == nil)
    }

    @Test func ignoredPlateEntries() throws {
        var a = Replica(1)
        try a.perform(CreateDefaultSwatches())
        let spot = try ColorFixture.add(&a, ColorFixture.grape, name: "Grape", spot: true)
        func entry(_ build: (inout Wiretuner_Doc_V1_Ink) -> Void) -> Wiretuner_Doc_V1_PlateSettings {
            var plate = Wiretuner_Doc_V1_PlateSettings()
            build(&plate.ink)
            plate.print = true
            return plate
        }
        let entries = [entry { $0.process = .unspecified }, entry { _ in }, entry { $0.spot.id = spot.proto }]
        let keys = try PathEditing.keys(between: nil, and: nil, count: entries.count)
        try a.perform(OpsCommand("Raw", ops: [Ops.elementInsert(WellKnown.settings, PrintFields.plates, positions: keys,
                                                                values: PrintFields.values { $0.plates = entries })]))
        #expect(DocumentPrintSettings(a.state).plates.map(\.ink) == [.spot(spot)])
        // The swatch turned process, then removed: the entry is ignored; restoring brings it back.
        try a.perform(OpsCommand("Process", ops: [Ops.set(spot, [SwatchFields.spot], values: SwatchFields.values { $0.spot = false })]))
        #expect(DocumentPrintSettings(a.state).plates.isEmpty)
        a.undo()
        try a.perform(RemoveSwatches([spot]))
        #expect(DocumentPrintSettings(a.state).plates.isEmpty)
        a.undo()
        #expect(DocumentPrintSettings(a.state).plate(.spot(spot))?.print == true)
    }

    @Test func concurrentFirstTouchesOfOneSpotInkConvergeOnTheSmallestElement() throws {
        var spot = OpID.zero
        var pair = try Self.pair { spot = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape", spot: true) }
        try pair.a.perform(SetPlate(.spot(spot), frequency: 120, in: pair.a.state))
        try pair.b.perform(SetPlate(.spot(spot), angle: 20, in: pair.b.state))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let a = try #require(DocumentPrintSettings(pair.a.state).plate(.spot(spot)))
        #expect(DocumentPrintSettings(pair.b.state).plates == DocumentPrintSettings(pair.a.state).plates)
        #expect(a.duplicates.count == 1 && a.element < a.duplicates[0])
        let elements = pair.a.state.liveElements(WellKnown.settings, PrintFields.plates)
        #expect(elements.count == 2 && a.element == elements.min())
        // The next local edit of the row deletes the duplicate in the same change.
        let edit = try #require(try pair.b.perform(SetPlate(.spot(spot), print: false, in: pair.b.state)))
        #expect(edit.ops.count == 2)
        pair.sync()
        let merged = try #require(DocumentPrintSettings(pair.a.state).plate(.spot(spot)))
        #expect(merged.duplicates.isEmpty && !merged.print && pair.a.state.liveElements(WellKnown.settings, PrintFields.plates).count == 1)
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func concurrentFrequencyAndPrintEditsOnOnePlateBothSurvive() throws {
        var pair = try Self.pair { try $0.perform(SetPlate(.cyan, print: true, in: $0.state)) }
        try pair.a.perform(SetPlate(.cyan, frequency: 175, in: pair.a.state))
        try pair.b.perform(SetPlate(.cyan, print: false, in: pair.b.state))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let cyan = try #require(DocumentPrintSettings(pair.a.state).plate(.cyan))
        #expect(cyan.frequency == 175 && !cyan.print)
    }

    @Test func concurrentBleedsResolveByOpIDWithTheLoserRetained() throws {
        var pair = try Self.pair()
        try pair.a.perform(SetPrintSettings(.bleed(9)))
        try pair.b.perform(SetPrintSettings(.bleed(18)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(DocumentPrintSettings(pair.a.state).bleed == 18)
        #expect(pair.a.state.store.losingWrites(WellKnown.settings, PrintFields.field(10)).count == 1)
    }

    @Test func thePrintInfoArchiveStaysOnThisMac() throws {
        var pair = try Self.pair()
        let archive = Data("NSPrintInfo archive".utf8)
        let change = try #require(try pair.a.perform(SetPrintInfo(archive)))
        #expect(change.label == "Page Setup")
        #expect(DocumentPrintSettings(pair.a.state).printInfo == archive)
        let sent = try #require(pair.a.sent.last)
        #expect(sent.ops.allSatisfy { $0.set.values.settings.printInfo.isEmpty && !$0.set.paths.map(RegisterPath.init).contains(PrintFields.printInfo) })
        pair.sync()
        #expect(DocumentPrintSettings(pair.b.state).printInfo == nil)
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        try pair.a.perform(SetPrintInfo(nil))
        #expect(DocumentPrintSettings(pair.a.state).printInfo == nil)
        #expect(throws: PrintSettingsError.invalidValue("print info")) { try pair.a.perform(SetPrintInfo(Data(count: 262_145))) }
    }
}
