import AppKit
import SwiftUI

/// menu:File[Share…] -- also the Main toolbar's btn:[Share], which runs the same command
/// (COLLAB-013).  It replaces `ContextMenuCatalog`'s placeholder in place, so the File menu,
/// the tab bar's menu and the toolbar keep their positions.  Offline it still opens the sheet,
/// which explains that sharing needs a connection and disables everything.
enum ShareCommands {
    static let id = ContextMenuCatalog.ID.share
    static let noDocument = "No document is open"

    @MainActor
    static func command(
        existing: Command?, canShare: @escaping @MainActor @Sendable () -> Bool, share: @escaping @MainActor @Sendable () -> Void
    ) -> Command {
        Command(
            id: id, title: "Share…", menu: existing?.menuPath ?? MenuPath(StandardCommands.Menu.file, section: 1),
            contexts: existing?.contexts ?? [], keywords: ["invite", "link", "people", "collaborate", "permissions"],
            validation: { canShare() ? .enabled : .disabled(noDocument) }, action: .perform(share)
        )
    }

    @MainActor
    static func install(into registry: CommandRegistry, canShare: @escaping @MainActor @Sendable () -> Bool, share: @escaping @MainActor @Sendable () -> Void) {
        registry.replace(command(existing: registry.command(id), canShare: canShare, share: share))
    }
}

/// Shows the Share sheet on a document window, one at a time.  Offline, a click on the
/// toolbar's btn:[Share] opens a popover explaining that sharing needs a connection instead
/// (sharing.adoc, "The Share sheet"); without the button in the toolbar (menu:File[Share…] with
/// it customised away) the sheet opens with the same notice and everything disabled.
@MainActor
final class SharePresenter {
    static let identifier = NSUserInterfaceItemIdentifier("share-sheet")
    static let offlineTitle = "Sharing needs a connection"
    static let offlineText = "Sharing will be available when you reconnect. Invitations and links are made on the server, so nothing is queued while you are offline."

    let services: CollaborationServices
    /// The signed-in account id (the personal space's id).
    var accountID: @MainActor () -> String?
    /// Whether the app believes it is online and signed in; the sheet re-checks by loading.
    var isOnline: @MainActor () -> Bool
    /// Fills in what the sheet needs from the rest of the app (teams, spaces, *Move to*, the
    /// request badge) before it loads.
    var configure: @MainActor (ShareSheetModel) -> Void = { _ in }
    /// The window's btn:[Share] toolbar item, when the toolbar shows it.
    var shareItem: @MainActor (NSWindow) -> NSToolbarItem? = { SharePresenter.toolbarItem(in: $0) }
    /// Shows a popover from a toolbar item.
    var showPopover: @MainActor (NSPopover, NSToolbarItem) -> Void = { popover, item in popover.show(relativeTo: item) }
    private(set) var sheet: NSWindow?
    private(set) var model: ShareSheetModel?
    /// The offline explanation last shown.
    private(set) var offlinePopover: NSPopover?

    init(services: CollaborationServices, accountID: @escaping @MainActor () -> String?, isOnline: @escaping @MainActor () -> Bool) {
        self.services = services
        self.accountID = accountID
        self.isOnline = isOnline
    }

    /// The Main toolbar's btn:[Share] in `window`, while the toolbar is shown.
    static func toolbarItem(in window: NSWindow) -> NSToolbarItem? {
        guard let toolbar = window.toolbar, toolbar.isVisible, window.isVisible else { return nil }
        let identifier = MainToolbarController.itemIdentifier(for: ShareCommands.id)
        return toolbar.items.first { $0.itemIdentifier == identifier }
    }

    /// Opens the sheet for `document` on `window` and starts loading it; nil while one is open,
    /// and nil offline when the popover explains instead.
    @discardableResult
    func present(_ document: ShareDocument, on window: NSWindow) -> ShareSheetModel? {
        guard sheet == nil else { return nil }
        let online = isOnline()
        if !online, let item = shareItem(window) {
            showOffline(from: item)
            return nil
        }
        let model = ShareSheetModel(document: document, services: services, accountID: accountID(), isOnline: online)
        model.onDone = { [weak self] in self?.dismiss() }
        configure(model)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ShareSheetView(model: model)))
        sheet.identifier = Self.identifier
        sheet.title = "Share"
        self.sheet = sheet
        self.model = model
        window.beginSheet(sheet)
        if online { model.send(.reload) }
        return model
    }

    /// The offline popover from `item`.
    func showOffline(from item: NSToolbarItem) {
        offlinePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ShareOfflineNotice())
        offlinePopover = popover
        showPopover(popover, item)
    }

    func dismiss() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        self.sheet = nil
        model = nil
    }
}

/// What the offline popover says.
struct ShareOfflineNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SharePresenter.offlineTitle, systemImage: "icloud.slash").font(.headline)
            Text(SharePresenter.offlineText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .accessibilityIdentifier("share.offlinePopover")
    }
}
