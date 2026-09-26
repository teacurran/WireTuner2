import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel

/// Services out (exporting.adoc, "The Share menu and Services"; IO-037): the canvas is a services
/// requestor while something is selected -- a Text tool range offers its text, selected objects
/// their artwork in the drag-export image formats -- so the services other apps provide for text,
/// images and PDF appear in menu:WireTuner[Services].  Nothing is offered with no selection, and
/// nothing is taken back.
@MainActor
final class ServicesRequestor: NSObject, @preconcurrency NSServicesMenuRequestor {
    static let textTypes: [NSPasteboard.PasteboardType] = [.string]
    static let imageTypes: [NSPasteboard.PasteboardType] = [.pdf, .png, .tiff]

    /// The window (AppKit may ask the canvas after its window controller is gone).
    weak var window: DocumentWindowController?

    init(window: DocumentWindowController) {
        self.window = window
    }

    /// The selected text of the Text tool, when it has a range.
    var selectedText: String? {
        guard let session = window?.objectEditing.textSession, session.isLive, !session.selectedRange.isEmpty else { return nil }
        return session.selectedText
    }

    /// The selected objects.
    var selectedNodes: [OpID] { window?.objectEditing.selectedNodes ?? [] }

    /// What the selection offers.
    var offeredTypes: [NSPasteboard.PasteboardType] {
        if selectedText != nil { return Self.textTypes }
        return selectedNodes.isEmpty ? [] : Self.imageTypes
    }

    /// The requestor for a service that takes `sendType` and returns `returnType`: this, when the
    /// selection offers the send type and nothing comes back.
    func requestor(sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard returnType == nil, let sendType, offeredTypes.contains(sendType) else { return nil }
        return self
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let window else { return false }
        let wanted = types.filter(offeredTypes.contains)
        guard !wanted.isEmpty else { return false }
        pboard.declareTypes(wanted, owner: nil)
        if let text = selectedText { return pboard.setString(text, forType: .string) }
        let writer = ClipboardWriter.copy(of: selectedNodes, in: window, payload: nil, settings: ClipboardSettings(), blobs: BlobPlacement())
        var wrote = false
        for type in wanted {
            if let data = try? writer.data(for: type.rawValue) { wrote = pboard.setData(data, forType: type) || wrote }
        }
        return wrote
    }

    /// Registers the types the app sends to services.
    static func register() {
        NSApp.registerServicesMenuSendTypes(textTypes + imageTypes, returnTypes: [])
    }
}

/// Services in: *Add to WireTuner Document* (the `NSServices` entry in Info.plist) places the
/// image, PDF, SVG or text another app sends into the frontmost document exactly as a paste does
/// (images and PDF through the import path, text and SVG through the richest-format paste), one
/// change.  With no document open, or with kbd:[Option] held, a chooser lists the library's recent
/// documents and *New Document* first.
@MainActor
final class ServicesProvider: NSObject {
    /// The front document window.
    var window: @MainActor () -> DocumentWindowController?
    /// Places `pasteboard`'s contents in a window; answers whether it did.
    var place: @MainActor (NSPasteboard, DocumentWindowController) async -> Bool
    /// Asks which document to add to; calls back with the window, or nil when cancelled.
    var choose: @MainActor (@escaping @MainActor (DocumentWindowController?) -> Void) -> Void
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    /// The pending placement (tests wait on it).
    private(set) var running: Task<Bool, Never>?
    /// The app's provider (`NSApp.servicesProvider` holds it too).
    static var shared: ServicesProvider?

    init(window: @escaping @MainActor () -> DocumentWindowController?, place: @escaping @MainActor (NSPasteboard, DocumentWindowController) async -> Bool,
         choose: @escaping @MainActor (@escaping @MainActor (DocumentWindowController?) -> Void) -> Void) {
        self.window = window
        self.place = place
        self.choose = choose
    }

    /// The service's message (`NSMessage` = addToDocument).
    @objc func addToDocument(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pboard)
    }

    /// Places `pboard` in the front document, or the chosen one.
    func receive(_ pboard: NSPasteboard) {
        // The service's pasteboard is read now: it does not outlive the call.
        let copy = NSPasteboard.withUniqueName()
        copy.clearContents()
        for item in pboard.pasteboardItems ?? [] {
            let clone = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { clone.setData(data, forType: type) } }
            copy.writeObjects([clone])
        }
        if !optionHeld(), let front = window() {
            running = Task { await self.place(copy, front) }
            return
        }
        choose { [weak self] chosen in
            guard let self, let chosen else { return }
            self.running = Task { await self.place(copy, chosen) }
        }
    }

    /// The paste path: images and PDF import, text and SVG the richest-format paste.
    static func place(_ pasteboard: NSPasteboard, on window: DocumentWindowController, imports: ImportController, edit: EditFeatures) async -> Bool {
        let types = EditFeatures.types(of: pasteboard)
        let textual = types.contains { [UTType.svg.identifier, UTType.rtf.identifier, UTType.utf8PlainText.identifier].contains($0) }
        if !textual || types.contains(where: { $0 == UTType.pdf.identifier || $0 == UTType.png.identifier || $0 == UTType.tiff.identifier || $0 == UTType.jpeg.identifier }) {
            if !(await imports.paste(from: pasteboard, on: window)).placed.isEmpty { return true }
        }
        guard let scene = try? ClipboardReader.readRichest(types: types, data: { pasteboard.data(forType: NSPasteboard.PasteboardType($0)) }) else { return false }
        return await edit.place(scene, on: window)
    }
}

/// The chooser: the library's recent documents and *New Document*.
struct ServiceDocumentChooser: View {
    let documents: [(id: String, name: String)]
    let choose: (String?) -> Void
    let cancel: () -> Void
    @State private var selected: String?

    static let newDocument = "new"

    static func choosing(_ id: String?, _ choose: @escaping (String?) -> Void) -> () -> Void {
        { choose(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to Document").font(.headline)
            List(documents, id: \.id, selection: $selected) { Text($0.name).tag($0.id) }
                .frame(minHeight: 140)
                .accessibilityIdentifier("services.documents")
            HStack {
                Button("New Document", action: Self.choosing(Self.newDocument, choose)).accessibilityIdentifier("services.new")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("services.cancel")
                Button("Add", action: Self.choosing(selected, choose)).keyboardShortcut(.defaultAction).disabled(selected == nil)
                    .accessibilityIdentifier("services.add")
            }
        }
        .padding()
        .frame(width: 340)
        .accessibilityIdentifier("services.chooser")
    }
}

/// The chooser's window and what a choice opens.
@MainActor
enum ServiceChooser {
    /// Tests keep it from ordering front.
    static var showsWindow = true
    private(set) static var panel: NSPanel?

    /// Shows the chooser; `open` makes the chosen (or a new, for nil) document's window.
    @discardableResult
    static func present(documents: [(id: String, name: String)], open: @escaping @MainActor (String?) -> DocumentWindowController?,
                        done: @escaping @MainActor (DocumentWindowController?) -> Void) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier("services-chooser")
        panel.isReleasedWhenClosed = false
        panel.title = "Add to Document"
        let close: () -> Void = { [weak panel] in panel?.orderOut(nil) }
        panel.contentViewController = NSHostingController(rootView: ServiceDocumentChooser(documents: documents, choose: { id in
            close()
            done(open(id == ServiceDocumentChooser.newDocument ? nil : id))
        }, cancel: {
            close()
            done(nil)
        }))
        self.panel = panel
        if showsWindow { panel.makeKeyAndOrderFront(nil) }
        return panel
    }
}
