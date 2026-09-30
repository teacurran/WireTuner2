import Foundation
import Observation
import OSLog
import WTCRDT
import WTModel
import WTProto
import WTRender
import WTSync

/// Who wrote a remote change, as presence names them: the display name and colour of the session
/// whose replica it is (`PresenceUpdate.session`, COLLAB-004).
struct SessionAuthor: Hashable, Sendable {
    var name: String
    var colorIndex: Int
}

/// What a document's session tells its windows.
enum SessionNotice: Sendable {
    /// The divergence rules hold the outbox: the review sheet opens (SYNC-007).
    case reviewNeeded(ReviewModel)
    /// A reconnect merged without holding the outbox: the toast, with *Review what changed* when
    /// the merge was large (`ReviewModel.decision == .suggestReview`).
    case merged(ReviewModel)
    /// A status-bar message (salvage, a dropped change).
    case message(String)
    /// menu:File[Review Merge…] or the popover's *Review Merge…*: open the sheet on the model.
    case openReview(ReviewModel)
    /// A server-state event on the subscription (`DocumentEvent`): a branch merged, a comment
    /// that concerns this account (COLLAB-018, COLLAB-027).
    case document(Wiretuner_Sync_V1_DocumentEvent)
}

/// The sync state a window shows, mirrored from the session's `SyncClient.states()`.
@MainActor
@Observable
final class SessionSyncStatus: SyncStatusProviding {
    private(set) var state: SyncState = .opening
    private(set) var details = SyncDetails()
    @ObservationIgnored var onAction: @MainActor (SyncAction) -> Void = { _ in }
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    init() {}

    func update(_ state: SyncState, now: Date = Date()) {
        guard state != self.state else { return }
        self.state = state
        if state == .saved { details.lastSynced = now }
        if case .error(let detail) = state { details.errorDetail = detail } else { details.errorDetail = nil }
        notify()
    }

    func update(collaborators: [String]) {
        guard collaborators != details.collaborators else { return }
        details.collaborators = collaborators
        notify()
    }

    private func notify() {
        for observer in observers.values { observer() }
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    func perform(_ action: SyncAction) {
        onAction(action)
    }
}

/// One open document's sync session (sync-protocol.adoc, "The client as built"; saving.adoc):
/// once the document's `LocalStore` is open it creates the `SyncClient` with the document as its
/// sink, a `LocalPresence` the windows write into and the blob queue, starts it, tells it about
/// every local change, mirrors its states into `status` and its presence into `presence`, and
/// turns its events into window notices.  A memory document (tests) has no store and no client:
/// the session then reports *Saved to cloud* and nobody else present.
@MainActor
final class DocumentSession {
    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "sync")

    let document: DocumentHandle
    let status = SessionSyncStatus()
    let presenceModel: PresenceModel
    let presence: PresenceAdapter
    let localPresence = LocalPresence()
    private let connector: (any SyncConnecting)?
    private(set) var connection: SyncConnection?
    /// The review holding the outbox, until resolved.
    private(set) var pendingReview: ReviewModel?
    /// The last merge that did not hold the outbox (*Review what changed*).
    private(set) var lastMerge: ReviewModel?
    /// Remote replicas' authors, from presence.
    private(set) var authors: [UInt64: SessionAuthor] = [:]
    /// The store's replica (local changes never flash).
    private(set) var localReplica: UInt64?
    private var starting: Task<Void, Never>?
    /// The library thumbnail's capture beside the session's blob queue (DOC-032).
    private(set) var thumbnails: ThumbnailCapture?
    private var feeds: [Task<Void, Never>] = []
    private var documentToken: DocumentHandle.ObservationToken?
    private var observers: [UUID: @MainActor (SessionNotice) -> Void] = [:]
    private(set) var isStopped = false

    /// *Sign In…*, *Export a Package…* and *Use Without an Account* from the popover (the app's
    /// account, export and Local mode).
    var onSignIn: @MainActor () -> Void = {}
    var onExportPackage: @MainActor () -> Void = {}
    var onUseWithoutAccount: @MainActor () -> Void = {}
    /// Local mode (D-079): no client runs and the state is *On this Mac*.
    let isLocal: @MainActor () -> Bool
    /// Creates a document made here on the server before the client subscribes (D-089).
    var creation: DocumentCreationGate?

