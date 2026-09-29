import AppKit
import GRPCNIOTransportHTTP2
import Observation
import SwiftUI
import WTInterchange
import WTModel
import WTProto
import WTSync

/// Publishing to a web link (WEB-013; publish-html.adoc, "Publishing to a web link"): the Publish
/// sheet's *Web link* destination uploads the bundle through WTSync's `PublishUploader` and copies
/// the address; the *Published links* sheet lists every publish of the document over
/// `PublishedLinks`, follows the document's `PublishesChanged` event, and offers *Open*, *Copy
/// Link*, *Download as Folder*, *Change access* and *Unpublish*.  Offline, the destination is
/// dimmed with "Needs a connection" and the sheet shows the cached list read-only.

/// What web-link publishing needs from the app: the document's uploader, its links, the blob
/// transport under its session, and whether the account is reachable.
@MainActor
protocol WebLinkServices: AnyObject {
    var isOnline: Bool { get }
    func uploader(for document: DocumentHandle) -> PublishUploader?
    func links(for document: DocumentHandle) -> PublishedLinks?
    func blobs(for document: DocumentHandle) -> (any BlobTransport)?
    /// The document's session events (`PublishesChanged` refreshes the links), nil without one.
    func events(for document: DocumentHandle) -> AsyncStream<SyncEvent>?
    /// The server seq the document's local copy has reached (the version a publish renders).
    func serverSeq(of document: DocumentHandle) async -> UInt64
    /// Why the web link cannot be chosen while `isOnline` is false.
    var unavailableReason: String { get }
}

extension WebLinkServices {
    var unavailableReason: String { WebLinks.needsConnection }
}

enum WebLinks {
    static let needsConnection = "Needs a connection"

    /// Why the web link cannot be chosen now: the services' reason, a connection without them.
    @MainActor static var unavailableReason: String { services?.unavailableReason ?? needsConnection }

    /// The app's services; nil in tests that set none (the destination is then offline).
    @MainActor static var services: (any WebLinkServices)?

    /// The pasteboard *Copy Link* writes to; replaceable in tests.
    @MainActor static var pasteboard: NSPasteboard = .general

    @MainActor
    static func copy(_ url: String) {
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    /// "People with access to this document" / "Anyone with the link".
    static func title(_ access: Wiretuner_Publish_V1_PublishAccess) -> String {
        access == .anyoneWithLink ? "Anyone with the link" : "People with access to this document"
    }

    /// A bundle's files as the uploader takes them.
    static func files(_ bundle: HTMLBundle) -> [PublishBundleFile] {
        bundle.files.map { PublishBundleFile(path: $0.path, data: $0.data, mediaType: PublishBundleFile.mediaType(forPath: $0.path)) }
    }
}

/// The app's services over the account and the document sessions.
@MainActor
final class AppWebLinkServices: WebLinkServices {
    let sessions: DocumentSessions
    let isReachable: @MainActor () -> Bool
    let token: @Sendable () async throws -> String
    private let makeTransport: () throws -> any PublishTransport
    private var transport: (any PublishTransport)?
    private var uploaders: [String: PublishUploader] = [:]
    private var linkModels: [String: PublishedLinks] = [:]

    init(sessions: DocumentSessions, isReachable: @escaping @MainActor () -> Bool, token: @escaping @Sendable () async throws -> String,
         makeTransport: @escaping () throws -> any PublishTransport) {
        self.sessions = sessions
        self.isReachable = isReachable
        self.token = token
        self.makeTransport = makeTransport
    }

    var isOnline: Bool { isReachable() }

    /// Local mode (D-079) says an account is needed, not a connection.
    var isLocal: @MainActor () -> Bool = { false }
    var unavailableReason: String { isLocal() ? LocalMode.needsAccount : WebLinks.needsConnection }

    private func publishTransport() -> (any PublishTransport)? {
        if let transport { return transport }
        transport = try? makeTransport()
        return transport
    }

    func blobs(for document: DocumentHandle) -> (any BlobTransport)? {
        sessions.sessions[document.id]?.connection?.transport as? any BlobTransport
    }

    func uploader(for document: DocumentHandle) -> PublishUploader? {
        if let existing = uploaders[document.id] { return existing }
        guard let blobs = blobs(for: document), let transport = publishTransport() else { return nil }
        let made = PublishUploader(documentID: document.id, blobs: blobs, publishes: transport, token: token)
        uploaders[document.id] = made
        return made
    }

    func links(for document: DocumentHandle) -> PublishedLinks? {
        if let existing = linkModels[document.id] { return existing }
        guard let transport = publishTransport() else { return nil }
        let made = PublishedLinks(documentID: document.id, transport: transport, token: token)
        linkModels[document.id] = made
        return made
    }

