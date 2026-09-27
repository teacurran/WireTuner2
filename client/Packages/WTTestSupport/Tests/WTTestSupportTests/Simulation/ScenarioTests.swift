import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// How a scenario's clients push: pipelined `PushChange` calls, or one `PushChangeBatch` at a time
/// (a client behind a gateway).  Every scenario runs in both (TEST-001's done-when).
enum PushMode: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case native, gateway

    var gateway: Bool { self == .gateway }
    var testDescription: String { rawValue }
}

/// The scenarios of docs/spec/testing.adoc, "Multi-client simulation" (TEST-001), against the
/// in-process server.  Each asserts convergence (`Simulation.expectConverged`) and the sync-state
/// transitions the scenario implies.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct ScenarioTests {
    /// 1. Three users editing one path for ten minutes with 200 ms latency, pipelined pushes
    /// deliberately reordered (native) or batched (gateway).
    @Test(arguments: PushMode.allCases) func threeUsersEditOnePathForTenMinutes(mode: PushMode) async throws {
        let sim = try await Simulation(name: "one-path-\(mode)", seed: Simulation.seed(101), scale: 0.01)
        defer { Task { await sim.shutdown() } }
        let conditions = LinkConditions(latency: .milliseconds(200), jitter: .milliseconds(80), reorder: 0.35,
                                        reorderWindow: .milliseconds(900), streamDrop: 0.004)
        let people = try await ["ana", "ben", "cy"].asyncMap { try await sim.addClient($0, gateway: mode.gateway, conditions: conditions) }
        let path = try await Workload.createPath(people[0], points: 12)
        try await sim.settle()
        var random = sim.random.fork(1)
        // Ten simulated minutes as 200 steps 3 s apart: counted, not timed, so a loaded machine
        // (edits taking longer while the clock runs) cannot shorten the workload.
        try await sim.steps(200, every: .seconds(3)) { _ in
            for person in people where random.chance(0.8) {
                for _ in 0..<random.within(1...5) {
                    await Workload.editPath(person, path.node, &random)
                }
            }
        }
        try await sim.settle()
        try await sim.expectConverged()
        print(await sim.summary())
        let stats = try #require(await sim.server?.stats)
        let edits = people.reduce(0) { $0 + $1.performed.count }
        #expect(edits > 300)
        #expect(people.reduce(0) { $0 + $1.link.stats.droppedConnections } > 0)
        if mode == .native {
            #expect(people.reduce(0) { $0 + $1.link.stats.reordered } > 0)
            #expect(stats.gaps > 0, "reordered pushes must have met SEQ_GAP and been resent")
            #expect(stats.batches == 0)
        } else {
            #expect(stats.batches > 0 && stats.pushes == 0)
        }
        for person in people {
            #expect(person.events.contains { if case .presenceUpdate(let update) = $0 { update.user.displayName != person.name } else { false } },
                     "\(person.name) sees the others' presence")
            #expect(person.reached { if case .syncing = $0 { true } else { false } })
            #expect(person.reached { if case .offline = $0 { true } else { false } } || person.link.stats.droppedConnections == 0)
            // A connection dropped for seconds while everyone edits the path merges without asking
            // (TEST-001 finding c, D-070): no review ever held an outbox.
            #expect(person.reviews == 0, "\(person.name) was asked to review \(person.reviews) times")
            #expect(!person.reached { $0 == .needsReview })
        }
        #expect(people[0].state.isLive(path.node))
    }

    /// The overlap of scenarios 2 and 3: sixty rectangles; the offline person edits 0..<40 and
    /// the others 30..<60 -- both move 30..<34 (same attribute), the others delete 34 and 35
    /// (edited and deleted) and rename 36..<40 while the offline person moves them (both edited).
    struct Offline {
        let sim: Simulation
        let away: SimClient
        let others: [SimClient]
        let shapes: [OpID]
        let localBefore: [UInt8]
        let review: ReviewModel
        let offlineOps: Int
    }

    func goOfflineFor48Hours(_ name: String, mode: PushMode) async throws -> Offline {
        let sim = try await Simulation(name: name, seed: Simulation.seed(202), scale: 0.002)
        let conditions = LinkConditions(latency: .milliseconds(40), jitter: .milliseconds(20))
        let away = try await sim.addClient("priya", gateway: mode.gateway, conditions: conditions, skew: .seconds(-7_200),
                                           keepsMergedResult: false)
        let tom = try await sim.addClient("tom", gateway: mode.gateway, conditions: conditions, skew: .seconds(3 * 24 * 3600))
        let uma = try await sim.addClient("uma", gateway: mode.gateway, conditions: conditions)
        let shapes = try await Workload.createShapes(away, count: 60)
        try await sim.settle()
        away.goOffline()
        var random = sim.random.fork(2)
        // The offline day: 30,000 ops in 1,000 changes of 30 moves (the first covers the overlap).
        let offlineChanges = 1_000
        let offlineOps = offlineChanges * 30
        let mine = Array(shapes[0..<40])
        for index in 0..<offlineChanges {
            let nodes = index == 0 ? Array(shapes[20..<50].prefix(10) + shapes[0..<20]) : (0..<30).map { _ in random.pick(mine) }
            let targets = index == 0 ? Array(shapes[30..<40]) + Array(shapes[0..<20]) : nodes
            await Workload.move(away, targets, &random)
            if index == offlineChanges / 2 {
                sim.advance(by: .seconds(48 * 3600))
            }
        }
        // Meanwhile the others: 5,000 ops each, in changes of 10.
        let moved = Array(shapes[30..<34]) + Array(shapes[40..<60])
        await Workload.delete(uma, Array(shapes[34..<36]))
        await Workload.rename(tom, Array(shapes[36..<40]), "theirs")
        for index in 0..<500 {
            for person in [tom, uma] {
                let nodes = index == 0 ? Array(shapes[30..<34]) + Array(shapes[40..<46]) : (0..<10).map { _ in random.pick(moved) }
                await Workload.move(person, nodes, &random)
            }
        }
        try await sim.settle([tom, uma])
        let localBefore = away.state.stateHash
        #expect(try await away.store.outboxCount() == offlineChanges)
        away.goOnline()
        try await away.waitFor("needs review", timeout: .seconds(120)) { $0 == .needsReview }
        let review = try #require(await away.client.pendingReview)
        return Offline(sim: sim, away: away, others: [tom, uma], shapes: shapes, localBefore: localBefore, review: review, offlineOps: offlineOps)
    }

    /// The review's classification for the overlap above.
    func expectClassified(_ offline: Offline) {
        let review = offline.review
        let shapes = offline.shapes
        #expect(review.mode == .wholeDocument && review.decision == .wholeDocument)
        #expect(Set(review.entries.map(\.node)) == Set(shapes[30..<40]))
        for entry in review.entries {
            let index = shapes.firstIndex(of: entry.node)!
            let expected: OverlapKind = index < 34 ? .sameRegister : index < 36 ? .editVsDelete : .bothEdited
            #expect(entry.kind == expected, "shape \(index) is \(entry.kinds), expected \(expected)")
        }
        #expect(review.localOps >= offline.offlineOps)
        #expect(review.gap >= .seconds(48 * 3600))
        #expect(Set(review.authors.map(\.name)) == ["tom", "uma"])
    }

    /// 2. One user offline for 48 simulated hours producing 30,000 ops while two others produce
    /// 5,000 each; reconnect; the review sheet's classification; *Keep the merged result*.
    @Test(arguments: PushMode.allCases) func offlineFor48HoursThenKeepTheMergedResult(mode: PushMode) async throws {
        let offline = try await goOfflineFor48Hours("offline-keep-\(mode)", mode: mode)
        let sim = offline.sim
        defer { Task { await sim.shutdown() } }
        expectClassified(offline)
        let start = ContinuousClock.now
        try await offline.away.keepMerged()
        try await sim.settle(timeout: .seconds(180))
        print(await sim.summary())
        PerfBudget.expect(ContinuousClock.now - start, within: .seconds(5), "TEST-001 scenario 2, \(mode): upload 1,000 changes and converge")
        try await sim.expectConverged()
        let stats = try #require(await sim.server?.stats)
        if mode == .native { #expect(stats.bulkUploads > 0) } else { #expect(stats.bulkUploads == 0 && stats.batches > 0) }
        #expect(offline.away.reached { $0 == .needsReview })
        #expect(offline.away.reached { if case .offline(let count) = $0 { count > 0 } else { false } })
    }

    /// 3. The same, with *Save my version as a copy*: the original converges to the remote state,
    /// the copy holds the local state.
    @Test(arguments: PushMode.allCases) func offlineFor48HoursThenSaveMyVersionAsACopy(mode: PushMode) async throws {
        let offline = try await goOfflineFor48Hours("offline-copy-\(mode)", mode: mode)
        let sim = offline.sim
        defer { Task { await sim.shutdown() } }
        expectClassified(offline)
        let server = try #require(sim.server)
        let copyID = try await offline.away.saveCopy(on: server, as: "copy-of-\(sim.documentID)")
        try await sim.settle()
        try await sim.expectConverged()
        // Nothing of the offline work reached the original.
        let labels = Set(await server.log(sim.documentID).map(\.change.label))
        #expect(labels.isDisjoint(with: offline.away.discarded))
        #expect(offline.away.state.stateHash == (await server.state(sim.documentID)).stateHash)
        // The copy, opened on a new Mac, holds the local state as it was before the reconnect.
        let copy = try await sim.addClient("priya-copy", user: offline.away.user, document: copyID)
        try await sim.settle([copy])
        #expect(copy.state.stateHash == offline.localBefore)
        try await sim.expectConverged([copy], document: copyID)
    }

    /// 4. A replica's store copied to a second client -- a backup restored on another Mac (it
    /// rotates at open and salvages), and a cloned disk reporting the same hardware (the server
    /// answers `REPLICA_CONFLICT`) -- rotates without any id colliding.
    @Test(arguments: PushMode.allCases) func aCopiedStoreRotatesWithoutIdCollisions(mode: PushMode) async throws {
        let sim = try await Simulation(name: "store-copy-\(mode)", seed: Simulation.seed(404), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana", gateway: mode.gateway)
        let shapes = try await Workload.createShapes(ana, count: 10)
        try await sim.settle()
        ana.goOffline()
        var random = sim.random.fork(4)
        for _ in 0..<3 { await Workload.move(ana, shapes, &random) }
        let backup = try await sim.copyStore(of: ana, as: "backup")
        let clone = try await sim.copyStore(of: ana, as: "clone")
        let replica = await ana.store.replica
        ana.goOnline()
        try await sim.settle([ana])
        let restored = try await sim.addClient("ana-mac2", user: ana.user, device: "device-mac2", hardware: "MAC-mac2", store: backup,
                                               gateway: mode.gateway, start: false)
        let cloned = try await sim.addClient("ana-clone", user: ana.user, device: "device-clone", hardware: "MAC-ana", store: clone,
                                             gateway: mode.gateway, start: false)
        let restoredAt = await restored.store.replica
        await restored.start()
        await cloned.start()
        #expect(restored.store.report.rotatedFrom == replica)
        #expect(cloned.store.report.rotatedFrom == nil)
        for _ in 0..<5 {
            for person in [ana, restored, cloned] { await Workload.move(person, [random.pick(shapes)], &random) }
        }
        try await sim.settle()
        try await sim.expectConverged()
        #expect((await sim.server?.stats.conflicts ?? 0) > 0, "the clone's replica is bound to ana's device")
        let replicas = Set([await ana.store.replica, await restored.store.replica, await cloned.store.replica])
        #expect(replicas.count == 3)
        // The backup rotated when it opened and salvages its old replica's changes; the clone is
        // told by the server.
        #expect(restored.events.contains { if case .replicaRotated(restoredAt, _) = $0 { true } else { false } })
        #expect(restored.events.contains { if case .salvaged(let report) = $0 { report.reason == .conflict } else { false } })
        #expect(cloned.events.contains { if case .replicaRotated(replica, _) = $0 { true } else { false } })
    }

    /// 5. A replica retired by the stability job reconnects and is salvaged onto the collected
    /// snapshot; the edit of a node that was deleted and compacted meanwhile is dropped and named.
    @Test(arguments: PushMode.allCases) func aRetiredReplicaIsSalvaged(mode: PushMode) async throws {
        let sim = try await Simulation(name: "retired-\(mode)", seed: Simulation.seed(505), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let away = try await sim.addClient("vic", gateway: mode.gateway, keepsMergedResult: false)
        let ben = try await sim.addClient("ben", gateway: mode.gateway)
        let cy = try await sim.addClient("cy", gateway: mode.gateway)
        let shapes = try await Workload.createShapes(ben, count: 10)
        try await sim.settle()
        away.goOffline()
        var random = sim.random.fork(5)
        await Workload.move(away, [shapes[0]], &random)
        await Workload.rename(away, [shapes[2]], "kept")
        await Workload.delete(ben, [shapes[0]])
        try await sim.settle([ben, cy])
        let deletion = await server.head(sim.documentID)
        sim.advance(by: .seconds(91 * 24 * 3600))
        // Ben and Cy keep working, one change at a time with every ack answered in between, and
        // the stability job runs after each round.
        for _ in 0..<8 {
            for person in [ben, cy] {
                await Workload.move(person, [shapes[5 + random.below(5)]], &random)
                try await sim.settle([ben, cy])
                try await Task.sleep(for: .milliseconds(100))
            }
            await server.runStabilityJob()
            if (await server.collectionPoint(sim.documentID)?.seq ?? 0) >= deletion { break }
        }
        let point = await server.collectionPoint(sim.documentID)
        sim.log.record(await server.describe(sim.documentID))
        // D-067: each client confirms the answers that raise the stable point, so at a quiet moment
        // every live replica's horizon is the head and the job publishes it (TEST-001 finding a).
        #expect((point?.seq ?? 0) >= deletion)
        #expect(point.map { $0.timeMs > sim.clock.nowMs() - 86_400_000 } == true, "T is the clock of a recent publication")
        await server.takeSnapshot(sim.documentID)
        let replica = await away.store.replica
        #expect(await server.isRetired(replica, in: sim.documentID))
        try await sim.settle([ben, cy])
        away.goOnline()
        try await away.waitFor("recovered review") { $0 == .needsReview }
        let review = try #require(await away.client.pendingReview)
        #expect(review.mode == .recovered)
        #expect(review.recovered?.dropped.map(\.missing).contains(shapes[0]) == true)
        try await away.keepMerged()
        try await sim.settle()
        try await sim.expectConverged()
        #expect(away.events.contains { if case .replicaRotated(replica, _) = $0 { true } else { false } })
        let stats = await server.stats
        #expect(stats.expired > 0 && stats.fetchSnapshots > 0)
        #expect(away.state.props(shapes[2]).rect.common.name == "kept")
    }

    /// 6. A server node restart mid-session (abrupt, then a drain), a Valkey restart, and a
    /// Postgres failover to the replica, while three people keep editing.
    @Test(arguments: PushMode.allCases) func serverValkeyAndPostgresFailures(mode: PushMode) async throws {
        let sim = try await Simulation(name: "server-failures-\(mode)", seed: Simulation.seed(606), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let server = try #require(sim.server)
        let conditions = LinkConditions(latency: .milliseconds(30), jitter: .milliseconds(30))
        let people = try await ["ana", "ben", "cy"].asyncMap { try await sim.addClient($0, gateway: mode.gateway, conditions: conditions) }
        let shapes = try await Workload.createShapes(people[0], count: 20)
        try await sim.settle()
        var random = sim.random.fork(6)
        try await sim.steps(120, every: .seconds(2)) { step in
            for person in people { await Workload.randomEdit(person, shapes, &random) }
            switch step {
            case 20: await sim.restartServer(downFor: .seconds(6))
            case 45: await sim.restartServer(downFor: .seconds(3), graceful: true)
            case 70:
                sim.log.record("Valkey restart")
                await server.restartBus(outage: .seconds(5))
            case 95:
                sim.log.record("Postgres failover")
                await server.failOverDatabase(outage: .seconds(4))
            default: break
            }
        }
        try await sim.settle()
        try await sim.expectConverged()
        print(await sim.summary())
        let stats = await server.stats
        #expect(stats.unavailable > 0 && stats.droppedLiveFrames > 0)
        #expect(stats.lostReplies == 1, "the push in flight at the failover committed and lost its reply")
        for person in people {
            #expect(person.reached { if case .offline = $0 { true } else { false } })
            #expect(person.events.contains { if case .document(let event) = $0, case .reconnect? = event.event { true } else { false } })
        }
    }

    /// 7. A person's role is downgraded to viewer mid-session: the document goes read-only with
    /// the outbox kept, keeps receiving, and uploads once the role is back.
    @Test(arguments: PushMode.allCases) func aRoleDowngradedMidSession(mode: PushMode) async throws {
        let sim = try await Simulation(name: "role-\(mode)", seed: Simulation.seed(707), scale: 0.005)
        defer { Task { await sim.shutdown() } }
        let conditions = LinkConditions(latency: .milliseconds(100), jitter: .milliseconds(100), reorder: 0.2, reorderWindow: .milliseconds(300))
        let ana = try await sim.addClient("ana", gateway: mode.gateway, conditions: conditions)
        let ben = try await sim.addClient("ben", gateway: mode.gateway, conditions: conditions)
        let shapes = try await Workload.createShapes(ana, count: 10)
        try await sim.settle()
        var random = sim.random.fork(7)
        var benEdits = 0
        // Counted steps, so the downgrade at step 30 happens however slow the machine is.
        try await sim.steps(120, every: .seconds(1)) { step in
            await Workload.randomEdit(ana, shapes, &random)
            if step == 30 {
                try await sim.grant(.viewer, to: ben.user)
            }
            // Ben keeps going until the app shows the document read-only.
            if case .readOnly = await ben.syncState {} else {
                for _ in 0..<3 { if await Workload.randomEdit(ben, shapes, &random) != nil { benEdits += 1 } }
            }
        }
        try await ben.waitFor("read-only") { if case .readOnly = $0 { true } else { false } }
        try await sim.settle([ana])
        let head = await sim.server!.head(sim.documentID)
        try await sim.clients.first!.waitFor("ana saved") { $0 == .saved }
        let deadline = ContinuousClock.now + .seconds(30)
        while await ben.store.lastServerSeq < head, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ben.store.lastServerSeq == head, "a viewer keeps receiving")
        #expect(benEdits > 0)
        try await sim.grant(.editor, to: ben.user)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(ben.reached { if case .readOnly = $0 { true } else { false } })
    }

    /// 8. Tokens expiring every minute for an hour of editing.
    @Test(arguments: PushMode.allCases) func tokensExpiringEveryMinuteForAnHour(mode: PushMode) async throws {
        let sim = try await Simulation(name: "tokens-\(mode)", seed: Simulation.seed(808), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let conditions = LinkConditions(latency: .milliseconds(50), jitter: .milliseconds(50))
        let people = try await ["ana", "ben", "cy"].asyncMap {
            try await sim.addClient($0, gateway: mode.gateway, conditions: conditions, tokenLifetime: .seconds(60))
        }
        let shapes = try await Workload.createShapes(people[0], count: 10)
        var random = sim.random.fork(8)
        try await sim.run(for: .seconds(3_600), every: .seconds(10)) { _ in
            for person in people where random.chance(0.7) { await Workload.randomEdit(person, shapes, &random) }
        }
        try await sim.settle()
        try await sim.expectConverged()
        #expect((await sim.server?.stats.tokenRefusals ?? 0) > 0)
        for person in people {
            let tokens = try #require(person.tokens as? SimTokens)
            let issued = await tokens.issued
            #expect(issued >= 30, "\(person.name) took \(issued) tokens in the hour")
            #expect(await tokens.refreshes > 0)
            #expect(!person.reached { $0 == .needsSignIn })
        }
    }
}

extension Array {
    @MainActor
    func asyncMap<T>(_ transform: @MainActor (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
