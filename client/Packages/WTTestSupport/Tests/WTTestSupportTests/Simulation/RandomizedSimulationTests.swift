import Foundation
import Testing
import WTCRDT
import WTModel
import WTSync
@testable import WTTestSupport

/// Randomized runs (TEST-001): from one seed, two to four clients with random push modes, network
/// conditions and clock skews edit objects, a path and a text block while the script cuts clients
/// off for up to a day and a half, restarts the server, Valkey and Postgres, and changes the
/// network, and someone opens the document for the first time half-way (a snapshot bootstrap,
/// the server snapshotting every 40 changes); then everything heals and must converge.
/// `WT_SIM_SEEDS=5,9` runs those seeds, `WT_SIM_RUNS=n` seeds 1 to n; `WT_SIM_SEED` replays one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10))) struct RandomizedSimulationTests {
    nonisolated static func seeds(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [UInt64] {
        if let seed = environment["WT_SIM_SEED"].flatMap({ UInt64($0) }) {
            return [seed]
        }
        if let list = environment["WT_SIM_SEEDS"] {
            return list.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let runs = environment["WT_SIM_RUNS"].flatMap({ UInt64($0) }), runs > 0 {
            return Array(1...runs)
        }
        return [1, 2, 3, 4]
    }

    @Test func seedsComeFromTheEnvironment() {
        #expect(Self.seeds([:]) == [1, 2, 3, 4])
        #expect(Self.seeds(["WT_SIM_SEED": "77"]) == [77])
        #expect(Self.seeds(["WT_SIM_SEEDS": "5, 9"]) == [5, 9])
        #expect(Self.seeds(["WT_SIM_RUNS": "3"]) == [1, 2, 3])
        #expect(Self.seeds(["WT_SIM_RUNS": "0"]) == [1, 2, 3, 4])
    }

    static func conditions(_ random: inout SimRandom) -> LinkConditions {
        LinkConditions(latency: .milliseconds(random.within(0...300)), jitter: .milliseconds(random.within(0...200)),
                       reorder: Double(random.within(0...40)) / 100, reorderWindow: .milliseconds(random.within(0...800)),
                       requestLoss: Double(random.within(0...4)) / 100, responseLoss: Double(random.within(0...4)) / 100,
                       streamDrop: Double(random.within(0...10)) / 1_000)
    }

    @Test(arguments: seeds()) func aRandomRunConverges(seed: UInt64) async throws {
        var serverOptions = SimServer.Options()
        serverOptions.snapshotEvery = 40
        let sim = try await Simulation(name: "random", seed: seed, scale: 0.005, serverOptions: serverOptions)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        var random = sim.random.fork(9)
        var people: [SimClient] = []
        for index in 0..<random.within(2...4) {
            let skew = Duration.seconds(random.within(-3 * 86_400...3 * 86_400))
            people.append(try await sim.addClient("p\(index)", gateway: random.chance(0.4), conditions: Self.conditions(&random), skew: skew))
        }
        let shapes = try await Workload.createShapes(people[0], count: 20)
        let path = try await Workload.createPath(people[0], points: 8)
        let text = try await Workload.createText(people[0], "The quick brown fox")
        try await sim.settle()
        var offlineUntil: [Int: Int] = [:]
        try await sim.steps(80, every: .seconds(2)) { step in
            if step == 40 {
                // Someone opens the document for the first time: a snapshot bootstrap mid-run.
                people.append(try await sim.addClient("late", gateway: random.chance(0.4), conditions: Self.conditions(&random)))
            }
            for (index, person) in people.enumerated() {
                if let until = offlineUntil[index], step >= until {
                    offlineUntil[index] = nil
                    person.goOnline()
                }
                switch random.below(3) {
                case 0: await Workload.randomEdit(person, shapes, &random)
                case 1: await Workload.editPath(person, path.node, &random)
                default: await Workload.editText(person, text, &random)
                }
            }
            switch random.below(40) {
            case 0, 1:
                let index = random.below(people.count)
                if offlineUntil[index] == nil && offlineUntil.count < people.count - 1 {
                    offlineUntil[index] = step + random.within(3...20)
                    people[index].goOffline()
                    sim.advance(by: .seconds(random.within(60...36 * 3600)))
                }
            case 2: await sim.restartServer(downFor: .seconds(random.within(1...8)), graceful: random.chance(0.5))
            case 3: await server.restartBus(outage: .seconds(random.within(1...6)))
            case 4: await server.failOverDatabase(outage: .seconds(random.within(1...5)))
            case 5:
                let person = random.pick(people)
                person.link.conditions = Self.conditions(&random)
                sim.log.record("\(person.name): conditions now \(person.link.conditions)")
            default: break
            }
        }
        for (index, _) in offlineUntil { people[index].goOnline() }
        // Calm the network so the run ends; the faults above already happened.
        for person in people { person.link.conditions = LinkConditions(latency: .milliseconds(20)) }
        try await sim.settle(timeout: .seconds(120))
        try await sim.expectConverged()
        print(await sim.summary())
    }
}
