import AppKit
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel

/// Dragging objects between windows and out of the app (copying.adoc, "Copying by dragging";
/// OBJ-013).  A Pointer move that leaves the window becomes an `NSDraggingSession` carrying the
/// selection as the native objects payload (the clipboard's `ClipboardPayload`) and as a PDF file
/// promise.  Another document window -- or this one -- that takes the drop pastes a copy centred on
/// the drop point on its active layer, selected; the Finder, or any application that takes file
/// promises, gets a PDF of the selection written by the export pipeline.  The source document is
/// never changed: a drag out of the window copies.
@MainActor
final class ObjectDragging: NSObject, NSDraggingSource {
    static let type = SystemObjectPasteboard.type

    let editing: ObjectEditing
    /// Writes a PDF of the window's selection to the URL (the app's export pipeline); false when
    /// it could not.  Nil promises no file.
    var writePDF: (@MainActor @Sendable (URL) async -> Bool)?
    /// The session begun last (tests).
    private(set) var session: NSDraggingSession?

    init(editing: ObjectEditing) {
        self.editing = editing
    }

    var document: DocumentHandle { editing.document }

    /// The selection as the native payload; nil with nothing selected.
    func payload() -> Data? {
        guard editing.hasSelection else { return nil }
        return Data(ClipboardPayload(copying: editing.selectedNodes, from: document.state, document: document.id).encoded())
    }

    /// What a drag of the selection carries: the objects, and a PDF promise when a writer is set.
    func draggingItems(image: NSImage?, frame: NSRect) -> [NSDraggingItem] {
        guard let data = payload() else { return [] }
        let objects = NSPasteboardItem()
        objects.setData(data, forType: Self.type)
        var writers: [any NSPasteboardWriting] = [objects]
        if let writePDF {
            writers.append(PDFPromise(name: "\(document.title) objects", write: writePDF))
        }
        return writers.map { writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame, contents: image)
            return item
        }
    }

    /// Starts the drag of the selection from `view` for the mouse event `event`; nil with nothing
    /// selected.
    @discardableResult
    func begin(with event: NSEvent, from view: NSView) -> NSDraggingSession? {
        guard editing.hasSelection else { return nil }
        let origin = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: origin.x - 16, y: origin.y - 16, width: 32, height: 32)
        let items = draggingItems(image: NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Objects"), frame: frame)
        guard !items.isEmpty else { return nil }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        self.session = session
        return session
    }

    /// What a drag of objects does wherever it lands: a copy.
    nonisolated static let operation: NSDragOperation = .copy

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operation
    }

    // MARK: Dropping

    /// Whether `pasteboard` carries objects.
    static func carriesObjects(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [type, SystemObjectPasteboard.legacyType]) != nil
    }

    /// Pastes the objects on `pasteboard` centred on `point` (pasteboard space) on the active
    /// layer and selects them; false when the pasteboard carries none.
    @discardableResult
    func drop(_ pasteboard: NSPasteboard, at point: Point) -> Task<Void, Never>? {
        guard let bytes = SystemObjectPasteboard(pasteboard).read(), let payload = ClipboardPayload(decoding: bytes), !payload.isEmpty else { return nil }
        let task = editing.perform(Paste(payload, placement: .top(layer: editing.activeLayer, center: point), rememberLayerInfo: editing.rememberLayerInfo()))
        let model = editing.selection.model
        return Task { @MainActor in
            if let created = await task.value?.createdRoots, !created.isEmpty { model.set(Selection(created.map { SelectionID($0) })) }
        }
    }
}

/// A PDF file promised to the drop target (the Finder), written when it asks.
final class PDFPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let name: String
    private let write: @MainActor @Sendable (URL) async -> Bool

    struct Failed: Error {}

    init(name: String, write: @escaping @MainActor @Sendable (URL) async -> Bool) {
        self.name = name
        self.write = write
        super.init()
        fileType = UTType.pdf.identifier
        delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "\(name).pdf"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        nonisolated(unsafe) let completion = completionHandler
        let write = write
        Task { @MainActor in
            let written = await write(url)
            completion(written ? nil : Failed())
        }
    }
}
