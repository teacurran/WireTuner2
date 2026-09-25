import AppKit
import WTCRDT
import WTInterchange
import WTModel
import WTRender

/// The three clipboard preferences as `ClipboardSettings` (copying.adoc, "Clipboard formats";
/// menu:WireTuner[Settings… > Export]): *Clipboard formats* (the names of the formats a Copy
/// writes, WireTuner always), *Convert colors to* and *Clipboard image resolution*.
enum ClipboardPreferences {
    /// The format a preference entry names ("PDF", "Image", "Rich text", "Plain text").
    static func format(named name: String) -> ClipboardFormat? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = ClipboardFormat.allCases.first(where: { $0.displayName.lowercased() == key }) { return exact }
        switch key {
        case "image", "tiff", "png": return .image
        case "rtf", "rich text": return .rtf
        case "text", "plain text": return .plainText
        default: return nil
        }
    }

    /// The short name the preference stores for `format`.
    static func name(of format: ClipboardFormat) -> String {
        switch format {
        case .image: "Image"
        case .rtf: "Rich text"
        default: format.displayName
        }
    }

    @MainActor
    static func settings(_ preferences: PreferenceStore) -> ClipboardSettings {
        let formats = Set(preferences[PreferenceCatalog.Export.copyFormats].compactMap(format(named:)))
        let colors = ClipboardColors(rawValue: preferences[PreferenceCatalog.Export.convertColors]) ?? .cmykAndRGB
        let resolution = Double(preferences[PreferenceCatalog.Export.clipboardResolution])
        return ClipboardSettings(formats: formats, colors: colors, imageResolution: resolution)
    }
}

/// Supplies a Copy's expensive types when a reader asks (`NSPasteboardItemDataProvider`): the
/// writer holds the selection's export scene captured at the copy.
final class ClipboardItemProvider: NSObject, NSPasteboardItemDataProvider {
    let writer: ClipboardWriter

    init(writer: ClipboardWriter) {
        self.writer = writer
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = try? writer.data(for: type.rawValue) { item.setData(data, forType: type) }
    }
}

/// The window's clipboard with the interchange formats (OBJ-015's app half): a Copy puts the
/// native payload on the pasteboard at once and promises every other enabled format through an
/// `ClipboardItemProvider`, written from the scene captured at the copy.  Reading is the native
/// payload, as before.
@MainActor
final class FormatsPasteboard: ObjectPasteboard {
    let pasteboard: NSPasteboard
    /// The writer of a Copy of `payload` (the window's selection as an export scene); nil writes the
    /// native type alone.
    var makeWriter: @MainActor (_ payload: [UInt8]) -> ClipboardWriter?
    /// The provider of the last copy, kept alive while its promises stand.
    private(set) var provider: ClipboardItemProvider?

    init(_ pasteboard: NSPasteboard, makeWriter: @escaping @MainActor ([UInt8]) -> ClipboardWriter? = { _ in nil }) {
        self.pasteboard = pasteboard
        self.makeWriter = makeWriter
    }

    func write(_ payload: [UInt8]) {
        guard let writer = makeWriter(payload) else {
            pasteboard.clearContents()
            pasteboard.setData(Data(payload), forType: SystemObjectPasteboard.type)
            return
        }
        write(writer)
    }

    /// Declares every type `writer` offers: the native payload now, the rest on demand.
    func write(_ writer: ClipboardWriter) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let promised = writer.types.filter { $0 != ClipboardFormat.nativeType }.map { NSPasteboard.PasteboardType($0) }
        if let native = writer.native, writer.types.contains(ClipboardFormat.nativeType) {
            item.setData(native, forType: SystemObjectPasteboard.type)
        }
        let provider = ClipboardItemProvider(writer: writer)
        if !promised.isEmpty { item.setDataProvider(provider, forTypes: promised) }
        self.provider = provider
        pasteboard.writeObjects([item])
    }

    func read() -> [UInt8]? {
        (pasteboard.data(forType: SystemObjectPasteboard.type) ?? pasteboard.data(forType: SystemObjectPasteboard.legacyType)).map { Array($0) }
    }

    /// The types on the pasteboard now.
    var types: [String] { EditFeatures.types(of: pasteboard) }
}

extension ClipboardWriter {
    /// What a Copy of `nodes` in `window` offers under `settings`, with `payload` as the native bytes.
    @MainActor
    static func copy(of nodes: [OpID], in window: DocumentWindowController, payload: [UInt8]?, settings: ClipboardSettings, blobs: BlobPlacement) -> ClipboardWriter {
        let document = window.documentHandle
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("clipboard-\(document.id)"))
        builder.textLayout = TextSceneLayout(engine: document.textEngine)
        let scene = ClipboardExport.scene(of: nodes, in: document.state, builder: builder, blob: { blobs.cached($0) })
        return ClipboardWriter(scene: scene, settings: settings, native: payload.map { Data($0) })
    }
}
