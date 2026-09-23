import AppKit
import SwiftUI

/// menu:Extensions[Other > Manage Extensions…] (BASIC-032): an outline of categories with a
/// checkbox per extension and per category.  Every click writes the registry's disabled set at
/// once; the menu and the toolbars follow without a restart.
struct ManageExtensionsView: View {
    let registry: ExtensionRegistry
    /// Bumped by the owner after each change so the checkboxes redraw.
    let revision: Int
    let onChange: @MainActor () -> Void
    let done: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Manage Extensions").font(.headline).padding(12)
            List {
                ForEach(registry.categories, id: \.title) { category in
                    Section {
                        ForEach(category.extensions) { descriptor in
                            Toggle(descriptor.shortTitle, isOn: binding(extension: descriptor.id))
                                .padding(.leading, 16)
                                .accessibilityIdentifier("extensions.manage.\(descriptor.id)")
                        }
                    } header: {
                        Toggle(category.title, isOn: binding(category: category.title))
                            .font(.headline)
                            .accessibilityIdentifier("extensions.manage.category.\(category.title)")
                    }
                }
            }
            .id(revision)
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).accessibilityIdentifier("extensions.manage.done")
            }
            .padding(12)
        }
        .frame(width: 360, height: 480)
    }

    func binding(extension id: String) -> Binding<Bool> {
        Binding(get: { registry.isEnabled(id) }, set: { registry.setEnabled($0, id); onChange() })
    }

    /// A partly enabled category shows unchecked; checking it turns every member on.
    func binding(category: String) -> Binding<Bool> {
        Binding(get: { registry.categoryState(category) == true }, set: { registry.setEnabled($0, category: category); onChange() })
    }
}

/// Presents the Manage Extensions sheet on the front document window (a window of its own
/// when there is none).
@MainActor
final class ManageExtensionsController {
    let registry: ExtensionRegistry
    private(set) var window: NSWindow?
    private var hosting: NSHostingController<ManageExtensionsView>?
    private var revision = 0

    init(registry: ExtensionRegistry) {
        self.registry = registry
    }

    @discardableResult
    func show(attachedTo parent: NSWindow?) -> NSWindow {
        let hosting = NSHostingController(rootView: makeView())
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("extensions.manage")
        window.title = "Manage Extensions"
        self.hosting = hosting
        self.window = window
        if let parent {
            parent.beginSheet(window)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }

    func makeView() -> ManageExtensionsView {
        ManageExtensionsView(registry: registry, revision: revision, onChange: { [weak self] in self?.refresh() }, done: { [weak self] in self?.close() })
    }

    func refresh() {
        revision += 1
        hosting?.rootView = makeView()
    }

    func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        self.window = nil
        hosting = nil
    }
}
