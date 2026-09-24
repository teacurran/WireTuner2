import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTSync

/// The Web API source sheet (data-merge.adoc, "A web API"; DATA-010's WTApp half): the request --
/// method, URL with `{{param}}`s, headers, body, credential name, records path, pagination,
/// timeout -- the parameters' shared defaults and the mapping, btn:[Test] (the first page, fetched
/// by the service) and btn:[Connect].  No secret is ever typed here: a credential header is refused
/// with the reason, and credentials are named, never entered.
@MainActor
@Observable
final class WebSourceModel {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    /// The source edited (nil: a new source).
    let editing: OpID?
    var name: String
    var method: Wiretuner_Doc_V1_HttpMethod
    var url: String
    var headers: [Row]
    var body: String
    var credential: String
    var recordsPath: String
    var pagination: Wiretuner_Doc_V1_PaginationMode
    var nextURLPath: String
    var pageParam: String
    var maxPages: Int
    var timeout: Int
    var params: [Row]
    /// Each field's path inside a record ("" reads the member of its own name).
    var mapping: [OpID: String]
    private(set) var credentials: [String] = []
    private(set) var testRecords: [DataRecord]?
    private(set) var message: String?
    private(set) var isTesting = false
    @ObservationIgnored let session: DataSession
    @ObservationIgnored let fields: [DataFieldInfo]

    init(session: DataSession, source: DataSourceInfo?) {
        self.session = session
        editing = source?.id
        let model = session.model
        fields = model.fields
        let http = source?.http ?? Wiretuner_Doc_V1_HttpSource.with {
            $0.method = .get
            $0.timeoutS = 30
            $0.pagination.mode = .none
            $0.pagination.maxPages = 1000
        }
        name = source?.name ?? "Web API"
        method = http.method
        url = http.url
        headers = http.headers.map { Row(name: $0.name, value: $0.value) }
        body = http.bodyTemplate
        credential = http.credentialName
        recordsPath = http.recordsPath
        pagination = http.pagination.mode
        nextURLPath = http.pagination.nextURLPath
        pageParam = http.pagination.pageParam
        maxPages = Int(http.pagination.maxPages)
        timeout = Int(http.timeoutS)
        params = http.params.map { Row(name: $0.name, value: $0.defaultValue) }
        var mapping: [OpID: String] = [:]
        for field in fields { mapping[field.id] = source?.mapping.last { $0.field == field.id }?.path ?? "" }
        self.mapping = mapping
    }

    var title: String { editing == nil ? "Web API Source" : "Edit Web API Source" }

    /// The request as the document stores it.
    var http: Wiretuner_Doc_V1_HttpSource {
        var http = Wiretuner_Doc_V1_HttpSource()
        http.method = method
        http.url = url.trimmingCharacters(in: .whitespaces)
        http.headers = headers.filter { !$0.name.isEmpty }.map { row in Wiretuner_Doc_V1_HttpHeader.with { $0.name = row.name; $0.value = row.value } }
        http.bodyTemplate = method == .post ? body : ""
        http.credentialName = credential
        http.recordsPath = recordsPath
        http.pagination.mode = pagination
        http.pagination.nextURLPath = pagination == .nextURL ? nextURLPath : ""
        http.pagination.pageParam = pagination == .pageParam ? pageParam : ""
        http.pagination.maxPages = UInt32(max(0, maxPages))
        http.timeoutS = UInt32(min(max(timeout, 0), 120))
        http.params = params.filter { !$0.name.isEmpty }.map { row in Wiretuner_Doc_V1_HttpParam.with { $0.name = row.name; $0.defaultValue = row.value } }
        return http
    }

    /// Why the request cannot be stored (the doc.v1 validation, said before writing).
    var problem: String? {
        let url = self.url.trimmingCharacters(in: .whitespaces).lowercased()
        if url.isEmpty { return "Enter the API’s address." }
        if !url.hasPrefix("https://") || url.count <= "https://".count { return DataEditMessages.text(.invalidURL(self.url)) }
        if let secret = headers.first(where: { ["authorization", "proxy-authorization", "cookie", "x-api-key"].contains($0.name.lowercased()) }) {
            return DataEditMessages.text(.secretHeader(secret.name))
        }
        return nil
    }

    func addHeader() { headers.append(Row(name: "", value: "")) }
    func removeHeader(_ id: UUID) { headers.removeAll { $0.id == id } }
    func addParam() { params.append(Row(name: "", value: "")) }
    func removeParam(_ id: UUID) { params.removeAll { $0.id == id } }