    init(document: DocumentHandle, connector: (any SyncConnecting)?, localUserID: String, clearAfter: Duration = .seconds(5),
         isLocal: @escaping @MainActor () -> Bool = { false }) {
        self.document = document
        self.connector = connector
        self.isLocal = isLocal
        presenceModel = PresenceModel(localUserID: localUserID, clearAfter: clearAfter)
        presence = PresenceAdapter(source: presenceModel)
        status.onAction = { [weak self] action in self?.perform(action) }
        presence.observe { [weak self] in self?.presenceDidChange() }
    }

    /// The running client, once connected.
    var client: SyncClient? { connection?.client }

    // MARK: Lifecycle

    /// Waits for the document's store, then connects and starts the client (idempotent).
    @discardableResult
    func start() -> Task<Void, Never> {
        if let starting { return starting }
        let task = Task { [weak self] in
            guard let self else { return }
            guard !self.isLocal() else {
                // Local mode: nothing syncs; leaving it (a sign-in) connects (`leaveLocalMode`).
                self.status.update(.localOnly)
                return
            }
            guard let connector = self.connector, let model = await self.document.openedModel(),
                  let store = model.backend as? LocalStore, !self.isStopped else {
                // Nothing to sync (a memory document, or sync is off in this launch).
                self.status.update(.saved)
                return
            }
            do {
                let connection = try await connector.connect(store: store, sink: model, presence: self.localPresence, creation: self.creation)
                let replica = await store.replica
                self.localReplica = replica
                // Only this session's own presence entry is left out (the person's other Macs are not).
                self.presenceModel.localReplica = replica
                if let queue = connection.client.blobs {
                    let capture = await ThumbnailCapture(store: store, queue: queue)
                    self.thumbnails = capture
                    await capture.start()
                }
                await self.run(connection)
            } catch {
                Self.logger.error("sync for \(self.document.id, privacy: .public) could not start: \(String(describing: error), privacy: .public)")
                self.status.update(.error(String(describing: error)))
            }
        }
        starting = task
        return task
    }

    private func run(_ connection: SyncConnection) async {
        self.connection = connection
        let client = connection.client
        presenceModel.bind(to: client.events())
        let events = client.events()
        let states = await client.states()
        feeds.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        feeds.append(Task { [weak self] in
            for await state in states { self?.status.update(state) }
        })
        documentToken = document.observe { [weak self] change in self?.documentDidChange(change) }
        // A branch store made on this Mac is created on the server before its client pushes (COLLAB-016).
        if let copies = connection.copies, let tokens = connection.tokens, let store = document.model?.backend as? LocalStore {
            _ = try? await BranchCreator(transport: copies, tokens: tokens).ensureOnServer(store)
        }
        await client.start()
    }

    // MARK: Local mode (D-079)

    /// Local mode began (*Use Without an Account*): the client stops and the state is *On this
    /// Mac*; the store keeps its outbox for the upload after a sign-in.
    func enterLocalMode() async {
        await starting?.value
        starting = nil
        await disconnect()
        status.update(.localOnly)
    }

    /// Local mode ended (a sign-in): the session connects as if the window had just opened.
    @discardableResult
    func leaveLocalMode() -> Task<Void, Never>? {
        guard !isStopped, connection == nil, !isLocal() else { return nil }
        starting = nil
        status.update(.opening)
        return start()
    }

    /// Ends the running client and what follows it, keeping the session usable.
    private func disconnect() async {
        for feed in feeds { feed.cancel() }
        feeds = []
        if let documentToken { document.stopObserving(documentToken) }
        documentToken = nil
        presenceModel.unbind()
        // The thumbnail is captured once more, into the queue, before the client stops.
        if let thumbnails {
            self.thumbnails = nil
            _ = try? await thumbnails.close()
        }
        guard let connection else { return }
        self.connection = nil
        await connection.client.stop()
        await connection.close()
    }

    /// Stops the client (ack, `GONE`), closes its transport and stops following it.
    func stop() async {
        isStopped = true
        ReviewFloors.shared.update(nil, for: document.id)
        await starting?.value
        presence.detach()
        await disconnect()
    }

    // MARK: Local changes and presence

    private func documentDidChange(_ change: ContentChange) {
        guard change.change != nil, change.summary.origin == .local, let client else { return }
        Task { await client.localChangesAvailable() }
    }

    private func presenceDidChange() {
        status.update(collaborators: presence.participants.map(\.name))
    }

    // MARK: Events

