import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Synchronization
import SwiftProtobuf
import WTCRDT
import WTModel
import WTProto

// DATA-010's client half (data-merge.adoc, "Client", "Data service client"): `DataSourceClient`
// over `DataSourceService`.  Every web request is made by the server: `fetch` streams an API
// source's records page by page and resumes from the last cursor when the stream drops;
// `fetchAsset` fetches an IMAGE field's picture into a server-side blob; `proxy` is `wt.fetch`.
// The last complete fetch of each source is cached on this Mac so the Data panel and the preview
// work offline; nothing is ever sent to any host but the WireTuner service.

/// Why a data-service call failed, from the API conventions' error detail.
public enum DataServiceError: Error, Hashable, Sendable {
    /// The service could not be reached: offline.  Refresh, Test and merges needing the full set
    /// are disabled rather than queued.
    case offline
    /// The host is not permitted for the document's scope; `admins` names whom to ask (a team).
    case hostNotAllowed(host: String, admins: String)
    /// The source names a credential that does not exist in the scope.
    case credentialMissing
    /// A page or response over the service's cap.
    case responseTooLarge
    /// The upstream failed.
    case upstream(String)
    /// The team's or account's fair-use limit: the panel pauses for `retryAfter`.
    case rateLimited(retryAfter: Duration?)
    /// Any other rejection, as the service sent it.
    case rejected(code: Int, message: String)

    /// The `wt.fetch` error a script sees.
    public var scriptError: ScriptFetchError {
        switch self {
        case .offline: .offline
        case .hostNotAllowed(let host, let admins): .hostNotAllowed(host: host, admins: admins)
        case .credentialMissing: .credentialMissing("")
        case .responseTooLarge: .responseTooLarge
        case .upstream(let message): .upstream(message)
        case .rateLimited(let delay): .rateLimited(retryAfter: delay.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 })
        case .rejected(_, let message): .failed(message)
        }
    }

    /// The error of a `SyncCallError` (a fake transport's, or `GRPCSyncTransport.mapped`'s).
    static func from(_ error: SyncCallError, metadata: [String: String] = [:]) -> DataServiceError {
        switch error.reason {
        case .hostNotAllowed?: return .hostNotAllowed(host: metadata["host"] ?? "", admins: metadata["admins"] ?? "")
        case .credentialMissing?: return .credentialMissing
        case .responseTooLarge?: return .responseTooLarge
        case .upstreamError?: return .upstream(error.message)
        default: break
        }
        switch error.code {
        case SyncCallError.unavailable: return .offline
        case SyncCallError.resourceExhausted: return .rateLimited(retryAfter: error.retryAfter)
        default: return .rejected(code: error.code, message: error.message)
        }
    }

    /// Any error thrown by a transport, as a `DataServiceError`.
    static func from(_ error: any Error) -> DataServiceError {
        switch error {
        case let error as DataServiceError: error
        case let error as SyncCallError: from(error, metadata: [:])
        default: .rejected(code: 2, message: String(describing: error))
        }
    }
}

/// The calls of `DataSourceService`.  `GRPCDataSourceTransport` is the network one; tests supply
/// fakes.  Errors are `DataServiceError`s (or `SyncCallError`s, mapped by the client).
public protocol DataSourceTransport: Sendable {
    func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error>
    func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse
    func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse
    func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse
    func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse
    func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse
    func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse
    func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse
    func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse
}

