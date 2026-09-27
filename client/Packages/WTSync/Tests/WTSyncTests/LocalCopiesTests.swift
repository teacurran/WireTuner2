import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// IO-035's *Remove Local Copy*: a store goes only when nothing in it waits for the cloud.
@Suite struct LocalCopiesTests {
    let scratch = Scratch()

    @Test func aCopyIsRemovedOnlyOnceEverythingReachedTheCloud() async throws {
        let url = scratch.url("doc")
        #expect(try await LocalCopies.remove(documentID: "D1", at: url, options: options()) == .notOnThisMac)
        let store = try await LocalStore.open(documentID: "D1", at: url, options: options())
        let created = try await store.perform(createLayer("A"), recording: Fixture.recording()).change!
        try await store.addPendingBlob(.init(hash: "img", path: "/i", size: 10))
        try await store.replacePendingCalls(kind: "NameVersion", with: [PendingCall(id: "v", kind: "NameVersion", payload: Data(), createdAt: Date())])
        try await store.close()
        // A change, an image and a call wait: nothing is deleted.
        let waiting = LocalCopies.Waiting(changes: 1, blobs: 1, calls: 1)
        #expect(try await LocalCopies.waiting(documentID: "D1", at: url, options: options()) == waiting)
        #expect(try await LocalCopies.remove(documentID: "D1", at: url, options: options()) == .waiting(waiting))
        #expect(waiting.message == "1 change, 1 image and 1 pending action have not reached the cloud yet.")
        #expect(LocalCopies.exists(at: url))
        // Acknowledged and uploaded: the copy goes, directory and all.
        let reopened = try await LocalStore.open(documentID: "D1", at: url, options: options())
        _ = try await reopened.acknowledge(seq: created.seq, serverSeq: 1)
        try await reopened.removePendingBlob(hash: "img")
        try await reopened.replacePendingCalls(kind: "NameVersion", with: [])
        try await reopened.close()
        #expect(try await LocalCopies.remove(documentID: "D1", at: url, options: options()) == .removed)
        #expect(!LocalCopies.exists(at: url) && !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    /// A store whose folder cannot be deleted reports the failure (the folder stays).
    @Test func aDirectoryThatCannotBeDeletedReportsTheFailure() async throws {
        let url = scratch.url("locked/doc")
        let store = try await LocalStore.open(documentID: "D2", at: url, options: options())
        try await store.close()
        let parent = url.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        await #expect(throws: (any Error).self) { try await LocalCopies.remove(documentID: "D2", at: url, options: options()) }
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "the store's folder is still there")
    }

    @Test func theMessageNamesWhatWaits() {
        #expect(LocalCopies.Waiting(changes: 2, salvaged: 1).message == "3 changes have not reached the cloud yet.")
        #expect(LocalCopies.Waiting(blobs: 2).message == "2 images have not reached the cloud yet.")
        #expect(LocalCopies.Waiting(calls: 1).message == "1 pending action has not reached the cloud yet.")
        #expect(LocalCopies.Waiting().isEmpty && LocalCopies.Waiting().message == "Everything has reached the cloud.")
    }
}