    func events(for document: DocumentHandle) -> AsyncStream<SyncEvent>? {
        sessions.sessions[document.id]?.client?.events()
    }

    func serverSeq(of document: DocumentHandle) async -> UInt64 {
        guard let store = document.model?.backend as? LocalStore else { return 0 }
        return await store.lastServerSeq
    }
}

extension LaunchEnvironment {
    /// The Publish service client over the configured API; nil in test launches.
    @MainActor
    func makeWebLinkServices(sessions: DocumentSessions, account: AccountModel, library: LibraryModel, infoDictionary: [String: Any]?,
                             defaults: UserDefaults, isLocal: @escaping @MainActor () -> Bool = { false }) -> (any WebLinkServices)? {
        guard !isTesting else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(clientVersion: Self.clientVersion(infoDictionary),
                                                                               deviceID: DeviceIdentity.current(defaults: defaults))
        let auth = account.auth
        let services = AppWebLinkServices(sessions: sessions, isReachable: { !isLocal() && library.isOnline && account.isSignedIn },
                                          token: { try await auth.validAccessToken() },
                                          makeTransport: { try GRPCPublishTransport.http2(api: configuration.api, identity: identity) })
        services.isLocal = isLocal
        return services
    }
}

/// The Publish sheet's web-link half: uploads a built bundle with progress, resumable.
@MainActor
@Observable
final class WebLinkUpload {
    private(set) var progress: PublishProgress?
    /// The address of the last publish.
    private(set) var url: String?
    @ObservationIgnored private(set) var job: PublishUploader.Job?

    init() {}

    /// Uploads `files` for `document` with `access`; resumes an unfinished job for the same files.
    func publish(_ files: [PublishBundleFile], document: DocumentHandle, settingName: String, access: Wiretuner_Publish_V1_PublishAccess,
                 services: any WebLinkServices) async throws -> String {
        guard let uploader = services.uploader(for: document) else { throw PublishFailure.offline }
        var job: PublishUploader.Job
        if let pending = self.job, pending.files == files, pending.access == access {
            job = pending
        } else {
            job = await uploader.job(files, serverSeq: await services.serverSeq(of: document), settingName: settingName, access: access)
        }
        defer { self.job = job.publish == nil ? job : nil }
        let publish = try await uploader.run(&job) { [weak self] progress in
            Task { @MainActor in self?.progress = progress }
        }
        url = publish.url
        WebLinks.copy(publish.url)
        return publish.url
    }

    enum PublishFailure: Error, Equatable {
        case offline
    }

    /// "Uploading 3 of 12 files (4.2 MB of 40 MB)".
    static func label(_ progress: PublishProgress) -> String {
        switch progress.phase {
        case .checking: return "Checking what the server has…"
        case .uploading:
            let sent = ByteCountFormatter.string(fromByteCount: progress.sentBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
            return "Uploading \(sent) of \(total)"
        case .registering: return "Publishing…"
        case .published: return "Published"
        }
    }
}

/// The *Published links* sheet's model.
@MainActor
@Observable
final class PublishedLinksModel {
    let document: DocumentHandle
    private(set) var listing = PublishedLinks.Listing(publishes: [], isCurrent: false)
    private(set) var message: String?
    private(set) var isLoaded = false
    @ObservationIgnored let links: PublishedLinks?
    @ObservationIgnored let services: (any WebLinkServices)?
    @ObservationIgnored private var feeds: [Task<Void, Never>] = []
    @ObservationIgnored var onClose: @MainActor () -> Void = {}
    /// Opens a URL (*Open*); chooses a folder (*Download as Folder*).  Replaceable in tests.
    @ObservationIgnored var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var chooseFolder: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        return await panel.begin() == .OK ? panel.url : nil
    }

    init(document: DocumentHandle, services: (any WebLinkServices)?) {
        self.document = document
        self.services = services
        links = services?.links(for: document)
    }

    /// Lists the publishes and follows the listings and the document's events.
    func start() {
        guard let links, feeds.isEmpty else { return }
        feeds.append(Task { [weak self] in
            for await listing in await links.listings() {
                self?.listing = listing
                self?.isLoaded = true
            }
        })
        if let events = services?.events(for: document) {
            feeds.append(Task {
                for await event in events { await links.handle(event) }
            })
        }
        feeds.append(Task { await links.refresh() })
    }

    func stop() {
        for feed in feeds { feed.cancel() }
        feeds = []
    }

    /// Whether the list can be changed (it is the server's, not the cached one).
    var isEditable: Bool { listing.isCurrent && (services?.isOnline ?? false) }

