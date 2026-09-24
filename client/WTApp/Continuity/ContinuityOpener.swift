import AppKit
import WTSync

/// Opening a document by id from outside the app (IO-035, IO-036): a Handoff from another Mac
/// or a Spotlight result, both arriving in `application(_:continue:restorationHandler:)`.  The
/// document opens through the library -- its entry on this Mac first, else `DocumentService.Get`
/// -- in a window, or comes forward if it is open; a Handoff's page, zoom and scroll then apply
/// once the document is open.  A trashed document, or one this Mac cannot reach (offline with no
/// copy here, or an id the account cannot open), shows the Library window with a message instead,
/// never an error dialog.
@MainActor
final class ContinuityOpener {
    /// What a continuation did.
    enum Outcome: Equatable {
        case opened(String)
        case library(String)
    }

    static func offlineMessage() -> String { "Connect to open the document from your other Mac." }
    static func unavailableMessage() -> String { "That document is not available to this account." }
    static func trashedMessage(_ name: String) -> String { "“\(name)” is in the Trash." }

    /// The open window of a document, if any.
    var window: @MainActor (String) -> DocumentWindowController? = { _ in nil }
    /// The library's entry for a document, fetched when this Mac has none; nil offline or without
    /// access.
    var entry: @MainActor (String) async -> LibraryDocument? = { _ in nil }
    /// Whether this Mac holds a local copy of the document.
    var hasLocalCopy: @MainActor (String) -> Bool = { id in
        (try? LocalStore.defaultURL(documentID: id)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    /// Whether the library is online.
    var isOnline: @MainActor () -> Bool = { true }
    /// Opens a document in a window.
    var open: @MainActor (_ id: String, _ name: String) -> DocumentWindowController? = { _, _ in nil }
    /// Shows the Library window with a message.
    var showLibrary: @MainActor (String) -> Void = { _ in }

    /// Continues `activity`; false when it is not one of the app's.
    @discardableResult
    func continueActivity(_ activity: NSUserActivity) -> Task<Outcome, Never>? {
        if activity.activityType == HandoffActivity.type, let place = HandoffActivity.place(from: activity.userInfo) {
            return Task { await self.open(place.documentID, place: place) }
        }
        if let id = SpotlightIndexer.documentID(of: activity) {
            return Task { await self.open(id, place: nil) }
        }
        return nil
    }

    /// Opens document `id`, then shows `place` in it.
    func open(_ id: String, place: HandoffActivity.Place?) async -> Outcome {
        if let window = window(id) {
            window.showWindow(nil)
            if let place { window.apply(place) }
            return .opened(id)
        }
        let entry = await entry(id)
        if let entry, entry.isTrashed {
            return library(Self.trashedMessage(entry.name))
        }
        guard entry != nil || hasLocalCopy(id) else {
            return library(isOnline() ? Self.unavailableMessage() : Self.offlineMessage())
        }
        guard let window = open(id, entry?.name ?? LibraryModel.untitled) else { return library(Self.unavailableMessage()) }
        if let place {
            _ = await window.documentHandle.openedModel()
            window.apply(place)
        }
        return .opened(id)
    }

    private func library(_ message: String) -> Outcome {
        showLibrary(message)
        return .library(message)
    }
}
