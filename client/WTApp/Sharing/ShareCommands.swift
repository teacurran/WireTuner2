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

/// Shows the Share sheet on a document window, one at a time.
@MainActor
final class SharePresenter {
    static let identifier = NSUserInterfaceItemIdentifier("share-sheet")

    let services: CollaborationServices
    /// The signed-in account id (the personal space's id).
    var accountID: @MainActor () -> String?
    /// Whether the app believes it is online and signed in; the sheet re-checks by loading.
    var isOnline: @MainActor () -> Bool
    private(set) var sheet: NSWindow?
    private(set) var model: ShareSheetModel?

    init(services: CollaborationServices, accountID: @escaping @MainActor () -> String?, isOnline: @escaping @MainActor () -> Bool) {
        self.services = services
        self.accountID = accountID
        self.isOnline = isOnline
    }

    /// Opens the sheet for `document` on `window` and starts loading it; nil while one is open.
    @discardableResult
    func present(_ document: ShareDocument, on window: NSWindow) -> ShareSheetModel? {
        guard sheet == nil else { return nil }
        let online = isOnline()
        let model = ShareSheetModel(document: document, services: services, accountID: accountID(), isOnline: online)
        model.onDone = { [weak self] in self?.dismiss() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ShareSheetView(model: model)))
        sheet.identifier = Self.identifier
        sheet.title = "Share"
        self.sheet = sheet
        self.model = model
        window.beginSheet(sheet)
        if online { model.send(.reload) }
        return model
    }

    func dismiss() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        self.sheet = nil
        model = nil
    }
}
