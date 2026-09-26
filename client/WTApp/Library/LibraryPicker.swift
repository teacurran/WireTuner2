import AppKit
import Observation
import SwiftUI

/// The Library in picker mode (importing.adoc, "From another app's Share menu"; IMG-026 over
/// APP-009's library): where items shared from another app go when no document is open or
/// kbd:[Option] was held.  It lists the library's recent documents this Mac can open and the
/// account may edit, and offers btn:[New Document]; btn:[Add] (or a double-click) chooses the
/// selected document and btn:[Cancel] places nothing.
@MainActor
@Observable
final class LibraryPickerModel {
    enum Choice: Equatable {
        case document(LibraryDocument)
        case newDocument
        case cancel
    }

    let prompt: String
    let documents: [LibraryDocument]
    var selection: LibraryDocument.ID?
    @ObservationIgnored var finish: @MainActor (Choice) -> Void = { _ in }

    init(prompt: String, library: LibraryModel) {
        self.prompt = prompt
        documents = library.cache.recentDocuments.filter { library.isAvailable($0) && Self.canEdit($0.role) }
        selection = documents.first?.id
    }

    /// Owners and editors may add to a document; a document with no role recorded is the
    /// account's own.
    static func canEdit(_ role: LibraryDocument.Role?) -> Bool {
        guard let role else { return true }
        return role == .owner || role == .editor
    }

    var canAdd: Bool { documents.contains { $0.id == selection } }

    func add() {
        guard let document = documents.first(where: { $0.id == selection }) else { return }
        finish(.document(document))
    }

    func newDocument() { finish(.newDocument) }

    func cancel() { finish(.cancel) }
}

struct LibraryPickerView: View {
    let model: LibraryPickerModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text(model.prompt).font(.headline)
            if model.documents.isEmpty {
                Text("No recent documents.  Start a new one.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(model.documents, selection: $model.selection) { document in
                    Text(document.name).tag(document.id).accessibilityIdentifier("library-picker.row.\(document.id)")
                }
                .frame(minHeight: 160)
                .contextMenu(forSelectionType: LibraryDocument.ID.self) { _ in } primaryAction: { _ in model.add() }
                .accessibilityIdentifier("library-picker.list")
            }
            HStack {
                Button("New Document", action: model.newDocument).accessibilityIdentifier("library-picker.new")
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("library-picker.cancel")
                Button("Add", action: model.add).keyboardShortcut(.defaultAction).disabled(!model.canAdd).accessibilityIdentifier("library-picker.add")
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// Runs the picker in a window of its own and waits for the choice.
@MainActor
enum LibraryPicker {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("library-picker")

    /// The choice made in a picker over `library` titled with `prompt`.  `present` shows the
    /// window (the tests answer through the model instead).
    static func choose(prompt: String, library: LibraryModel,
                       present: @escaping @MainActor (NSWindow, LibraryPickerModel) -> Void = show) async -> LibraryPickerModel.Choice {
        let model = LibraryPickerModel(prompt: prompt, library: library)
        let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryPickerView(model: model)))
        window.title = "Choose a Document"
        window.identifier = windowIdentifier
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        return await withCheckedContinuation { continuation in
            model.finish = { [weak window] choice in
                model.finish = { _ in }
                window?.close()
                continuation.resume(returning: choice)
            }
            present(window, model)
        }
    }

    static func show(_ window: NSWindow, _ model: LibraryPickerModel) {
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
