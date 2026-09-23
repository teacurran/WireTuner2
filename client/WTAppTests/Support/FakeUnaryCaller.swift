import Foundation
import GRPCCore
import SwiftProtobuf
@testable import WireTuner

/// A unary method a `FakeUnaryCaller` answers: the request in, the response out (or a throw,
/// which reaches the client as it would from the server).
protocol FakeRoute: Sendable {
    var descriptor: MethodDescriptor { get }
    func answer(_ request: [UInt8]) throws -> [UInt8]
}

struct UnaryRoute<Input: SwiftProtobuf.Message & Sendable, Output: SwiftProtobuf.Message & Sendable>: FakeRoute {
    let descriptor: MethodDescriptor
    let reply: @Sendable (Input) throws -> Output

    func answer(_ request: [UInt8]) throws -> [UInt8] {
        try reply(try Input(serializedBytes: request)).serializedBytes()
    }
}

/// Builds a route with the request and response types taken from `reply`.
func route<Input: SwiftProtobuf.Message & Sendable, Output: SwiftProtobuf.Message & Sendable>(
    _ descriptor: MethodDescriptor, _ reply: @escaping @Sendable (Input) throws -> Output
) -> any FakeRoute {
    UnaryRoute(descriptor: descriptor, reply: reply)
}

/// An in-memory `UnaryCaller` answering only the routes given, so the gRPC team and share
/// clients run end to end -- request building, the wire encoding both ways, paging and the
/// response mapping -- without a server.  (A local test server is not possible: the hosted
/// tests run inside the sandboxed app, which may not listen on a port.)  An unknown method is
/// `UNIMPLEMENTED`, as a server would answer.
struct FakeUnaryCaller: UnaryCaller {
    let routes: [String: any FakeRoute]
    let tokens = RequestLog()

    init(_ routes: [any FakeRoute]) {
        self.routes = Dictionary(routes.map { ($0.descriptor.fullyQualifiedMethod, $0) }, uniquingKeysWith: { $1 })
    }

    func unary<Input: SwiftProtobuf.Message & Sendable, Output: SwiftProtobuf.Message & Sendable>(
        _ method: MethodDescriptor, _ request: Input, accessToken: String
    ) async throws -> Output {
        tokens.append(accessToken)
        guard let route = routes[method.fullyQualifiedMethod] else { throw RPCError(code: .unimplemented, message: method.fullyQualifiedMethod) }
        return try Output(serializedBytes: try route.answer(try request.serializedBytes()))
    }
}

/// What a fake route saw, for assertions.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}
