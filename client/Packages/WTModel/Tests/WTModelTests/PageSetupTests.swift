import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Test fixtures for the document setup chapter.
enum PageFixture {
    /// A replica whose synthesized page has been written (one real Letter page at the origin).
    static func onePage(_ replica: inout Replica) throws -> OpID {
        try replica.perform(SetBleed([PageList.synthesizedID], to: 0))
        return PageList(replica.state).pages[0].id
    }

    /// A rectangle of `size` with its top-left at `origin`.
    @discardableResult
    static func rect(_ replica: inout Replica, at origin: Point, size: Double = 10) throws -> OpID {
        try replica.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: size, height: size),
                                        transform: .translation(x: origin.x, y: origin.y)))!.createdObjects[0]
    }

    static func later(_ a: Wiretuner_Doc_V1_Change, _ b: Wiretuner_Doc_V1_Change) -> Bool {
        OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
    }
}

/// DOC-002: the typed page, master and settings views, their read-time normalizations, the
/// Document panel's commands and the objects-on-page query (document-panel.adoc).
@Suite struct PageSetupTests {
    @Test func emptyDocumentReadsAsOneLetterPageAndDefaults() {
        let state = EngineState()
        let list = PageList(state)
        #expect(list.isSynthesized)
        let page = list.pages[0]
        #expect(page.id == PageList.synthesizedID && page.number == 1 && page.origin == .zero)
        #expect(page.geometry == .letter && page.bleed == 0 && !page.isChild)
        #expect(page.rulerOrigin == Point(x: 0, y: 792))
        #expect(page.zeroPoint == Point(x: 0, y: 792))
        #expect(list.bounds == Rect(x: 0, y: 0, width: 612, height: 792))
        let settings = DocumentSettings(state)
        #expect(settings.units == .points && settings.printerResolution == 300)
        #expect(settings.grid == GridSettings(size: 12, relative: false))
        #expect(settings.customPageSizes.isEmpty && settings.customUnits.isEmpty && !settings.guidesLocked)
        #expect(settings.presetNames == ["Letter", "Legal", "Tabloid", "A3", "A4", "A5", "B4", "B5"])
        #expect(settings.unitConverter.documentUnit == .points)
    }

    @Test func presetsAndGeometry() {
        let a4 = PagePreset.named("A4")!
        #expect(abs(a4.width - 595.2756) < 1e-3 && abs(a4.height - 841.8898) < 1e-3)
        #expect(PagePreset.named("Nope") == nil)
        let landscape = PageGeometry(a4, orientation: .landscape)
        #expect(landscape.width > landscape.height && landscape.preset == "A4")
        #expect(landscape.oriented(.portrait) == PageGeometry(a4))
        #expect(landscape.oriented(.landscape) == landscape)
        #expect(PageGeometry(width: 10, height: 5).orientation == .landscape)
        #expect(PageGeometry(width: 5, height: 5).orientation == .portrait)
        #expect(!PageGeometry(width: 0, height: 5).isValid && !PageGeometry(width: 20_000, height: 5).isValid)
        var stored = Wiretuner_Doc_V1_PageGeometry()
        stored.width = 100
        stored.height = 50
        #expect(PageGeometry(stored).orientation == .landscape)
        stored.orientation = .portrait
        #expect(PageGeometry(stored).orientation == .portrait)
        #expect(PageGeometry(PageGeometry.letter.stored) == .letter)
        #expect(PageGeometry.letter.size == Size(width: 612, height: 792))
    }

