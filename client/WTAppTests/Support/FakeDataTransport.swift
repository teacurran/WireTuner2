import AppKit
import Foundation
import Synchronization
import WTGeometry
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// The data service as the Data panel's tests need it: pages to stream, credentials and permitted
/// hosts kept in memory, a host refused until permitted, errors on demand, every request recorded.
final class FakeDataTransport: DataSourceTransport, @unchecked Sendable {
    struct State {
        var pages: [[[String: String]]] = []
        var credentials: [Wiretuner_Data_V1_Credential] = []
        var allowed: [String] = []
        /// A host every fetch and proxy call is refused for until it is permitted.
        var guarded: String?
        /// The admins named when `guarded` refuses (a team document).
        var admins = ""
        /// Thrown by the next call of any kind.
        var failure: (any Error)?
        var fetches: [Wiretuner_Data_V1_FetchRequest] = []
        var puts: [Wiretuner_Data_V1_PutCredentialRequest] = []
        var proxies: [Wiretuner_Data_V1_ProxyRequest] = []
        var proxyBody = Data("{\"ok\":true}".utf8)
    }

    let state = Mutex(State())

    init(pages: [[[String: String]]] = []) {
        state.withLock { $0.pages = pages }
    }

    func update(_ body: (inout State) -> Void) { state.withLock { state in body(&state) } }
    var snapshot: State { state.withLock { $0 } }

    private func check() throws {
        if let failure = state.withLock({ state -> (any Error)? in
            defer { state.failure = nil }
            return state.failure
        }) { throw failure }
    }

    private func guardHost() throws {
        let (guarded, allowed, admins) = state.withLock { ($0.guarded, $0.allowed, $0.admins) }
        if let guarded, !allowed.contains(guarded) { throw DataServiceError.hostNotAllowed(host: guarded, admins: admins) }
    }

    func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error> {
        state.withLock { $0.fetches.append(request) }
        let pages = state.withLock { $0.pages }
        return AsyncThrowingStream { continuation in
            do {
                try check()
                try guardHost()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            for (index, page) in pages.enumerated() {
                var response = Wiretuner_Data_V1_FetchResponse()
                response.page.pageNumber = UInt32(index + 1)
                response.page.records = page.map { values in Wiretuner_Data_V1_Record.with { $0.values = values } }
                response.page.nextCursor = index + 1 < pages.count ? "page-\(index + 2)" : ""
                continuation.yield(response)
            }
            continuation.finish()
        }
    }

    func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse {
        try check()
        return Wiretuner_Data_V1_FetchAssetResponse()
    }

    func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse {
        state.withLock { $0.proxies.append(request) }
        try check()
        try guardHost()
        return Wiretuner_Data_V1_ProxyResponse.with {
            $0.status = 200
            $0.body = state.withLock { $0.proxyBody }
        }
    }

    func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse {
        try check()
        return Wiretuner_Data_V1_ListCredentialsResponse.with { $0.credentials = state.withLock { $0.credentials } }
    }

    func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse {
        state.withLock { $0.puts.append(request) }
        try check()
        let credential = Wiretuner_Data_V1_Credential.with {
            $0.name = request.name
            $0.kind = request.kind
            $0.host = request.host
            $0.createdByName = "Ann"
        }
        state.withLock { state in
            state.credentials.removeAll { $0.name == request.name }
            state.credentials.append(credential)
        }
        return Wiretuner_Data_V1_PutCredentialResponse.with { $0.credential = credential }
    }

    func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse {
        try check()
        state.withLock { $0.credentials.removeAll { $0.name == request.name } }
        return Wiretuner_Data_V1_DeleteCredentialResponse.with { $0.deleted = true }
    }

    func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse {
        try check()
        return Wiretuner_Data_V1_ListAllowedHostsResponse.with { response in
            response.hosts = state.withLock { $0.allowed }.map { host in Wiretuner_Data_V1_AllowedHost.with { $0.host = host } }
        }
    }

    func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse {
        try check()
        state.withLock { $0.allowed.append(request.host) }
        return Wiretuner_Data_V1_PutAllowedHostResponse.with { $0.host.host = request.host }
    }

    func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse {
        try check()
        state.withLock { $0.allowed.removeAll { $0 == request.host } }
        return Wiretuner_Data_V1_DeleteAllowedHostResponse.with { $0.deleted = true }
    }
}

/// A document window with data merge wired to a fake service: fields, a text block, the features.
@MainActor
struct DataWorld {
    let setup = SetupWindow()
    let features: DataFeatures
    let transport: FakeDataTransport
    let client: DataSourceClient
    let blobs: URL

    init(pages: [[[String: String]]] = [], scope: DataScope? = DataScope(kind: .personal(account: "acct"), canManage: true), consent: Bool = true) {
        transport = FakeDataTransport(pages: pages)
        let directory = TestEnvironment.temporaryDirectory()
        blobs = directory.appending(path: "blobs")
        let client = DataSourceClient(transport: transport, directory: directory.appending(path: "cache")) { "token" }
        self.client = client
        features = DataFeatures(preferences: setup.environment.preferences)
        features.services.client = { client }
        features.services.scope = { _ in scope }
        features.services.consent = { _, _ in consent }
        let blobDirectory = blobs
        features.blobs.directory = { blobDirectory }
        let window = setup.window
        features.install(commands: setup.environment.commands, panels: setup.environment.panels) { [weak window] in window }
        // No modal alert in a test: the first *Embed Sample* is confirmed.
        features.session(for: window).confirmEmbed = { _, _ in true }
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var session: DataSession { features.session(for: window) }

    func close() {
        features.detach(window)
        setup.close()
    }

    /// Adds fields named `names` (text unless `kinds` says), returns their ids.
    @discardableResult
    func fields(_ names: [String], kinds: [DataFieldKind] = []) async -> [OpID] {
        let fields = names.enumerated().map { AddFields.Field($1, kind: $0 < kinds.count ? kinds[$0] : .text) }
        _ = await document.perform(AddFields(fields)).value
        await document.settle()
        let model = DataModel(document.state)
        return names.compactMap { model.field(named: $0)?.id }
    }

    /// A text block holding `text` with a placeholder for `field` at its end.
    func placeholderText(_ text: String, field: OpID, at point: Point = Point(x: 60, y: 80)) async -> OpID? {
        guard let node = await document.addText(text, at: point) else { return nil }
        _ = await document.perform(InsertPlaceholder(node: node, at: .end, field: field)).value
        await document.settle()
        return node
    }

    /// Connects a pasted source holding `table` (TSV text) and waits for its records.
    func paste(_ tsv: String) async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DataWorld-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(tsv, forType: .string)
        _ = await features.connectPastedTable(from: pasteboard)?.value
        await document.settle()
        await session.load()
    }
}
