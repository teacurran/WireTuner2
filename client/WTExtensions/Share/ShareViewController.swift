import AppKit

/// *Add to WireTuner Document* in another app's Share menu (IMG-026; importing.adoc, "From another
/// app's Share menu"): the `WireTunerShare` extension of point `com.apple.share-services`.  It shows
/// no interface of its own: the shared images, PDFs and SVGs (or files of those types) are copied
/// into the app group's inbox, the app is opened with the hand-off URL -- carrying the host app's
/// name and whether kbd:[Option] was held -- and the request completes at once, so the extension
/// exits.  Sandboxed with only the app group: it has no network entitlement and links neither
/// WTModel nor WTSync.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let option = NSEvent.modifierFlags.contains(.option)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let items = ShareInboxWriter.items(providers)
        guard let root = ShareHandoff.inboxRoot(), !items.isEmpty else {
            extensionContext?.cancelRequest(withError: CocoaError(.featureUnsupported))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let id = try await ShareInboxWriter(root: root).write(items)
                NSWorkspace.shared.open(ShareHandoff.url(inbox: id, app: app, option: option))
                self?.extensionContext?.completeRequest(returningItems: nil)
            } catch {
                self?.extensionContext?.cancelRequest(withError: error)
            }
        }
    }
}
