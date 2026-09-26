import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// FONT-007: the always-list rule for font-level changes and the units-per-em rows
/// (font-info.adoc, "Merge semantics"), measured on reconnect against the reconcile decision table.
@Suite struct FontRescaleReviewTests {
    /// A typeface with glyphs A and B on both sides.
    static func typeface(_ world: inout Reconnect) throws -> (a: OpID, b: OpID) {
        try world.shared(NewTypeface(family: "Marlowe", style: "Regular", upm: 1_000, set: nil))
        try world.shared(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        let index = GlyphIndex(world.theirs.state)
        return (index.glyph(named: "A")!.id, index.glyph(named: "B")!.id)
    }

    enum Side { case shared, mine, theirs }

    /// A `width` × `height` rectangle at (`x`, `y`) placed on `glyph`'s canvas.
    @discardableResult
    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, on glyph: OpID, by side: Side,
                    in world: inout Reconnect) throws -> OpID {
        let create = CreateShape(.rectangle(CornerRadii()), size: Size(width: width, height: height), transform: .translation(x: x, y: y))
        func run(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
            switch side {
            case .shared: try world.shared(command)
            case .mine: try world.byMe(command)
            case .theirs: try world.byThem(command)
            }
        }
        let node = try #require(try run(create)).createdObjects[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.common.canvas.id = glyph.proto
        try run(OpsCommand("Place", ops: [Ops.set(node, [RegisterPath([NodeKind.rect.rawValue, 1, 5])], values: props)]))
        return node
    }

    static func bounds(_ node: OpID, _ world: Reconnect) -> Rect? {
        Objects.bounds(of: node, in: world.mine.state)
    }

