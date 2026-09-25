import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

/// COLOR-022: the colour list under concurrency (swatches.adoc, "Merge semantics"; tints.adoc),
/// through the simulator.  Each scenario converges to one hash (`expectConverged`) and every
/// client reads out the same panel order and the same resolved colour for every object, which
/// match the expected read-out.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct SwatchScenarioTests {
    static let grape = Color(cyan: 0.5, magenta: 0.8, yellow: 0, black: 0.1)
    static let plum = Color(cyan: 0.2, magenta: 0.9, yellow: 0.1, black: 0.3)
    static let red = Color(red: 230.0 / 255, green: 57.0 / 255, blue: 70.0 / 255)

    /// What the Swatches panel lists and what every object on the canvas looks like.
    struct Readout: Equatable, CustomStringConvertible {
        var panel: [String]
        var colors: [OpID: Color?]

        var description: String { "panel \(panel), colors \(colors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.map { "\($0)" } ?? "none")" })" }
    }

    static func readout(_ client: SimClient, objects: [OpID]) -> Readout {
        let state = client.state
        let resolver = ColorResolver(state)
        var colors: [OpID: Color?] = [:]
        for object in objects where state.isLive(object) {
            colors[object] = resolver.color(fill(object, state))
        }
        return Readout(panel: SwatchList(state).swatches.map(\.name), colors: colors)
    }

    /// Every client reads out the same, and returns it.
    static func agreed(_ clients: [SimClient], objects: [OpID]) -> Readout {
        let first = readout(clients[0], objects: objects)
        for client in clients.dropFirst() {
            #expect(readout(client, objects: objects) == first, "\(client.name) reads differently")
        }
        return first
    }

    static func fill(_ node: OpID, _ state: EngineState) -> Wiretuner_Doc_V1_ColorRef {
        state.props(node).path.appearance.fills.first?.settings.basic.color ?? Wiretuner_Doc_V1_ColorRef()
    }

    /// `count` filled squares in one change.
    static func squares(_ client: SimClient, _ count: Int, fill: Wiretuner_Doc_V1_ColorRef) async throws -> [OpID] {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        var basic = Wiretuner_Doc_V1_Fill()
        basic.settings.kind = .basic
        basic.settings.basic.color = fill
        appearance.fills = [basic]
        var commands: [any Command] = []
        for index in 0..<count {
            var points: [VectorPoint] = []
            for corner in 0..<4 {
                let x = Double(index) * 20 + Double(corner % 2) * 10
                let y = Double(corner / 2) * 10
                points.append(VectorPoint(anchor: Point(x: x, y: y)))
            }
            commands.append(CreatePath(contours: [NewContour(closed: true, points: points)], appearance: appearance))
        }
        return try Workload.created(await client.perform(CompositeCommand("Squares", commands)), by: client, "squares")
    }

    static func swatch(_ client: SimClient, _ color: Color, _ name: String) async throws -> OpID {
        try #require(await client.perform(AddSwatch(color, name: name))).createdNodes[0]
    }

    static func reference(_ client: SimClient, _ swatch: OpID) -> Wiretuner_Doc_V1_ColorRef {
        SwatchList(client.state).resolver.reference(to: swatch)
    }

    /// Clients sharing the defaults, one editor each.
    static func start(_ sim: Simulation, _ names: [String], conditions: LinkConditions = .perfect) async throws -> [SimClient] {
        var clients: [SimClient] = []
        for name in names {
            clients.append(try await sim.addClient(name, conditions: conditions))
        }
        await clients[0].perform(CreateDefaultSwatches())
        try await sim.settle()
        return clients
    }

    /// A recolor storm: five clients redefine one swatch forty times each with latency and
    /// reordering; the register's greatest write stands everywhere and every object using the
    /// swatch shows it.
    @Test func recolorStormOnOneSwatchFromFiveClients() async throws {
        let sim = try await Simulation(name: "swatch-storm", seed: Simulation.seed(2201), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let conditions = LinkConditions(latency: .milliseconds(120), jitter: .milliseconds(60), reorder: 0.3, reorderWindow: .milliseconds(500))
        let people = try await Self.start(sim, ["ana", "ben", "cy", "dee", "eli"], conditions: conditions)
        let grape = try await Self.swatch(people[0], Self.grape, "Grape")
        let objects = try await Self.squares(people[0], 12, fill: Self.reference(people[0], grape))
        try await sim.settle()
        var random = sim.random.fork(22)
        var written: [String: Color] = [:]
        try await sim.steps(40, every: .milliseconds(400)) { _ in
            for person in people where random.chance(0.9) {
                let color = Color(red: Double(random.within(0...255)) / 255, green: Double(random.within(0...255)) / 255,
                                  blue: Double(random.within(0...255)) / 255)
                if let change = await person.perform(RedefineSwatch(grape, to: color, autoRename: false)) {
                    written[change.label] = color
                }
            }
        }
        try await sim.settle()
        try await sim.expectConverged()
        #expect(written.count > 100)
        // Expected: the colour of the change holding the register's winning write.
        let state = people[0].state
        let winner = try #require(state.store.register(grape, SwatchFields.value)?.op)
        let log = try #require(await sim.server?.log(sim.documentID))
        let change = try #require(log.map(\.change).first { $0.replica == winner.replica && $0.opIDs.contains(winner) })
        let expected = try #require(written[change.label])
        let readout = Self.agreed(people, objects: objects)
        #expect(readout.panel == ["White", "Black", "Registration", "Grape"])
        #expect(objects.allSatisfy { readout.colors[$0] == expected })
    }

    /// *Delete Unused Named Colors* on a partitioned client while another applies one of the
    /// unused colours: the use keeps its look (the cache), the swatch is gone from every panel,
    /// and *Restore* brings it back and re-links the objects with no write on them.
    @Test func deleteUnusedRacingUseUnderPartition() async throws {
        let sim = try await Simulation(name: "swatch-delete-unused", seed: Simulation.seed(2202), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let people = try await Self.start(sim, ["ana", "ben"])
        let (ana, ben) = (people[0], people[1])
        let grape = try await Self.swatch(ana, Self.grape, "Grape")
        let plum = try await Self.swatch(ana, Self.plum, "Plum")
        let red = try await Self.swatch(ana, Self.red, "Red")
        let objects = try await Self.squares(ana, 4, fill: Self.reference(ana, red))
        try await sim.settle()
        ana.goOffline()
        #expect(DeleteUnusedSwatches.unused(in: ana.state) == [grape, plum])
        #expect(await ana.perform(DeleteUnusedSwatches()) != nil)
        #expect(await ben.perform(ApplyColor(Array(objects[0..<2]), target: .fill, color: Self.reference(ben, grape), name: "Grape")) != nil)
        try await sim.settle([ben])
        ana.goOnline()
        try await sim.settle()
        try await sim.expectConverged()
        let readout = Self.agreed(people, objects: objects)
        #expect(readout.panel == ["White", "Black", "Registration", "Red"])
        #expect(readout.colors[objects[0]] == Self.grape && readout.colors[objects[1]] == Self.grape)
        #expect(readout.colors[objects[2]] == Self.red && readout.colors[objects[3]] == Self.red)
        #expect(ColorResolver(ana.state).isDangling(Self.fill(objects[0], ana.state)))
        #expect(await ben.perform(RestoreSwatches([grape])) != nil)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(Self.agreed(people, objects: objects).panel == ["White", "Black", "Registration", "Grape", "Red"])
        #expect(!ColorResolver(ana.state).isDangling(Self.fill(objects[0], ana.state)))
    }

    /// Sort, drag and add at once on three partitioned clients: every swatch survives, every
    /// client lists them in one order, and a sort afterwards is the canonical order everywhere.
    @Test func sortVersusDragVersusAdd() async throws {
        let sim = try await Simulation(name: "swatch-sort-drag-add", seed: Simulation.seed(2203), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let people = try await Self.start(sim, ["ana", "ben", "cy"])
        var ids: [OpID] = []
        for name in ["delta", "alpha", "charlie", "bravo"] {
            ids.append(try await Self.swatch(people[0], Self.grape, name))
        }
        try await sim.settle()
        people.forEach { $0.goOffline() }
        #expect(await people[0].perform(SortSwatches()) != nil)
        #expect(await people[1].perform(MoveSwatches([ids[3]], after: ids[0])) != nil)
        _ = try await Self.swatch(people[2], Self.plum, "echo")
        people.forEach { $0.goOnline() }
        try await sim.settle()
        try await sim.expectConverged()
        let merged = Self.agreed(people, objects: [])
        #expect(Set(merged.panel) == ["White", "Black", "Registration", "alpha", "bravo", "charlie", "delta", "echo"])
        #expect(Array(merged.panel.prefix(3)) == ["White", "Black", "Registration"])
        #expect(await people[1].perform(SortSwatches()) != nil)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(Self.agreed(people, objects: []).panel == ["White", "Black", "Registration", "alpha", "bravo", "charlie", "delta", "echo"])
    }

    /// Removing a base while another client makes a tint of it and applies the tint: the tint
    /// stays live with a dangling parent and renders from its cache; objects keep their look.
    @Test func tintBaseDeletionVersusTintCreation() async throws {
        let sim = try await Simulation(name: "swatch-tint-base", seed: Simulation.seed(2204), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let people = try await Self.start(sim, ["ana", "ben"])
        let (ana, ben) = (people[0], people[1])
        let grape = try await Self.swatch(ana, Self.grape, "Grape")
        let objects = try await Self.squares(ana, 2, fill: ColorResolver.inline(.white))
        try await sim.settle()
        ana.goOffline()
        #expect(await ana.perform(RemoveSwatches([grape])) != nil)
        let tint = try #require(await ben.perform(AddTintSwatch(of: grape, percent: 40))).createdNodes[0]
        let expected = try #require(ColorResolver(ben.state).color(ofSwatch: tint))
        #expect(await ben.perform(ApplyColor([objects[0]], target: .fill, color: Self.reference(ben, tint))) != nil)
        try await sim.settle([ben])
        ana.goOnline()
        try await sim.settle()
        try await sim.expectConverged()
        let readout = Self.agreed(people, objects: objects)
        #expect(readout.panel == ["White", "Black", "Registration", "40% Grape"])
        #expect(readout.colors[objects[0]] == expected && readout.colors[objects[1]] == .white)
        for client in people {
            let swatch = try #require(SwatchList(client.state)[tint])
            #expect(swatch.baseRemoved && swatch.color == expected)
        }
    }

    /// *Name All Colors* on two partitioned clients: both sets of swatches survive, the later
    /// duplicates read with ` (2)`, and every object keeps its colour.
    @Test func nameAllColorsOnTwoPartitionedClients() async throws {
        let sim = try await Simulation(name: "swatch-name-all", seed: Simulation.seed(2205), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let people = try await Self.start(sim, ["ana", "ben"])
        let reds = try await Self.squares(people[0], 3, fill: ColorResolver.inline(Self.red))
        let plums = try await Self.squares(people[0], 2, fill: ColorResolver.inline(Self.plum))
        let objects = reds + plums
        try await sim.settle()
        let before = Self.agreed(people, objects: objects)
        people.forEach { $0.goOffline() }
        for person in people {
            #expect(await person.perform(NameAllColors()) != nil)
        }
        people.forEach { $0.goOnline() }
        try await sim.settle()
        try await sim.expectConverged()
        let readout = Self.agreed(people, objects: objects)
        #expect(readout.colors == before.colors)
        let red = ColorText.defaultName(Self.red)
        let plum = ColorText.defaultName(Self.plum)
        #expect(Array(readout.panel.prefix(3)) == ["White", "Black", "Registration"])
        #expect(Set(readout.panel.dropFirst(3)) == [red, "\(red) (2)", plum, "\(plum) (2)"])
        let state = people[0].state
        #expect(objects.allSatisfy { SwatchList(state).resolver.isSwatch(OpID(Self.fill($0, state).swatch.id)) })
    }
}