    @Test func commandsEmitOneLabelledChangeAndUndo() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let cases: [(any Command, String)] = [
            (SetPageGeometry([page], to: PageGeometry(PagePreset.named("A4")!)), "Change page size"),
            (SetPageOrientation([page], to: .landscape), "Change orientation"),
            (SetBleed([page], to: 9), "Change bleed"),
            (SetPrinterResolution(1200), "Change printer resolution"),
            (SetUnits(.millimeters), "Change units"),
            (SetGrid(size: 36, relative: true), "Change grid"),
            (SetGuidesLocked(true), "Lock guides"),
            (SetRulerOrigin(page, to: Point(x: 10, y: 20)), "Move zero point"),
            (AddCustomPageSize(name: "Card", size: Size(width: 252, height: 144)), "Add page size"),
            (AddCustomUnit(name: "agate", amount: 5.25, base: .points), "Add unit"),
        ]
        for (command, label) in cases {
            let before = PageList(a.state)
            let change = try #require(try a.perform(command))
            #expect(change.label == label)
            #expect(PageList(a.state) != before)
            a.undo()
            #expect(PageList(a.state) == before, "\(label) undo")
            try a.perform(command)
        }
        let list = PageList(a.state)
        let settings = list.settings
        #expect(list.pages[0].geometry.orientation == .landscape && list.pages[0].geometry.preset == "A4")
        #expect(list.pages[0].bleed == 9 && list.pages[0].rulerOrigin == Point(x: 10, y: 20))
        #expect(settings.printerResolution == 1200 && settings.units == .millimeters && settings.guidesLocked)
        #expect(settings.grid == GridSettings(size: 36, relative: true))
        #expect(settings.customPageSizes.map(\.name) == ["Card"] && settings.customUnits.map(\.name) == ["agate"])
        #expect(SetGuidesLocked(false).label == "Unlock guides")
        #expect(SetRulerOrigin(page, to: nil).label == "Reset zero point")
        try a.perform(SetRulerOrigin(page, to: nil))
        #expect(PageList(a.state).pages[0].rulerOrigin == Point(x: 0, y: PageList(a.state).pages[0].geometry.height))
    }

    @Test func invalidValuesAreRefused() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let refused: [any Command] = [
            SetPageGeometry([page], to: PageGeometry(width: 0, height: 10)),
            SetBleed([page], to: 721), SetBleed([page], to: -1), SetBleed([page], to: .nan),
            SetPrinterResolution(71), SetPrinterResolution(9601),
            SetUnits(.custom(OpID(counter: 99, replica: 9))),
            SetGrid(size: 0), SetGrid(size: 7201),
            SetRulerOrigin(page, to: Point(x: .infinity, y: 0)),
            AddCustomPageSize(name: "Bad", size: Size(width: 0, height: 1)),
            AddCustomUnit(name: "u", amount: 0, base: .points), AddCustomUnit(name: "u", amount: 1, base: .custom(page)),
            EditCustomPageSize(OpID(counter: 99, replica: 9), name: "x"),
            RemoveCustomPageSize(OpID(counter: 99, replica: 9)),
            EditCustomUnit(OpID(counter: 99, replica: 9), name: "x"), RemoveCustomUnit(OpID(counter: 99, replica: 9)),
            SetBleed([OpID(counter: 99, replica: 9)], to: 1),
        ]
        for command in refused {
            #expect(throws: (any Error).self) { try a.perform(command) }
        }
        // Nothing to write writes nothing.
        #expect(try a.perform(SetGrid()) == nil)
    }

    @Test func customSizesEditFollowAndDeleteNormalizes() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(AddCustomPageSize(name: "Card", size: Size(width: 252, height: 144)))
        let card = DocumentSettings(a.state).customPageSizes[0]
        #expect(card.size == Size(width: 252, height: 144))
        try a.perform(SetPageGeometry([page], to: PageGeometry(preset: "Card", portrait: card.size, orientation: .landscape)))
        #expect(PageList(a.state).pages[0].geometry == PageGeometry(preset: "Card", width: 252, height: 144, orientation: .landscape))
        #expect(DocumentSettings(a.state).portraitSize(of: "Card") == card.size)
        // Rename and resize: the page follows, keeping its orientation.
        try a.perform(EditCustomPageSize(card.id, name: "Postcard", size: Size(width: 288, height: 432)))
        #expect(PageList(a.state).pages[0].geometry == PageGeometry(preset: "Postcard", width: 432, height: 288, orientation: .landscape))
        #expect(try a.perform(EditCustomPageSize(card.id, name: "Postcard")) == nil)
        // Delete: the page keeps its size and reads as Custom; restore brings the name back.
        try a.perform(RemoveCustomPageSize(card.id))
        let custom = PageList(a.state).pages[0].geometry
        #expect(custom.preset == "" && custom.width == 432 && custom.height == 288)
        a.undo()
        #expect(PageList(a.state).pages[0].geometry.preset == "Postcard")
        #expect(DocumentSettings(a.state).portraitSize(of: "Letter") == Size(width: 612, height: 792))
        #expect(DocumentSettings(a.state).portraitSize(of: "Nope") == nil)
    }

    @Test func editedSizeIsFollowedByMastersAndOnlyTheFirstOfDuplicateNames() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(AddCustomPageSize(name: "Card", size: Size(width: 252, height: 144)))
        try a.perform(AddCustomPageSize(name: "Card", size: Size(width: 100, height: 100)))
        let sizes = DocumentSettings(a.state).customPageSizes
        try a.perform(NewMasterPage(from: page))
        let master = PageList(a.state).masters[0].id
        try a.perform(SetPageGeometry([master], to: PageGeometry(preset: "Card", portrait: sizes[0].size)))
        #expect(throws: PageSetupError.invalidValue("size")) { try a.perform(EditCustomPageSize(sizes[0].id, size: Size(width: -1, height: 1))) }
        // Editing the duplicate (not the one the name reads as) writes only the element.
        let duplicate = try #require(try a.perform(EditCustomPageSize(sizes[1].id, size: Size(width: 90, height: 90))))
        #expect(duplicate.ops.count == 1)
        try a.perform(EditCustomPageSize(sizes[0].id, size: Size(width: 300, height: 200)))
        #expect(PageList(a.state).master(master)?.geometry == PageGeometry(preset: "Card", width: 200, height: 300, orientation: .portrait))
        // Named pages export with their names.
        try a.perform(RenamePage(page, to: "Cover"))
        #expect(PageList(a.state).exportPages[0].name == "Cover")
        let unknown = PageObjectIndex(objects: [], pages: PageList(a.state))
        #expect(unknown.pasteboardObjects(among: [NodeID(counter: 5, replica: 5)]).isEmpty && unknown.count == 0)
    }

    @Test func customUnitsEditAndDanglingUnitReadsAsPoints() throws {
        var a = Replica(0xA)
        try a.perform(AddCustomUnit(name: "agate", amount: 5.25, base: .points))
        let agate = DocumentSettings(a.state).customUnits[0]
        try a.perform(SetUnits(.custom(agate.id)))
        #expect(DocumentSettings(a.state).units == .custom(agate.id))
        try a.perform(EditCustomUnit(agate.id, name: "ag", amount: 2, base: .picas))
        let edited = DocumentSettings(a.state).customUnits[0]
        #expect(edited.name == "ag" && edited.amount == 2 && edited.base == .picas && edited.pointsPerUnit == 24)
        #expect(throws: PageSetupError.invalidValue("amount")) { try a.perform(EditCustomUnit(agate.id, amount: 0, base: .points)) }
        #expect(throws: PageSetupError.invalidValue("base")) { try a.perform(EditCustomUnit(agate.id, amount: 1, base: .custom(agate.id))) }
        #expect(try a.perform(EditCustomUnit(agate.id)) == nil)
        try a.perform(RemoveCustomUnit(agate.id))
        #expect(DocumentSettings(a.state).units == .points)
        #expect(EditCustomUnit(agate.id).label == "Change unit" && RemoveCustomUnit(agate.id).label == "Remove unit")
    }

    @Test func childPagesAreMaskedAndSkipped() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page))
        let master = try #require(PageList(a.state).masters.first)
        #expect(master.name == "Master 1" && master.rect == Rect(x: 0, y: 0, width: 612, height: 792))
        try a.perform(SetPageGeometry([master.id], to: PageGeometry(PagePreset.named("A5")!)))
        try a.perform(SetBleed([master.id], to: 18))
        try a.perform(SetPageOrientation([master.id], to: .landscape))
        try a.perform(ApplyMasterPage(master.id, to: [page]))
        var read = PageList(a.state).pages[0]
        #expect(read.isChild && read.geometry.preset == "A5" && read.geometry.orientation == .landscape && read.bleed == 18)
        #expect(read.ownGeometry == .letter && read.ownBleed == 0)
        // Geometry, bleed and orientation commands skip a child; rotate refuses it.
        #expect(try a.perform(SetPageGeometry([page], to: .letter)) == nil)
        #expect(try a.perform(SetBleed([page], to: 3)) == nil)
        #expect(try a.perform(SetPageOrientation([page], to: .portrait)) == nil)
        #expect(try a.perform(SetPageOrientation([master.id], to: .landscape)) == nil)
        #expect(throws: PageSetupError.childOfMaster(page)) { try a.perform(RotatePages([page])) }
        // Deleting the master: the page reads ordinary with its own registers.
        try a.perform(DeleteMasterPage(master.id))
        read = PageList(a.state).pages[0]
        #expect(!read.isChild && read.geometry == .letter)
    }

    @Test func normalizationsOfStoredValues() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        // A preset naming no size reads as Custom; an out-of-range geometry reads as Letter-sized.
        var geometry = PageGeometry.letter
        geometry.preset = "From a template"
        try a.perform(OpsCommand("raw", ops: [Ops.set(page, [PageFields.geometry], values: PageFields.values { $0.geometry = geometry.stored })]))
        #expect(PageList(a.state).pages[0].geometry.preset == "")
        var broken = Wiretuner_Doc_V1_PageGeometry()
        broken.width = -1
        try a.perform(OpsCommand("raw", ops: [Ops.set(page, [PageFields.geometry], values: PageFields.values { $0.geometry = broken })]))
        #expect(PageList(a.state).pages[0].geometry.size == Size(width: 612, height: 792))
        // Out-of-range bleed clamps; a master reference to a page reads unset.
        try a.perform(OpsCommand("raw", ops: [Ops.set(page, [PageFields.bleed, PageFields.master], values: PageFields.values {
            $0.bleed = 5000
            $0.master.id = page.proto
        })]))
        #expect(PageList(a.state).pages[0].bleed == 720 && !PageList(a.state).pages[0].isChild)
        #expect(PageList.bleed(.nan) == 0 && PageList.bleed(-4) == 0)
        // A custom unit choice without a live element reads as points; an unset element too.
        var settings = Wiretuner_Doc_V1_SettingsProps()
        settings.units.unit = .custom
        #expect(DocumentSettings(settings).units == .points)
        settings.units.unit = .kyus
        settings.grid.size = .infinity
        #expect(DocumentSettings(settings).units == .kyus && DocumentSettings(settings).grid.size == 12)
    }

    @Test func pageQueriesAndRenderInputs() throws {
        var a = Replica(0xA)
        let first = try PageFixture.onePage(&a)
        try a.perform(AddPages(count: 2))
        try a.perform(SetBleed([first], to: 9))
        let list = PageList(a.state)
        #expect(list.pages.map(\.number) == [1, 2, 3])
        let second = list.pages[1]
        #expect(second.origin == Point(x: 612 + 72, y: 0))
        #expect(list.number(of: second.id) == 2 && list.page(number: 3)?.id == list.pages[2].id && list.page(number: 4) == nil)
        #expect(list.page(containing: Point(x: -5, y: 10))?.id == first)
        #expect(list.page(containing: Point(x: 650, y: 10)) == nil)
        #expect(list.page(ofBounds: Rect(x: 700, y: 10, width: 20, height: 20))?.id == second.id)
        #expect(list.pages(intersecting: Rect(x: 600, y: 0, width: 100, height: 10)).map(\.number) == [1, 2])
        #expect(list[OpID(counter: 99, replica: 9)] == nil && list.master(first) == nil)
        let frames = list.frames(active: second.id, presence: [first: [.black]])
        #expect(frames.map(\.isActive) == [false, true, false] && frames[0].presence == [.black] && frames[0].bleed == 9)
        #expect(list.exportPages.map(\.bounds) == list.pages.map(\.rect) && list.exportPages[0].bleed == 9)
        #expect(list.grid().origin == Point(x: 0, y: 792) && list.grid(on: second).origin == Point(x: 684, y: 792))
        #expect(list.grid().size == 12 && !list.grid().relative)
    }

    @Test func mergeConcurrentGeometryLaterWinsWholeAndLoserIsKept() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        pair.sync()
        let a = try #require(try pair.a.perform(SetPageGeometry([page], to: PageGeometry(PagePreset.named("A4")!, orientation: .landscape))))
        let b = try #require(try pair.b.perform(SetPageGeometry([page], to: PageGeometry(PagePreset.named("Legal")!))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let winner = PageList(pair.a.state).pages[0].geometry
        #expect(winner == (PageFixture.later(a, b) ? PageGeometry(PagePreset.named("A4")!, orientation: .landscape) : PageGeometry(PagePreset.named("Legal")!)))
        // The losing replica's write stays in the register's log.
        let losing = pair.a.state.store.losingWrites(page, PageFields.geometry)
        #expect(!losing.isEmpty)
    }

    @Test func mergeBleedAndGeometryBothApplyAndCustomSizesKeepBoth() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        try pair.a.perform(AddCustomPageSize(name: "Card", size: Size(width: 252, height: 144)))
        pair.sync()
        let card = DocumentSettings(pair.a.state).customPageSizes[0].id
        try pair.a.perform(SetBleed([page], to: 9))
        try pair.b.perform(SetPageGeometry([page], to: PageGeometry(PagePreset.named("A4")!)))
        try pair.a.perform(EditCustomPageSize(card, name: "Postcard"))
        try pair.b.perform(EditCustomPageSize(card, size: Size(width: 300, height: 400)))
        try pair.a.perform(AddCustomPageSize(name: "One", size: Size(width: 10, height: 10)))
        try pair.b.perform(AddCustomPageSize(name: "Two", size: Size(width: 10, height: 10)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let list = PageList(pair.a.state)
        #expect(list.pages[0].bleed == 9 && list.pages[0].geometry.preset == "A4")
        let sizes = list.settings.customPageSizes
        #expect(sizes.count == 3 && sizes[0].name == "Postcard" && sizes[0].size == Size(width: 300, height: 400))
        #expect(Set(sizes.map(\.name)) == ["Postcard", "One", "Two"])
    }

    @Test func objectsOnPageFromStateAndIndex() throws {
        var a = Replica(0xA)
        let first = try PageFixture.onePage(&a)
        try a.perform(AddPages(count: 1))
        try a.perform(SetBleed([first], to: 36))
        let inside = try PageFixture.rect(&a, at: Point(x: 100, y: 100))
        let inBleed = try PageFixture.rect(&a, at: Point(x: 615, y: 100))
        let second = try PageFixture.rect(&a, at: Point(x: 700, y: 100))
        let pasteboard = try PageFixture.rect(&a, at: Point(x: 100, y: 2000))
        let list = PageList(a.state)
        let onFirst = PageObjects.objects(on: list.pages[0], in: a.state, pages: list).map(\.id)
        #expect(onFirst == [inside, inBleed])
        #expect(PageObjects.objects(on: list.pages[1], in: a.state, pages: list).map(\.id) == [second])
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let index = PageObjectIndex(scene: scene, pages: list)
        #expect(index.count == 4)
        #expect(Set(index.objects(on: list.pages[0])) == [NodeID(inside), NodeID(inBleed)])
        #expect(index.objects(on: list.pages[1]) == [NodeID(second)])
        #expect(index.page(of: NodeID(second))?.id == list.pages[1].id && index.page(of: NodeID(pasteboard)) == nil)
        #expect(index.pasteboardObjects(among: scene.topLevel) == [NodeID(pasteboard)])
    }

    @Test func overlappingBleedsGiveObjectsToTheLowerPage() throws {
        let pages = try overlapping()
        let index = PageObjectIndex(objects: [(NodeID(counter: 1, replica: 1), Rect(x: 600, y: 10, width: 10, height: 10)),
                                              (NodeID(counter: 2, replica: 1), Rect(x: 650, y: 10, width: 10, height: 10)),
                                              (NodeID(counter: 3, replica: 1), Rect(x: .nan, y: 0, width: 1, height: 1))], pages: pages)
        #expect(index.count == 2)
        #expect(index.objects(on: pages.pages[0]) == [NodeID(counter: 1, replica: 1)])
        #expect(index.objects(on: pages.pages[1]) == [NodeID(counter: 2, replica: 1)])
    }

    /// Two pages whose bleed rectangles overlap (page 2 starts at x = 620, bleeds 36).
    func overlapping() throws -> PageList {
        var a = Replica(0xA)
        let first = try PageFixture.onePage(&a)
        try a.perform(AddPages(count: 1))
        let second = PageList(a.state).pages[1].id
        try a.perform(MovePage(second, by: Vector(dx: 620 - 684, dy: 0), withContents: false))
        try a.perform(SetBleed([first, second], to: 36))
        return PageList(a.state)
    }

    @Test func objectsOnPageQueryOf50000ObjectsIsFast() throws {
        var a = Replica(0xA)
        _ = try PageFixture.onePage(&a)
        try a.perform(AddPages(count: 3))
        let pages = PageList(a.state)
        var objects: [(NodeID, Rect)] = []
        var generator = SplitMix64(seed: 42)
        for index in 0..<50_000 {
            let x = Double.random(in: -200...3200, using: &generator)
            let y = Double.random(in: -200...1000, using: &generator)
            objects.append((NodeID(counter: UInt64(index + 1), replica: 1), Rect(x: x, y: y, width: 20, height: 20)))
        }
        let index = PageObjectIndex(objects: objects, pages: pages)
        var total = 0
        let clock = ContinuousClock()
        var worst = Duration.zero
        for page in pages.pages {
            let started = clock.now
            total += index.objects(on: page).count
            worst = max(worst, clock.now - started)
        }
        let expected = objects.filter { pages.page(ofBounds: $0.1) != nil }.count
        #expect(total == expected)
        PerfBudget.expect(worst, within: .milliseconds(5), "objects on page, 50,000 objects")
    }
}

