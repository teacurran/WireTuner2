import AppKit
import UniformTypeIdentifiers
import WTCRDT
import WTModel

/// A graphic style on the drag pasteboard (styles.adoc, "Applying styles": dragging a style's
/// preview onto an object, or onto another style to redefine it): the document it belongs to and
/// the style's id, under `com.villagecompute.wiretuner.graphic-style`.  A style dragged into
/// another document is not carried over (cross-document style copying is LIB-022's).
struct StyleDrag: Equatable {
    static let typeIdentifier = "com.villagecompute.wiretuner.graphic-style"
    static let type = NSPasteboard.PasteboardType(typeIdentifier)
    static let utType = UTType(exportedAs: typeIdentifier)
    /// Objects dragged out of a window (`ObjectDragging`), which the panel also takes.
    static let objectsUTType = UTType(exportedAs: ClipboardPayload.pasteboardType)

    let document: String
    let style: OpID

    /// The payload as bytes: `document`, then the id's replica and counter, one per line.
    var data: Data {
        Data("\(document)\n\(style.replica)\n\(style.counter)".utf8)
    }

    init(document: String, style: OpID) {
        self.document = document
        self.style = style
    }

    init?(data: Data) {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 3, let replica = UInt64(lines[1]), let counter = UInt64(lines[2]) else { return nil }
        document = String(lines[0])
        style = OpID(counter: counter, replica: replica)
    }

    /// A drag's item.
    var itemProvider: NSItemProvider {
        NSItemProvider(item: data as NSData, typeIdentifier: Self.typeIdentifier)
    }

    /// Writes the payload to `pasteboard`, replacing its contents.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.declareTypes([Self.type], owner: nil)
        pasteboard.setData(data, forType: Self.type)
    }

    /// The style `pasteboard` carries, if any.
    static func read(from pasteboard: NSPasteboard) -> StyleDrag? {
        pasteboard.data(forType: type).flatMap(StyleDrag.init(data:))
    }
}
