import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

extension SimClient {
    /// The review of the last reconnect: the merge reported for the toast, or the one holding the
    /// outbox.
    var lastReview: ReviewModel? {
        for event in events.reversed() {
            switch event {
            case .merged(let review), .reviewNeeded(let review): return review
            default: continue
            }
        }
        return nil
    }
}

/// COLLAB-032 in the simulator (comments.adoc, "Review sheet"): threads written offline never
/// reach the review sheet or hold the outbox, and a commented object deleted remotely is listed
/// with *Restore*, which brings the object and its pin back everywhere.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct CommentScenarioTests {
    static func thread(_ client: SimClient, on anchor: OpID, _ text: String) -> CreateThread {
        CreateThread(at: Point(x: 2, y: 2), on: anchor, author: client.user.id, body: CommentBody(text), postedAt: client.clock(), in: client.state)
    }

    /// 200 comment threads written offline against 200 remote artwork edits: no review rows, the
    /// outbox never held.
    @Test(arguments: PushMode.allCases) func offlineThreadsAgainstRemoteArtworkEdits(mode: PushMode) async throws {
        let sim = try await Simulation(name: "comments-offline-\(mode)", seed: Simulation.seed(3232), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let priya = try await sim.addClient("priya", gateway: mode.gateway, keepsMergedResult: false)
        let tom = try await sim.addClient("tom", gateway: mode.gateway)
        let shapes = try await Workload.createShapes(tom, count: 40)
        try await sim.settle()
        priya.goOffline()
        var random = sim.random.fork(32)
        for index in 0..<200 {
            #expect(await priya.perform(Self.thread(priya, on: shapes[index % shapes.count], "Thread \(index)")) != nil)
        }
        for index in 0..<200 {
            let shape = shapes[(index * 7) % shapes.count]
            if index.isMultiple(of: 2) {
                await Workload.move(tom, [shape], &random)
            } else {
                await Workload.rename(tom, [shape], "tom-\(index)")
            }
        }
        try await sim.settle([tom])
        sim.advance(by: .seconds(8 * 3600))
        priya.goOnline()
        try await sim.settle()
        try await sim.expectConverged()
        #expect(priya.reviews == 0 && !priya.reached { $0 == .needsReview })
        let review = try #require(priya.lastReview)
        #expect(review.entries.isEmpty && review.mergeRuns.isEmpty && review.removedFields.isEmpty && !review.holdsOutbox)
        #expect(review.localObjects == 0 && review.remoteObjects > 0)
        for client in [priya, tom] {
            let threads = CommentThreadModel(client.state).threads
            #expect(threads.count == 200 && threads.allSatisfy { if case .object = $0.anchoring { true } else { false } })
        }
    }

    /// A thread written offline on an object someone else deletes: the reconnect lists the object
    /// as *Edited and deleted*; *Restore* brings it and its pin back on every client.
    @Test func aCommentedObjectDeletedRemotelyIsRestoredWithItsPin() async throws {
        let sim = try await Simulation(name: "comments-restore", seed: Simulation.seed(3233), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let priya = try await sim.addClient("priya", keepsMergedResult: false)
        let tom = try await sim.addClient("tom")
        let shapes = try await Workload.createShapes(tom, count: 3)
        try await sim.settle()
        priya.goOffline()
        let thread = try #require(await priya.perform(Self.thread(priya, on: shapes[0], "Keep this"))).createdNodes[0]
        await Workload.delete(tom, [shapes[0], shapes[1]])
        try await sim.settle([tom])
        sim.advance(by: .seconds(3600))
        priya.goOnline()
        try await priya.waitFor("needs review") { $0 == .needsReview }
        let review = try #require(await priya.client.pendingReview)
        #expect(review.entries.map(\.node) == [shapes[0]])
        let entry = review.entries[0]
        #expect(entry.kind == .editVsDelete && entry.anchoredComment && entry.actions.contains(.restore))
        #expect(await priya.perform(ReviewModel.restore(entry)) != nil)
        try await priya.keepMerged()
        try await sim.settle()
        try await sim.expectConverged()
        for client in [priya, tom] {
            let restored = try #require(CommentThreadModel(client.state)[thread])
            #expect(client.state.isLive(shapes[0]) && !client.state.isLive(shapes[1]))
            #expect(restored.anchoring == .object(shapes[0]) && restored.pin != nil)
        }
    }
}