    /// One event from the client.
    func handle(_ event: SyncEvent) {
        switch event {
        case .stateReplaced:
            document.reload()
        case .merged(let review):
            lastMerge = review
            post(.merged(review))
        case .reviewNeeded(let review):
            pendingReview = review
            post(.reviewNeeded(review))
        case .salvaged(let report):
            post(.message(Self.salvageMessage(report)))
        case .changeDropped:
            post(.message("A change could not be synced and was left out; it is kept on this Mac"))
        case .collectionPoint(let seq, _):
            // Collecting at the point needs a DocumentCore entry point WTModel does not have yet
            // (sync-protocol.adoc, *Horizon*); the point is at or before the stable seq, so it
            // is recorded as the horizon, which only moves forward.
            if let model = document.model, seq > 0 { Task { await model.advanceHorizon(to: seq) } }
        case .presence(let snapshot):
            for update in snapshot.participants { learn(update) }
        case .presenceUpdate(let update):
            learn(update)
        case .replicaRotated(_, let to):
            localReplica = to
        case .document(let event):
            post(.document(event))
        case .reviewFloor(let floor):
            ReviewFloors.shared.update(floor, for: document.id)
        default:
            break
        }
    }

    /// A frame names the replica of the session it describes (`PresenceUpdate.session`,
    /// COLLAB-004): that replica's changes are this person's.
    private func learn(_ update: Wiretuner_Sync_V1_PresenceUpdate) {
        guard update.session != 0 else { return }
        authors[update.session] = SessionAuthor(name: update.user.displayName, colorIndex: Int(update.colorIndex))
    }

    /// The author of a change by `replica`; nil for this replica's own and for unknown ones.
    func author(of replica: UInt64) -> SessionAuthor? {
        replica == localReplica ? nil : authors[replica]
    }

    /// "Recovered 12 changes from an expired session"; for a change over the server's limits
    /// (`SalvageReport.Reason.oversized`) "A large change was split to send it".
    static func salvageMessage(_ report: SalvageReport) -> String {
        let count = report.salvagedChanges
        let changes = count == 1 ? "1 change" : "\(count) changes"
        let what = report.reason == .oversized
            ? (count == 1 ? "A large change was split to send it" : "\(count) large changes were split to send them")
            : "Recovered \(changes) from an expired session"
        return report.dropped.isEmpty ? what : "\(what); \(report.dropped.count) could not be applied"
    }

    // MARK: Actions

    func perform(_ action: SyncAction) {
        switch action {
        case .retryNow:
            guard let client else { return }
            Task {
                await client.retry()
                await client.blobs?.retry()
            }
        case .reviewMerge:
            openReview()
        case .signIn:
            onSignIn()
        case .exportPackage:
            onExportPackage()
        case .useWithoutAccount:
            onUseWithoutAccount()
        }
    }

    /// The account signed in again: the client reconnects with a fresh token.
    func signedIn() {
        guard let client else { return }
        Task { await client.signedIn() }
    }

    /// menu:File[Review Merge…]: the pending review, else the last merge read-only.
    @discardableResult
    func openReview() -> ReviewModel? {
        guard let review = pendingReview ?? lastMerge else { return nil }
        post(.openReview(review))
        return review
    }

    /// Whether menu:File[Review Merge…] has something to open.
    var canReview: Bool { pendingReview != nil || lastMerge != nil }

    /// Ends the hold: `.upload` after *Keep the merged result*, *Done* or dismissing;
    /// `.discardLocalChanges` once a copy or branch holds the local work.
    func resolveReview(_ resolution: SyncClient.ReviewResolution) async throws {
        pendingReview = nil
        try await client?.resolveReview(resolution)
    }

    /// The unsent local changes and the head before the reconnect, for *Save my version as a
    /// copy…* and *Keep my changes on a branch*.
    func localWork() async throws -> (changes: [Wiretuner_Doc_V1_Change], baseSeq: UInt64) {
        guard let store = document.model?.backend as? LocalStore else { return ([], 0) }
        let changes = try await store.outbox()
        let base = try await store.reviewHold()?.baseSeq ?? 0
        return (changes, base)
    }

    /// The remote changes merged since the head before the reconnect (the review preview's
    /// *Theirs* side).
    func remoteWork() async throws -> [Wiretuner_Doc_V1_Change] {
        guard let store = document.model?.backend as? LocalStore, let base = try await store.reviewHold()?.baseSeq else { return [] }
        return try await store.remoteChanges(after: base)
    }

    // MARK: Notices

    @discardableResult
    func observe(_ handler: @escaping @MainActor (SessionNotice) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    private func post(_ notice: SessionNotice) {
        for observer in observers.values { observer(notice) }
    }
}