    /// "Sep 26, 2026 at 9:41 · Default · by you · version 1,204".
    static func detail(_ publish: Wiretuner_Publish_V1_Publish) -> String {
        let date = publish.hasPublishedAt ? publish.publishedAt.date.formatted(date: .abbreviated, time: .shortened) : ""
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: publish.totalSize), countStyle: .file)
        return [date, publish.settingName, "\(publish.fileCount) files, \(size)", "version \(publish.serverSeq.formatted())"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func copyLink(_ publish: Wiretuner_Publish_V1_Publish) {
        WebLinks.copy(publish.url)
        message = "Link copied"
    }

    func openLink(_ publish: Wiretuner_Publish_V1_Publish) {
        if let url = URL(string: publish.url) { open(url) }
    }

    @discardableResult
    func setAccess(_ access: Wiretuner_Publish_V1_PublishAccess, of publish: Wiretuner_Publish_V1_Publish) -> Task<Void, Never>? {
        guard isEditable, let links else { return nil }
        return Task {
            do { try await links.setAccess(access, of: publish.publishID) } catch { message = "The access could not be changed: \(error.localizedDescription)" }
        }
    }

    @discardableResult
    func unpublish(_ publish: Wiretuner_Publish_V1_Publish) -> Task<Void, Never>? {
        guard isEditable, let links else { return nil }
        return Task {
            do { try await links.unpublish(publish.publishID) } catch { message = "It could not be unpublished: \(error.localizedDescription)" }
        }
    }

    /// *Download as Folder*: every file of the publish written under the chosen folder.
    @discardableResult
    func download(_ publish: Wiretuner_Publish_V1_Publish) -> Task<Void, Never>? {
        guard let links, let blobs = services?.blobs(for: document) else {
            message = "Downloading needs a connection"
            return nil
        }
        return Task {
            guard let folder = await chooseFolder() else { return }
            do {
                let files = try await links.files(of: publish.publishID, blobs: blobs)
                let root = folder.appending(path: "\(document.title) \(publish.serverSeq)")
                for file in files {
                    let url = root.appending(path: file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.data.write(to: url)
                }
                message = "Downloaded to \(root.lastPathComponent)"
            } catch {
                message = "The publish could not be downloaded: \(error.localizedDescription)"
            }
        }
    }

    func close() {
        stop()
        onClose()
    }
}

struct PublishedLinksSheet: View {
    let model: PublishedLinksModel

    static func access(_ model: PublishedLinksModel, _ publish: Wiretuner_Publish_V1_Publish) -> Binding<Wiretuner_Publish_V1_PublishAccess> {
        Binding(get: { publish.access }, set: { model.setAccess($0, of: publish) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.listing.isCurrent, model.isLoaded {
                Text("Offline: showing the last list, read-only").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("links.offline")
            }
            if model.listing.publishes.isEmpty {
                Text(model.isLoaded ? "This document has not been published to a web link." : "Loading…").foregroundStyle(.secondary)
            }
            List(model.listing.publishes, id: \.publishID) { publish in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(publish.url).lineLimit(1).truncationMode(.middle)
                        if publish.current { Text("Current").font(.caption).foregroundStyle(.tint) }
                    }
                    Text(PublishedLinksModel.detail(publish)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("Access", selection: Self.access(model, publish)) {
                            Text(WebLinks.title(.members)).tag(Wiretuner_Publish_V1_PublishAccess.members)
                            Text(WebLinks.title(.anyoneWithLink)).tag(Wiretuner_Publish_V1_PublishAccess.anyoneWithLink)
                        }
                        .labelsHidden()
                        .disabled(!model.isEditable)
                        Button("Open") { model.openLink(publish) }
                        Button("Copy Link") { model.copyLink(publish) }
                        Button("Download as Folder…") { model.download(publish) }
                        Button("Unpublish") { model.unpublish(publish) }.disabled(!model.isEditable)
                    }
                    .controlSize(.small)
                }
                .accessibilityIdentifier("links.row.\(publish.publishID)")
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("links.message") }
            HStack {
                Spacer()
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 320)
    }
}

extension WebFeatures {
    static let publishedLinksSheet = "published-links-sheet"

    /// menu:File[Publish as HTML… > Published links…].
    @discardableResult
    func presentPublishedLinks() -> PublishedLinksModel? {
        guard let window = window() else { return nil }
        let model = PublishedLinksModel(document: window.documentHandle, services: WebLinks.services)
        model.onClose = { [weak self] in self?.dismiss(Self.publishedLinksSheet) }
        present(PublishedLinksSheet(model: model), identifier: Self.publishedLinksSheet, title: "Published Links", on: window)
        model.start()
        return model
    }
}
