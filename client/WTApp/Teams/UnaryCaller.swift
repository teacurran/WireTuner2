import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

/// Runs one unary RPC by its method descriptor.  The team and share clients build requests and
/// map responses around it, so tests exercise them end to end against an in-memory caller
/// (the app's sandbox cannot listen on a port, which rules out a local test server).
protocol UnaryCaller: Sendable {
    func unary<Input: SwiftProtobuf.Message & Sendable, Output: SwiftProtobuf.Message & Sendable>(
        _ method: MethodDescriptor, _ request: Input, accessToken: String
    ) async throws -> Output
}

/// grpc-swift 2's HTTP/2 transport, one connection per call like `GRPCAccountClient`, with the
/// metadata every call carries (`CallMetadata`).
struct GRPCUnaryCaller: UnaryCaller {
    let api: URL
    let clientVersion: String
    let deviceID: String

    var endpoint: (host: String, port: Int, tls: Bool) {
        GRPCAccountClient(api: api, clientVersion: clientVersion, deviceID: deviceID).endpoint
    }

    func unary<Input: SwiftProtobuf.Message & Sendable, Output: SwiftProtobuf.Message & Sendable>(
        _ method: MethodDescriptor, _ request: Input, accessToken: String
    ) async throws -> Output {
        let endpoint = self.endpoint
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: endpoint.host, port: endpoint.port), transportSecurity: endpoint.tls ? .tls : .plaintext
        )
        let message = ClientRequest(message: request, metadata: CallMetadata(accessToken: accessToken, clientVersion: clientVersion, deviceID: deviceID).metadata)
        return try await withGRPCClient(transport: transport) { client in
            try await client.unary(
                request: message, descriptor: method, serializer: ProtobufSerializer<Input>(), deserializer: ProtobufDeserializer<Output>(),
                options: .defaults, onResponse: Self.message
            )
        }
    }

    @Sendable
    static func message<Output>(_ response: ClientResponse<Output>) throws -> Output { try response.message }
}
