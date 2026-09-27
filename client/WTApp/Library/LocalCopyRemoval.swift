import AppKit
import WTSync

/// menu:File[Remove Local Copy] and the Library window's *Remove Local Copy* (saving.adoc,
/// "Keeping a copy on this Mac"; IO-035): frees the space a document's local store takes once
/// everything in it has reached the cloud.  An open document must read *Saved to cloud*; its
/// windows close first (after a confirmation), then the store is deleted -- only when no change,
/// image or queued call is still waiting (`LocalCopies`) -- and the document leaves Spotlight and
/// loses its offline badge.  The document stays in the cloud; opening it again downloads it.
@MainActor
final class LocalCopyRemoval {
    static let id: CommandID = "file.removeLocalCopy"
    static let title = "Remove Local Copy"

    /// A document the command acts on.
    struct Target: Equatable {
        let id: String
        let title: String
    }

    /// Where a document's store lives on this Mac.
    var storeURL: @MainActor (String) -> URL? = { try? LocalStore.defaultURL(documentID: $0) }
    var options = LocalStore.Options()
    /// What the command acts on: the Library window's selection when it is key, else the front
    /// document.
    var targets: @MainActor () -> [Target] = { [] }
    /// The sync state of a document a session holds (nil: none does).
    var syncState: @MainActor (String) -> SyncState? = { _ in nil }
    /// Whether a window shows the document.
    var isOpen: @MainActor (String) -> Bool = { _ in false }
    /// Closes the document's windows and waits until nothing holds its store.
    var closeDocument: @MainActor (String) async -> Void = { _ in }
    /// The copy is gone: Spotlight and the offline badge follow.
    var onRemoved: @MainActor (String) -> Void = { _ in }
    /// Asks the person (message, detail); true goes ahead.
    var confirm: @MainActor (String, String) -> Bool = { message, detail in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: LocalCopyRemoval.title)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Tells the person why nothing was removed.
    var alert: @MainActor (String, String) -> Void = { message, detail in ModalUI.alert(message, detail, on: NSApp.keyWindow) }

    init() {}

    /// Whether this Mac holds a copy of `id`.
    func hasCopy(_ id: String) -> Bool {
        storeURL(id).map(LocalCopies.exists(at:)) ?? false
    }

    func command() -> Command {
        Command(id: Self.id, title: Self.title + "…", menu: MenuPath(StandardCommands.Menu.file, section: 2), keywords: ["offline", "free space", "delete copy"],
                validation: { [weak self] in
                    guard let self else { return .disabled("") }
                    return self.targets().contains { self.hasCopy($0.id) } ? .enabled : .disabled("No copy of this document is on this Mac")
                },
                action: .perform { [weak self] in
                    guard let self else { return }
                    let targets = self.targets()
                    Task { for target in targets { await self.remove(target) } }
                })
    }

    /// Removes `target`'s copy when it can go; the outcome (nil when the person cancelled or an
    /// open document is still syncing).
    @discardableResult
    func remove(_ target: Target) async -> LocalCopies.Outcome? {
        guard let url = storeURL(target.id), LocalCopies.exists(at: url) else {
            alert("“\(target.title)” is not on this Mac.", "There is no local copy to remove.")
            return .notOnThisMac
        }
        if let state = syncState(target.id), state != .saved {
            alert("“\(target.title)” is still syncing.", "Remove its local copy once it reads Saved to cloud (now: \(state.description)).")
            return nil
        }
        let open = isOpen(target.id)
        let detail = "It stays in the cloud; opening it again downloads it." + (open ? " Its windows close." : "")
        guard confirm("Remove the local copy of “\(target.title)”?", detail) else { return nil }
        await closeDocument(target.id)
        do {
            let outcome = try await LocalCopies.remove(documentID: target.id, at: url, options: options)
            switch outcome {
            case .removed: onRemoved(target.id)
            case .waiting(let waiting): alert("The local copy of “\(target.title)” was kept.", waiting.message)
            case .notOnThisMac: break
            }
            return outcome
        } catch {
            alert("The local copy of “\(target.title)” could not be removed.", error.localizedDescription)
            return nil
        }
    }
}

extension AppDelegate {
    /// *Remove Local Copy* (IO-035) over the library and the open documents.
    func installLocalCopyRemoval() {
        let documents = documents!
        let library = library
        let sessions = sessions
        let spotlight = spotlight
        let removal = localCopyRemoval
        removal.targets = { [weak self] in
            if let controller = self?.libraryWindowController, controller.window?.isKeyWindow == true {
                return library.rows.map(\.document).filter { library.selection.contains($0.id) }.map { LocalCopyRemoval.Target(id: $0.id, title: $0.name) }
            }
            return documents.activeWindowController.map { [LocalCopyRemoval.Target(id: $0.documentHandle.id, title: $0.documentHandle.title)] } ?? []
        }
        removal.syncState = { sessions.state(of: $0) }
        removal.isOpen = { !documents.views(of: $0).isEmpty }
        removal.closeDocument = { id in
            documents.close(id)
            await sessions.released(id)
        }
        removal.onRemoved = { id in
            library.forgetLocalCopy(id)
            Task { await spotlight.remove(id) }
        }
        library.removeLocalCopy = { document in Task { await removal.remove(LocalCopyRemoval.Target(id: document.id, title: document.name)) } }
        library.hasLocalCopy = { removal.hasCopy($0) }
        commands.replace(removal.command())
    }
}
