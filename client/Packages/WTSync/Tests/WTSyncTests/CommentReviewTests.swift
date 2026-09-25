import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// COLLAB-032: comments in the review sheet and in restore (comments.adoc, "Review sheet"),
/// through two `DocumentCore`s reconnecting (`Reconnect`).
@Suite struct CommentReviewTests {
    static func shape(_ world: inout Reconnect, _ index: Int = 0) throws -> OpID {
        try #require(try world.shared(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10),
                                                  transform: .translation(x: Double(index) * 20, y: 0)))).createdObjects[0]
    }

    static func thread(on anchor: OpID?, _ text: String, in state: EngineState) -> CreateThread {
        CreateThread(at: Point(x: 5, y: 5), on: anchor, author: "priya", body: CommentBody(text),
                     postedAt: Date(timeIntervalSince1970: 1_000), in: state)
    }

    /// Threads written offline against remote artwork edits of the very objects they are pinned
    /// to: no review rows, and the outbox is not held.
    @Test func offlineThreadsAgainstRemoteArtworkEditsListNothing() throws {
        var world = Reconnect()
        let shapes = try (0..<20).map { try Self.shape(&world, $0) }
        for (index, shape) in shapes.enumerated() {
            try world.byMe(Self.thread(on: shape, "Thread \(index)", in: world.mine.state))
            try world.byThem(SetTransforms([(shape, .translation(x: Double(index), y: 99))]))
            try world.byThem(SetNameOrNote([shape], .name, "Renamed \(index)"))
        }
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty && !divergence.hasRows)
        #expect(divergence.localObjects == 0 && divergence.remoteObjects == shapes.count)
        #expect(!divergence.decision(.standard).holdsOutbox)
        world.upload()
        #expect(CommentThreadModel(world.theirs.state).threads.count == shapes.count)
    }

    /// A thread anchored to an object deleted remotely lists the object as *Edited and deleted*;
    /// *Restore* brings the object and its pin back on both sides.
    @Test func restoringARemotelyDeletedCommentedObjectBringsBackItsPin() throws {
        var world = Reconnect()
        let shape = try Self.shape(&world)
        let bystander = try Self.shape(&world, 1)
        let thread = try #require(try world.byMe(Self.thread(on: shape, "Make this red", in: world.mine.state))).createdNodes[0]
        try world.byThem(DeleteNodes([shape, bystander]))
        let divergence = world.measure()
        #expect(divergence.entries.map(\.node) == [shape], "the uncommented object is not listed")
        let entry = divergence.entries[0]
        #expect(entry.kind == .editVsDelete && entry.kind.title == "Edited and deleted" && entry.anchoredComment)
        #expect(entry.actions == [.restore, .useTheirs])
        #expect(CommentThreadModel(world.mine.state)[thread]?.anchoring == .deleted(shape))
        try world.byMe(ReviewModel.restore(entry))
        world.upload()
        for state in [world.mine.state, world.theirs.state] {
            let restored = try #require(CommentThreadModel(state)[thread])
            #expect(state.isLive(shape) && restored.anchoring == .object(shape) && restored.pin != nil)
        }
    }

    /// Restoring a version from before a thread existed, while the other side writes a reply:
    /// the thread and its reply stay, the artwork is restored, and both converge.
    @Test func restoringAVersionFromBeforeAThreadLeavesTheThread() throws {
        var world = Reconnect()
        let shape = try Self.shape(&world)
        let version = world.mine.state
        let thread = try #require(try world.shared(Self.thread(on: shape, "Before the restore", in: world.theirs.state))).createdNodes[0]
        try world.shared(SetTransforms([(shape, .translation(x: 50, y: 50))]))
        let restore = try #require(try world.byMe(RestoreCommand(target: version, name: "v1")))
        #expect(restore.label == "Restore 'v1'")
        try world.byThem(Reply(to: thread, author: "sam", body: CommentBody("concurrent reply")))
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty, "the thread is not a conflict")
        world.upload()
        for state in [world.mine.state, world.theirs.state] {
            let threads = CommentThreadModel(state)
            #expect(threads.threads.map(\.id) == [thread] && threads[thread]?.replies.count == 1)
            #expect(Objects.transform(of: shape, in: state).tx == 0)
        }
    }
}
