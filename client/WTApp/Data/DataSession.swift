import AppKit
import Foundation
import Observation
import WTCRDT
import WTModel
import WTProto
import WTSync

/// One window's data merge state (data-merge.adoc, "The Data panel", "Previewing records"): the
/// records of the connected source as this Mac has them, where they came from, the record
/// navigator and the preview, a fetch in progress.  None of it is document state: records are
/// never written (except an embedded sample), and the preview is this window's own.  Nothing here
/// connects or runs a script on its own -- only `refresh` does, from btn:[Refresh] or a merge.
@MainActor
@Observable
final class DataSession {
    /// Where the records shown came from.
    enum Origin: Equatable {
        /// No source, or nothing read yet.
        case none
        /// The source's embedded sample (every collaborator has it).
        case sample(count: Int, complete: Bool)
        /// The file on this Mac.
        case file(name: String)
        /// A fetch or script run in this session.
        case fetched(Date)
        /// The last complete fetch cached on this Mac.
        case cached
    }

    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored var services: DataServices
    @ObservationIgnored var preferences: PreferenceStore?
    /// Where embedded samples are stored and read.
    @ObservationIgnored var blobs: BlobPlacement
    /// When it is now (the status line's "Fetched 2 minutes ago"); replaceable in tests.
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }
    /// Asks before the first *Embed Sample* ("samples are document data"); replaceable in tests.
    @ObservationIgnored var confirmEmbed: @MainActor (String, String) -> Bool = { message, detail in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Embed")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Bumped on every document change, so the panel re-reads the model.
    private(set) var revision = 0
    /// The raw records of the connected source as read (nil: none).
    private(set) var table: DataTable?
    private(set) var origin: Origin = .none
    /// A problem to show under the source (offline, a missing file, a refused fetch).
    private(set) var message: String?
    /// A fetch or script run in progress.
    private(set) var isFetching = false
    /// The record navigator and *Preview*.
    private(set) var preview = DataPreviewState()
    /// The `{{param}}` values typed in the panel (local; the defaults are the document's).
    var params: [String: String] = [:]
    /// The hosts the last script source run reached through `wt.fetch` (*Show Hosts*), kept in
    /// the local store per source so a relaunch still lists them (DATA-015).
    private(set) var scriptHosts: [String] = []
    /// Where a script source's hosts are kept: the document's `LocalStore` (`ScriptSourceHosts`);
    /// a document without one keeps them for the session.
    struct HostStorage {
        var load: @MainActor (OpID) async -> [String]
        var save: @MainActor (OpID, [String]) async -> Void
    }
    @ObservationIgnored var hostStorage: HostStorage

    /// The resolved records (mapping, transforms, formats), rebuilt when the records or the data
    /// block change.
    private(set) var records: RecordSet
    @ObservationIgnored private var resolvedFrom: (fields: [DataFieldInfo], source: DataSourceInfo?)?
    @ObservationIgnored private var lastState: EngineState
    @ObservationIgnored private var loadedSource: DataSourceInfo?
    @ObservationIgnored private var token: DocumentHandle.ObservationToken?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    static let embeddedSampleSize = 5
    static let maxSample = 2 * 1024 * 1024
    static let maxComplete = 20 * 1024 * 1024
    static let embedWarningKey = "data.embed_sample_warned"

    init(document: DocumentHandle, services: DataServices = DataServices(), blobs: BlobPlacement = BlobPlacement(), preferences: PreferenceStore? = nil) {
        self.document = document
        self.services = services
        self.blobs = blobs
        self.preferences = preferences
        hostStorage = Self.localStore(of: document)
        lastState = document.state
        records = RecordSet(model: DataModel(document.state), source: nil, raw: [])
        token = document.observe { [weak self] change in self?.documentDidChange(change) }
    }

    /// The document's `LocalStore` rows; in memory without one.
    static func localStore(of document: DocumentHandle) -> HostStorage {
        var memory: [OpID: [String]] = [:]
        return HostStorage(
            load: { [weak document] source in
                if let store = await document?.openedModel()?.backend as? LocalStore { return (try? await store.scriptHosts(source: source)) ?? [] }
                return memory[source] ?? []
            },
            save: { [weak document] source, hosts in
                memory[source] = ScriptSourceHosts.normalized(hosts)
                guard let store = await document?.openedModel()?.backend as? LocalStore else { return }
                try? await store.setScriptHosts(hosts, source: source)
            }
        )
    }

    /// Stops following the document (the window closed).
    func close() {
        if let token { document.stopObserving(token) }
        token = nil
        fetchTask?.cancel()
    }

    var model: DataModel { DataModel(document.state) }

    // MARK: Following the document

    private func documentDidChange(_ change: ContentChange) {
        // A view invalidation (the preview itself, local hiding) is not a document change.
        guard let written = change.change else { return }
        let state = document.state
        let before = lastState
        lastState = state
        revision += 1
        if written.replica != document.model?.replica {
            let removed = DataNotices.fieldsRemoved(before: before, after: state)
            if !removed.isEmpty { postRemoved(removed) }
        }
        let model = DataModel(state)
        if model.activeSource?.id != loadedSource?.id || model.activeSource?.spec != loadedSource?.spec {
            Task { await load() }
        } else {
            resolve(force: false)
        }
        window?.canvas.setNeedsFurnitureDisplay()
    }

    /// The *field removed* notice with *Restore field* (someone else deleted a used field).
    func postRemoved(_ removed: [DataNotices.FieldRemoved]) {
        guard let window else { return }
        for field in removed {
            let uses = field.uses == 1 ? "1 place uses it" : "\(field.uses) places use it"
            window.pageNotices.post("The field “\(field.name)” was removed; \(uses)", action: "Restore field", command: RestoreField(field.field))
        }
        window.showNotices()
    }

    /// Re-resolves the records when the fields, the source or the records changed; re-applies
    /// the preview with the new values.
    private func resolve(force: Bool) {
        let model = model
        let source = model.activeSource
        guard force || resolvedFrom?.fields != model.fields || resolvedFrom?.source != source else { return }
        resolvedFrom = (model.fields, source)
        let transforms = model.fields.contains { $0.transform != nil } ? ScriptTransformer(state: document.state) : nil
        records = RecordSet(model: model, source: source, raw: table?.records ?? [], transforms: transforms)
        applyPreview()
    }

    // MARK: Reading records (local only)

    /// Reads the connected source's records from what this Mac has -- a pasted table or embedded
    /// records, the file through its bookmark, the last fetch cached here, the embedded sample --
    /// without connecting or running a script.
    func load() async {
        let model = model
        let source = model.activeSource
        loadedSource = source
        message = nil
        guard let source else {
            set(nil, origin: .none)
            return
        }
        scriptHosts = source.kind == .script ? await hostStorage.load(source.id) : []
        switch source.kind {
        case .file:
            if await readFile(source) { return }
            if source.spec.file.bookmark.isEmpty {
                message = source.sample == nil ? "The file is on another Mac. Embed a sample on that Mac so everyone can preview."
                    : "The file is on another Mac -- showing the embedded sample."
            }
        case .http:
            if let client = services.client(), let cached = await client.cachedRecords(documentID: document.id, source: source.id) {
                set(cached, origin: .cached)
                return
            }
        default:
            break
        }
        if !loadSample(source) { set(nil, origin: .none) }
    }

    /// The source's embedded records, when this Mac has the blob.
    @discardableResult
    private func loadSample(_ source: DataSourceInfo) -> Bool {
        guard let sample = source.sample else { return false }
        guard let data = blobs.cached(sample.blobSha256), let table = try? DataTable.embedded(data, mediaType: sample.mediaType) else {
            message = message ?? "The embedded sample is not on this Mac yet."
            return false
        }
        set(table, origin: .sample(count: table.records.count, complete: sample.complete))
        return true
    }

    /// Reads a file source through its bookmark; false (with a message) when it cannot.
    private func readFile(_ source: DataSourceInfo) async -> Bool {
        let file = source.spec.file
        guard !file.bookmark.isEmpty else { return false }
        let options = DataFileOptions(file)
        let paths = model.fields.map { model.path(of: $0, in: source) }
        let bookmark = file.bookmark
        let result = await Task.detached {
            Result { try DataFileBookmarks.withAccess(bookmark) { try DataFileReader.read($0, options: options, paths: paths) } }
        }.value
        switch result {
        case .success(let contents):
            set(contents.table, origin: .file(name: file.fileName))
            return true
        case .failure(let error):
            message = "\(error) -- showing the embedded sample."
            return false
        }
    }

    private func set(_ table: DataTable?, origin: Origin) {
        self.table = table
        self.origin = origin
        resolve(force: true)
    }

    // MARK: Refreshing (a user action)

    /// btn:[Refresh]: reads the file again, fetches the API source through the service, or runs
    /// the script source.  With *Embed sample records* on, the sample is embedded again.
    func refresh() async {
        guard let source = model.activeSource, !isFetching else { return }
        isFetching = true
        message = nil
        defer { isFetching = false }
        switch source.kind {
        case .file:
            if !(await readFile(source)) {
                message = source.spec.file.bookmark.isEmpty ? "The file is on another Mac; only that Mac can refresh it." : message
                return
            }
        case .http:
            guard await fetch(source) else { return }
        case .script:
            guard await runScriptSource(source) else { return }
        default:
            _ = loadSample(source)
            return
        }
        if source.kind != .pasted, preferences?[PreferenceCatalog.Automation.embedSampleRecords] ?? false {
            await embed(all: false, confirming: false)
        }
    }

    /// Fetches every record of an API source; on `HOST_NOT_ALLOWED` in a personal document the
    /// consent sheet permits the host and the fetch is tried once more.
    private func fetch(_ source: DataSourceInfo) async -> Bool {
        guard source.hasValidURL else {
            message = "The source’s URL must be an https address."
            return false
        }
        guard let client = services.client() else {
            message = DataServiceMessages.signedOut
            return false
        }
        let model = model
        let params = effectiveParams(source)
        let id = document.id
        do {
            let table = try await permitting { try await client.fetchAll(documentID: id, source: source, model: model, params: params) }
            set(table, origin: .fetched(clock()))
            return true
        } catch {
            message = DataServiceMessages.text(error)
            if case DataServiceError.offline? = error as? DataServiceError { _ = loadSample(source) }
            return false
        }
    }

    /// Runs `body`; `HOST_NOT_ALLOWED` in a personal document asks the consent sheet once and, on
    /// *Allow*, permits the host on the account's own list and runs it again.  In a team document
    /// the error (naming the admins) stands.
    func permitting<T: Sendable>(_ body: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch DataServiceError.hostNotAllowed(let host, let admins) {
            guard admins.isEmpty, let client = services.client(), let scope = await services.scope(document), scope.isPersonal else {
                throw DataServiceError.hostNotAllowed(host: host, admins: admins)
            }
            guard await services.consent(window, host) else { throw DataConsentDenied(host: host) }
            _ = try await client.putAllowedHost(scope: scope.proto, host: host)
            return try await body()
        }
    }

    /// The typed values over the source's defaults.
    func effectiveParams(_ source: DataSourceInfo) -> [String: String] {
        var values: [String: String] = [:]
        for param in source.http.params { values[param.name] = param.defaultValue }
        for (name, value) in params where !value.isEmpty { values[name] = value }
        return values
    }

    /// Runs a script source's `records` export on a thread of its own (its `wt.fetch` goes
    /// through the service; consent once per host in a personal document).
    private func runScriptSource(_ source: DataSourceInfo) async -> Bool {
        guard let script = source.script else {
            message = "The source’s script is missing."
            return false
        }
        let state = document.state
        let fetcher = await scriptFetcher()
        let params = effectiveParams(source)
        let result = await Task.detached {
            Result { try ScriptRecordSource.records(script: script, state: state, params: params, fetcher: fetcher) }
        }.value
        switch result {
        case .success(let output):
            scriptHosts = output.hosts
            await hostStorage.save(source.id, output.hosts)
            set(output.table, origin: .fetched(clock()))
            return true
        case .failure(let error):
            message = DataServiceMessages.text(error)
            return false
        }
    }

    /// `wt.fetch` for this window's document: the service, with consent in a personal document.
    func scriptFetcher() async -> (any ScriptFetching)? {
        guard let client = services.client() else { return nil }
        let scope = await services.scope(document)
        let account: String? = if case .personal(let id)? = scope?.kind { id } else { nil }
        let consent = services.consent
        return DataScriptFetcher(client: client, documentID: document.id, personalAccount: account) { @MainActor [weak self] host in
            await consent(self?.window, host)
        }
    }

    // MARK: Embedding

    /// *Embed Sample* (the first five records, up to 2 MB) or *Embed All Records* (a complete
    /// embed, up to 20 MB): a CSV blob and the source's `sample`, one change.  The first time it
    /// is used, it says the records become document data.
    @discardableResult
    func embed(all: Bool, confirming: Bool = true) async -> Bool {
        guard let source = model.activeSource, let table else { return false }
        let defaults = preferences?.defaults
        if confirming, defaults?.bool(forKey: Self.embedWarningKey) != true {
            guard confirmEmbed("Embed records in the document?",
                               "Embedded records are document data: everyone who can read the document can read them.") else { return false }
            defaults?.set(true, forKey: Self.embedWarningKey)
        }
        let rows = all ? table : table.prefix(Self.embeddedSampleSize)
        let data = Data(rows.csv().utf8)
        guard data.count <= (all ? Self.maxComplete : Self.maxSample) else {
            message = all ? "The records are over 20 MB and cannot be embedded." : "The sample is over 2 MB and cannot be embedded."
            return false
        }
        do {
            try await blobs.store([(data: data, mediaType: "text/csv")], for: document)
        } catch {
            message = "The sample could not be stored: \(error.localizedDescription)"
            return false
        }
        var sample = Wiretuner_Doc_V1_EmbeddedRecords()
        sample.blobSha256 = Data(SHA256Digest.of(data))
        sample.mediaType = "text/csv"
        sample.recordCount = UInt32(rows.records.count)
        sample.complete = all || source.kind == .pasted
        sample.fetchedAtMs = Int64(clock().timeIntervalSince1970 * 1000)
        _ = await perform(SetSample(source.id, sample)).value
        return true
    }

    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        window?.objectEditing.perform(command) ?? document.perform(command)
    }

    // MARK: Preview

    var recordCount: Int { records.count }

    /// The current record's 0-based index (clamped).
    var currentIndex: Int { preview.index(in: records.count) }

    func setPreview(_ showing: Bool) {
        preview.showing = showing
        applyPreview()
    }

    func next() {
        preview = preview.next(in: records.count)
        applyPreview()
    }

    func previous() {
        preview = preview.previous(in: records.count)
        applyPreview()
    }

    /// The record number typed in the navigator (1-based).
    func go(to number: Int) {
        guard records.count > 0 else { return }
        preview.recordIndex = min(max(number, 1), records.count) - 1
        applyPreview()
    }

    /// The previewed record's substitution, or nil when the preview is off or there are no
    /// records.
    var substitution: RecordSubstitution? {
        guard preview.showing, let record = records.record(at: preview.recordIndex) else { return nil }
        return RecordSubstitution(model: model, record: record)
    }

    /// Draws the canvas with the current record (or the placeholders).
    private func applyPreview() {
        let next = substitution
        guard next != nil || document.recordPreview != nil else { return }
        document.previewRecord(next)
    }

    /// The value field `field` has in the previewed record (the Fields list's value column).
    func value(of field: OpID) -> String? {
        records.record(at: preview.recordIndex)?.value(field).text
    }

    // MARK: Status

    /// The Source section's status line.
    var status: String {
        guard model.activeSource != nil else { return "No source connected" }
        if isFetching { return "Fetching…" }
        let count = records.count == 1 ? "1 record" : "\(records.count) records"
        switch origin {
        case .none: return "No records"
        case .sample(_, let complete): return complete ? count : "\(count) -- embedded sample"
        case .file: return count
        case .cached: return "\(count) -- last fetch on this Mac"
        case .fetched(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "\(count) -- fetched \(formatter.localizedString(for: date, relativeTo: clock()))"
        }
    }
}
