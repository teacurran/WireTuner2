import AppKit
import SwiftUI
import WTRender

/// The New View sheet (document-view.adoc, "Named views"): a name for the view the Zoom tool's
/// Shift-drag or menu:View[Custom > New…] captured.  btn:[OK] saves it with the document (a
/// `custom_view` node, BASIC-015); Cancel writes nothing.
enum NamedViewSheet {
    static let identifier = NSUserInterfaceItemIdentifier("named-view-sheet")
    static let sharedNote = "Named views are saved with the document, so everyone who opens it can recall them."

    /// "View at 400%" for a target.
    static func summary(of target: Viewport) -> String {
        "View at \(MagnificationFormat.string(for: target.zoom))"
    }

    @MainActor
    static func window(target: Viewport, finish: @escaping @MainActor (String?) -> Void) -> NSWindow {
        let controller = NSHostingController(rootView: NamedViewSheetView(summary: summary(of: target), finish: finish))
        let window = NSWindow(contentViewController: controller)
        window.identifier = identifier
        window.title = "New View"
        return window
    }
}

struct NamedViewSheetView: View {
    let summary: String
    let finish: @MainActor (String?) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New View").font(.headline)
            TextField("Name", text: $name, prompt: Text("View name"))
                .accessibilityIdentifier("named-view.name")
            Text(summary).font(.callout)
            Text(NamedViewSheet.sharedNote).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).accessibilityIdentifier("named-view.cancel")
                Button("OK") { finish(name) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("named-view.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
