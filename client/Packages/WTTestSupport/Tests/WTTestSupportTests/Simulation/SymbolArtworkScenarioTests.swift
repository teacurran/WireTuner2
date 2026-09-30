import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// Two people in one symbol (library.adoc, "Working together" and "Merge semantics"): drawing into
/// its artwork at once through the symbol editing window's commands (`SymbolPlacedCommand`, LIB-012),
/// the same attribute of one part of it, and concurrent settings of one text override's last
/// paragraph (`Override.tail_paragraph`, LIB-027).  Each case runs live (the edits cross within a
/// dropped connection) and with Ben offline for 12 simulated hours; every run converges to one
/// state hash across three clients and the server, and the offline run asserts the review rows the
/// page names.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct SymbolArtworkScenarioTests {
    typealias Team = LibraryScenarioTests.Team

    /// A closed triangle drawn on the symbol's canvas at `x`: the Pen's `CreatePath`, placed in the
    /// symbol as the symbol editing window places what its tools create.
    static func draw(_ client: SimClient, in symbol: OpID, x: Double) async throws -> OpID {
        let points = [(x, 0.0), (x + 10, 0.0), (x + 5, 8.0)].map { VectorPoint(anchor: Point(x: $0.0, y: $0.1)) }
        let command = SymbolPlacedCommand.placing(CreatePath(contours: [NewContour(closed: true, points: points)]), in: symbol)
        return try Workload.created(await client.perform(command), by: client, "a triangle in the symbol")[0]
    }

    // MARK: Drawing into one symbol

    /// Two people draw into one symbol's artwork at once: both new paths are the symbol's -- above
    /// the part it had, in one order everywhere -- and every instance draws all three.  Different
    /// objects: nothing is listed.
    @Test(arguments: [false, true]) func twoPeopleDrawIntoOneSymbol(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("symbol-draw-\(offline)", seed: 2901)
        defer { Task { await team.sim.shutdown() } }
        let star = try await LibraryScenarioTests.star(team)
        var drawn: (ben: OpID?, ana: OpID?)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            drawn.ben = try await Self.draw(team.ben, in: star.symbol, x: 40)
        } theirs: {
            drawn.ana = try await Self.draw(team.ana, in: star.symbol, x: 80)
        }
        let ben = try #require(drawn.ben), ana = try #require(drawn.ana)
        try await LibraryScenarioTests.expect(team, review, offline: offline, rows: [])
        let order = team.ana.state.liveChildren(star.symbol)
        #expect(Set(order) == [star.part, ben, ana] && order.first == star.part, "both drawings above the part")
        for person in team.everyone {
            #expect(person.state.liveChildren(star.symbol) == order, "\(person.name) has the artwork in one order")
            #expect(Set(Symbols.artworkNodes(of: star.symbol, in: person.state)).isSuperset(of: [ben, ana]))
            #expect(Symbols.symbol(of: star.instance, in: person.state) == star.symbol)
            #expect(person.state.nodeKind(ben) == .path && person.state.nodeKind(ana) == .path)
            #expect(Symbols.canvasBounds(of: star.symbol, in: person.state).maxX >= 90, "the canvas (and every instance) takes in both drawings")
        }
    }

    /// Both rename the same part of one symbol: the later name stands everywhere.  Offline the part
    /// is listed as *Same attribute* (*Name*), as the page says of the same attribute on one object.
    @Test(arguments: [false, true]) func sameAttributeOfOnePartOfASymbol(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("symbol-same-attribute-\(offline)", seed: 2902)
        defer { Task { await team.sim.shutdown() } }
        let star = try await LibraryScenarioTests.star(team)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(SymbolPlacedCommand.placing(SetNameOrNote([star.part], .name, "Ben's ray"), in: star.symbol))
        } theirs: {
            await team.ana.perform(SymbolPlacedCommand.placing(SetNameOrNote([star.part], .name, "Ana's ray"), in: star.symbol))
        }
        try await LibraryScenarioTests.expect(team, review, offline: offline,
                                              rows: offline ? [ReviewRow(node: star.part, kind: .sameRegister, attributes: ["Name"])] : [])
        let name = team.ana.state.props(star.part).rect.common.name
        #expect(name == "Ben's ray" || name == "Ana's ray")
        for person in team.everyone { #expect(person.state.props(star.part).rect.common.name == name) }
    }

    // MARK: Tail paragraph of one text override

    /// Ana's badge with its label overridden ("Sale") and one setting of the override's last
    /// paragraph written, so the element carries the tail registers (the first write copies the
    /// master's settings with it, library.adoc's LIB-027 note).
    static func overriddenBadge(_ name: String, seed: UInt64) async throws -> OverrideScenarioTests.Badge {
        let badge = try await OverrideScenarioTests.badge(name, seed: seed)
        let ana = badge.team.ana
        try #require(await ana.perform(OverrideText(badge.instance, master: badge.label, edits: [.replace(0..<5, with: "Sale")])))
        try #require(await ana.perform(Self.tail(badge, [[4]]) { $0.leftIndent = 1 }))
        try await badge.team.sim.settle()
        return badge
    }

    /// The last paragraph's registers `fields` of the badge's label override, from `set`.
    static func tail(_ badge: OverrideScenarioTests.Badge, _ fields: [[UInt32]], _ set: (inout Wiretuner_Doc_V1_ParagraphProps) -> Void) -> OverrideText {
        var props = Wiretuner_Doc_V1_ParagraphProps()
        set(&props)
        return OverrideText(badge.instance, master: badge.label, edits: [.paragraph(4..<4, props, fields: fields)], label: "Paragraph")
    }

    /// The label's last paragraph as the instance shows it.
    static func shown(_ badge: OverrideScenarioTests.Badge, _ client: SimClient) throws -> Wiretuner_Doc_V1_ParagraphProps {
        try #require(Symbols.textNode(badge.label, in: badge.instance, state: client.state)?.paragraphs.last?.props)
    }

    /// Different settings of the tail paragraph: Ben centres it while Ana adds space below; both keep
    /// theirs, with Ana's earlier indent.  Offline the instance is listed as *Both edited* -- its
    /// override edited on both sides -- and nothing as *Same attribute*.
    @Test(arguments: [false, true]) func differentTailParagraphSettingsBothStand(offline: Bool) async throws {
        let badge = try await Self.overriddenBadge("override-tail-different-\(offline)", seed: 2903)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            try #require(await team.ben.perform(Self.tail(badge, [[1]]) { $0.alignment = .center }))
        } theirs: {
            try #require(await team.ana.perform(Self.tail(badge, [[8]]) { $0.spaceBelow = 6 }))
        }
        try await LibraryScenarioTests.expect(team, review, offline: offline,
                                              rows: offline ? [ReviewRow(node: badge.instance, kind: .bothEdited, attributes: ["Overrides"])] : [])
        for person in team.everyone {
            let shown = try Self.shown(badge, person)
            #expect(shown.alignment == .center && shown.spaceBelow == 6 && shown.leftIndent == 1, "\(person.name) keeps both settings")
            #expect(Symbols.textNode(badge.label, in: badge.instance, state: person.state)?.string == "Sale")
        }
    }

    /// The same setting of the tail paragraph: Ben centres it while Ana right-aligns it; the later
    /// write stands everywhere (LWW) and Ana's indent is untouched.  Offline the instance is listed
    /// as *Same attribute*, as the page's merge table says.
    @Test(arguments: [false, true]) func sameTailParagraphSettingIsLastWriterWins(offline: Bool) async throws {
        let badge = try await Self.overriddenBadge("override-tail-same-\(offline)", seed: 2904)
        defer { Task { await badge.team.sim.shutdown() } }
        let team = badge.team
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            try #require(await team.ben.perform(Self.tail(badge, [[1]]) { $0.alignment = .center }))
        } theirs: {
            try #require(await team.ana.perform(Self.tail(badge, [[1]]) { $0.alignment = .right }))
        }
        try await LibraryScenarioTests.expect(team, review, offline: offline,
                                              rows: offline ? [ReviewRow(node: badge.instance, kind: .sameRegister, attributes: ["Overrides"])] : [])
        let element = try #require(team.ana.state.liveElements(badge.instance, SymbolFields.overrides).first)
        let register = SymbolFields.overrideTailParagraph(element).child(1)
        let winner = try #require(team.ana.state.store.register(badge.instance, register)?.op)
        let expected: Wiretuner_Doc_V1_Alignment = winner.replica == (await team.ben.store.replica) ? .center : .right
        for person in team.everyone {
            let shown = try Self.shown(badge, person)
            #expect(shown.alignment == expected && shown.leftIndent == 1, "\(person.name) shows the later alignment")
        }
    }
}
