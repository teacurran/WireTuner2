import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

/// FONT-029: a typeface under concurrency (glyph-grid.adoc, kerning-metrics.adoc,
/// opentype-features.adoc, font-info.adoc and typeface-documents.adoc, "Merge semantics"), through
/// the simulator, with LIB-023's three clients -- Ben's work concurrent with Ana's, live or after 12
/// hours offline.  Every run converges to one state hash everywhere; offline runs assert exactly the
/// review rows the pages name, settle them with the rows' own choices, and then every client
/// generates the same font, byte for byte.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct TypefaceScenarioTests {
    typealias Team = LibraryScenarioTests.Team

    struct Font {
        let glyphs: [String: OpID]
        subscript(_ name: String) -> OpID { glyphs[name]! }
    }

    /// "Marlowe Regular" with A, B, C, O and V, and the pair A V at -50.
    static func typeface(_ team: Team) async throws -> Font {
        await team.ana.perform(NewTypeface(family: "Marlowe", style: "Regular", upm: 1_000, set: nil))
        await team.ana.perform(AddGlyphs([0x41, 0x42, 0x43, 0x4F, 0x56].map { NewGlyph(scalar: $0) }))
        let index = GlyphIndex(team.ana.state)
        let font = Font(glyphs: Dictionary(uniqueKeysWithValues: ["A", "B", "C", "O", "V"].map { ($0, index.glyph(named: $0)!.id) }))
        await team.ana.perform(SetKernPair(font["A"], font["V"], to: -50))
        try await team.sim.settle()
        return font
    }

    /// A 100 × 500 box on `glyph`'s canvas.
    static func draw(_ client: SimClient, on glyph: OpID) async throws -> OpID {
        try await AccountAndPublishScenarioTests.box(on: glyph, by: client)
    }

    /// The review, checked: the object rows, the collision kinds, the removed-target kinds and the
    /// rescale count are exactly the given ones; held reviews are settled with *Keep the merged
    /// result* after `settle` performs the rows' choices.  Live, nothing asked.  Then everyone
    /// converges.
    static func expect(_ team: Team, _ review: ReviewModel?, offline: Bool, rows: Set<ReviewRow> = [],
                       collisions: [FontCollisionEntry.Kind] = [], removed: [RemovedTargetEntry.Kind] = [], rescales: Int = 0,
                       settle: (ReviewModel) async throws -> Void = { _ in }) async throws {
        if offline {
            let review = try #require(review)
            #expect(ReviewRow.rows(review) == rows)
            #expect(review.fontCollisions.map(\.kind) == collisions)
            #expect(review.removedTargets.map(\.kind) == removed)
            #expect(review.rescaleRows.count == rescales)
            try await settle(review)
            if review.holdsOutbox { try await team.ben.keepMerged() }
        } else {
            #expect(review?.holdsOutbox != true, "a brief drop merges without asking")
            #expect(team.ben.reviews == 0)
        }
        try await team.sim.settle()
        try await team.sim.expectConverged()
    }

    /// Every client generates the same OpenType font (the generator's date fixed).
    static func expectSameFonts(_ team: Team) async throws {
        var fonts: [Data] = []
        for person in team.everyone {
            fonts.append(try await FontGeneration.generate(person.state, format: .otf, date: Date(timeIntervalSince1970: 1_700_000_000)).data)
        }
        #expect(!fonts[0].isEmpty && fonts.allSatisfy { $0 == fonts[0] }, "identical generated fonts")
    }

    // MARK: Glyphs

    /// Two glyphs claim one codepoint: Ana encodes Å on B while Ben adds a glyph "Aring" for it.
    /// The older glyph (B) keeps it everywhere; offline, the row "Two glyphs encode U+00C5" moves it
    /// to Ben's glyph in one change.
    @Test(arguments: [false, true]) func twoGlyphsClaimOneCodepoint(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-codepoint-\(offline)", seed: 2901)
        defer { Task { await team.sim.shutdown() } }
        let font = try await Self.typeface(team)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(AddGlyphs([NewGlyph(name: "Aring", codepoints: [0xC5])]))
        } theirs: {
            await team.ana.perform(SetGlyphCodepoints(font["B"], add: [0xC5]))
        }
        let aring = try #require(GlyphIndex(team.ben.state).glyph(named: "Aring")?.id)
        try await Self.expect(team, review, offline: offline, collisions: offline ? [.codepoint(0xC5)] : []) { review in
            let row = try #require(review.fontCollisions.first)
            #expect(row.ids == [font["B"], aring] && row.title(GlyphIndex(team.ben.state)) == "Two glyphs encode U+00C5 'Å'")
            #expect(await team.ben.perform(try #require(row.command(.moveToThisGlyph, other: aring, in: team.ben.state))) != nil)
        }
        for person in team.everyone {
            let index = GlyphIndex(person.state)
            #expect(index.glyph(for: 0xC5)?.id == (offline ? aring : font["B"]))
            #expect(index.codepointCollisions.isEmpty == offline)
        }
        if offline { try await Self.expectSameFonts(team) }
    }

    /// Rename collision: Ana and Ben rename C and O to "eacute" at once.  The older glyph keeps the
    /// name; the other reads `eacute.dup…` everywhere.  Offline, "Two glyphs named eacute" offers
    /// *Remove duplicate* (it has no artwork) and *Rename…*; renaming it clears the row's cause.
    @Test(arguments: [false, true]) func renameCollision(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-rename-\(offline)", seed: 2902)
        defer { Task { await team.sim.shutdown() } }
        let font = try await Self.typeface(team)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(RenameGlyph(font["O"], to: "eacute"))
        } theirs: {
            await team.ana.perform(RenameGlyph(font["C"], to: "eacute"))
        }
        let (keeper, duplicate) = font["C"] < font["O"] ? (font["C"], font["O"]) : (font["O"], font["C"])
        try await Self.expect(team, review, offline: offline, collisions: offline ? [.glyphName("eacute")] : []) { review in
            let row = try #require(review.fontCollisions.first)
            #expect(row.ids == [keeper, duplicate] && row.choices == [.removeDuplicate, .rename])
            #expect(row.title(GlyphIndex(team.ben.state)) == "Two glyphs named eacute" && row.command(.rename, in: team.ben.state) == nil)
            await team.ben.perform(RenameGlyph(duplicate, to: "eacute.alt"))
        }
        for person in team.everyone {
            let index = GlyphIndex(person.state)
            #expect(index.glyph(named: "eacute")?.id == keeper)
            #expect(index[duplicate]?.name == (offline ? "eacute.alt" : "eacute.dup\(duplicate.counter)_\(String(duplicate.replica, radix: 16))"))
        }
        if offline { try await Self.expectSameFonts(team) }
    }

    /// UPM scale vs. concurrent drawing on three glyphs: Ana scales 1000→2048 while Ben draws on A,
    /// B and C.  Offline, the three boxes are "drawn while the font was rescaled"; *Rescale mine*
    /// makes them match a box that was scaled.
    @Test(arguments: [false, true]) func upmScaleVersusDrawingOnThreeGlyphs(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-upm-\(offline)", seed: 2903)
        defer { Task { await team.sim.shutdown() } }
        let font = try await Self.typeface(team)
        let fixture = try await Self.draw(team.ana, on: font["O"])
        try await team.sim.settle()
        var boxes: [OpID] = []
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            for name in ["A", "B", "C"] { boxes.append(try await Self.draw(team.ben, on: font[name])) }
        } theirs: {
            await team.ana.perform(SetUnitsPerEm(2_048, scale: true))
        }
        try await Self.expect(team, review, offline: offline, rescales: offline ? 3 : 0) { review in
            #expect(review.rescaleRows.map(\.node) == boxes)
            await team.ben.perform(try #require(FontRescaleReview.rescaleAll(review.rescaleRows)))
        }
        let scaled = try #require(Objects.bounds(of: fixture, in: team.ana.state))
        for person in team.everyone {
            #expect(FontInfo(person.state).metrics.upm == 2_048)
            for box in boxes {
                let bounds = try #require(Objects.bounds(of: box, in: person.state))
                #expect((abs(bounds.height - scaled.height) < 0.01) == offline, offline ? "rescaled" : "a live drop leaves it unscaled")
            }
        }
        if offline { try await Self.expectSameFonts(team) }
    }

    /// Glyph removal vs. drawing: Ana removes B while Ben draws on it.  The box survives on the
    /// Sketches pasteboard; offline, it is "Drawn on a glyph that was removed" with *Restore*, which
    /// brings B back with the box on it.
    @Test(arguments: [false, true]) func glyphRemovalVersusDrawing(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-remove-draw-\(offline)", seed: 2904)
        defer { Task { await team.sim.shutdown() } }
        let font = try await Self.typeface(team)
        var drawn: OpID?
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            drawn = try await Self.draw(team.ben, on: font["B"])
        } theirs: {
            await team.ana.perform(RemoveGlyphs([font["B"]], in: team.ana.state))
        }
        let box = try #require(drawn)
        try await Self.expect(team, review, offline: offline, removed: offline ? [.removedGlyph] : []) { review in
            let row = try #require(review.removedTargets.first)
            #expect(row.object == box && row.target == font["B"] && row.kind.title == "Drawn on a glyph that was removed")
            #expect(await team.ben.perform(try #require(try row.command(.restore, in: team.ben.state))) != nil)
        }
        for person in team.everyone {
            #expect(person.state.isLive(box))
            #expect((GlyphIndex(person.state)[font["B"]] != nil) == offline)
            #expect(GlyphArtwork.objectIDs(on: font["B"], in: person.state) == [box], "its canvas still names B: restoring B re-attaches it")
        }
    }

    // MARK: Kerning

    /// Kern pair race: both set A V; the later value stands (a register of the pair element) and
    /// the settings node is *Same attribute* (*Font*).  Same-pair creation: both create O V; the
    /// greater element id is used, and "Two kerning pairs for O V" keeps the latest, deleting the
    /// other.
    @Test(arguments: [false, true]) func kernPairRaceAndSamePairCreation(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-kern-\(offline)", seed: 2905)
        defer { Task { await team.sim.shutdown() } }
        let font = try await Self.typeface(team)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(SetKernPair(font["A"], font["V"], to: -60))
            await team.ben.perform(SetKernPair(font["O"], font["V"], to: -40))
        } theirs: {
            await team.ana.perform(SetKernPair(font["A"], font["V"], to: -80))
            await team.ana.perform(SetKernPair(font["O"], font["V"], to: -30))
        }
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: .wellKnown(1), kind: .sameRegister, attributes: ["Font"])],
                              collisions: offline ? [.kernPair(left: font["O"], right: font["V"])] : []) { review in
            let row = try #require(review.fontCollisions.first)
            #expect(row.title(GlyphIndex(team.ben.state)) == "Two kerning pairs for O V")
            await team.ben.perform(try #require(row.command(.keepLatest, in: team.ben.state)))
        }
        let kerning = Kerning(team.cy.state)
        #expect([-60.0, -80].contains(kerning.value(font["A"], font["V"])) && [-40.0, -30].contains(kerning.value(font["O"], font["V"])))
        #expect(kerning.storedPairs.filter { $0.left == font["O"] }.count == (offline ? 1 : 2))
        for person in team.everyone { #expect(Kerning(person.state) == kerning) }
        if offline { try await Self.expectSameFonts(team) }
    }

    /// Class creation race: both create a left class "O" (with O, and with C).  Both stay; C and O
    /// each in one.  Offline, "Two left classes named O" merges them: one class with both members.
    @Test(arguments: [false, true]) func classCreationRaceWithMergeClasses(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-classes-\(offline)", seed: 2906)
        defer { Task { await team.sim.shutdown() } }
        let font = try await Self.typeface(team)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(CreateKernClass("O", side: .left, members: [font["C"]]))
        } theirs: {
            await team.ana.perform(CreateKernClass("O", side: .left, members: [font["O"]]))
        }
        try await Self.expect(team, review, offline: offline, collisions: offline ? [.className("O", .left)] : []) { review in
            let row = try #require(review.fontCollisions.first)
            #expect(row.title(GlyphIndex(team.ben.state)) == "Two left classes named O" && row.choices == [.mergeClasses])
            await team.ben.perform(try #require(row.command(.mergeClasses, in: team.ben.state)))
        }
        for person in team.everyone {
            let classes = Kerning(person.state).classes
            #expect(classes.count == (offline ? 1 : 2))
            #expect(Set(classes.flatMap(\.members)) == [font["C"], font["O"]])
        }
        if offline { try await Self.expectSameFonts(team) }
    }

    // MARK: Features

    /// Inserts `text` into the feature file at `offset` (the feature editor's typing).
    struct TypeFeatures: Command {
        let text: String
        let offset: Int
        var label: String { "Edit features" }

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            let origins = state.insertionOrigins(WellKnown.settings, FontFields.features, at: offset, stableSeq: 0)
            builder.append(Ops.textInsert(WellKnown.settings, FontFields.features, text, left: origins.left, right: origins.right))
        }
    }

    static let features = "feature liga {\n  sub f i by f_i;\n} liga;\nfeature kern {\n  pos A V -50;\n} kern;\n"

    /// Feature file edits: in different blocks both survive whole and nothing is listed; in the
    /// same line both survive character by character (the text may not parse) and offline the
    /// settings node is listed *Same text*.
    @Test(arguments: [false, true]) func featureFileEdits(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("font-features-\(offline)", seed: 2907)
        defer { Task { await team.sim.shutdown() } }
        _ = try await Self.typeface(team)
        await team.ana.perform(TypeFeatures(text: Self.features, offset: 0))
        try await team.sim.settle()
        let liga = (Self.features as NSString).range(of: "} liga;").location
        let kern = (Self.features as NSString).range(of: "} kern;").location
        let different = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(TypeFeatures(text: "  pos O V -30;\n", offset: kern))
        } theirs: {
            await team.ana.perform(TypeFeatures(text: "  sub f l by f_l;\n", offset: liga))
        }
        try await Self.expect(team, different, offline: offline)
        let merged = FontInfo(team.cy.state).features
        #expect(merged.contains("  sub f l by f_l;\n} liga;") && merged.contains("  pos O V -30;\n} kern;"))
        let line = (merged as NSString).range(of: "pos A V -50;").location + 4
        let same = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(TypeFeatures(text: "[A Aring]", offset: line))
        } theirs: {
            await team.ana.perform(TypeFeatures(text: "@A_left", offset: line))
        }
        try await Self.expect(team, same, offline: offline, rows: [ReviewRow(node: .wellKnown(1), kind: .sameText, attributes: ["Text"])])
        let text = FontInfo(team.cy.state).features
        #expect(text.contains("[A Aring]") && text.contains("@A_left"), "both survive, neither interleaved")
        for person in team.everyone { #expect(FontInfo(person.state).features == text) }
    }

    // MARK: A day offline

    /// An offline day of glyph work on two clients, then generate: Ana and Ben each spend 24
    /// simulated hours on their own glyphs -- adding glyphs, drawing, widths, kerning -- with Cy
    /// online.  Nothing collides, so neither review lists a row; every client generates the same
    /// font.
    @Test func anOfflineDayOfGlyphWorkThenGenerate() async throws {
        let team = try await LibraryScenarioTests.team("font-offline-day", seed: 2908)
        defer { Task { await team.sim.shutdown() } }
        team.ana.keepsMergedResult = false
        let font = try await Self.typeface(team)
        team.ana.goOffline()
        team.ben.goOffline()
        for hour in 0..<24 {
            if hour == 1 { await team.ana.perform(AddGlyphs([0x61, 0x62].map { NewGlyph(scalar: $0) })) }
            if hour == 2 { await team.ben.perform(AddGlyphs([0x78, 0x79].map { NewGlyph(scalar: $0) })) }
            if hour.isMultiple(of: 6) {
                _ = try await Self.draw(team.ana, on: font["A"])
                _ = try await Self.draw(team.ben, on: font["V"])
            }
            await team.ana.perform(SetGlyphWidth([font["A"]], to: 500 + Double(hour)))
            await team.ben.perform(SetGlyphWidth([font["V"]], to: 600 + Double(hour)))
            if hour == 10 { await team.ana.perform(SetKernPair(font["A"], font["O"], to: -20)) }
            if hour == 11 { await team.ben.perform(SetKernPair(font["V"], font["C"], to: -25)) }
            team.sim.advance(by: .seconds(3600))
        }
        await team.cy.perform(RenameGlyph(font["B"], to: "B.alt"))
        try await team.sim.settle([team.cy])
        let seen = (team.ana.events.count, team.ben.events.count)
        team.ana.goOnline()
        team.ben.goOnline()
        try await team.sim.settle()
        try await team.sim.expectConverged()
        for (person, from) in [(team.ana, seen.0), (team.ben, seen.1)] {
            let reviews = person.events.dropFirst(from).compactMap { event -> ReviewModel? in
                switch event {
                case .merged(let review), .reviewNeeded(let review): review
                default: nil
                }
            }
            #expect(!reviews.isEmpty && reviews.allSatisfy { ReviewRow.rows($0).isEmpty && $0.fontCollisions.isEmpty && !$0.holdsOutbox },
                    "\(person.name): nothing collided")
        }
        let index = GlyphIndex(team.cy.state)
        #expect(index.count == 9 && index[font["A"]]?.advanceWidth == 523 && index[font["V"]]?.advanceWidth == 623)
        #expect(GlyphArtwork.objectIDs(on: font["A"], in: team.cy.state).count == 4)
        try await Self.expectSameFonts(team)
    }
}