/// `DataSourceTransport` over grpc-swift 2 with the API conventions' metadata; a rejection's
/// `ErrorInfo` (reason and metadata: `host`, `admins`) and `RetryInfo` become a
/// `DataServiceError`.
public final class GRPCDataSourceTransport<Transport: ClientTransport>: DataSourceTransport {
    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Data_V1_DataSourceService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Data_V1_DataSourceService.Client(wrapping: client)
        self.identity = identity
        connections = Task { try? await client.runConnections() }
    }

    /// Closes the connection once in-flight calls have finished.
    public func close() async {
        client.beginGracefulShutdown()
        await connections.value
    }

    private func metadata(_ token: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        metadata.addString(UUID().uuidString, forKey: "wt-request-id")
        return metadata
    }

    /// A gRPC error as a `DataServiceError`.
    static func mapped(_ error: any Error) -> any Error {
        guard let rpc = error as? RPCError else { return error }
        let details = (try? rpc.unpackGoogleRPCStatus())?.details ?? []
        let info = details.lazy.compactMap(\.errorInfo).first
        let reason = info.flatMap { SyncCallError.reason(named: $0.reason) }
        let delay = details.lazy.compactMap(\.retryInfo).first?.delay
        return DataServiceError.from(SyncCallError(code: rpc.code.rawValue, reason: reason, message: rpc.message, retryAfter: delay), metadata: info?.metadata ?? [:])
    }

    private func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> Output {
        do {
            return try await body()
        } catch {
            throw Self.mapped(error)
        }
    }

    public func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error> {
        let metadata = metadata(token)
        return AsyncThrowingStream { continuation in
            let task = Task { [service] in
                do {
                    try await service.fetch(request, metadata: metadata) { response in
                        for try await message in response.messages {
                            continuation.yield(message)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse {
        try await unary { try await service.fetchAsset(request, metadata: metadata(token)) }
    }

    public func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse {
        try await unary { try await service.proxy(request, metadata: metadata(token)) }
    }

    public func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse {
        try await unary { try await service.listCredentials(request, metadata: metadata(token)) }
    }

    public func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse {
        try await unary { try await service.putCredential(request, metadata: metadata(token)) }
    }

    public func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse {
        try await unary { try await service.deleteCredential(request, metadata: metadata(token)) }
    }

    public func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse {
        try await unary { try await service.listAllowedHosts(request, metadata: metadata(token)) }
    }

    public func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse {
        try await unary { try await service.putAllowedHost(request, metadata: metadata(token)) }
    }

    public func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse {
        try await unary { try await service.deleteAllowedHost(request, metadata: metadata(token)) }
    }
}

extension GRPCDataSourceTransport where Transport == HTTP2ClientTransport.Posix {
    /// The HTTP/2 transport to the API at `api` (`https` for TLS; the port defaults by scheme).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCDataSourceTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
                                                       transportSecurity: tls ? .tls : .plaintext)
        return GRPCDataSourceTransport(transport: transport, identity: identity)
    }
}

/// One step of a fetch, for the Data panel's progress bar and the preview.
public enum DataFetchEvent: Hashable, Sendable {
    case progress(Wiretuner_Data_V1_FetchProgress)
    /// A page of records (values keyed by the requested paths).
    case page([DataRecord], number: UInt32)
    /// The stream dropped and was resumed from its cursor.
    case resumed(attempt: Int)
}

/// The data service on this Mac: fetches through the server, caches each source's last complete
/// fetch, and serves `wt.fetch`.
public actor DataSourceClient {
    private let transport: any DataSourceTransport
    private let token: @Sendable () async throws -> String
    private let directory: URL
    /// How many times a dropped stream is resumed before the fetch fails.
    public let maxResumes: Int

    public init(transport: any DataSourceTransport, directory: URL, maxResumes: Int = 3, token: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.directory = directory
        self.maxResumes = maxResumes
        self.token = token
    }

    /// `~/Library/Caches/WireTuner/DataSources`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "DataSources")
    }

    // MARK: Fetching an API source

    /// The request for `source` of `documentID` with the typed `params` and the mapping paths of
    /// `model`'s fields (each field's path, deduplicated, in field order).
    public static func request(documentID: String, source: DataSourceInfo, model: DataModel, params: [String: String]) -> Wiretuner_Data_V1_FetchRequest {
        var request = Wiretuner_Data_V1_FetchRequest()
        request.documentID = documentID
        request.sourceID = source.id.elementID
        request.source = source.http
        request.params = params
        var seen: Set<String> = []
        request.paths = model.fields.map { model.path(of: $0, in: source) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return request
    }

    /// Streams the source's records page by page.  A stream that drops (`offline`, or the
    /// connection going away) after a page is resumed from that page's `next_cursor` up to
    /// `maxResumes` times, so no record is repeated or missed; other errors end the stream.
    public func fetch(_ request: Wiretuner_Data_V1_FetchRequest) -> AsyncThrowingStream<DataFetchEvent, any Error> {
        let transport = transport
        let token = token
        let maxResumes = maxResumes
        return AsyncThrowingStream { continuation in
            let task = Task {
                var current = request
                var attempts = 0
                while true {
                    var progressed = false
                    do {
                        let bearer = try await token()
                        for try await response in transport.fetch(current, token: bearer) {
                            switch response.body {
                            case .page(let page)?:
                                continuation.yield(.page(page.records.map { DataRecord($0.values) }, number: page.pageNumber))
                                current.cursor = page.nextCursor
                                progressed = true
                                if page.nextCursor.isEmpty {
                                    continuation.finish()
                                    return
                                }
                            case .progress(let progress)?:
                                continuation.yield(.progress(progress))
                            case nil:
                                break
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        let mapped = DataServiceError.from(error)
                        guard mapped == .offline, progressed || attempts > 0, attempts < maxResumes, !Task.isCancelled else {
                            continuation.finish(throwing: mapped)
                            return
                        }
                        attempts += 1
                        continuation.yield(.resumed(attempt: attempts))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetches every record of `source` and caches the result for offline use (the key is the
    /// document and the source's element id).
    public func fetchAll(documentID: String, source: DataSourceInfo, model: DataModel, params: [String: String] = [:]) async throws -> DataTable {
        let request = Self.request(documentID: documentID, source: source, model: model, params: params)
        var records: [DataRecord] = []
        for try await event in fetch(request) {
            if case .page(let page, _) = event { records += page }
        }
        let table = DataTable(columns: request.paths, records: records)
        write(table, key: Self.key(documentID, source.id))
        return table
    }

    /// The records of `source`'s last complete fetch on this Mac, or nil.
    public func cachedRecords(documentID: String, source: OpID) -> DataTable? {
        guard let data = try? Data(contentsOf: file(Self.key(documentID, source))), let table = try? DataTable.json(data) else { return nil }
        return table
    }

    /// Forgets a source's cached records.
    public func forget(documentID: String, source: OpID) {
        try? FileManager.default.removeItem(at: file(Self.key(documentID, source)))
    }

    // MARK: Assets and wt.fetch

    /// An IMAGE field's picture through the service (same allowlist and credential): the blob is
    /// stored server-side and its hash comes back.
    public func fetchAsset(documentID: String, url: String, credential: String = "") async throws -> Wiretuner_Data_V1_FetchAssetResponse {
        var request = Wiretuner_Data_V1_FetchAssetRequest()
        request.documentID = documentID
        request.url = url
        request.credentialName = credential
        return try await call { [request] in try await self.transport.fetchAsset(request, token: $0) }
    }

    /// `wt.fetch`: one request through `DataSourceService.Proxy`.
    public func proxy(documentID: String, _ fetch: ScriptFetchRequest) async throws -> ScriptFetchResponse {
        var request = Wiretuner_Data_V1_ProxyRequest()
        request.documentID = documentID
        request.method = fetch.method
        request.url = fetch.url
        request.headers = fetch.headers
        request.body = fetch.body
        request.credentialName = fetch.credential
        request.timeoutS = min(fetch.timeout, 120)
        let response = try await call { [request] in try await self.transport.proxy(request, token: $0) }
        return ScriptFetchResponse(status: Int(response.status), headers: response.headers, body: response.body)
    }

    // MARK: Credentials and hosts

    /// The credentials the document's sources may use (metadata only), every page.
    public func credentials(documentID: String) async throws -> [Wiretuner_Data_V1_Credential] {
        var all: [Wiretuner_Data_V1_Credential] = []
        var cursor = ""
        repeat {
            var request = Wiretuner_Data_V1_ListCredentialsRequest()
            request.documentID = documentID
            request.cursor = cursor
            request.pageSize = 50
            let response = try await call { [request] in try await self.transport.listCredentials(request, token: $0) }
            all += response.credentials
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return all
    }

    /// Stores or replaces a secret (team admins, or the account itself).  The secret leaves with
    /// the request and is never returned.
    public func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest) async throws -> Wiretuner_Data_V1_Credential {
        try await call { [request] in try await self.transport.putCredential(request, token: $0) }.credential
    }

    public func deleteCredential(scope: Wiretuner_Data_V1_Scope, name: String) async throws -> Bool {
        var request = Wiretuner_Data_V1_DeleteCredentialRequest()
        request.scope = scope
        request.name = name
        return try await call { [request] in try await self.transport.deleteCredential(request, token: $0) }.deleted
    }

    /// The hosts the document's scope permits, every page.
    public func allowedHosts(documentID: String) async throws -> [Wiretuner_Data_V1_AllowedHost] {
        var all: [Wiretuner_Data_V1_AllowedHost] = []
        var cursor = ""
        repeat {
            var request = Wiretuner_Data_V1_ListAllowedHostsRequest()
            request.documentID = documentID
            request.cursor = cursor
            request.pageSize = 50
            let response = try await call { [request] in try await self.transport.listAllowedHosts(request, token: $0) }
            all += response.hosts
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return all
    }

    /// Permits `host` for `scope` (the consent sheet's *Allow*, on the account's own scope).
    @discardableResult
    public func putAllowedHost(scope: Wiretuner_Data_V1_Scope, host: String) async throws -> Wiretuner_Data_V1_AllowedHost {
        var request = Wiretuner_Data_V1_PutAllowedHostRequest()
        request.scope = scope
        request.host = host
        return try await call { [request] in try await self.transport.putAllowedHost(request, token: $0) }.host
    }

    public func deleteAllowedHost(scope: Wiretuner_Data_V1_Scope, host: String) async throws -> Bool {
        var request = Wiretuner_Data_V1_DeleteAllowedHostRequest()
        request.scope = scope
        request.host = host
        return try await call { [request] in try await self.transport.deleteAllowedHost(request, token: $0) }.deleted
    }

    // MARK: Plumbing

    private func call<Output: Sendable>(_ body: @Sendable (String) async throws -> Output) async throws -> Output {
        do {
            return try await body(try await token())
        } catch {
            throw DataServiceError.from(error)
        }
    }

    static func key(_ documentID: String, _ source: OpID) -> String {
        let document = String(documentID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
        return "\(document)-\(source.counter)-\(source.replica)"
    }

    private func file(_ key: String) -> URL {
        directory.appending(component: "records-\(key).json")
    }

    private func write(_ table: DataTable, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? table.json().write(to: file(key), options: .atomic)
    }
}

/// `wt.fetch` for scripts (`ScriptFetching`): a synchronous bridge onto `DataSourceClient.proxy`
/// for the script's thread.  `HOST_NOT_ALLOWED` on a personal document (`account` set) asks
/// `consent` -- the window's sheet naming the document and host -- and on *Allow* permits the
/// host on the account's own scope and retries once; on a team document the error names the
/// admins to ask.
public final class DataScriptFetcher: ScriptFetching, @unchecked Sendable {
    private let client: DataSourceClient
    private let documentID: String
    private let account: String?
    private let consent: @Sendable (String) async -> Bool
    /// Hosts the user permitted during this run, so the sheet appears once per host.
    private let permitted = Mutex<Set<String>>([])

    public init(client: DataSourceClient, documentID: String, personalAccount account: String?,
                consent: @escaping @Sendable (String) async -> Bool = { _ in false }) {
        self.client = client
        self.documentID = documentID
        self.account = account
        self.consent = consent
    }

    public func fetch(_ request: ScriptFetchRequest) throws -> ScriptFetchResponse {
        let box = Mutex<Result<ScriptFetchResponse, ScriptFetchError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task { [self] in
            let result: Result<ScriptFetchResponse, ScriptFetchError>
            do {
                result = .success(try await client.proxy(documentID: documentID, request))
            } catch {
                let error = DataServiceError.from(error)
                if case .hostNotAllowed(let host, _) = error, let account, !permitted.withLock({ $0.contains(host) }), await consent(host) {
                    do {
                        var scope = Wiretuner_Data_V1_Scope()
                        scope.accountID = account
                        try await client.putAllowedHost(scope: scope, host: host)
                        permitted.withLock { _ = $0.insert(host) }
                        result = .success(try await client.proxy(documentID: documentID, request))
                    } catch {
                        result = .failure(DataServiceError.from(error).scriptError)
                    }
                } else {
                    result = .failure(error.scriptError)
                }
            }
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return try box.withLock { $0! }.get()
    }
}
