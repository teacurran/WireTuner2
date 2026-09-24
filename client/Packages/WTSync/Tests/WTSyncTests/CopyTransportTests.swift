import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Testing
import WTProto
@testable import WTSync

/// `GRPCDocumentCopyTransport` end to end over grpc-swift's in-process transport.
@Suite(.timeLimit(.minutes(2))) struct CopyTransportTests {
    typealias Documents = Wiretuner_Docs_V1_DocumentService.Method
    typealias Branches = Wiretuner_Docs_V1_BranchService.Method

    static func router(calls: FakeGRPCService.Calls) -> RPCRouter<InProcessTransport.Server> {
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func record(_ request: ServerRequest<some Sendable>) {
            calls.metadata.withLock { $0.append(request.metadata) }
        }
        router.registerHandler(forMethod: Documents.Fork.descriptor, deserializer: ProtobufDeserializer<Documents.Fork.Input>(),
                               serializer: ProtobufSerializer<Documents.Fork.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            record(single)
            guard single.message.name != "refuse" else {
                throw FakeGRPCService.status(SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "no"))
            }
            return StreamingServerResponse(single: ServerResponse(message: .with { $0.document.id = single.message.newDocumentID }))
        }
        router.registerHandler(forMethod: Branches.CreateBranch.descriptor, deserializer: ProtobufDeserializer<Branches.CreateBranch.Input>(),
                               serializer: ProtobufSerializer<Branches.CreateBranch.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            record(single)
            return StreamingServerResponse(single: ServerResponse(message: .with {
                $0.branch.branchDocumentID = single.message.branchDocumentID
                $0.branch.forkServerSeq = single.message.forkServerSeq
            }))
        }
        return router
    }

    @Test func forkAndCreateBranchRunOverGRPC() async throws {
        let recorded = FakeGRPCService.Calls()
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: Self.router(calls: recorded))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCDocumentCopyTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let forked = try await transport.fork(.with { $0.newDocumentID = "copy"; $0.name = "Mine" }, token: "tok")
            #expect(forked.document.id == "copy")
            let branch = try await transport.createBranch(.with { $0.branchDocumentID = "b"; $0.forkServerSeq = 7 }, token: "tok")
            #expect(branch.branch.branchDocumentID == "b" && branch.branch.forkServerSeq == 7)
            await #expect(throws: SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "no")) {
                try await transport.fork(.with { $0.name = "refuse" }, token: "tok")
            }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { Array($0[stringValues: "wt-device"]) == ["device-1"] && Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() async throws {
        let plain = try GRPCDocumentCopyTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await plain.close()
        let tls = try GRPCDocumentCopyTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await tls.close()
        let hostless = try GRPCDocumentCopyTransport.http2(api: URL(string: "grpc:/path")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await hostless.close()
    }
}