    static func close(_ a: Rect?, _ b: Rect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @Test func aScaleWhileTwoPathsWereDrawnListsBothAndRescaleMineMatchesTheScaledFixture() throws {
        var world = Reconnect()
        let glyphs = try Self.typeface(&world)
        let fixture = try Self.box(0, -500, 100, 500, on: glyphs.a, by: .shared, in: &world)
        try world.byThem(SetUnitsPerEm(2_048, scale: true))
        let one = try Self.box(0, -500, 100, 500, on: glyphs.a, by: .mine, in: &world)
        let two = try Self.box(0, -500, 100, 500, on: glyphs.b, by: .mine, in: &world)
        let divergence = world.measure()
        let rows = divergence.rescaleRows
        #expect(rows.map(\.node) == [one, two] && rows.map(\.glyph) == [glyphs.a, glyphs.b])
        #expect(rows.allSatisfy { $0.reason == .drawnWhileRescaled && abs($0.factor - 2.048) < 1e-12 && $0.authors == [world.theirs.replica] })
        #expect(rows[0].id == "rescale:\(one)" && rows[0].reason.title == "Drawn while the font was rescaled")
        #expect(rows[0].reason.actionTitle == "Rescale mine" && RescaleEntry.Reason.transformKept.actionTitle == "Rescale")
        #expect(RescaleEntry.Reason.transformKept.title == "Same attribute")
        // The metric write is always listed, and the review holds the outbox.
        #expect(divergence.entries.contains { $0.setting == .fontMetrics })
        #expect(divergence.decision(.standard).holdsOutbox)
        #expect(ReviewModel(divergence, decision: .perObject).rescaleRows == rows)

        // Unscaled until *Rescale mine*, which is one change and matches the scaler's fixture.
        #expect(Self.bounds(one, world) == Rect(x: 0, y: -500, width: 100, height: 500))
        let all = try #require(FontRescaleReview.rescaleAll(rows))
        #expect(all.label == "Rescale 2 Objects" && rows[0].command.label == "Rescale Object")
        let change = try #require(try world.byMe(all))
        #expect(change.ops.count == 2)
        let scaled = Self.bounds(fixture, world)
        #expect(Self.close(Self.bounds(one, world), scaled) && Self.close(Self.bounds(two, world), scaled))
        world.upload()
        #expect(FontRescaleReview.rescaleAll([]) == nil)
    }

    @Test func aWinningDragAgainstTheScaleIsOfferedRescale() throws {
        var world = Reconnect()
        let glyphs = try Self.typeface(&world)
        let box = try Self.box(0, -500, 100, 500, on: glyphs.a, by: .shared, in: &world)
        try world.byThem(SetUnitsPerEm(2_000, scale: true))
        // The drag is made after the scale arrived at the server but before this Mac saw it:
        // its op id is greater, so it wins the transform register whole.
        var name = Wiretuner_Doc_V1_NodeProps()
        name.rect.common.name = "Box"
        try world.byMe(OpsCommand("Rename", ops: Array(repeating: Ops.set(box, [CommonFields.name(.rect)], values: name), count: 200)))
        try world.byMe(MoveObjects([box], by: Vector(dx: 10, dy: 0)))
        let divergence = world.measure()
        let row = try #require(divergence.rescaleRows.first)
        #expect(divergence.rescaleRows.count == 1 && row.node == box && row.reason == .transformKept && row.factor == 2)
        #expect(divergence.entries.contains { $0.node == box && $0.kinds.contains(.sameRegister) })
        #expect(Self.bounds(box, world) == Rect(x: 10, y: -500, width: 100, height: 500))
        try world.byMe(row.command)
        #expect(Self.close(Self.bounds(box, world), Rect(x: 20, y: -1_000, width: 200, height: 1_000)))
    }

    @Test func aLosingDragIsAlreadyScaledAndNotOffered() throws {
        var world = Reconnect()
        let glyphs = try Self.typeface(&world)
        let box = try Self.box(0, -500, 100, 500, on: glyphs.a, by: .shared, in: &world)
        try world.byMe(MoveObjects([box], by: Vector(dx: 10, dy: 0)))
        try world.byThem(SetUnitsPerEm(2_000, scale: true))
        #expect(world.measure().rescaleRows.isEmpty)
    }

    @Test func metricWriteAgainstOneGlyphEditOpensTheSheetAndAgainstNothingMergesWithTheToast() throws {
        var edited = Reconnect()
        let glyphs = try Self.typeface(&edited)
        try Self.box(0, 0, 10, 10, on: glyphs.a, by: .shared, in: &edited)
        try edited.byMe(OpsCommand("Width", ops: [Ops.set(glyphs.a, [GlyphFields.advanceWidth], values: GlyphFields.values { $0.advanceWidth = 640 })]))
        try edited.byThem(SetFontMetrics([.xHeight: 480]))
        let opened = edited.measure()
        #expect(opened.decision(.standard) == .perObject)
        #expect(opened.entries.map(\.setting) == [.fontMetrics, nil] && opened.entries[1].node == glyphs.a)
        #expect(opened.rescaleRows.isEmpty)

        var quiet = Reconnect()
        _ = try Self.typeface(&quiet)
        try quiet.byThem(SetFontMetrics([.xHeight: 480]))
        let merged = quiet.measure()
        #expect(merged.entries.map(\.setting) == [.fontMetrics] && merged.decision(.standard) == .silentMerge)
        #expect(ReviewModel(merged, decision: .silentMerge).toast.hasPrefix("Merged 1 change"))
    }

    @Test func namesKerningAndFeaturesAreOrdinaryRegisters() throws {
        var world = Reconnect()
        let glyphs = try Self.typeface(&world)
        try world.byMe(OpsCommand("Width", ops: [Ops.set(glyphs.a, [GlyphFields.advanceWidth], values: GlyphFields.values { $0.advanceWidth = 640 })]))
        try world.byThem(SetFontNames([.family: "Other"]))
        #expect(world.measure().entries.isEmpty)
    }

    @Test func aScaleWithoutConcurrentDrawingOrAUPMChangeWithoutScaleListsNothing() throws {
        var world = Reconnect()
        let glyphs = try Self.typeface(&world)
        try world.byThem(SetUnitsPerEm(2_000, scale: false))
        try Self.box(0, 0, 10, 10, on: glyphs.a, by: .mine, in: &world)
        #expect(world.measure().rescaleRows.isEmpty)

        var same = Reconnect()
        let unchanged = try Self.typeface(&same)
        try same.byThem(SetUnitsPerEm(1_000, scale: true))
        try Self.box(0, 0, 10, 10, on: unchanged.a, by: .mine, in: &same)
        #expect(same.measure().rescaleRows.isEmpty)

        var both = Reconnect()
        let second = try Self.typeface(&both)
        try both.byThem(SetUnitsPerEm(2_000, scale: true))
        try both.byMe(SetUnitsPerEm(1_200, scale: true))
        try Self.box(0, 0, 10, 10, on: second.a, by: .mine, in: &both)
        #expect(both.measure().rescaleRows.isEmpty)
    }

    @Test func scaleLabels() {
        for label in ["Scale to 2048 UPM", "Scale to 2048 UPM [1/8]", "Undo] Scale to 12 UPM"] {
            #expect(FontRescaleReview.isScaleLabel(label), "\(label)")
        }
        for label in ["Set UPM to 2048", "Scale to UPM", "Scale 2 Objects", "Scale to 2048 UPM [x]"] {
            #expect(!FontRescaleReview.isScaleLabel(label), "\(label)")
        }
        #expect(FontRescaleReview.isTransform(RegisterPath([NodeKind.rect.rawValue, 1, 4])))
        #expect(!FontRescaleReview.isTransform(RegisterPath([NodeKind.rect.rawValue, 1, 5])))
    }
}
