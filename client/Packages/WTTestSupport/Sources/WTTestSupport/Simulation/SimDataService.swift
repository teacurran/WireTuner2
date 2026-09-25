import Foundation
import WTProto
import WTSync

/// The server's data service as the data-merge scenarios need it (DATA-023; data-merge.adoc,
/// "A web API"): the cloud fetches an API source for every editor with the scope's credential, so
/// every client receives the same records.  It serves registered APIs page by page, enforces the
/// host allowlist and the credential's existence, and keeps credential secrets on the server --
/// no call ever answers one.  `transport(link:)` gives a client its `DataSourceTransport` through
/// that client's network link: a partitioned client is offline.
public final class SimDataService: Sendable {
    struct API: Sendable {
        var records: [[String: String]]
        var pageSize: Int
    }

    struct Credential: Sendable {
        var stored: Wiretuner_Data_V1_Credential
        var secret: String
    }

    struct State: Sendable {
        var apis: [String: API] = [:]
        var allowed: Set<String> = []
        var credentials: [String: Credential] = [:]
        var fetches = 0
    }

    private let state = Locked(State())

    public init() {}

    /// Serves `records` at `url`, `pageSize` to a page.
    public func serve(_ url: String, records: [[String: String]], pageSize: Int = 25) {
        state.withLock { $0.apis[url] = API(records: records, pageSize: max(1, pageSize)) }
    }

    /// Puts `host` on the allowlist (the document's scope, as *Allow* in the Hosts sheet does).
    public func allow(_ host: String) {
        state.withLock { _ = $0.allowed.insert(host.lowercased()) }
    }

    /// Fetch streams started.
    public var fetches: Int { state.withLock(\.fetches) }

    /// Every secret the service holds, for tests that assert none left the server.
    public var secrets: [String] { state.withLock { $0.credentials.values.map(\.secret) } }

    /// A client's transport, through `link`.
    public func transport(link: NetworkLink) -> any DataSourceTransport {
        SimDataTransport(service: self, link: link)
    }

    /// One fetch: every page from `request.cursor` on of the source's API, each record's values
    /// keyed by the requested paths.
    func fetch(_ request: Wiretuner_Data_V1_FetchRequest) throws(DataServiceError) -> [Wiretuner_Data_V1_FetchResponse] {
        let host = URL(string: request.source.url)?.host?.lowercased() ?? ""
        let (allowed, api, known) = state.withLock { state -> (Bool, API?, Bool) in
            guard state.allowed.contains(host) else { return (false, nil, false) }
            state.fetches += 1
            let name = request.source.credentialName
            return (true, state.apis[request.source.url], name.isEmpty || state.credentials[name]?.stored.host == host)
        }
        guard allowed else { throw .hostNotAllowed(host: host, admins: "") }
        guard known else { throw .credentialMissing }
        guard let api else { throw .upstream("HTTP 404") }
        var responses: [Wiretuner_Data_V1_FetchResponse] = []
        var start = min(Int(request.cursor) ?? 0, api.records.count)
        repeat {
            let end = min(start + api.pageSize, api.records.count)
            var progress = Wiretuner_Data_V1_FetchResponse()
            progress.progress.pageNumber = UInt32(start / api.pageSize + 1)
            progress.progress.records = UInt64(start)
            var page = Wiretuner_Data_V1_FetchResponse()
            page.page.pageNumber = progress.progress.pageNumber
            page.page.records = api.records[start..<end].map { record in
                var out = Wiretuner_Data_V1_Record()
                out.values = Dictionary(uniqueKeysWithValues: request.paths.map { ($0, record[$0] ?? "") })
                return out
            }
            page.page.nextCursor = end < api.records.count ? String(end) : ""
            responses += [progress, page]
            start = end
        } while start < api.records.count
        return responses
    }

    /// Stores a credential; its secret stays here.
    func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest) -> Wiretuner_Data_V1_PutCredentialResponse {
        var stored = Wiretuner_Data_V1_Credential()
        stored.name = request.name
        stored.kind = request.kind
        stored.host = request.host.lowercased()
        state.withLock { $0.credentials[request.name] = Credential(stored: stored, secret: request.token + request.password + request.headerValue) }
        var response = Wiretuner_Data_V1_PutCredentialResponse()
        response.credential = stored
        return response
    }

    /// The credentials, names and hosts only.
    func listCredentials() -> Wiretuner_Data_V1_ListCredentialsResponse {
        var response = Wiretuner_Data_V1_ListCredentialsResponse()
        response.credentials = state.withLock { $0.credentials.values.map(\.stored) }.sorted { $0.name < $1.name }
        return response
    }
}

/// `SimDataService` through one client's link.
struct SimDataTransport: DataSourceTransport {
    let service: SimDataService
    let link: NetworkLink

    private func online() throws(DataServiceError) {
        guard !link.isPartitioned else { throw .offline }
    }

    func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error> {
        AsyncThrowingStream { continuation in
            do {
                try online()
                for response in try service.fetch(request) {
                    continuation.yield(response)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse {
        try online()
        return service.putCredential(request)
    }

    func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse {
        try online()
        return service.listCredentials()
    }

    /// The calls the scenarios do not make.
    private func unsupported() -> DataServiceError {
        .rejected(code: 12, message: "not simulated")
    }

    func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse {
        throw unsupported()
    }

    func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse {
        throw unsupported()
    }

    func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse {
        throw unsupported()
    }

    func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse {
        throw unsupported()
    }

    func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse {
        throw unsupported()
    }

    func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse {
        throw unsupported()
    }
}
