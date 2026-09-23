import Foundation
@testable import WireTuner

/// A fake Keycloak token and logout endpoint behind `URLProtocol`.  Each test registers a
/// unique host, so tests running in parallel never see each other's requests.
final class FakeTokenEndpoint: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, [String: String]) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: [(url: URL, form: [String: String])]] = [:]

    /// A new host with `handler`; the returned session routes to it.
    static func register(_ handler: @escaping Handler) -> (host: String, session: URLSession) {
        let host = "kc-\(UUID().uuidString.lowercased()).test"
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeTokenEndpoint.self]
        return (host, URLSession(configuration: configuration))
    }

    static func requests(to host: String) -> [(url: URL, form: [String: String])] {
        lock.withLock { requests[host] ?? [] }
    }

    static func form(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding
        }
        return result
    }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// A successful token response.
    static func tokens(access: String = "access", refresh: String? = "refresh", expiresIn: Double = 300, refreshExpiresIn: Double = 1800) -> Data {
        var object: [String: Any] = ["access_token": access, "expires_in": expiresIn, "refresh_expires_in": refreshExpiresIn, "token_type": "Bearer"]
        if let refresh { object["refresh_token"] = refresh }
        return json(object)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url!.host!
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let form = Self.form(body)
        let handler = Self.lock.withLock {
            Self.requests[host, default: []].append((request.url!, form))
            return Self.handlers[host]!
        }
        let (status, data) = handler(request, form)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Answers the browser step with a callback built from the authorization request.
struct FakeWebAuthenticator: WebAuthenticator {
    enum Behaviour: Sendable {
        case approve(code: String)
        case wrongState
        case error(String)
        case noCode
        case fail(AuthError)
    }

    let behaviour: Behaviour
    let seen: Recorder<URL>

    init(_ behaviour: Behaviour, seen: Recorder<URL> = Recorder()) {
        self.behaviour = behaviour
        self.seen = seen
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        seen.append(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        let base = "\(callbackScheme)://auth/callback"
        switch behaviour {
        case let .approve(code): return URL(string: "\(base)?code=\(code)&state=\(state)")!
        case .wrongState: return URL(string: "\(base)?code=x&state=forged")!
        case let .error(code): return URL(string: "\(base)?error=\(code)&error_description=Denied&state=\(state)")!
        case .noCode: return URL(string: "\(base)?state=\(state)")!
        case let .fail(error): throw error
        }
    }
}

/// A thread-safe list for values recorded from `@Sendable` closures.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    init() {}

    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