    /// The credential names the document may use (metadata only), for the pop-up.
    func loadCredentials() async {
        guard let client = session.services.client() else { return }
        credentials = ((try? await client.credentials(documentID: session.document.id)) ?? []).map(\.name)
    }

    /// The fetch request of the request as edited: the mapping paths, or each field's name.
    var request: Wiretuner_Data_V1_FetchRequest {
        var request = Wiretuner_Data_V1_FetchRequest()
        request.documentID = session.document.id
        if let editing { request.sourceID = editing.elementID }
        var http = self.http
        if http.timeoutS == 0 { http.timeoutS = 30 }
        request.source = http
        var values: [String: String] = [:]
        for param in http.params { values[param.name] = session.params[param.name].flatMap { $0.isEmpty ? nil : $0 } ?? param.defaultValue }
        request.params = values
        var seen: Set<String> = []
        request.paths = fields.map { mapping[$0.id].flatMap { $0.isEmpty ? nil : $0 } ?? $0.name }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return request
    }

    /// btn:[Test]: the first page, fetched by the service (consent first for a new host in a
    /// personal document).
    func test() async {
        if let problem {
            message = problem
            return
        }
        guard let client = session.services.client() else {
            message = DataServiceMessages.signedOut
            return
        }
        isTesting = true
        defer { isTesting = false }
        let request = self.request
        do {
            let records = try await session.permitting { try await Self.firstPage(client, request) }
            testRecords = records
            message = records.count == 1 ? "The first page has 1 record." : "The first page has \(records.count) records."
        } catch {
            testRecords = nil
            message = DataServiceMessages.text(error)
        }
    }

    /// The records of the stream's first page.
    static func firstPage(_ client: DataSourceClient, _ request: Wiretuner_Data_V1_FetchRequest) async throws -> [DataRecord] {
        for try await event in await client.fetch(request) {
            if case .page(let records, _) = event { return records }
        }
        return []
    }

    /// The change btn:[Connect] writes: a new source (one change "Connect source"), or the edited
    /// one's registers, headers, parameters and mapping in one change "Change source".
    func command() -> (any WTModel.Command)? {
        guard problem == nil else { return nil }
        let http = self.http
        guard let editing else {
            var source = Wiretuner_Doc_V1_DataSource()
            source.name = name
            source.spec.kind = .http
            source.spec.http = http
            source.mapping = fields.compactMap { field in
                guard let path = mapping[field.id], !path.isEmpty else { return nil }
                return Wiretuner_Doc_V1_FieldMapping.with { $0.field = field.id.elementID; $0.path = path }
            }
            return AddSource(source)
        }
        var spec = Wiretuner_Doc_V1_DataSourceSpec()
        spec.kind = .http
        spec.http = http
        let registers: [[UInt32]] = [[1], [4, 1], [4, 2], [4, 4], [4, 5], [4, 6], [4, 7, 1], [4, 7, 2], [4, 7, 3], [4, 7, 5], [4, 9]]
        var commands: [any WTModel.Command] = [
            EditSource(editing, name: name, spec: spec, paths: registers),
            SetSourceHeaders(editing, http.headers.map { ($0.name, $0.value) }),
            SetSourceParams(editing, http.params.map { ($0.name, $0.defaultValue) }),
        ]
        let model = session.model
        let source = model.source(editing)
        for field in fields {
            let path = mapping[field.id] ?? ""
            let current = source?.mapping.last { $0.field == field.id }?.path ?? ""
            if path != current { commands.append(SetMapping(editing, field: field.id, path: path.isEmpty ? nil : path)) }
        }
        return CommandBatch("Change source", commands)
    }

    /// Connects (or saves) the source; whether the sheet closes.
    @discardableResult
    func connect() -> Bool {
        guard let command = command() else {
            message = problem
            return false
        }
        session.perform(command)
        if editing != nil, let source = session.model.source(editing!), session.model.activeSource?.id != source.id {
            session.perform(SetActiveSource(source.id))
        }
        return true
    }
}

struct WebSourceSheet: View {
    @Bindable var model: WebSourceModel
    let close: @MainActor () -> Void

    static let methods: [(Wiretuner_Doc_V1_HttpMethod, String)] = [(.get, "GET"), (.post, "POST")]
    static let modes: [(Wiretuner_Doc_V1_PaginationMode, String)] = [(.none, "None"), (.nextURL, "Next URL"), (.pageParam, "Page number")]

    static func connect(_ model: WebSourceModel, _ close: @escaping @MainActor () -> Void) -> () -> Void {
        { if model.connect() { close() } }
    }

