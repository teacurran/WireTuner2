import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// LIB-023: layers, symbols and styles under concurrency (layers.adoc, library.adoc and
/// styles.adoc, "Merge semantics"), through the simulator.  Each case runs twice: live (the
/// concurrent edits cross within a dropped connection, which merges without asking) and with the
/// editor offline for 12 simulated hours.  Every run converges to one state hash across three
/// clients and the server; the offline run asserts the review-sheet rows its page names -- and
/// that none are listed where the page says nothing is.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct LibraryScenarioTests {
    static let grey = Wiretuner_Doc_V1_ColorRef.with { $0.inline.rgb = .with { $0.r = 0.5; $0.g = 0.5; $0.b = 0.5 } }
    static let red = Wiretuner_Doc_V1_ColorRef.with { $0.inline.rgb.r = 1 }
    static let blue = Wiretuner_Doc_V1_ColorRef.with { $0.inline.rgb.b = 1 }

    struct Team {
        let sim: Simulation
        let ana: SimClient
        /// The one whose concurrent work is measured on reconnect; he examines his reviews.
        let ben: SimClient
        let cy: SimClient
        var everyone: [SimClient] { [ana, ben, cy] }
    }

    static func team(_ name: String, seed: UInt64) async throws -> Team {
        let sim = try await Simulation(name: name, seed: Simulation.seed(seed), scale: 0.005)
        let conditions = LinkConditions(latency: .milliseconds(30), jitter: .milliseconds(20))
        let ana = try await sim.addClient("ana", conditions: conditions)
        let ben = try await sim.addClient("ben", conditions: conditions, keepsMergedResult: false)
        let cy = try await sim.addClient("cy", conditions: conditions)
        return Team(sim: sim, ana: ana, ben: ben, cy: cy)
    }

    /// Ben's `mine` and the others' `theirs`, concurrent: Ben is cut off while both happen, then
    /// back at once (live) or after 12 hours (offline).  Returns what his reconcile measured.
    static func concurrently(_ team: Team, offline: Bool, mine: () async throws -> Void, theirs: () async throws -> Void) async throws -> ReviewModel? {
        try await team.sim.offline(team.ben, hours: offline ? 12 : 0) {
            try await mine()
            try await theirs()
            try await team.sim.settle([team.ana, team.cy])
        }
    }

    /// Live: nothing held Ben's work.  Offline: the rows are exactly `rows`; then *Keep the merged
    /// result*.  Either way everyone converges.
    static func expect(_ team: Team, _ review: ReviewModel?, offline: Bool, rows: Set<ReviewRow>) async throws {
        if offline {
            let review = try #require(review)
            #expect(ReviewRow.rows(review) == rows)
            if rows.isEmpty, review.removedTargets.isEmpty { #expect(!review.holdsOutbox, "nothing overlapped: merged and sent") }
            if review.holdsOutbox { try await team.ben.keepMerged() }
        } else {
            #expect(review?.holdsOutbox != true, "a brief drop merges without asking")
            #expect(team.ben.reviews == 0)
        }
        try await team.sim.settle()
        try await team.sim.expectConverged()
    }

    static func layer(_ client: SimClient, _ name: String) async throws -> OpID {
        try #require(await client.perform(CreateLayer(name: name))?.createdNodes.first)
    }

    static func rect(_ width: Double) -> Wiretuner_Doc_V1_NodeProps {
        .with { $0.rect.size.width = width; $0.rect.size.height = width }
    }

    /// Draws a rectangle straight onto `layer` (a pen or shape tool's create under that layer).
    static func draw(_ client: SimClient, on layer: OpID) async throws -> OpID {
        let last = client.state.store.children(layer).last.flatMap { client.state.store.placement($0)?.position }
        let key = try FractionalIndex.between(last, nil, suffix: 11)
        return try #require(await client.perform(OpsCommand("Rectangle", ops: [Ops.create(parent: layer, position: key, props: rect(12))]))?.createdNodes.first)
    }

    // MARK: Layers

    /// Remove layer vs. draw on it: the layer and the objects Ana saw on it are deleted; Ben's new
    /// rectangle stays live, shown on the default layer.  Offline, it is listed as added to a layer
    /// that was removed (*Edited and deleted* through its deleted layer).
    @Test(arguments: [false, true]) func removeLayerVersusDrawOnIt(offline: Bool) async throws {
        let team = try await Self.team("lib-remove-layer-\(offline)", seed: 2301)
        defer { Task { await team.sim.shutdown() } }
        let shapes = try await Workload.createShapes(team.ana, count: 2)
        let art = try await Self.layer(team.ana, "Art")
        await team.ana.perform(MoveObjectsToLayer(shapes, to: art))
        try await team.sim.settle()
        var drawn: OpID?
        let review = try await Self.concurrently(team, offline: offline) {
            drawn = try await Self.draw(team.ben, on: art)
        } theirs: {
            await team.ana.perform(RemoveLayers([art]))
        }
        let rectangle = try #require(drawn)
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: rectangle, kind: .editVsDelete, attributes: [])])
        if offline { #expect(review?.entries.first?.deletedAncestor == art) }
        for person in team.everyone {
            let order = LayerOrder(person.state)
            #expect(person.state.isLive(rectangle) && !order.isLive(art))
            #expect(order.layer(of: rectangle, in: person.state) == order.defaultLayer)
            #expect(shapes.allSatisfy { !person.state.isLive($0) })
        }
    }

    /// Overlapping layer merges onto different targets: every object of the shared source ends on
    /// one of the two targets, both merges delete it, nothing is lost.  Offline: its objects are
    /// *Both moved*, and the source layer *Edited and deleted* (both deleted it, and `merged_into`
    /// names each side's target: the later write stands).
    @Test(arguments: [false, true]) func overlappingLayerMerges(offline: Bool) async throws {
        let team = try await Self.team("lib-merge-layers-\(offline)", seed: 2302)
        defer { Task { await team.sim.shutdown() } }
        let shapes = try await Workload.createShapes(team.ana, count: 4)
        let bottom = try #require(LayerOrder(team.ana.state).layers.first?.id)
        let middle = try await Self.layer(team.ana, "Middle")
        let top = try await Self.layer(team.ana, "Top")
        await team.ana.perform(MoveObjectsToLayer([shapes[1]], to: middle))
        await team.ana.perform(MoveObjectsToLayer([shapes[2], shapes[3]], to: top))
        try await team.sim.settle()
        let review = try await Self.concurrently(team, offline: offline) {
            await team.ben.perform(MergeLayers([middle, top]))
        } theirs: {
            await team.ana.perform(MergeLayers([bottom, top]))
        }
        try await Self.expect(team, review, offline: offline, rows: [
            ReviewRow(node: shapes[2], kind: .moveVsMove, attributes: ["Position"]),
            ReviewRow(node: shapes[3], kind: .moveVsMove, attributes: ["Position"]),
            ReviewRow(node: top, kind: .editVsDelete, attributes: ["Deleted", "Merged into"]),
        ])
        for person in team.everyone {
            let order = LayerOrder(person.state)
            #expect(order.isLive(bottom) && order.isLive(middle) && !order.isLive(top))
            #expect(shapes.allSatisfy(person.state.isLive))
            for shape in shapes[2...] { #expect([bottom, middle].contains(order.layer(of: shape, in: person.state))) }
        }
    }

    /// Lock vs. an in-progress drag: the drag finishes (a lock is advisory; the engine applies any
    /// op) and the layer is locked.  Different nodes: nothing is listed.
    @Test(arguments: [false, true]) func lockVersusInProgressDrag(offline: Bool) async throws {
        let team = try await Self.team("lib-lock-drag-\(offline)", seed: 2303)
        defer { Task { await team.sim.shutdown() } }
        let shapes = try await Workload.createShapes(team.ana, count: 1)
        let art = try await Self.layer(team.ana, "Art")
        await team.ana.perform(MoveObjectsToLayer(shapes, to: art))
        try await team.sim.settle()
        let review = try await Self.concurrently(team, offline: offline) {
            for step in 1...5 {
                await team.ben.perform(SetTransforms([(shapes[0], WTGeometry.AffineTransform.translation(x: Double(step * 10), y: 0))], label: "Drag"))
            }
        } theirs: {
            await team.ana.perform(SetLayerFlag([art], .locked, true))
        }
        try await Self.expect(team, review, offline: offline, rows: [])
        for person in team.everyone {
            #expect(LayerOrder(person.state).layer(art)?.locked == true)
            #expect(person.state.props(shapes[0]).rect.common.transform.tx == 50)
        }
    }

    // MARK: Symbols

    /// A symbol "Star" made of one rectangle, with an instance where the rectangle was.
    struct Star {
        let symbol: OpID
        let part: OpID
        let instance: OpID
    }

    static func star(_ team: Team) async throws -> Star {
        let part = try await Workload.createShapes(team.ana, count: 1)[0]
        await team.ana.perform(SetNameOrNote([part], .name, "Point"))
        let change = try #require(await team.ana.perform(ConvertToSymbol([part], name: "Star")))
        let created = change.createdNodes
        try await team.sim.settle()
        return Star(symbol: created[0], part: part, instance: try #require(created.last))
    }

    /// Remove symbol vs. place an instance: the instance placed concurrently references a deleted
    /// symbol and draws as its placeholder on every client; restoring the symbol draws it again.
    /// Offline, the instance is listed as "placed an instance of a removed symbol" (and live the
    /// brief drop merges it without asking).
    @Test(arguments: [false, true]) func removeSymbolVersusPlaceInstance(offline: Bool) async throws {
        let team = try await Self.team("lib-remove-symbol-\(offline)", seed: 2304)
        defer { Task { await team.sim.shutdown() } }
        let star = try await Self.star(team)
        var placed: OpID?
        let review = try await Self.concurrently(team, offline: offline) {
            placed = try #require(await team.ben.perform(PlaceInstance(star.symbol, at: Point(x: 100, y: 100)))?.createdNodes.last)
        } theirs: {
            await team.ana.perform(RemoveSymbols([star.symbol], instances: .delete, in: team.ana.state))
        }
        let instance = try #require(placed)
        if offline {
            #expect(review?.removedTargets.map(\.kind) == [.removedSymbol] && review?.removedTargets.first?.object == instance)
            #expect(review?.removedTargets.first?.target == star.symbol)
        }
        try await Self.expect(team, review, offline: offline, rows: [])
        for person in team.everyone {
            #expect(!person.state.isLive(star.instance) && !person.state.isLive(star.symbol))
            #expect(person.state.isLive(instance) && Symbols.symbol(of: instance, in: person.state) == nil, "the placeholder")
        }
        await team.cy.perform(OpsCommand("Restore symbol", ops: [Ops.setDeleted(star.symbol, false), Ops.setDeleted(star.part, false)]))
        try await team.sim.settle()
        try await team.sim.expectConverged()
        for person in team.everyone { #expect(Symbols.symbol(of: instance, in: person.state) == star.symbol) }
    }

    /// Two editors in one symbol: the artwork merges as objects do -- Ana's rename and Ben's move
    /// of the same part both stand.  Offline: the part is *Both edited* (*Name*, *Transform*).
    @Test(arguments: [false, true]) func twoEditorsInOneSymbol(offline: Bool) async throws {
        let team = try await Self.team("lib-symbol-editors-\(offline)", seed: 2305)
        defer { Task { await team.sim.shutdown() } }
        let star = try await Self.star(team)
        let review = try await Self.concurrently(team, offline: offline) {
            await team.ben.perform(SetTransforms([(star.part, WTGeometry.AffineTransform.translation(x: 5, y: 5))]))
        } theirs: {
            await team.ana.perform(SetNameOrNote([star.part], .name, "Ray"))
        }
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: star.part, kind: .bothEdited, attributes: ["Name", "Transform"])])
        for person in team.everyone {
            #expect(person.state.props(star.part).rect.common.name == "Ray")
            #expect(person.state.props(star.part).rect.common.transform.tx == 5)
        }
    }

    /// Release vs. a symbol edit: the released copy keeps the artwork as Ana saw it -- Ben's rename
    /// of the part does not reach it.  Ben's move of the instance meets the release: offline it is
    /// *Edited and deleted* (*Deleted*), and *Restore* brings the instance back beside the group.
    @Test(arguments: [false, true]) func releaseVersusSymbolEdit(offline: Bool) async throws {
        let team = try await Self.team("lib-release-\(offline)", seed: 2306)
        defer { Task { await team.sim.shutdown() } }
        let star = try await Self.star(team)
        var group: OpID?
        let review = try await Self.concurrently(team, offline: offline) {
            await team.ben.perform(SetNameOrNote([star.part], .name, "Renamed"))
            await team.ben.perform(SetTransforms([(star.instance, WTGeometry.AffineTransform.translation(x: 30, y: 30))]))
        } theirs: {
            group = try #require(await team.ana.perform(ReleaseInstances([star.instance]))?.createdNodes.first)
        }
        let released = try #require(group)
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: star.instance, kind: .editVsDelete, attributes: ["Deleted"])])
        for person in team.everyone {
            let copies = person.state.liveChildren(released)
            #expect(copies.count == 1 && person.state.props(copies[0]).rect.common.name == "Point", "the copy is as released")
            #expect(person.state.props(star.part).rect.common.name == "Renamed")
            #expect(!person.state.isLive(star.instance))
        }
        if offline, let entry = review?.entries.first {
            try await ReviewChoices.restore(entry, on: team.ben)
            try await team.sim.settle()
            try await team.sim.expectConverged()
            for person in team.everyone { #expect(person.state.isLive(star.instance) && person.state.isLive(released)) }
        }
    }

    // MARK: Styles

    /// The fill an object is drawn with: its effective look through its graphic style.
    static func drawnFill(_ node: OpID, _ state: EngineState) -> Wiretuner_Doc_V1_ColorRef? {
        var props = state.props(node)
        var order: [AppearanceRow] = []
        _ = StyleAppearance.apply(GraphicStyleResolver(state), to: &props, order: &order, node: node, state: state)
        return props.path.appearance.fills.first?.settings.basic.color
    }

    /// Two grey squares using the style "Callout" (made from the first), and a red square outside it.
    static func callout(_ team: Team) async throws -> (style: OpID, users: [OpID], red: OpID) {
        let users = try await SwatchScenarioTests.squares(team.ana, 2, fill: grey)
        let red = try await SwatchScenarioTests.squares(team.ana, 1, fill: Self.red)[0]
        let style = try #require(await team.ana.perform(CreateGraphicStyle(.selection(users[0]), name: "Callout", applyTo: users))?
            .createdNodes.first { team.ana.state.store.kind($0) == 154 })
        try await team.sim.settle()
        #expect(users.allSatisfy { drawnFill($0, team.ana.state) == grey })
        return (style, users, red)
    }

    /// Redefine vs. override: different nodes -- the overriding object shows its override, every
    /// other user of the style the redefinition.  Nothing to review.
    @Test(arguments: [false, true]) func redefineVersusOverride(offline: Bool) async throws {
        let team = try await Self.team("lib-redefine-\(offline)", seed: 2307)
        defer { Task { await team.sim.shutdown() } }
        let callout = try await Self.callout(team)
        let overridden = callout.users[1]
        let review = try await Self.concurrently(team, offline: offline) {
            var values = Wiretuner_Doc_V1_NodeProps()
            values.path.appearance.fills = [.with { $0.settings.kind = .basic; $0.settings.basic.color = Self.blue }]
            let fills = RegisterPath([NodeKind.path.rawValue, 3, 1])
            await team.ben.perform(OpsCommand("Change fill color", ops: [Ops.elementInsert(overridden, fills, positions: [[0x80]], values: values)]))
        } theirs: {
            await team.ana.perform(RedefineGraphicStyle(callout.style, from: .object(callout.red), in: team.ana.state))
        }
        try await Self.expect(team, review, offline: offline, rows: [])
        for person in team.everyone {
            #expect(Self.drawnFill(callout.users[0], person.state) == Self.red, "the redefinition")
            #expect(Self.drawnFill(overridden, person.state) == Self.blue, "the override")
        }
    }

    /// Remove style vs. apply: Ana's removal keeps the look of every object she saw using the
    /// style; the object Ben styled concurrently points at the deleted style, which still resolves
    /// through the deleted node's registers, so it looks as styled.  Offline it is listed as "uses a
    /// removed style".
    @Test(arguments: [false, true]) func removeStyleVersusApply(offline: Bool) async throws {
        let team = try await Self.team("lib-remove-style-\(offline)", seed: 2308)
        defer { Task { await team.sim.shutdown() } }
        let callout = try await Self.callout(team)
        let review = try await Self.concurrently(team, offline: offline) {
            await team.ben.perform(ApplyGraphicStyle(callout.style, to: [callout.red], in: team.ben.state))
        } theirs: {
            await team.ana.perform(RemoveGraphicStyle(callout.style, in: team.ana.state))
        }
        if offline {
            #expect(review?.removedTargets.map(\.kind) == [.removedStyle] && review?.removedTargets.first?.object == callout.red)
        }
        try await Self.expect(team, review, offline: offline, rows: [])
        for person in team.everyone {
            #expect(!person.state.isLive(callout.style))
            #expect(callout.users.allSatisfy { Self.drawnFill($0, person.state) == Self.grey }, "the look Ana saw is kept")
            #expect(Self.drawnFill(callout.red, person.state) == Self.grey, "styled through the deleted style")
        }
    }
}
