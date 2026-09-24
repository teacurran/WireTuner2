import Foundation
import WTCRDT

// DATA-011/012: what a script reaches beyond the document -- `wt.fetch` (the server's
// `DataSourceService.Proxy`, supplied by WTSync), `wt.ui` and `wt.records.merge` (the window,
// supplied by WTApp).  WTModel only defines the seams; nothing here opens a connection.

/// One `wt.fetch` request as the script gave it.
public struct ScriptFetchRequest: Hashable, Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    /// At most 1 MiB.
    public var body: Data
    /// The name of a credential stored on the server (`options.credential`).
    public var credential: String
    /// Seconds; 0 reads 30.
    public var timeout: UInt32

    public init(method: String = "GET", url: String, headers: [String: String] = [:], body: Data = Data(), credential: String = "", timeout: UInt32 = 0) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.credential = credential
        self.timeout = timeout
    }
}

/// The response a script sees: `status`, `headers`, `text()`, `json()`.
public struct ScriptFetchResponse: Hashable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Why `wt.fetch` failed.
public enum ScriptFetchError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No connection to the service (`OfflineError`).
    case offline
    /// The host is not permitted for the document's scope; for a team, the admins to ask.
    case hostNotAllowed(host: String, admins: String)
    /// The named credential does not exist in the scope.
    case credentialMissing(String)
    /// The response was over the proxy's cap.
    case responseTooLarge
    /// The upstream failed (connection refused, TLS, timeout).
    case upstream(String)
    /// The team's or account's fair-use limit; retry after the delay.
    case rateLimited(retryAfter: Double?)
    /// Anything else, with the service's message.
    case failed(String)

    public var description: String {
        switch self {
        case .offline: "OfflineError: wt.fetch needs a connection to the WireTuner service"
        case .hostNotAllowed(let host, let admins):
            admins.isEmpty ? "HostNotAllowed: \(host) is not a permitted host" : "HostNotAllowed: \(host) is not a permitted host; ask \(admins) to permit it"
        case .credentialMissing(let name): "CredentialMissing: no credential named \(name)"
        case .responseTooLarge: "ResponseTooLarge: the response is over 16 MiB"
        case .upstream(let message): "UpstreamError: \(message)"
        case .rateLimited(let delay): "RateLimited: too many requests" + (delay.map { "; retry in \(Int($0.rounded(.up))) s" } ?? "")
        case .failed(let message): "FetchError: \(message)"
        }
    }
}

/// `wt.fetch`: makes a request through the service on the script's behalf.  Called
/// synchronously from the script's thread (the implementation may block it).
public protocol ScriptFetching: Sendable {
    func fetch(_ request: ScriptFetchRequest) throws -> ScriptFetchResponse
}

/// The window's side of a run: `wt.ui`, `wt.records.merge`, `wt.document.export` and `print`.
/// Every method may block the script's thread while a sheet is up.  The defaults refuse, so a
/// headless run (a merge transform) has no UI.
public protocol ScriptHost: AnyObject, Sendable {
    /// `alert`, `confirm`, `prompt`, `choose`, `openFile` (contents, never a path), `saveFile`
    /// (a token for `write`), `write`, `progress`, `progressDone`, `merge`.
    func ui(_ call: String, _ arguments: [Any]) throws -> Any?
    /// `wt.document.export(options)`.
    func export(_ options: [String: Any]) throws -> Any?
    /// `wt.document.print(preset)`.
    func print(_ preset: String?) throws -> Any?
    /// A progress update: the fraction and text for the sheet.  Returning false cancels the
    /// script after the current change.
    func progress(_ fraction: Double, _ text: String) -> Bool
}

extension ScriptHost {
    public func ui(_ call: String, _ arguments: [Any]) throws -> Any? { throw ScriptUnavailable(call: "wt.ui.\(call)") }
    public func export(_ options: [String: Any]) throws -> Any? { throw ScriptUnavailable(call: "wt.document.export") }
    public func print(_ preset: String?) throws -> Any? { throw ScriptUnavailable(call: "wt.document.print") }
    public func progress(_ fraction: Double, _ text: String) -> Bool { true }
}

/// A `wt` call the run cannot make (no window: a transform or a script source).
public struct ScriptUnavailable: Error, Hashable, Sendable, CustomStringConvertible {
    public var call: String
    public var description: String { "\(call) is not available here" }
}

/// A run with no window and no network: `wt.ui`, export and print refuse.
public final class HeadlessScriptHost: ScriptHost, @unchecked Sendable {
    public init() {}
}
