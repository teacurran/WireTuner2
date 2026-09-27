import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// DOC-029's WTSync half: a template's state from its local store, else from the server at head,
/// cached in a local store the first time.
@Suite(.timeLimit(.minutes(2))) struct TemplateDownloadTests {
    @Test func aCloudTemplateIsFetchedOnceThenReadFromItsStore() async throws {
        let scratch = Scratch()
        let (_, changes) = try await SymbolSourcesTests.storeWithSymbol(scratch)
        let server = FakeSyncServer()
        for change in changes { _ = try await server.inject(change) }
        let url = scratch.url("template")
        #expect(!TemplateDownload.isCached(at: url))
        let fetched = try await TemplateDownload.state(documentID: server.documentID, at: url, transport: FakeTransport(server: server),
                                                       token: { "token-1" }, options: options())
        #expect(SymbolSources.package(of: fetched).names == ["Dot"])
        #expect(TemplateDownload.isCached(at: url))
        // Offline now: the store answers.
        let cached = try await TemplateDownload.state(documentID: server.documentID, at: url, transport: nil, token: { "t" }, options: options())
        #expect(cached.stateHash == fetched.stateHash)
        let head = try await SymbolSources.cloudHead(documentID: server.documentID, transport: FakeTransport(server: server), token: "token-1")
        #expect(head.serverSeq == UInt64(changes.count))
    }

    @Test func anUncachedTemplateOfflineIsRefused() async throws {
        let scratch = Scratch()
        await #expect(throws: TemplateDownload.Failure.notCached) {
            try await TemplateDownload.state(documentID: "doc", at: scratch.url(), transport: nil, token: { "t" }, options: options())
        }
    }

    @Test func aFailedFetchLeavesNoStoreBehind() async throws {
        let scratch = Scratch()
        let url = scratch.url("template")
        await #expect(throws: SymbolSources.Failure.self) {
            try await TemplateDownload.state(documentID: "doc", at: url, transport: VersionStateTests.GapTransport(), token: { "t" }, options: options())
        }
        #expect(!TemplateDownload.isCached(at: url))
    }
}
