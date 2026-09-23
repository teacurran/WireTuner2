import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// `GRPCSyncTransport` end to end over grpc-swift 2's in-process transport: every RPC, the call
/// metadata, and rejections read back from `google.rpc.Status` details.
@Suite(.timeLimit(.minutes(2))) struct GRPCSyncTransportTests {
    @Test func aSessionRunsOverGRPC() async throws {
        let server = FakeSyncServer()
        for seq in 1...20 {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        await server.takeSnapshot(through: 15)
        await server.update { $0.delay = [3: .milliseconds(50)] }
        let calls = FakeGRPCService.Calls()
        let presence = FakePresence()
        presence.move(tool: "pen")
        try await FakeGRPCService.withTransport(server, calls: calls) { transport in
            let harness = try await Harness(server: server, presence: presence, transport: { _ in transport })
            await harness.client.start()
            try await harness.edit(40)
            try await harness.expectConverged()
            presence.move(tool: "pencil")
            try await eventually("presence") { await server.presences.contains { $0.tool == "pencil" } }
            try await eventually("acked") { await server.acks.last == 60 }
            try await harness.stop()
        }
        #expect(await server.fetchSnapshotCalls == 1)
        #expect(await server.gaps > 0)
        let metadata = calls.metadata.withLock { $0 }
        #expect(metadata.allSatisfy { Array($0[stringValues: "wt-client"]) == ["macos/1.0/1"] })
        #expect(metadata.allSatisfy { Array($0[stringValues: "wt-device"]) == ["device-1"] })
        #expect(metadata.allSatisfy { $0[stringValues: "wt-request-id"].first(where: { _ in true }) != nil })
    }

    @Test func gatewayAndBulkUploadsRunOverGRPC() async throws {
        let server = FakeSyncServer()
        try await FakeGRPCService.withTransport(server) { transport in
            let gateway = try await Harness(server: server, options: fastOptions(gateway: true), transport: { _ in transport })
            try await gateway.edit(40)
            await gateway.client.start()
            try await gateway.expectConverged()
            try await gateway.stop()
        }
        #expect(await server.batches.count == 2)
        let bulk = FakeSyncServer()
        try await FakeGRPCService.withTransport(bulk) { transport in
            let harness = try await Harness(server: bulk, transport: { _ in transport })
            try await harness.edit(230)
            await harness.client.start()
            try await harness.expectConverged()
            try await harness.stop()
        }
        #expect(await bulk.bulkFrames.flatMap { $0 }.count == 230)
    }

    @Test func refusalsCarryTheirReasonAndRetryDelay() async throws {
        let server = FakeSyncServer()
        await server.update {
            $0.reject = [1: SyncCallError(code: SyncCallError.resourceExhausted, reason: .rateLimited, message: "slow", retryAfter: .milliseconds(250))]
        }
        try await FakeGRPCService.withTransport(server) { transport in
            var change = Wiretuner_Sync_V1_PushChangeRequest()
            change.documentID = "D1"
            change.change = remoteChange(seq: 1)
            let error = await #expect(throws: SyncCallError.self) { _ = try await transport.pushChange(change, token: "token-1") }
            #expect(error?.code == SyncCallError.resourceExhausted && error?.reason == .rateLimited)
            #expect(error?.retryAfter == .milliseconds(250) && error?.message == "slow")
            let expired = await #expect(throws: SyncCallError.self) { _ = try await transport.pushChange(change, token: "stale") }
            #expect(expired?.reason == .tokenExpired && expired?.code == SyncCallError.unauthenticated)
            let stream = transport.fetchSnapshot(.with { $0.documentID = "D1" }, token: "token-1")
            let unavailable = await #expect(throws: SyncCallError.self) { for try await _ in stream {} }
            #expect(unavailable?.reason == .historyUnavailable)
            let subscribe = transport.subscribe(.with { $0.documentID = "D1" }, token: "stale")
            await #expect(throws: SyncCallError.self) { for try await _ in subscribe {} }
            let changes = transport.fetchChanges(.with { $0.documentID = "D1" }, token: "stale")
            await #expect(throws: SyncCallError.self) { for try await _ in changes {} }
        }
    }

    @Test func errorsWithoutAStatusAreKeptAsTheyAre() {
        let plain = URLError(.timedOut)
        #expect(GRPCSyncTransport<InProcessTransport.Client>.mapped(plain) is URLError)
        let bare = GRPCSyncTransport<InProcessTransport.Client>.mapped(RPCError(code: .unavailable, message: "down"))
        #expect(bare as? SyncCallError == SyncCallError(code: SyncCallError.unavailable, message: "down"))
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() async throws {
        let identity = GRPCSyncTransport<InProcessTransport.Client>.Identity(clientVersion: "1", deviceID: "d")
        let plain = try GRPCSyncTransport.http2(api: URL(string: "http://localhost:1")!,
                                                identity: .init(clientVersion: identity.clientVersion, deviceID: identity.deviceID))
        await plain.close()
        let tls = try GRPCSyncTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await tls.close()
        let hostless = try GRPCSyncTransport.http2(api: URL(string: "grpc:/path")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await hostless.close()
    }
}
