import Foundation
import Observation
import WTModel
import WTSync

/// A document with changes that have not reached the cloud (the quit sheet's rows).
struct WaitingDocument: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var state: SyncState

    /// "412 changes waiting (offline)", "Uploading backlog 61%", "2 images uploading".
    var detail: String {
        switch state {
        case .offline(let count): count == 1 ? "1 change waiting (offline)" : "\(count) changes waiting (offline)"
        case .uploadingBlobs(let count): count == 1 ? "1 image uploading" : "\(count) images uploading"
        default: state.description
        }
    }
}

/// Every document's sync session (one per document, however many windows show it), the sessions
/// of closed windows still uploading, and the headless uploads the launch started (saving.adoc,
/// "Closing and quitting with changes waiting"; IO-007).
@MainActor
@Observable
final class DocumentSessions {
    /// Makes a document's `SyncClient`; nil runs no sync (memory documents, tests, test launches).
    @ObservationIgnored let connector: (any SyncConnecting)?
    /// The signed-in account, never listed among the collaborators.
    @ObservationIgnored var localUserID: @MainActor () -> String
    /// Closes a document's backend once its session is done with it.
    @ObservationIgnored var closeDocument: @MainActor (DocumentHandle) -> Void = { $0.close() }
    /// Sessions of open documents by document id.
    private(set) var sessions: [String: DocumentSession] = [:]
    /// Sessions whose windows closed while changes were still going up.
    private(set) var background: [String: DocumentSession] = [:]
    /// Headless uploads started at launch, by document id.
    private(set) var headless: [String: HeadlessUpload] = [:]
    @ObservationIgnored private var backgroundTokens: [String: UUID] = [:]
    /// Sessions stopping after their last window closed, until their store is closed.
    @ObservationIgnored private var closing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    /// Sign-in and export from any document's popover.
    @ObservationIgnored var onSignIn: @MainActor () -> Void = {}
    @ObservationIgnored var onExportPackage: @MainActor () -> Void = {}

    init(connector: (any SyncConnecting)?, localUserID: @escaping @MainActor () -> String = { "" }) {
        self.connector = connector
        self.localUserID = localUserID
    }

    /// The session of `document`, created and started on first use.
    func session(for document: DocumentHandle) -> DocumentSession {
        if let existing = sessions[document.id] { return existing }
        let session = DocumentSession(document: document, connector: connector, localUserID: localUserID())
        session.onSignIn = { [weak self] in self?.onSignIn() }
        session.onExportPackage = { [weak self] in self?.onExportPackage() }
        sessions[document.id] = session
        session.start()
        session.status.observe { [weak self] in self?.notify() }
        return session
    }

    /// Stops whatever still holds `documentID`'s store -- a closed window's upload or a headless
    /// one -- so a window can open it (the window then takes over the upload).
    func release(_ documentID: String) async {
        if let session = background.removeValue(forKey: documentID) {
            if let token = backgroundTokens.removeValue(forKey: documentID) { session.status.stopObserving(token) }
            await session.stop()
            closeDocument(session.document)
        }
        if let upload = headless.removeValue(forKey: documentID) { await upload.stop() }
        notify()
    }

    /// The document's last window closed: a session with work still going up keeps running in the
    /// background and stops once it is done; otherwise it stops now.  The backend closes after.
    @discardableResult
    func documentDidClose(_ document: DocumentHandle) -> Task<Void, Never> {
        guard let session = sessions.removeValue(forKey: document.id) else {
            closeDocument(document)
            return Task {}
        }
        if Self.keepsUploading(session.status.state) {
            background[document.id] = session
            backgroundTokens[document.id] = session.status.observe { [weak self, weak session] in
                guard let session, !Self.keepsUploading(session.status.state) else { return }
                self?.finishBackground(document.id)
            }
            notify()
            return Task {}
        }
        notify()
        let task = Task { [weak self] in
            await session.stop()
            self?.closeDocument(document)
        }
        closing[document.id] = task
        return task
    }

    /// Stops whatever holds `documentID`'s store and waits until a session that closed with its
    /// last window has closed the store (*Remove Local Copy*, IO-035).
    func released(_ documentID: String) async {
        await release(documentID)
        if let task = closing.removeValue(forKey: documentID) { await task.value }
    }

    /// The sync state of `documentID` while a session holds it (a window's, or a closed window's
    /// upload); nil when none does.
    func state(of documentID: String) -> SyncState? {
        (sessions[documentID] ?? background[documentID])?.status.state ?? headless[documentID]?.state
    }

    private func finishBackground(_ documentID: String) {
        guard let session = background.removeValue(forKey: documentID) else { return }
        if let token = backgroundTokens.removeValue(forKey: documentID) { session.status.stopObserving(token) }
        notify()
        Task { [weak self] in
            await session.stop()
            self?.closeDocument(session.document)
        }
    }

    /// Whether a closed window's session keeps running: changes or images are going up and
    /// nothing needs the user (a review, a sign-in, an error parks it instead).
    static func keepsUploading(_ state: SyncState) -> Bool {
        switch state {
        case .syncing, .uploadingBlobs, .uploadingBacklog: true
        case .offline(let count): count > 0
        default: false
        }
    }

    /// Adds a launch-time headless upload (`HeadlessUploads`).
    func add(_ upload: HeadlessUpload) {
        headless[upload.documentID] = upload
        upload.onFinish = { [weak self] id in
            self?.headless[id] = nil
            self?.notify()
        }
        upload.onChange = { [weak self] in self?.notify() }
        notify()
    }

    /// Every document with changes that have not reached the cloud, open or not.
    var waitingDocuments: [WaitingDocument] {
        let live = (sessions.values.map { $0 } + background.values.map { $0 })
            .filter { $0.status.state.hasWaitingWork }
            .map { WaitingDocument(id: $0.document.id, title: $0.document.title, state: $0.status.state) }
        let parked = headless.values.filter { $0.state.hasWaitingWork }
            .map { WaitingDocument(id: $0.documentID, title: $0.title, state: $0.state) }
        return (live + parked).sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    /// The account signed in again: every session reconnects.
    func signedIn() {
        for session in sessions.values { session.signedIn() }
    }

    /// Stops every session (quitting).
    func stopAll() async {
        let all = Array(sessions.values) + Array(background.values)
        sessions = [:]
        background = [:]
        for session in all { await session.stop() }
        for upload in headless.values { await upload.stop() }
        headless = [:]
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

    private func notify() {
        for observer in observers.values { observer() }
    }
}
