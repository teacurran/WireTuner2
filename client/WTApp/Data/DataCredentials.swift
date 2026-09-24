import AppKit
import SwiftUI
import WTModel
import WTProto
import WTSync

/// The *Credentials…* sheet (data-merge.adoc, "Credentials"; DATA-010's WTApp half): the
/// credentials the document's scope holds -- names, kinds, hosts and who stored them, never a
/// secret -- with btn:[+], btn:[Replace] and btn:[Remove] for those who manage the scope (a team's
/// admins, D-062; a personal document's owner).  A secret leaves with `PutCredential` and its
/// fields are cleared the moment the call returns; nothing secret is kept, logged or written to
/// the document.
@MainActor
@Observable
final class CredentialsModel {
    /// A credential being added or replaced.
    struct Draft: Equatable {
        var name = ""
        var kind: Wiretuner_Data_V1_CredentialKind = .bearer
        var host = ""
        var token = ""
        var username = ""
        var password = ""
        var headerName = ""
        var headerValue = ""
        var clientID = ""
        var clientSecret = ""
        var tokenURL = ""
        var oauthScope = ""
        /// Replacing an existing credential (its name is fixed).
        var replacing = false

        /// The secret fields emptied (after the call returns, whatever it answered).
        mutating func clearSecrets() {
            token = ""
            password = ""
            headerValue = ""
            clientSecret = ""
        }

        /// The request carrying the secret of the draft's kind, for `scope`.
        func request(scope: Wiretuner_Data_V1_Scope) -> Wiretuner_Data_V1_PutCredentialRequest {
            var request = Wiretuner_Data_V1_PutCredentialRequest()
            request.scope = scope
            request.name = name
            request.kind = kind
            request.host = host.trimmingCharacters(in: .whitespaces).lowercased()
            switch kind {
            case .basic:
                request.username = username
                request.password = password
            case .header:
                request.headerName = headerName
                request.headerValue = headerValue
            case .oauth2Client:
                request.clientID = clientID
                request.clientSecret = clientSecret
                request.tokenURL = tokenURL
                request.oauthScope = oauthScope
            default:
                request.token = token
            }
            return request
        }

        /// Why the draft cannot be saved.
        var problem: String? {
            if name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) == nil { return "Names use letters, digits, dots, dashes and underscores." }
            if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the host the credential may be sent to." }
            let secret: String = switch kind {
            case .basic: password
            case .header: headerValue
            case .oauth2Client: clientSecret
            default: token
            }
            return secret.isEmpty ? "Enter the secret." : nil
        }
    }

    static let kinds: [(Wiretuner_Data_V1_CredentialKind, String)] = [
        (.bearer, "Bearer token"), (.basic, "User name and password"), (.header, "API key header"), (.oauth2Client, "OAuth 2 client credentials"),
    ]

    static func title(_ kind: Wiretuner_Data_V1_CredentialKind) -> String {
        kinds.first { $0.0 == kind }?.1 ?? "Unknown"
    }

    let documentID: String
    private(set) var items: [Wiretuner_Data_V1_Credential] = []
    private(set) var scope: DataScope?
    private(set) var message: String?
    private(set) var isBusy = false
    var draft: Draft?
    @ObservationIgnored let client: DataSourceClient?
    @ObservationIgnored let resolveScope: @MainActor () async -> DataScope?
    /// Asks before removing; replaceable in tests.
    @ObservationIgnored var confirmRemove: @MainActor (String) -> Bool = { name in
        let alert = NSAlert()
        alert.messageText = "Remove the credential “\(name)”?"
        alert.informativeText = "Sources and scripts that name it fail until it is added again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    init(documentID: String, client: DataSourceClient?, scope: @escaping @MainActor () async -> DataScope?) {
        self.documentID = documentID
        self.client = client
        resolveScope = scope
    }

    /// Adds, replaces and removes only for those who manage the scope.
    var canManage: Bool { scope?.canManage == true && client != nil }

    func load() async {
        guard let client else {
            message = "Credentials are stored in the WireTuner cloud. Sign in to see them."
            return
        }
        scope = await resolveScope()
        do {
            items = try await client.credentials(documentID: documentID)
            message = canManage ? nil : scope?.managerNote
        } catch {
            message = Self.message(error)
        }
    }

    static func message(_ error: any Error) -> String {
        if case DataServiceError.offline? = error as? DataServiceError { return "Credentials need a connection to the WireTuner service." }
        return DataServiceMessages.text(error)
    }

    func add() {
        guard canManage else { return }
        draft = Draft()
    }

    func replace(_ credential: Wiretuner_Data_V1_Credential) {
        guard canManage else { return }
        draft = Draft(name: credential.name, kind: credential.kind, host: credential.host, replacing: true)
    }

    func cancel() { draft = nil }

    /// Stores the draft's secret; its secret fields are cleared as soon as the call returns.
    @discardableResult
    func save() async -> Bool {
        guard var draft, canManage, let client, let scope else { return false }
        if let problem = draft.problem {
            message = problem
            return false
        }
        isBusy = true
        let request = draft.request(scope: scope.proto)
        let result: Result<Wiretuner_Data_V1_Credential, any Error>
        do {
            result = .success(try await client.putCredential(request))
        } catch {
            result = .failure(error)
        }
        draft.clearSecrets()
        self.draft = draft
        isBusy = false
        switch result {
        case .success(let stored):
            items.removeAll { $0.name == stored.name }
            items.append(stored)
            items.sort { $0.name < $1.name }
            self.draft = nil
            message = nil
            return true
        case .failure(let error):
            message = Self.message(error)
            return false
        }
    }

    @discardableResult
    func remove(_ name: String) async -> Bool {
        guard canManage, let client, let scope, confirmRemove(name) else { return false }
        do {
            _ = try await client.deleteCredential(scope: scope.proto, name: name)
            items.removeAll { $0.name == name }
            return true
        } catch {
            message = Self.message(error)
            return false
        }
    }
}

