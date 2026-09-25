import AppKit
import WTModel

extension AppDelegate {
    /// The glue of this build's smaller features: Document Info, the storage messaging, Preview in
    /// Browser's exporter, the Guides layer's hooks, the Links window's *Uploading* badge and the
    /// Object panel's btn:[Links…] (IO-011, IO-009, BASIC-017, DOC-018, DOC-023).
    func installWindowGlue() {
        let documents = documents!
        installDocumentInfo()
        installStorageMonitor()
        browserPreview.exporter = WebPreviewExporter(blobs: imports.blobs)
        GuidesLayer.window = { documents.activeWindowController }
        LinkUploads.pending = { [weak self] window in self?.images.attach(window).pending ?? [] }
        LinkUploads.showLinks = { [weak self] asset in self?.documentSetup.showLinks()?.model.select(asset) }
        InspectorRegistry.standard.register(LinkUploads.section)
    }

    /// A document window opened: the guide auto-scroll preference and the storage note.
    func attachWindowGlue(_ window: DocumentWindowController) {
        GuidesLayer.install(on: window, preferences: preferences)
        let storage = storage
        storage.windowDidChange(window)
        _ = window.syncStatus.observe { [weak window] in
            if let window { storage.windowDidChange(window) }
        }
        Task { await storage.refresh() }
    }
}