    static func test(_ model: WebSourceModel) -> () -> Void { { Task { await model.test() } } }
    static func removeHeader(_ id: UUID, _ model: WebSourceModel) -> () -> Void { { model.removeHeader(id) } }
    static func removeParam(_ id: UUID, _ model: WebSourceModel) -> () -> Void { { model.removeParam(id) } }

    static func mapping(_ id: OpID, _ model: WebSourceModel) -> Binding<String> {
        Binding(get: { model.mapping[id] ?? "" }, set: { model.mapping[id] = $0 })
    }

    static func maxPages(_ model: WebSourceModel) -> (Double) -> Void { { model.maxPages = Int($0) } }
    static func timeout(_ model: WebSourceModel) -> (Double) -> Void { { model.timeout = Int($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.headline)
            ScrollView {
                Form {
                    TextField("Name", text: $model.name).accessibilityIdentifier("web.name")
                    Picker("Method", selection: $model.method) {
                        ForEach(Self.methods, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("URL", text: $model.url, prompt: Text("https://api.example.com/orders?since={{since}}")).accessibilityIdentifier("web.url")
                    Section("Headers") {
                        ForEach($model.headers) { $row in
                            HStack {
                                TextField("Name", text: $row.name)
                                TextField("Value", text: $row.value)
                                Button(action: Self.removeHeader(row.id, model)) { Image(systemName: "minus") }
                            }
                        }
                        Button("Add Header", action: model.addHeader).accessibilityIdentifier("web.addHeader")
                    }
                    if model.method == .post {
                        TextField("Body", text: $model.body, axis: .vertical).lineLimit(3...6).accessibilityIdentifier("web.body")
                    }
                    Picker("Credential", selection: $model.credential) {
                        Text("None").tag("")
                        ForEach(model.credentials, id: \.self) { Text($0).tag($0) }
                        if !model.credential.isEmpty && !model.credentials.contains(model.credential) { Text(model.credential).tag(model.credential) }
                    }
                    .accessibilityIdentifier("web.credential")
                    TextField("Records path", text: $model.recordsPath, prompt: Text("$.data[*]")).accessibilityIdentifier("web.recordsPath")
                    Picker("Pagination", selection: $model.pagination) {
                        ForEach(Self.modes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .accessibilityIdentifier("web.pagination")
                    if model.pagination == .nextURL {
                        TextField("Next page path", text: $model.nextURLPath, prompt: Text("$.next"))
                    }
                    if model.pagination == .pageParam {
                        TextField("Page parameter", text: $model.pageParam, prompt: Text("page"))
                    }
                    if model.pagination != .none {
                        CommitField(title: "Maximum pages", value: Double(model.maxPages), identifier: "web.maxPages", commit: Self.maxPages(model))
                    }
                    CommitField(title: "Timeout (s)", value: Double(model.timeout), identifier: "web.timeout", commit: Self.timeout(model))
                    Section("Parameters") {
                        ForEach($model.params) { $row in
                            HStack {
                                TextField("Name", text: $row.name)
                                TextField("Default", text: $row.value)
                                Button(action: Self.removeParam(row.id, model)) { Image(systemName: "minus") }
                            }
                        }
                        Button("Add Parameter", action: model.addParam).accessibilityIdentifier("web.addParam")
                    }
                    Section("Mapping") {
                        ForEach(model.fields) { field in
                            TextField(field.displayName, text: Self.mapping(field.id, model), prompt: Text(field.name))
                        }
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(model.testRecords == nil ? .red : .secondary).accessibilityIdentifier("web.message")
            }
            if let records = model.testRecords, let first = records.first {
                Text(first.values.keys.sorted().map { "\($0): \(first.values[$0]!)" }.joined(separator: " · ")).font(.caption).lineLimit(3)
            }
            HStack {
                Button("Test", action: Self.test(model)).disabled(model.isTesting).accessibilityIdentifier("web.test")
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button(model.editing == nil ? "Connect" : "Save", action: Self.connect(model, close)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("web.connect")
            }
        }
        .padding()
        .frame(width: 520, height: 620)
        .task { await model.loadCredentials() }
    }
}

extension DataFeatures {
    /// *Connect… > Web API…* (or editing the connected API source).
    @discardableResult
    func presentWebSource(editing source: DataSourceInfo?) -> WebSourceModel? {
        guard let (window, session) = front else { return nil }
        let model = WebSourceModel(session: session, source: source)
        window.presentSheet("sheet.webSource") { close in WebSourceSheet(model: model, close: close) }
        return model
    }
}
