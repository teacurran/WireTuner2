import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// The review rows DOC-031 and FONT-029's scenarios found missing (pages.adoc, grid-guides.adoc,
/// glyph-grid.adoc, kerning-metrics.adoc, typeface-documents.adoc, "Merge semantics"): objects made
/// on a removed page or glyph, zero pages, a guide deleted while moved, the typeface collisions, and
/// the settings node listed only for a conflict of its own.
@Suite struct SetupAndFontReviewTests {
    static func square(at point: Point) -> CreateShape {
        CreateShape(.rectangle(CornerRadii.uniform(0)), size: Size(width: 20, height: 20), transform: .translation(x: point.x, y: point.y))
    }

    /// Three pages on both sides.
    static func pages(_ world: inout Reconnect) throws -> [Page] {
        try world.shared(AddPages(count: 2))
        return PageList(world.theirs.state).pages
    }

    // MARK: Pages

    @Test func anObjectDrawnOnARemovedPageIsListedWithRestorePage() throws {
        var world = Reconnect()
        let pages = try Self.pages(&world)
        let third = pages[2]
        let mine = try #require(try world.byMe(Self.square(at: Point(x: third.rect.midX, y: third.rect.midY)))?.createdObjects.first)
        try world.byMe(Self.square(at: Point(x: pages[0].rect.midX, y: pages[0].rect.midY)))
        try world.byThem(RemovePages([third.id]))
        let divergence = world.measure()
        let row = try #require(divergence.removedTargets.first)
        #expect(divergence.removedTargets.count == 1 && row.kind == .removedPage && row.object == mine && row.target == third.id)
        #expect(row.authors == [world.theirs.replica] && row.choices == [.restore] && row.kind.title == "Created on a page that was removed")
        #expect(try row.command(.release, in: world.mine.state) == nil)
        let restore = try #require(try row.command(.restore, in: world.mine.state))
        #expect(restore.label == "Restore Page")
        try world.byMe(restore)
        #expect(PageList(world.mine.state)[third.id] != nil)
        world.upload()
    }

    @Test func aPageRemovedHereWithObjectsDrawnThereIsListedToo() throws {
        var world = Reconnect()
        let pages = try Self.pages(&world)
        try world.byMe(RemovePages([pages[1].id]))
        let theirs = try #require(try world.byThem(Self.square(at: Point(x: pages[1].rect.midX, y: pages[1].rect.midY)))?.createdObjects.first)
        let rows = world.measure().removedTargets
        #expect(rows.map(\.kind) == [.removedPage] && rows[0].object == theirs && rows[0].authors == [world.mine.replica])
    }

    @Test func zeroPagesIsListedWithoutHoldingTheOutbox() throws {
        var world = Reconnect()
        try world.shared(AddPages(count: 1))
        let pages = PageList(world.theirs.state).pages.map(\.id)
        try world.byMe(RemovePages([pages[1]]))
        try world.byThem(RemovePages([pages[0]]))
        let divergence = world.measure()
        #expect(divergence.zeroPages && divergence.hasRows && divergence.entries.isEmpty)
        #expect(divergence.decision(.standard) == .suggestReview)
        #expect(ReviewModel(divergence, decision: .suggestReview).zeroPages)
        #expect(ZeroPages.removedOnBothSides(local: world.local, remote: [], merged: world.mine.state) == false)
    }

    @Test func oneSideRemovingAPageIsNotZeroPages() throws {
        var world = Reconnect()
        let pages = try Self.pages(&world)
        try world.byMe(RemovePages([pages[1].id]))
        try world.byThem(RemovePages([pages[2].id]))
        #expect(!world.measure().zeroPages)
        #expect(!ZeroPages.removedOnBothSides(local: world.local, remote: world.remote, merged: world.mine.state))
    }

    // MARK: Guides

