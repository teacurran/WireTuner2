import AppKit

/// The destructive effect tools and operations (FX-030, FX-032, FX-033), wired from
/// `installTools()` in one call.
extension AppDelegate {
    func installEffectTools() {
        let documents = documents!
        DistortFeatures.install(
            tools: tools, extensions: toolbars.extensions, store: preferences,
            target: { documents.activeWindowController?.objectEditing },
            tools: { documents.activeWindowController?.toolManager },
            present: { descriptor in _ = documents.activeWindowController?.presentToolOptions(descriptor) }
        )
    }
}
