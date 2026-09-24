import AppKit
import Observation
import SwiftUI
import WTSync

/// What the access bar needs from the document's `AccessController` (COLLAB-014): its status
/// stream and the two offers.  A protocol so the bar is tested without a sync session.
protocol AccessOffering: AnyObject, Sendable {
    func statuses() async -> AsyncStream<AccessController.Status>
    @discardableResult
    func saveAsCopy(name: String, newDocumentID: String) async throws -> String
    func discard() async throws
    func deleteStore() async throws
}

extension AccessController: AccessOffering {}

/// The bar under the toolbar when the caller's access changes mid-session (sharing.adoc, "When
/// your access changes mid-session"): "You can no longer edit this document" or "You no longer
/// have access", and while changes made before are frozen, btn:[Save as a Copy…] and btn:[Discard].
/// After a removal the window closes once the person has decided, and the local copy is deleted.
@MainActor
@Observable
final class AccessBarModel {
    private(set) var status = AccessController.Status()
    private(set) var isWorking = false
    private(set) var message: String?
    @ObservationIgnored let offer: any AccessOffering
    @ObservationIgnored let title: String
    /// Opens the copy the offer made.
    @ObservationIgnored var openDocument: @MainActor (String, String) -> Void = { _, _ in }
    /// Closes the window (after a removal).
    @ObservationIgnored var closeWindow: @MainActor () -> Void = {}
    /// The bar should show or hide.
    @ObservationIgnored var onChange: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored var makeID: @MainActor () -> String = { DocumentIdentifier.make() }
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init(offer: any AccessOffering, title: String) {
        self.offer = offer
        self.title = title
    }

    /// Whether the bar shows.
    var isShown: Bool { status.banner != nil }
    /// Whether the offer's buttons show.
    var offersChoice: Bool { status.unsent > 0 }

    var detail: String? {
        guard status.unsent > 0 else { return nil }
        return status.unsent == 1 ? "1 change of yours has not been sent." : "\(status.unsent.formatted()) changes of yours have not been sent."
    }

    /// Follows the controller's status until `stop`.
    @discardableResult
    func start() -> Task<Void, Never> {
        let offer = offer
        let task = Task { [weak self] in
            for await status in await offer.statuses() {
                guard let self else { return }
                self.apply(status)
            }
        }
        watcher = task
        return task
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func apply(_ status: AccessController.Status) {
        self.status = status
        onChange(isShown)
        if status.isRemoved && status.unsent == 0 && !isWorking { Task { await finishRemoval() } }
    }

    /// The copy's name: "Catalogue (my changes)".
    var copyName: String { "\(title) (my changes)" }

    /// btn:[Save as a Copy…].
    func saveAsCopy() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let name = copyName
        do {
            let id = try await offer.saveAsCopy(name: name, newDocumentID: makeID())
            message = "Your changes were saved as \(name)"
            openDocument(id, name)
        } catch {
            message = "Your changes could not be saved: \(error.localizedDescription)"
            return
        }
        if status.isRemoved { await finishRemoval() }
    }

    /// btn:[Discard].
    func discard() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await offer.discard()
        } catch {
            message = "Your changes could not be discarded: \(error.localizedDescription)"
            return
        }
        if status.isRemoved { await finishRemoval() }
    }

    /// After a removal: the local copy goes, then the window.
    func finishRemoval() async {
        try? await offer.deleteStore()
        closeWindow()
    }
}

struct AccessBarView: View {
    let model: AccessBarModel

    static func save(_ model: AccessBarModel) -> () -> Void { { Task { await model.saveAsCopy() } } }
    static func discard(_ model: AccessBarModel) -> () -> Void { { Task { await model.discard() } } }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.status.banner ?? "").font(.callout.bold()).accessibilityIdentifier("access.banner")
                if let detail = model.detail { Text(detail).font(.caption) }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if model.offersChoice {
                Button("Save as a Copy…", action: Self.save(model)).disabled(model.isWorking).accessibilityIdentifier("access.saveCopy")
                Button("Discard", action: Self.discard(model)).disabled(model.isWorking).accessibilityIdentifier("access.discard")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(SwiftUI.Color.orange.opacity(0.2))
    }
}

/// Puts the access bar under the window's toolbar (a title-bar accessory at the bottom) while it
/// has something to say.
@MainActor
final class AccessBarAccessory {
    let model: AccessBarModel
    let controller = NSTitlebarAccessoryViewController()
    private(set) weak var window: NSWindow?

    init(model: AccessBarModel, window: NSWindow?) {
        self.model = model
        self.window = window
        let hosting = NSHostingView(rootView: AccessBarView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 34)
        controller.view = hosting
        controller.layoutAttribute = .bottom
        controller.isHidden = true
        window?.addTitlebarAccessoryViewController(controller)
        model.onChange = { [weak self] shown in self?.controller.isHidden = !shown }
    }

    func remove() {
        model.stop()
        if let index = window?.titlebarAccessoryViewControllers.firstIndex(of: controller) {
            window?.removeTitlebarAccessoryViewController(at: index)
        }
    }
}