struct CredentialsSheet: View {
    @Bindable var model: CredentialsModel
    let close: @MainActor () -> Void

    static func replace(_ credential: Wiretuner_Data_V1_Credential, _ model: CredentialsModel) -> () -> Void { { model.replace(credential) } }
    static func remove(_ name: String, _ model: CredentialsModel) -> () -> Void { { Task { await model.remove(name) } } }
    static func save(_ model: CredentialsModel) -> () -> Void { { Task { await model.save() } } }

    static func draft(_ model: CredentialsModel) -> Binding<CredentialsModel.Draft> {
        Binding(get: { model.draft ?? CredentialsModel.Draft() }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Credentials").font(.headline)
            if model.items.isEmpty {
                Text("No credentials yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.items, id: \.name) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name).fontWeight(.medium)
                        Text("\(CredentialsModel.title(item.kind)) · \(item.host) · \(item.createdByName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canManage {
                        Button("Replace", action: Self.replace(item, model))
                        Button("Remove", action: Self.remove(item.name, model))
                    }
                }
                .accessibilityIdentifier("credential.\(item.name)")
            }
            if model.draft != nil {
                CredentialEditor(draft: Self.draft(model))
                HStack {
                    Spacer()
                    Button("Cancel", action: model.cancel)
                    Button("Save", action: Self.save(model)).disabled(model.isBusy).accessibilityIdentifier("credential.save")
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("credential.message")
            }
            HStack {
                if model.canManage && model.draft == nil {
                    Button(action: model.add) { Image(systemName: "plus") }.accessibilityIdentifier("credential.add")
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
        .task { await model.load() }
    }
}

/// The fields of a credential being added or replaced; the secret fields are secure fields.
struct CredentialEditor: View {
    @Binding var draft: CredentialsModel.Draft

    var body: some View {
        Form {
            TextField("Name", text: $draft.name).disabled(draft.replacing).accessibilityIdentifier("credential.name")
            Picker("Kind", selection: $draft.kind) {
                ForEach(CredentialsModel.kinds, id: \.0) { Text($0.1).tag($0.0) }
            }
            TextField("Host", text: $draft.host, prompt: Text("api.example.com")).accessibilityIdentifier("credential.host")
            switch draft.kind {
            case .basic:
                TextField("User name", text: $draft.username)
                SecureField("Password", text: $draft.password)
            case .header:
                TextField("Header", text: $draft.headerName, prompt: Text("X-Api-Key"))
                SecureField("Value", text: $draft.headerValue)
            case .oauth2Client:
                TextField("Client id", text: $draft.clientID)
                SecureField("Client secret", text: $draft.clientSecret)
                TextField("Token URL", text: $draft.tokenURL)
                TextField("Scope", text: $draft.oauthScope)
            default:
                SecureField("Token", text: $draft.token).accessibilityIdentifier("credential.token")
            }
        }
    }
}

/// *Show Hosts* (data-merge.adoc, "Hosts and permissions"): the hosts the document's sources and
/// scripts reach -- each source's URL host and the hosts the last script source run fetched from
/// -- and the scope's permitted hosts, with whether each is permitted; in a personal document its
/// owner can revoke one.
@MainActor
@Observable
final class HostsModel {
    struct Row: Identifiable, Equatable {
        var id: String { host }
        let host: String
        /// What reaches it ("Orders API", "script"), empty for a host only on the list.
        let usedBy: [String]
        let permitted: Bool
    }

    private(set) var rows: [Row] = []
    private(set) var message: String?
    private(set) var scope: DataScope?
    @ObservationIgnored let session: DataSession

    init(session: DataSession) {
        self.session = session
        rows = Self.rows(referenced: Self.referenced(session), allowed: [])
    }

    /// The hosts the document's sources and the last script run name.
    static func referenced(_ session: DataSession) -> [(host: String, by: String)] {
        var result: [(String, String)] = []
        for source in session.model.sources where source.kind == .http {
            if let host = host(of: source.spec.http.url) { result.append((host, source.name.isEmpty ? "Web API" : source.name)) }
        }
        for host in session.scriptHosts { result.append((host.lowercased(), "Script")) }
        return result
    }

    /// `host[:port]` of an https URL (a `{{param}}` in the host reads as none), lower case, port
    /// 443 dropped.
    static func host(of url: String) -> String? {
        guard let components = URLComponents(string: url.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")),
              components.scheme?.lowercased() == "https", let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if let port = components.port, port != 443 { return "\(host):\(port)" }
        return host
    }

    static func rows(referenced: [(host: String, by: String)], allowed: [String]) -> [Row] {
        var used: [String: [String]] = [:]
        for (host, by) in referenced where !(used[host]?.contains(by) ?? false) { used[host, default: []].append(by) }
        let hosts = Set(used.keys).union(allowed).sorted()
        return hosts.map { Row(host: $0, usedBy: used[$0] ?? [], permitted: allowed.contains($0)) }
    }

    /// A personal document's owner revokes; a team's list is kept in the team settings.
    var canRevoke: Bool { scope?.isPersonal == true && scope?.canManage == true }

    func load() async {
        guard let client = session.services.client() else {
            message = "Sign in to see which hosts are permitted."
            return
        }
        scope = await session.services.scope(session.document)
        do {
            let allowed = try await client.allowedHosts(documentID: session.document.id).map(\.host)
            rows = Self.rows(referenced: Self.referenced(session), allowed: allowed)
            message = nil
        } catch {
            message = CredentialsModel.message(error)
        }
    }

    @discardableResult
    func revoke(_ host: String) async -> Bool {
        guard canRevoke, let client = session.services.client(), let scope else { return false }
        do {
            _ = try await client.deleteAllowedHost(scope: scope.proto, host: host)
            await load()
            return true
        } catch {
            message = CredentialsModel.message(error)
            return false
        }
    }
}

struct HostsSheet: View {
    let model: HostsModel
    let close: @MainActor () -> Void

    static func revoke(_ host: String, _ model: HostsModel) -> () -> Void { { Task { await model.revoke(host) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hosts").font(.headline)
            if model.rows.isEmpty {
                Text("The document’s sources and scripts reach no host.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                HStack {
                    Image(systemName: row.permitted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(row.permitted ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(row.host)
                        Text(row.usedBy.isEmpty ? "Permitted, not used here" : row.usedBy.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canRevoke && row.permitted {
                        Button("Revoke", action: Self.revoke(row.host, model))
                    }
                }
                .accessibilityIdentifier("host.\(row.host)")
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hosts.message")
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
        .task { await model.load() }
    }
}

extension DataFeatures {
    /// *Credentials…*.
    @discardableResult
    func presentCredentials() -> CredentialsModel? {
        guard let (window, session) = front else { return nil }
        let services = session.services
        let document = window.documentHandle
        let model = CredentialsModel(documentID: document.id, client: services.client()) { await services.scope(document) }
        window.presentSheet("sheet.credentials") { close in CredentialsSheet(model: model, close: close) }
        return model
    }

    /// *Show Hosts*.
    @discardableResult
    func presentHosts() -> HostsModel? {
        guard let (window, session) = front else { return nil }
        let model = HostsModel(session: session)
        window.presentSheet("sheet.hosts") { close in HostsSheet(model: model, close: close) }
        return model
    }
}
