import AppKit
import Foundation
import WTProto

/// The badge on the toolbar's btn:[Share] (sharing.adoc, "Requesting access"): for a document
/// the caller owns, how many access requests are waiting.  Counted with `ListAccessRequests` when
/// its window opens online, again whenever the session says the People list changed
/// (`DocumentEvent.MembersChanged`, which a new request sends to the owners' sessions), and set
/// by the Share sheet whenever it lists or resolves requests.  Offline, or for anyone but the
/// owner, there is no badge.
@MainActor
final class ShareRequestBadges {
    /// One window's hook on its session.
    private struct Attachment {
        weak var window: DocumentWindowController?
        let documentID: String
        let token: UUID?
    }

    let services: CollaborationServices
    /// Whether the caller owns the document (the library's role for it).
    var isOwner: @MainActor (String) -> Bool
    /// Whether the app is online and signed in.
    var isOnline: @MainActor () -> Bool
    /// Pending requests per document, as last counted.
    private(set) var counts: [String: Int] = [:]
    private var attachments: [ObjectIdentifier: Attachment] = [:]

    init(services: CollaborationServices, isOwner: @escaping @MainActor (String) -> Bool, isOnline: @escaping @MainActor () -> Bool) {
        self.services = services
        self.isOwner = isOwner
        self.isOnline = isOnline
    }

    /// The count btn:[Share] shows for a document; nil (no badge) when there is none.
    func badge(for documentID: String) -> Int? {
        guard let count = counts[documentID], count > 0 else { return nil }
        return count
    }

    /// Hooks `window`: its toolbar's btn:[Share] shows the badge, and its session's
    /// `MembersChanged` counts again.  Returns the first count's task (nil when nothing is counted).
    @discardableResult
    func attach(_ window: DocumentWindowController) -> Task<Void, Never>? {
        let key = ObjectIdentifier(window)
        let id = window.documentHandle.id
        if attachments[key] == nil {
            let token = window.collaboration.session?.observe { [weak self] notice in _ = self?.handle(notice, for: id) }
            attachments[key] = Attachment(window: window, documentID: id, token: token)
            window.mainToolbar?.badgeProviders[ShareCommands.id] = { [weak self] in self?.badge(for: id) }
        }
        return refresh(id)
    }

    /// A session notice for a document: `MembersChanged` (a request arrived, or one was resolved
    /// elsewhere) counts again.
    @discardableResult
    func handle(_ notice: SessionNotice, for documentID: String) -> Task<Void, Never>? {
        guard case .document(let event) = notice, case .membersChanged? = event.event else { return nil }
        return refresh(documentID)
    }

    /// Unhooks `window`.
    func detach(_ window: DocumentWindowController) {
        guard let attachment = attachments.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let token = attachment.token { window.collaboration.session?.stopObserving(token) }
        window.mainToolbar?.badgeProviders[ShareCommands.id] = nil
    }

    /// Counts a document's pending requests again; nil when it is not the caller's or offline.
    @discardableResult
    func refresh(_ documentID: String) -> Task<Void, Never>? {
        guard isOwner(documentID), isOnline() else {
            set(documentID, count: 0)
            return nil
        }
        let services = services
        return Task { [weak self] in
            guard let token = try? await services.accessToken(),
                  let requests = try? await services.shares.listAccessRequests(documentID: documentID, accessToken: token) else { return }
            self?.set(documentID, count: requests.count)
        }
    }

    /// The count is `count` (the Share sheet listed or resolved requests): every window of the
    /// document redraws its badge.
    func set(_ documentID: String, count: Int) {
        guard counts[documentID, default: 0] != count else { return }
        counts[documentID] = count
        attachments = attachments.filter { $0.value.window != nil }
        for attachment in attachments.values where attachment.documentID == documentID {
            attachment.window?.mainToolbar?.refreshBadges()
        }
    }
}
