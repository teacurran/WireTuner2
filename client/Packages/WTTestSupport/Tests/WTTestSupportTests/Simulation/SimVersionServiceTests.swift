import Foundation
import Testing
import WTCRDT
import WTProto
import WTSync
@testable import WTTestSupport

/// `SimVersionService`'s rules, called directly (COLLAB-024; history.adoc, "Server").
@Suite struct SimVersionServiceTests {
    static func request(_ id: String, seq: UInt64 = 0, document: String = SimServerTests.doc) -> Wiretuner_Docs_V1_NameVersionRequest {
        var request = Wiretuner_Docs_V1_NameVersionRequest()
        request.documentID = document
        request.versionID = id
        request.serverSeq = seq
        request.name = "v \(id)"
        return request
    }

    static func code(_ body: () async throws -> Void) async -> Int? {
        do {
            try await body()
            return nil
        } catch let error as SyncCallError {
            return error.code
        } catch {
            return -1
        }
    }

    @Test func namesListsAndRefuses() async throws {
        let (server, alice, bob) = await SimServerTests.server()
        let service = SimVersionService(server: server)
        _ = try await SimServerTests.push(server, SimServerTests.change(7, seq: 1), token: bob)
        _ = try await SimServerTests.push(server, SimServerTests.change(7, seq: 2), token: bob)

        // Head, an explicit seq, and a local change resolved to its seq.
        let head = try await service.nameVersion(Self.request("a"), token: alice)
        #expect(head.serverSeq == 2)
        let explicit = try await service.nameVersion(Self.request("b", seq: 1), token: alice)
        #expect(explicit.serverSeq == 1)
        var through = Self.request("c")
        through.throughLocalChange = .with { $0.counter = 1; $0.replica = 7 }
        #expect(try await service.nameVersion(through, token: bob).serverSeq == 1)
        #expect(try await service.listVersions(.with { $0.documentID = SimServerTests.doc }, token: alice).versions.map(\.id) == ["c", "b", "a"])

        // Idempotent on the id; the id on another document, a seq past the head, a change not logged.
        #expect(try await service.nameVersion(Self.request("a"), token: alice) == head)
        await server.createDocument("D2", owner: SimServerTests.alice.id)
        #expect(await Self.code { _ = try await service.nameVersion(Self.request("a", document: "D2"), token: alice) } == 6)
        #expect(await Self.code { _ = try await service.nameVersion(Self.request("d", seq: 9), token: alice) } == SyncCallError.failedPrecondition)
        var missing = Self.request("e")
        missing.throughLocalChange = .with { $0.counter = 99; $0.replica = 7 }
        #expect(await Self.code { _ = try await service.nameVersion(missing, token: alice) } == SyncCallError.failedPrecondition)
        missing.throughLocalChange = .with { $0.counter = 0; $0.replica = 7 }
        #expect(await Self.code { _ = try await service.nameVersion(missing, token: alice) } == SyncCallError.failedPrecondition, "before the replica's first change")

        // Editors and owners only; a partitioned link is offline.
        await server.setRole(.viewer, for: SimServerTests.bob.id, on: SimServerTests.doc)
        #expect(await Self.code { _ = try await service.nameVersion(Self.request("f"), token: bob) } == SyncCallError.permissionDenied)
        let link = NetworkLink(name: "v", seed: 1, clock: SimClock(scale: 0.001), conditions: .perfect)
        let transport = service.transport(link: link)
        #expect(try await transport.listVersions(.with { $0.documentID = SimServerTests.doc }, token: bob).versions.count == 3)
        link.partition()
        #expect(await Self.code { _ = try await transport.nameVersion(Self.request("g"), token: alice) } == SyncCallError.unavailable)
        #expect(await Self.code { _ = try await transport.listVersions(.init(), token: alice) } == SyncCallError.unavailable)
        #expect(service.versions(of: "D2").isEmpty)
    }
}
