import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// COLLAB-003: the collaboration guide's cases (collaboration.adoc, "When two people change the
/// same thing", "Locked objects", "Working offline", "The Review Changes sheet") as simulator
/// scenarios, every one against two API nodes (`SimCluster`) with packet loss on every link.  Each
/// asserts hash convergence on all clients and the exact review-sheet rows shown -- kind and
/// attribute names -- or that no review was asked for.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct CollaborationCaseScenarioTests {
    /// Latency, jitter, and lost requests, replies and stream frames on every link.
    static let lossy = LinkConditions(latency: .milliseconds(40), jitter: .milliseconds(30), requestLoss: 0.03, responseLoss: 0.03,
                                      streamDrop: 0.002)

    struct Room {
        let sim: Simulation
        let cluster: SimCluster
        /// Ana and Cy keep their reviews settled; Ben, who goes offline, examines his.
        let ana: SimClient
        let ben: SimClient
        let cy: SimClient
        let shapes: [OpID]
    }

    static func room(_ name: String, seed: UInt64, shapes count: Int = 6) async throws -> Room {
        let (sim, cluster) = try await Simulation.clustered(name: name, seed: Simulation.seed(seed))
        let ana = try await sim.addClient("ana", conditions: lossy)
        let ben = try await sim.addClient("ben", conditions: lossy, keepsMergedResult: false)
        let cy = try await sim.addClient("cy", conditions: lossy)
        let shapes = try await Workload.createShapes(ana, count: count)
        try await sim.settle()
        return Room(sim: sim, cluster: cluster, ana: ana, ben: ben, cy: cy, shapes: shapes)
    }

    /// Converged, and both nodes carried calls.
    static func expectConverged(_ room: Room) async throws {
        try await room.sim.settle()
        try await room.sim.expectConverged()
        let stats = await room.cluster.stats
        #expect(stats.calls.allSatisfy { $0 > 0 }, "both nodes take calls: \(stats.calls)")
    }

    static func at(_ x: Double, _ y: Double) -> WTGeometry.AffineTransform { .translation(x: x, y: y) }

    static func name(_ node: OpID, _ client: SimClient) -> String { client.state.props(node).rect.common.name }

    static func transform(_ node: OpID, _ client: SimClient) -> Wiretuner_Doc_V1_Transform { client.state.props(node).rect.common.transform }

    /// Same attribute, live: Ana and Ben rename one star at once, again and again; the later write
    /// (the register's winner) stands everywhere and Cy's move of it is untouched.  Nothing asks.
    @Test func sameAttributeLive() async throws {
        let room = try await Self.room("collab-same-live", seed: 3101)
        defer { Task { await room.sim.shutdown() } }
        let star = room.shapes[0]
        var random = room.sim.random.fork(31)
        for round in 0..<12 {
            await Workload.rename(room.ana, [star], "ana-\(round)")
            await Workload.rename(room.ben, [star], "ben-\(round)")
            if round == 5 { await Workload.move(room.cy, [star], &random) }
        }
        try await Self.expectConverged(room)
        let winner = try #require(room.ana.state.store.register(star, RegisterPath([NodeKind.rect.rawValue, 1, 1]))?.op)
        let expected = winner.replica == (await room.ana.store.replica) ? "ana" : "ben"
        #expect(Self.name(star, room.ana).hasPrefix(expected))
        #expect(Self.transform(star, room.ana) != Wiretuner_Doc_V1_Transform(), "Cy's move is a separate attribute and stays")
        for person in [room.ana, room.ben, room.cy] { #expect(person.reviews == 0) }
    }

    /// Same attribute, offline: Ben renames the star on the plane while Ana renames it too; his
    /// review lists one *Same attribute* row naming *Name*; *Use mine* puts his name back as a new
    /// change on every client.
    @Test func sameAttributeOfflineThenUseMine() async throws {
        let room = try await Self.room("collab-same-offline", seed: 3102)
        defer { Task { await room.sim.shutdown() } }
        let star = room.shapes[0]
        let review = try required(try await room.sim.offline(room.ben, hours: 1) {
            await Workload.rename(room.ben, [star], "Ben's star")
            await Workload.rename(room.ana, [star], "Ana's star")
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(review.decision == .perObject)
        #expect(ReviewRow.rows(review) == [ReviewRow(node: star, kind: .sameRegister, attributes: ["Name"])])
        let entry = try #require(review.entries.first)
        #expect(entry.actions == [.useMine, .useTheirs, .keepBoth])
        if entry.properties[0].kept != .mine {
            #expect(entry.localWriteLost)
            try await ReviewChoices.useMine(entry, on: room.ben)
        }
        try await room.ben.keepMerged()
        try await Self.expectConverged(room)
        for person in [room.ana, room.ben, room.cy] { #expect(Self.name(star, person) == "Ben's star") }
    }

    /// Drag vs. drag, live: both drag one object at the presence rate; while they drag it jumps,
    /// and when both let go it sits where the later write put it, on every client.
    @Test func dragVersusDragLive() async throws {
        let room = try await Self.room("collab-drag-live", seed: 3103)
        defer { Task { await room.sim.shutdown() } }
        let logo = room.shapes[1]
        try await room.sim.steps(20, every: .milliseconds(50)) { step in
            let x = Double(step * 5)
            await room.ana.perform(SetTransforms([(logo, Self.at(-x, 0))], label: "Drag"))
            await room.ben.perform(SetTransforms([(logo, Self.at(0, -x))], label: "Drag"))
        }
        try await Self.expectConverged(room)
        let released = Self.transform(logo, room.ana)
        #expect(released.tx == -95 && released.ty == 0 || released.tx == 0 && released.ty == -95)
        for person in [room.ana, room.ben, room.cy] {
            #expect(Self.transform(logo, person) == released)
            #expect(person.reviews == 0)
        }
    }

    /// Drag vs. drag, offline: a transform both wrote is *Same attribute* (*Transform*) -- *Both
    /// moved* is a change of place in the tree, below -- and *Keep both copies* adds Ben's version
    /// beside the merged one, offset, as one change every client receives.
    @Test func dragVersusDragOfflineThenKeepBothCopies() async throws {
        let room = try await Self.room("collab-drag-offline", seed: 3104)
        defer { Task { await room.sim.shutdown() } }
        let logo = room.shapes[1]
        let review = try required(try await room.sim.offline(room.ben, hours: 1) {
            await room.ben.perform(SetTransforms([(logo, Self.at(300, 0))]))
            await room.ana.perform(SetTransforms([(logo, Self.at(0, 300))]))
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(ReviewRow.rows(review) == [ReviewRow(node: logo, kind: .sameRegister, attributes: ["Transform"])])
        let entry = try #require(review.entries.first)
        let copy = try await ReviewChoices.keepBoth(entry, on: room.ben)
        try await room.ben.keepMerged()
        try await Self.expectConverged(room)
        for person in [room.ana, room.cy] {
            #expect(person.state.isLive(copy))
            #expect(Self.transform(copy, person).tx == 310 && Self.transform(copy, person).ty == 10, "Ben's position, offset")
        }
    }

    /// Delete vs. move to another layer, live: the object is deleted; restored, it is on the layer
    /// it was moved to.
    @Test func deleteVersusMoveLive() async throws {
        let room = try await Self.room("collab-delete-move-live", seed: 3105)
        defer { Task { await room.sim.shutdown() } }
        let badge = room.shapes[2]
        let layer = try #require(await room.ana.perform(CreateLayer(name: "Layer 2"))?.createdNodes.first)
        try await room.sim.settle()
        await room.ben.perform(MoveObjectsToLayer([badge], to: layer))
        await Workload.delete(room.ana, [badge])
        try await room.sim.settle()
        #expect(!room.cy.state.isLive(badge))
        await room.cy.perform(OpsCommand("Restore", ops: [Ops.setDeleted(badge, false)]))
        try await Self.expectConverged(room)
        for person in [room.ana, room.ben, room.cy] {
            #expect(person.state.isLive(badge))
            #expect(person.state.store.placement(badge)?.parent == layer)
            #expect(person.reviews == 0)
        }
    }

    /// Delete vs. move, offline: *Edited and deleted* naming *Deleted*, offered *Restore* and *Use
    /// theirs*; *Restore* brings it back on the layer Ben moved it to.  A move to a layer both
    /// made is *Both moved* (*Position*).
    @Test func deleteVersusMoveOfflineThenRestore() async throws {
        let room = try await Self.room("collab-delete-move-offline", seed: 3106)
        defer { Task { await room.sim.shutdown() } }
        let (badge, logo) = (room.shapes[2], room.shapes[3])
        let layer = try #require(await room.ana.perform(CreateLayer(name: "Layer 2"))?.createdNodes.first)
        let other = try #require(await room.ana.perform(CreateLayer(name: "Layer 3"))?.createdNodes.first)
        try await room.sim.settle()
        let review = try required(try await room.sim.offline(room.ben, hours: 1) {
            await room.ben.perform(MoveObjectsToLayer([badge, logo], to: layer))
            await Workload.delete(room.ana, [badge])
            await room.ana.perform(MoveObjectsToLayer([logo], to: other))
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(ReviewRow.rows(review) == [ReviewRow(node: badge, kind: .editVsDelete, attributes: ["Deleted"]),
                                           ReviewRow(node: logo, kind: .moveVsMove, attributes: ["Position"])])
        let entry = try #require(review.entries.first { $0.node == badge })
        #expect(entry.actions == [.restore, .useTheirs])
        try await ReviewChoices.restore(entry, on: room.ben)
        try await room.ben.keepMerged()
        try await Self.expectConverged(room)
        for person in [room.ana, room.ben, room.cy] {
            #expect(person.state.isLive(badge) && person.state.store.placement(badge)?.parent == layer)
        }
    }

    /// Lock vs. offline edit: Ana locks the object while Ben, offline, moves it; both apply (the
    /// object is locked in Ben's position) and his review lists *Both edited* with *Locked* among
    /// the attributes; *Use theirs* writes nothing and *Keep the merged result* sends his move.
    @Test func lockVersusOfflineEdit() async throws {
        let room = try await Self.room("collab-lock-offline", seed: 3107)
        defer { Task { await room.sim.shutdown() } }
        let header = room.shapes[4]
        let review = try required(try await room.sim.offline(room.ben, hours: 1) {
            await room.ben.perform(SetTransforms([(header, Self.at(40, 40))]))
            await room.ana.perform(SetLocked([header], locked: true))
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(ReviewRow.rows(review) == [ReviewRow(node: header, kind: .bothEdited, attributes: ["Locked", "Transform"])])
        let before = room.ben.state.stateHash
        try await room.ben.keepMerged()
        #expect(room.ben.state.stateHash == before, "Use theirs writes nothing")
        try await Self.expectConverged(room)
        for person in [room.ana, room.ben, room.cy] {
            #expect(person.state.props(header).rect.common.locked)
            #expect(Self.transform(header, person).tx == 40)
        }
    }

    /// Text co-editing, live: three people type into one headline at once, one node restarting
    /// meanwhile; every word lands, character for character, in one order on every client.
    @Test func textCoEditingLiveAcrossANodeRestart() async throws {
        let room = try await Self.room("collab-text-live", seed: 3108, shapes: 1)
        defer { Task { await room.sim.shutdown() } }
        let headline = try await Workload.createText(room.ana, "Spring sale")
        try await room.sim.settle()
        var words: [String] = []
        try await room.sim.steps(15, every: .milliseconds(100)) { step in
            if step == 7 { await room.cluster.restart(node: 0, downFor: .seconds(2)) }
            for person in [room.ana, room.ben, room.cy] {
                guard let text = person.state.textNode(headline) else { continue }
                let word = " \(person.name)\(step)"
                if await person.perform(InsertText(node: headline, text: word, at: text.anchor(at: text.length), typing: true)) != nil {
                    words.append(word)
                }
            }
        }
        try await Self.expectConverged(room)
        let merged = try #require(room.ana.state.textNode(headline)?.string)
        for word in words { #expect(merged.contains(word), "\(word) is in \"\(merged)\"") }
        #expect(await room.cluster.stats.restarts == 1)
        for person in [room.ana, room.ben, room.cy] {
            #expect(person.state.textNode(headline)?.string == merged)
            #expect(person.reviews == 0)
        }
    }

    /// Text co-editing, offline: both edit the same paragraph -- *Same text* naming *Text*; the
    /// merge keeps both edits.
    @Test func textCoEditingOffline() async throws {
        let room = try await Self.room("collab-text-offline", seed: 3109, shapes: 1)
        defer { Task { await room.sim.shutdown() } }
        let headline = try await Workload.createText(room.ana, "Spring sale")
        try await room.sim.settle()
        let review = try required(try await room.sim.offline(room.ben, hours: 1) {
            let mine = try #require(room.ben.state.textNode(headline))
            await room.ben.perform(InsertText(node: headline, text: " now", at: mine.anchor(at: mine.length)))
            let theirs = try #require(room.ana.state.textNode(headline))
            await room.ana.perform(InsertText(node: headline, text: "Big ", at: theirs.anchor(at: 0)))
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(ReviewRow.rows(review) == [ReviewRow(node: headline, kind: .sameText, attributes: ["Text"])])
        try await room.ben.keepMerged()
        try await Self.expectConverged(room)
        #expect(room.cy.state.textNode(headline)?.string == "Big Spring sale now")
    }

    /// The three reconnect outcomes: nothing overlapped and little changed (a silent merge with
    /// the toast); nothing overlapped after a long gap (merged and sent, *Review what changed*
    /// offered read-only); the same objects changed (held for review).  Then a large overlap opens
    /// the whole-document review, and *Save my version as a copy…* leaves the shared document as
    /// the others left it.
    @Test func theThreeReconnectOutcomes() async throws {
        let room = try await Self.room("collab-outcomes", seed: 3110, shapes: 30)
        defer { Task { await room.sim.shutdown() } }
        let server = try #require(room.sim.server)
        var random = room.sim.random.fork(310)
        // 1. Silent: an hour away, different objects.
        let silent = try required(try await room.sim.offline(room.ben, hours: 1) {
            await Workload.move(room.ben, [room.shapes[0], room.shapes[1]], &random)
            await Workload.move(room.ana, [room.shapes[2]], &random)
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(silent.decision == .silentMerge && silent.mode == .readOnly && silent.entries.isEmpty)
        #expect(silent.toast.hasPrefix("Merged 1 change"))
        try await room.sim.settle()
        // 2. Suggested: a day away, still nothing in common.
        let suggested = try required(try await room.sim.offline(room.ben, hours: 24) {
            await Workload.move(room.ben, [room.shapes[3]], &random)
            await Workload.move(room.ana, [room.shapes[4]], &random)
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(suggested.decision == .suggestReview && !suggested.holdsOutbox && suggested.entries.isEmpty)
        try await room.sim.settle()
        // 3. Held: the same object, per object.
        let held = try required(try await room.sim.offline(room.ben, hours: 1) {
            await Workload.rename(room.ben, [room.shapes[5]], "mine")
            await Workload.rename(room.ana, [room.shapes[5]], "theirs")
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(held.decision == .perObject && held.holdsOutbox)
        #expect(ReviewRow.rows(held) == [ReviewRow(node: room.shapes[5], kind: .sameRegister, attributes: ["Name"])])
        #expect(held.documentActions == [.keepMerged, .saveCopy, .keepBranch])
        try await room.ben.keepMerged()
        try await room.sim.settle()
        // A large overlap: twenty-five objects both changed opens the whole-document review.
        let wide = Array(room.shapes[5..<30])
        var local: [UInt8] = []
        let whole = try required(try await room.sim.offline(room.ben, hours: 1) {
            await Workload.move(room.ben, wide, &random)
            local = room.ben.state.stateHash
            await Workload.rename(room.ana, wide, "renamed")
            try await room.sim.settle([room.ana, room.cy])
        })
        #expect(whole.decision == .wholeDocument && whole.mode == .wholeDocument)
        #expect(ReviewRow.rows(whole) == Set(wide.map { ReviewRow(node: $0, kind: .bothEdited, attributes: ["Name", "Transform"]) }))
        let copyID = try await room.ben.saveCopy(on: server, as: "copy-of-\(room.sim.documentID)")
        try await Self.expectConverged(room)
        #expect(room.ben.state.stateHash == (await server.state(room.sim.documentID)).stateHash)
        let copy = try await room.sim.addClient("ben-copy", user: room.ben.user, document: copyID)
        try await room.sim.settle([copy])
        #expect(copy.state.stateHash == local)
        try await room.sim.expectConverged([copy], document: copyID)
    }
}
