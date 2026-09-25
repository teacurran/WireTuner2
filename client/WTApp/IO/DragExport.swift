import AppKit
import UniformTypeIdentifiers
import WTInterchange
import WTModel

/// Dragging artwork out (exporting.adoc, "Dragging artwork out"; IO-016): a drag of the selection
/// carries the native objects and, written lazily from the scene captured when the drag began,
/// PDF, SVG, PNG, TIFF, RTF and plain text for drops into other applications, and a file promise
/// for the Finder in the *Drag export format* (kbd:[Option] held at the drop picks the format from
/// a menu).  Nothing a collaborator changes after the drag began reaches the files.
@MainActor
enum DragExport {
    /// The formats the file promise offers, in the menu's order.
    static let formats: [ExportFormat] = [.pdf, .svg, .png, .jpeg, .tiff]

    /// The *Drag export format* preference's format.
    static func format(_ value: String) -> ExportFormat {
        switch value {
        case "svg": .svg
        case "png": .png
        case "jpeg": .jpeg
        case "tiff": .tiff
        default: .pdf
        }
    }

    /// What a drag of `window`'s selection carries, given the native payload `data`.
    static func writers(_ data: Data, window: DocumentWindowController, format: ExportFormat, settings: ClipboardSettings = ClipboardSettings(),
                        chooseFormat: @escaping @MainActor () -> ExportFormat? = DragExport.menu) -> [any NSPasteboardWriting] {
        let writer = ClipboardWriter.copy(of: window.objectEditing.selectedNodes, in: window, payload: Array(data), settings: settings, blobs: BlobPlacement())
        let item = NSPasteboardItem()
        item.setData(data, forType: ObjectDragging.type)
        let promised = writer.types.filter { $0 != ClipboardFormat.nativeType }.map { NSPasteboard.PasteboardType($0) }
        let provider = ClipboardItemProvider(writer: writer)
        if !promised.isEmpty { item.setDataProvider(provider, forTypes: promised) }
        let promise = SnapshotPromise(name: "\(window.documentHandle.title) objects", scene: writer.scene, format: format, chooseFormat: chooseFormat)
        return [item, promise]
    }

    /// The kbd:[Option]-drop menu of formats at the pointer.
    static func menu() -> ExportFormat? {
        let menu = NSMenu(title: "Export As")
        for (index, format) in formats.enumerated() {
            let item = NSMenuItem(title: format.description, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        guard menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil), let chosen = menu.highlightedItem else { return nil }
        return formats[chosen.tag]
    }

    /// Connects `window`'s drags to these writers.
    static func attach(_ window: DocumentWindowController, preferences: PreferenceStore) {
        window.canvas.objectDrop?.makeWriters = { [weak window] data in
            guard let window else { return [] }
            return writers(data, window: window, format: format(preferences[PreferenceCatalog.Export.dragFormat]))
        }
    }
}

/// A file promised to the Finder, written from a scene captured when the drag began.  With
/// kbd:[Option] held when the Finder names it, a menu picks the format.
final class SnapshotPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let name: String
    let scene: ExportScene
    private(set) var format: ExportFormat
    private let chooseFormat: @MainActor () -> ExportFormat?
    /// kbd:[Option] held (tests replace it).
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    struct Failed: Error {}

    init(name: String, scene: ExportScene, format: ExportFormat, chooseFormat: @escaping @MainActor () -> ExportFormat?) {
        self.name = name
        self.scene = scene
        self.format = format
        self.chooseFormat = chooseFormat
        super.init()
        fileType = (UTType(filenameExtension: format.fileExtension) ?? .data).identifier
        delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        // AppKit names promised files on the main thread, where the menu can run.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if optionHeld(), let chosen = chooseFormat() { format = chosen }
            }
        }
        return "\(name).\(format.fileExtension)"
    }

    /// Writes the scene to `url` in the promised format.
    func write(to url: URL) throws {
        let exporter = try ExportRegistry.standard.exporter(for: format)
        _ = try exporter.export(scene: scene, options: ExportFormatOptions().options(for: format), to: ExportDestination(url: url))
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        do {
            try write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