    @Test(arguments: [false, true]) func aGuideDeletedWhileMovedIsEditVersusDeleteWithRestore(deletedHere: Bool) throws {
        var world = Reconnect()
        let page = try Self.pages(&world)[0].id
        try world.shared(AddGuides(on: [page], axis: .vertical, at: [100]))
        let guide = try #require(PageList(world.theirs.state)[page]?.guides.first?.id)
        if deletedHere {
            try world.byMe(DeleteGuides(on: page, [guide]))
            try world.byThem(MoveGuide(on: page, [guide], to: 180))
        } else {
            try world.byMe(MoveGuide(on: page, [guide], to: 180))
            try world.byThem(DeleteGuides(on: page, [guide]))
        }
        let divergence = world.measure()
        let entry = try #require(divergence.entries.first)
        #expect(divergence.entries.count == 1 && entry.node == page && entry.kinds == [.editVsDelete])
        #expect(entry.properties.map(\.property) == [.elementDeleted(PageFields.guides.element(guide))])
        #expect(entry.actions == [.restore, .useTheirs])
        let restore = ReviewModel.restore(entry)
        #expect(restore.ops.count == 1 && restore.ops[0].elementDelete.deleted == false)
        try world.byMe(restore)
        #expect(PageList(world.mine.state)[page]?.guides.map(\.position) == [180])
        world.upload()
    }

    @Test func restoreOfADeletedObjectStillRestoresTheObject() {
        let entry = ReviewEntry(node: OpID(counter: 5, replica: 1), kinds: [.editVsDelete],
                                properties: [PropertyConflict(property: .deleted, mine: .flag(false), theirs: .flag(true), merged: .flag(true), kept: .theirs)],
                                authors: [], actions: [.restore, .useTheirs])
        #expect(ReviewModel.restore(entry).ops.map(\.setDeleted.deleted) == [false])
    }

    // MARK: Typefaces

    struct Font {
        var glyphs: [String: OpID]
        subscript(_ name: String) -> OpID { glyphs[name]! }
    }

    static func font(_ world: inout Reconnect) throws -> Font {
        try world.shared(NewTypeface(family: "Marlowe", style: "Regular", upm: 1_000, set: nil))
        try world.shared(AddGlyphs([0x41, 0x42, 0x43, 0x4F, 0x56].map { NewGlyph(scalar: $0) }))
        let index = GlyphIndex(world.theirs.state)
        return Font(glyphs: Dictionary(uniqueKeysWithValues: ["A", "B", "C", "O", "V"].map { ($0, index.glyph(named: $0)!.id) }))
    }

    /// A box drawn on `glyph`'s canvas: the shape, then its `canvas` (as the scenarios place it).
    @discardableResult
    static func box(on glyph: OpID, _ world: inout Reconnect, shared: Bool = false) throws -> OpID {
        let create = square(at: Point(x: 0, y: -500))
        let node = try #require(try (shared ? world.shared(create) : world.byMe(create))?.createdObjects.first)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.common.canvas.id = glyph.proto
        let place = OpsCommand("Place", ops: [Ops.set(node, [RegisterPath([NodeKind.rect.rawValue, 1, 5])], values: props)])
        try shared ? world.shared(place) : world.byMe(place)
        return node
    }

