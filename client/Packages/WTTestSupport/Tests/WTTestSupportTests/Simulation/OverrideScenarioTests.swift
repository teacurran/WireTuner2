import CoreGraphics
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

/// LIB-028: every override case of library.adoc, "Merge semantics" -- same-text typing,
/// same-colour LWW, duplicate creation, reset vs. edit, reset all vs. edit, master node delete vs.
/// edit, swap vs. edit, release vs. edit -- across three clients, each asserting the rendered
/// outcome on every replica: the instance drawn through WTRender's Core Graphics renderer (the
/// centre pixel of the overridden part) and, for text, the override's text.  The conformance
/// vectors `library/override-*` pin the same cases in both engines.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct OverrideScenarioTests {
    static let grey = LibraryScenarioTests.grey
    static let red = LibraryScenarioTests.red
    static let blue = LibraryScenarioTests.blue
    static let green = Wiretuner_Doc_V1_ColorRef.with { $0.inline.rgb.g = 1 }
    static let yellow = Wiretuner_Doc_V1_ColorRef.with { $0.inline.rgb.r = 1; $0.inline.rgb.g = 1 }

    /// A symbol "Badge" of a grey 10 pt square at the origin and a text part far from it, with its
    /// instance in their place.
    struct Badge {
        let team: LibraryScenarioTests.Team
        let symbol: OpID
        let square: OpID
        let label: OpID
        let instance: OpID
    }

    static func badge(_ name: String, seed: UInt64) async throws -> Badge {
        let team = try await LibraryScenarioTests.team(name, seed: seed)
        let square = try await square(team.ana, fill: grey)
        let label = try #require(await team.ana.perform(CreateTextBlock(.point(Point(x: 200, y: 200)), text: "Label"))?.createdObjects.first)
        let created = try #require(await team.ana.perform(ConvertToSymbol([square, label], name: "Badge"))).createdNodes
        try await team.sim.settle()
        return Badge(team: team, symbol: created[0], square: square, label: label, instance: try #require(created.last))
    }

    /// A filled 10 pt square with its corner at the origin.
    static func square(_ client: SimClient, fill: Wiretuner_Doc_V1_ColorRef) async throws -> OpID {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [.with { $0.settings.kind = .basic; $0.settings.basic.color = fill }]
        let corners = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)].map { VectorPoint(anchor: Point(x: $0.0, y: $0.1)) }
        return try Workload.created(await client.perform(CreatePath(contours: [NewContour(closed: true, points: corners)], appearance: appearance)),
                                    by: client, "a square")[0]
    }

    /// Sets an override through `client` and returns the change.
    @discardableResult
    static func set(_ badge: Badge, _ client: SimClient, _ value: OverrideValue, master: OpID? = nil) async throws -> Wiretuner_Doc_V1_Change {
        try #require(await client.perform(SetOverride([badge.instance], master: master ?? badge.square, value: value, in: client.state)))
    }

    /// The centre of the square as `client` draws the document: RGBA, 8 bits, premultiplied.
    static func centre(_ client: SimClient) throws -> [UInt8] {
        var builder = DocumentDisplayListBuilder(canvas: "override-scenario")
        let list = builder.rebuild(client.state).displayList
        let image = try #require(ThumbnailRenderer.image(list, page: Rect(x: 0, y: 0, width: 10, height: 10), longEdge: 10))
        var pixels = [UInt8](repeating: 0, count: 400)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &pixels, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let index = (5 * 10 + 5) * 4
        return Array(pixels[index..<index + 4])
    }

    /// The pixel a colour draws as (opaque), or transparent for nil.
    static func pixel(_ color: Wiretuner_Doc_V1_ColorRef?) -> [UInt8] {
        guard let rgb = color?.inline.rgb else { return [0, 0, 0, 0] }
        return [rgb.r, rgb.g, rgb.b].map { UInt8(($0 * 255).rounded()) } + [255]
    }

    /// Every replica draws `color` at the square's centre (each channel within 2/255).
    static func expectDrawn(_ badge: Badge, _ color: Wiretuner_Doc_V1_ColorRef?, _ comment: Comment? = nil) throws {
        let expected = pixel(color)
        for person in badge.team.everyone {
            let drawn = try centre(person)
            #expect(zip(drawn, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "\(person.name) draws \(drawn), expected \(expected)")
        }
    }

    static func converge(_ badge: Badge) async throws {
        try await badge.team.sim.settle()
        try await badge.team.sim.expectConverged()
    }

    static func overrides(_ badge: Badge, _ client: SimClient) -> [OverrideKey: Wiretuner_Doc_V1_Override] {
        Symbols.liveOverrides(of: badge.instance, in: client.state)
    }

    /// Same override, two editors typing: Fugue merges both into the one element.
    @Test func sameTextTyping() async throws {
        let badge = try await Self.badge("override-typing", seed: 2801)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        var element = Wiretuner_Doc_V1_Override()
        element.masterNode = badge.label.proto
        element.property = .text
        await team.ana.perform(OpsCommand("Override text", ops: [
            Ops.elementInsert(badge.instance, SymbolFields.overrides, positions: [[0x80]], values: .with { $0.instance.overrides = [element] })]))
        try await team.sim.settle()
        let id = try #require(team.ana.state.liveElements(badge.instance, SymbolFields.overrides).first)
        let text = SymbolFields.override(id).child(4)
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            await team.ben.perform(OpsCommand("Type", ops: [Ops.textInsert(badge.instance, text, "two")]))
        } theirs: {
            await team.ana.perform(OpsCommand("Type", ops: [Ops.textInsert(badge.instance, text, "one")]))
        }
        try await Self.converge(badge)
        let merged = try #require(team.ana.state.text(badge.instance, text)?.string)
        #expect(merged == "onetwo" || merged == "twoone")
        for person in team.everyone {
            #expect(person.state.text(badge.instance, text)?.string == merged)
            #expect(Self.overrides(badge, person)[OverrideKey(master: badge.label, property: .text)] != nil)
        }
    }

    /// Same colour, two editors: LWW on the element's register; every replica draws the winner.
    @Test func sameColorLastWriterWins() async throws {
        let badge = try await Self.badge("override-lww", seed: 2802)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        try await Self.set(badge, team.ana, .fill(Self.red))
        try await team.sim.settle()
        try Self.expectDrawn(badge, Self.red)
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            try await Self.set(badge, team.ana, .fill(Self.green))
        }
        try await Self.converge(badge)
        let id = try #require(team.ana.state.liveElements(badge.instance, SymbolFields.overrides).first)
        let winner = try #require(team.ana.state.store.register(badge.instance, SymbolFields.overrideFill(id))?.op)
        try Self.expectDrawn(badge, winner.replica == (await team.ben.store.replica) ? Self.blue : Self.green)
    }

    /// Duplicate creation: two elements for one (part, fill); the greater element id is drawn, the
    /// other retained.
    @Test func duplicateCreation() async throws {
        let badge = try await Self.badge("override-duplicate", seed: 2803)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            try await Self.set(badge, team.ana, .fill(Self.red))
        }
        try await Self.converge(badge)
        let elements = team.ana.state.liveElements(badge.instance, SymbolFields.overrides)
        #expect(elements.count == 2)
        let greater = try #require(elements.max())
        let drawn = team.ana.state.props(badge.instance).instance.overrides.first { OpID(element: $0.id) == greater }?.fill
        try Self.expectDrawn(badge, drawn)
        for person in team.everyone { #expect(Self.overrides(badge, person).count == 1) }
    }

    /// Reset vs. edit: the element stays deleted (the master's grey is drawn) with the edit kept;
    /// *Restore* brings the edited override back.
    @Test func resetVersusEdit() async throws {
        let badge = try await Self.badge("override-reset", seed: 2804)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        try await Self.set(badge, team.ana, .fill(Self.red))
        try await team.sim.settle()
        let id = try #require(team.ana.state.liveElements(badge.instance, SymbolFields.overrides).first)
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            await team.ana.perform(ResetOverrides([badge.instance], key: OverrideKey(master: badge.square, property: .fill)))
        }
        try await Self.converge(badge)
        try Self.expectDrawn(badge, Self.grey, "reset")
        await team.cy.perform(OpsCommand("Restore", ops: [Ops.elementDelete(badge.instance, [SymbolFields.override(id)], deleted: false)]))
        try await Self.converge(badge)
        try Self.expectDrawn(badge, Self.blue, "restored with the edit")
    }

    /// Reset all vs. edit: both elements stay deleted -- the part is drawn, in the master's grey --
    /// though Ben hid it and recoloured it meanwhile.
    @Test func resetAllVersusEdit() async throws {
        let badge = try await Self.badge("override-reset-all", seed: 2805)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        try await Self.set(badge, team.ana, .fill(Self.red))
        try await Self.set(badge, team.ana, .hidden(false))
        try await team.sim.settle()
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .hidden(true))
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            await team.ana.perform(ResetOverrides([badge.instance]))
        }
        try await Self.converge(badge)
        #expect(team.ana.state.liveElements(badge.instance, SymbolFields.overrides).isEmpty)
        try Self.expectDrawn(badge, Self.grey)
    }

    /// Master node delete vs. edit: the override is retained and draws nothing while its part is
    /// deleted, then draws again, with the edit, once the part is restored.
    @Test func masterNodeDeleteVersusEdit() async throws {
        let badge = try await Self.badge("override-master-delete", seed: 2806)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        try await Self.set(badge, team.ana, .fill(Self.red))
        try await team.sim.settle()
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            await team.ana.perform(OpsCommand("Delete", ops: [Ops.setDeleted(badge.square)]))
        }
        try await Self.converge(badge)
        try Self.expectDrawn(badge, nil, "the part is deleted")
        #expect(team.ana.state.liveElements(badge.instance, SymbolFields.overrides).count == 1)
        await team.cy.perform(OpsCommand("Restore", ops: [Ops.setDeleted(badge.square, false)]))
        try await Self.converge(badge)
        try Self.expectDrawn(badge, Self.blue)
    }

    /// Swap vs. edit: the swap stands; the override, keyed to the old symbol's part, reads as
    /// nothing under the new symbol and returns, with the edit, on a swap back.
    @Test func swapVersusEdit() async throws {
        let badge = try await Self.badge("override-swap", seed: 2807)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        let other = try await Self.square(team.ana, fill: Self.yellow)
        let created = try #require(await team.ana.perform(ConvertToSymbol([other], name: "Seal"))).createdNodes
        let seal = created[0]
        await Workload.delete(team.ana, [try #require(created.last)])
        try await Self.set(badge, team.ana, .fill(Self.red))
        try await team.sim.settle()
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            await team.ana.perform(SwapSymbol([badge.instance], to: seal))
        }
        try await Self.converge(badge)
        for person in team.everyone {
            #expect(Symbols.symbol(of: badge.instance, in: person.state) == seal)
            #expect(Self.overrides(badge, person).isEmpty)
        }
        try Self.expectDrawn(badge, Self.yellow, "the seal is drawn, without the override")
        await team.cy.perform(SwapSymbol([badge.instance], to: badge.symbol))
        try await Self.converge(badge)
        try Self.expectDrawn(badge, Self.blue, "swapped back, the override returns with the edit")
    }

    /// Release vs. edit: the released copy is drawn as resolved at the release (red); the edit
    /// lands on the deleted instance, for *Restore*.
    @Test func releaseVersusEdit() async throws {
        let badge = try await Self.badge("override-release", seed: 2808)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        try await Self.set(badge, team.ana, .fill(Self.red))
        try await team.sim.settle()
        _ = try await LibraryScenarioTests.concurrently(team, offline: false) {
            try await Self.set(badge, team.ben, .fill(Self.blue))
        } theirs: {
            await team.ana.perform(ReleaseInstances([badge.instance]))
        }
        try await Self.converge(badge)
        try Self.expectDrawn(badge, Self.red)
        for person in team.everyone {
            #expect(!person.state.isLive(badge.instance))
            #expect(person.state.props(badge.instance).instance.overrides.first?.fill == Self.blue)
        }
    }
}
