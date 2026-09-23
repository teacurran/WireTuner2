import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Synchronization
import WTProto
@testable import WTSync

/// The `FakeSyncServer` served over grpc-swift 2's in-process transport, so `GRPCSyncTransport`
/// runs against it end to end: rejections travel as the server sends them, a status with
/// `google.rpc.ErrorInfo` (and `RetryInfo`) in its details.
enum FakeGRPCService {
    typealias Method = Wiretuner_Sync_V1_SyncService.Method

    /// Metadata of every call, for assertions.
    final class Calls: Sendable {
        let metadata = Mutex<[Metadata]>([])
    }

    static func router(_ server: FakeSyncServer, calls: Calls, blobs: FakeBlobServer? = nil) -> RPCRouter<InProcessTransport.Server> {
        let fake = FakeTransport(server: server)
        var router = RPCRouter<InProcessTransport.Server>()

        @Sendable func token(_ metadata: Metadata) -> String {
            calls.metadata.withLock { $0.append(metadata) }
            let value = metadata[stringValues: "authorization"].first(where: { _ in true }) ?? ""
            return String(value.dropFirst("Bearer ".count))
        }

        router.registerHandler(forMethod: Method.Subscribe.descriptor, deserializer: ProtobufDeserializer<Method.Subscribe.Input>(),
                               serializer: ProtobufSerializer<Method.Subscribe.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            let bearer = token(single.metadata)
            return StreamingServerResponse { writer in
                do {
                    for try await frame in fake.subscribe(single.message, token: bearer) {
                        try await writer.write(frame)
                    }
                } catch let error as SyncCallError {
                    throw status(error)
                }
                return [:]
            }
        }
        router.registerHandler(forMethod: Method.PushChange.descriptor, deserializer: ProtobufDeserializer<Method.PushChange.Input>(),
                               serializer: ProtobufSerializer<Method.PushChange.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.pushChange(single.message, token: token(single.metadata)) }
        }
        router.registerHandler(forMethod: Method.PushChangeBatch.descriptor,
                               deserializer: ProtobufDeserializer<Method.PushChangeBatch.Input>(),
                               serializer: ProtobufSerializer<Method.PushChangeBatch.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.pushChangeBatch(single.message, token: token(single.metadata)) }
        }
        router.registerHandler(forMethod: Method.PushChanges.descriptor, deserializer: ProtobufDeserializer<Method.PushChanges.Input>(),
                               serializer: ProtobufSerializer<Method.PushChanges.Output>()) { request, _ in
            let bearer = token(request.metadata)
            var frames: [Method.PushChanges.Input] = []
            for try await frame in request.messages {
                frames.append(frame)
            }
            return try await unary { [frames] in try await fake.pushChanges(frames, token: bearer) }
        }
        router.registerHandler(forMethod: Method.UpdatePresence.descriptor,
                               deserializer: ProtobufDeserializer<Method.UpdatePresence.Input>(),
                               serializer: ProtobufSerializer<Method.UpdatePresence.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary {
                try await fake.updatePresence(single.message, token: token(single.metadata))
                return Wiretuner_Sync_V1_UpdatePresenceResponse()
            }
        }
        router.registerHandler(forMethod: Method.Ack.descriptor, deserializer: ProtobufDeserializer<Method.Ack.Input>(),
                               serializer: ProtobufSerializer<Method.Ack.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.ack(single.message, token: token(single.metadata)) }
        }
        router.registerHandler(forMethod: Method.FetchChanges.descriptor, deserializer: ProtobufDeserializer<Method.FetchChanges.Input>(),
                               serializer: ProtobufSerializer<Method.FetchChanges.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            let bearer = token(single.metadata)
            return StreamingServerResponse { writer in
                do {
                    for try await message in fake.fetchChanges(single.message, token: bearer) {
                        try await writer.write(message)
                    }
                } catch let error as SyncCallError {
                    throw status(error)
                }
                return [:]
            }
        }
        router.registerHandler(forMethod: Method.FetchSnapshot.descriptor, deserializer: ProtobufDeserializer<Method.FetchSnapshot.Input>(),
                               serializer: ProtobufSerializer<Method.FetchSnapshot.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            let bearer = token(single.metadata)
            return StreamingServerResponse { writer in
                do {
                    for try await message in fake.fetchSnapshot(single.message, token: bearer) {
                        try await writer.write(message)
                    }
                } catch let error as SyncCallError {
                    throw status(error)
                }
                return [:]
            }
        }
        if let blobs {
            register(blobs, on: &router, token: token)
        }
        return router
    }

    typealias BlobMethod = Wiretuner_Blob_V1_BlobService.Method

    /// `BlobService` onto a `FakeBlobServer`.
    static func register(_ blobs: FakeBlobServer, on router: inout RPCRouter<InProcessTransport.Server>,
                         token: @escaping @Sendable (Metadata) -> String) {
        let fake = FakeBlobTransport(server: blobs)
        router.registerHandler(forMethod: BlobMethod.Stat.descriptor, deserializer: ProtobufDeserializer<BlobMethod.Stat.Input>(),
                               serializer: ProtobufSerializer<BlobMethod.Stat.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.stat(single.message, token: token(single.metadata)) }
        }
        router.registerHandler(forMethod: BlobMethod.Upload.descriptor, deserializer: ProtobufDeserializer<BlobMethod.Upload.Input>(),
                               serializer: ProtobufSerializer<BlobMethod.Upload.Output>()) { request, _ in
            let bearer = token(request.metadata)
            var header = Wiretuner_Blob_V1_UploadHeader()
            var chunks: [Data] = []
            for try await frame in request.messages {
                switch frame.frame {
                case .header(let value)?: header = value
                case .chunk(let chunk)?: chunks.append(chunk)
                case nil: break
                }
            }
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
            return try await unary { [header] in try await fake.upload(header, chunks: stream, token: bearer) }
        }
        router.registerHandler(forMethod: BlobMethod.Download.descriptor, deserializer: ProtobufDeserializer<BlobMethod.Download.Input>(),
                               serializer: ProtobufSerializer<BlobMethod.Download.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            let bearer = token(single.metadata)
            return StreamingServerResponse { writer in
                do {
                    for try await message in fake.download(single.message, token: bearer) {
                        try await writer.write(message)
                    }
                } catch let error as SyncCallError {
                    throw status(error)
                }
                return [:]
            }
        }
    }

    private static func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> StreamingServerResponse<Output> {
        do {
            return StreamingServerResponse(single: ServerResponse(message: try await body()))
        } catch let error as SyncCallError {
            throw status(error)
        }
    }

    /// A `SyncCallError` as the server sends it: code, message, `ErrorInfo` and `RetryInfo`.
    static func status(_ error: SyncCallError) -> GoogleRPCStatus {
        var details: [ErrorDetails] = []
        if let reason = error.reason, let name = reasonName(reason) {
            details.append(.errorInfo(reason: name, domain: "wiretuner.app"))
        }
        if let delay = error.retryAfter {
            details.append(.retryInfo(delay: delay))
        }
        let code = Status.Code(rawValue: error.code).flatMap(RPCError.Code.init) ?? .unknown
        return GoogleRPCStatus(code: code, message: error.message, details: details)
    }

    /// `ERROR_REASON_SEQ_GAP` → `SEQ_GAP`.
    static func reasonName(_ reason: Wiretuner_Sync_V1_ErrorReason) -> String? {
        let json = (try? Wiretuner_Sync_V1_ChangeRejected.with { $0.reason = reason }.jsonString()) ?? ""
        guard let range = json.range(of: "ERROR_REASON_") else { return nil }
        return String(json[range.upperBound...].prefix { $0 != "\"" })
    }

    /// Runs `body` with a `GRPCSyncTransport` connected in-process to `server`.
    static func withTransport<Result: Sendable>(
        _ server: FakeSyncServer, calls: Calls = Calls(), blobs: FakeBlobServer? = nil,
        _ body: @Sendable (GRPCSyncTransport<InProcessTransport.Client>) async throws -> Result
    ) async throws -> Result {
        let inProcess = InProcessTransport()
        let grpcServer = GRPCServer(transport: inProcess.server, router: router(server, calls: calls, blobs: blobs))
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await grpcServer.serve() }
            let transport = GRPCSyncTransport(transport: inProcess.client,
                                              identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let result = try await body(transport)
            await server.endStreams()
            grpcServer.beginGracefulShutdown()
            await transport.close()
            return result
        }
    }
}