    @Test func aBoxDrawnOnARemovedGlyphIsListedWithRestoreGlyph() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        let box = try Self.box(on: font["B"], &world)
        try world.byThem(RemoveGlyphs([font["B"]]))
        let rows = world.measure().removedTargets
        let row = try #require(rows.first)
        #expect(rows.count == 1 && row.kind == .removedGlyph && row.object == box && row.target == font["B"])
        #expect(row.kind.title == "Drawn on a glyph that was removed" && row.choices == [.restore])
        let restore = try #require(try row.command(.restore, in: world.mine.state))
        #expect(restore.label == "Restore Glyph")
        try world.byMe(restore)
        #expect(GlyphArtwork.objectIDs(on: font["B"], in: world.mine.state) == [box] && GlyphIndex(world.mine.state)[font["B"]] != nil)
        world.upload()
    }

    @Test func aCodepointClaimedOnBothSidesIsOneRowWithItsTwoChoices() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        try world.byMe(AddGlyphs([NewGlyph(name: "Aring", codepoints: [0xC5])]))
        try world.byThem(SetGlyphCodepoints(font["B"], add: [0xC5]))
        let divergence = world.measure()
        let aring = try #require(GlyphIndex(world.mine.state).glyph(named: "Aring")?.id)
        let row = try #require(divergence.fontCollisions.first)
        #expect(divergence.fontCollisions.count == 1 && row.kind == .codepoint(0xC5) && row.ids == [font["B"], aring])
        #expect(row.id == "codepoint:197" && row.choices == [.moveToThisGlyph, .removeFromOther])
        #expect(row.choices.map(\.title) == ["Move to this glyph", "Remove from other"])
        #expect(row.title(GlyphIndex(world.mine.state)) == "Two glyphs encode U+00C5 'Å'")
        #expect(divergence.hasRows && divergence.decision(.standard) == .perObject)
        #expect(ReviewModel(divergence, decision: .perObject).fontCollisions == [row])
        #expect(row.command(.mergeClasses, in: world.mine.state) == nil)
        let remove = try #require(row.command(.removeFromOther, in: world.mine.state))
        #expect(remove.label == "Set Unicode")
        try world.byMe(try #require(row.command(.moveToThisGlyph, in: world.mine.state)))
        #expect(GlyphIndex(world.mine.state).glyph(for: 0xC5)?.id == aring)
        // Convergence after the move is the simulator's (TypefaceScenarioTests), with acknowledged changes.
    }

    @Test func aNameClaimedOnBothSidesOffersRemoveDuplicateOnlyWithoutArtwork() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        try Self.box(on: font["O"], &world, shared: true)
        try world.byMe(RenameGlyph(font["O"], to: "eacute"))
        try world.byThem(RenameGlyph(font["C"], to: "eacute"))
        let row = try #require(world.measure().fontCollisions.first)
        let (keeper, duplicate) = font["C"] < font["O"] ? (font["C"], font["O"]) : (font["O"], font["C"])
        #expect(row.kind == .glyphName("eacute") && row.ids == [keeper, duplicate] && row.id == "glyph-name:eacute")
        #expect(row.choices == (duplicate == font["O"] ? [.rename] : [.removeDuplicate, .rename]))
        #expect(row.title(GlyphIndex(world.mine.state)) == "Two glyphs named eacute" && row.command(.rename, in: world.mine.state) == nil)
        if duplicate == font["C"] {
            let remove = try #require(row.command(.removeDuplicate, in: world.mine.state))
            try world.byMe(remove)
            #expect(GlyphIndex(world.mine.state)[font["C"]] == nil)
        }
    }

    @Test func classesAndPairsCreatedOnBothSidesAreListedAndFixed() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        try world.byMe(CreateKernClass("O", side: .left, members: [font["C"]]))
        try world.byMe(SetKernPair(font["O"], font["V"], to: -40))
        try world.byThem(CreateKernClass("O", side: .left, members: [font["O"]]))
        try world.byThem(SetKernPair(font["O"], font["V"], to: -30))
        try world.byThem(TypeFeatures(text: "# kern\n", offset: 0))
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty, "different settings: the settings node is not listed")
        let rows = divergence.fontCollisions
        #expect(rows.map(\.kind) == [.className("O", .left), .kernPair(left: font["O"], right: font["V"])])
        let index = GlyphIndex(world.mine.state)
        #expect(rows[0].title(index) == "Two left classes named O" && rows[0].id.hasPrefix("class-name:"))
        #expect(rows[1].title(index) == "Two kerning pairs for O V" && rows[1].id.hasPrefix("kern-pair:"))
        #expect(rows.map(\.choices) == [[.mergeClasses], [.keepLatest]] && rows[1].choices.map(\.title) == ["Keep the latest"])
        try world.byMe(try #require(rows[0].command(.mergeClasses, in: world.mine.state)))
        try world.byMe(try #require(rows[1].command(.keepLatest, in: world.mine.state)))
        let kerning = Kerning(world.mine.state)
        #expect(kerning.classes.count == 1 && Set(kerning.classes[0].members) == [font["C"], font["O"]])
        #expect(kerning.storedPairs.filter { $0.left == font["O"] }.count == 1)
        world.upload()
    }

    @Test func theSameKernPairWrittenOnBothSidesListsTheSettingsNode() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        try world.shared(SetKernPair(font["A"], font["V"], to: -50))
        try world.byMe(SetKernPair(font["A"], font["V"], to: -60))
        try world.byThem(SetKernPair(font["A"], font["V"], to: -80))
        let divergence = world.measure()
        #expect(divergence.entries.map(\.node) == [.wellKnown(1)] && divergence.entries[0].kinds == [.sameRegister])
        #expect(divergence.fontCollisions.isEmpty)
    }

    @Test func collisionsMadeOnOneSideOnlyAreNotListed() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        for glyph in [font["C"], font["O"]] {
            try world.byMe(OpsCommand("Name", ops: [Ops.set(glyph, [GlyphFields.name], values: GlyphFields.values { $0.name = "x" })]))
        }
        try world.byThem(RenameGlyph(font["V"], to: "vee"))
        #expect(world.measure().fontCollisions.isEmpty)
        var alone = Reconnect()
        _ = try Self.font(&alone)
        #expect(alone.measure().fontCollisions.isEmpty)
    }

    @Test func glyphsAddedOnBothSidesAreListedByNameAndCodepoint() throws {
        var world = Reconnect()
        let font = try Self.font(&world)
        let added = [NewGlyph(name: "x", codepoints: [0x100]), NewGlyph(name: "y", codepoints: [0x101])]
        try world.byMe(AddGlyphs(added))
        try world.byMe(SetKernPair(font["O"], font["V"], to: -10))
        try world.byMe(SetKernPair(font["C"], font["V"], to: -10))
        try world.byThem(AddGlyphs(added))
        try world.byThem(SetKernPair(font["O"], font["V"], to: -20))
        try world.byThem(SetKernPair(font["C"], font["V"], to: -20))
        let rows = world.measure().fontCollisions
        #expect(rows.map(\.kind) == [.glyphName("x"), .glyphName("y"), .codepoint(0x100), .codepoint(0x101),
                                     .kernPair(left: min(font["C"], font["O"]) == font["C"] ? font["C"] : font["O"], right: font["V"]),
                                     .kernPair(left: min(font["C"], font["O"]) == font["C"] ? font["O"] : font["C"], right: font["V"])])
        #expect(rows[0].choices == [.removeDuplicate, .rename])
        #expect(FontCollisionEntry.Choice.allCases.map(\.title) == ["Rename…", "Remove duplicate", "Move to this glyph", "Remove from other",
                                                                     "Merge classes", "Keep the latest"])
    }

    @Test func titlesCountThreeClaims() {
        let three = FontCollisionEntry(kind: .glyphName("a"), ids: [OpID(counter: 1, replica: 1), OpID(counter: 2, replica: 1), OpID(counter: 3, replica: 1)],
                                       choices: [.rename])
        #expect(three.title(GlyphIndex(EngineState())) == "3 glyphs named a")
        let right = FontCollisionEntry(kind: .className("H", .right), ids: [OpID(counter: 1, replica: 1)], choices: [.mergeClasses])
        #expect(right.title(GlyphIndex(EngineState())).hasSuffix("right classes named H") && right.command(.mergeClasses, in: EngineState()) == nil)
        let pair = FontCollisionEntry(kind: .kernPair(left: OpID(counter: 8, replica: 1), right: OpID(counter: 9, replica: 1)),
                                      ids: [OpID(counter: 1, replica: 1), OpID(counter: 2, replica: 1)], choices: [.keepLatest])
        #expect(pair.title(GlyphIndex(EngineState())) == "Two kerning pairs for 8:1 9:1" && pair.command(.keepLatest, in: EngineState()) == nil)
        let bad = FontCollisionEntry(kind: .codepoint(0xD800), ids: [], choices: [])
        #expect(bad.title(GlyphIndex(EngineState())) == "0 glyphs encode U+D800" && bad.id == "codepoint:55296")
    }

    /// Typing into the feature file at `offset`.
    struct TypeFeatures: Command {
        let text: String
        let offset: Int
        var label: String { "Edit features" }

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            let origins = state.insertionOrigins(WellKnown.settings, FontFields.features, at: offset, stableSeq: 0)
            builder.append(Ops.textInsert(WellKnown.settings, FontFields.features, text, left: origins.left, right: origins.right))
        }
    }
}
