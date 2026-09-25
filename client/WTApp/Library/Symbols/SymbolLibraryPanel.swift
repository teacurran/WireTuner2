import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// The Library panel's body: the preview, the column headers (click to sort), the outline, and
/// the bottom buttons (btn:[New symbol], btn:[New folder], btn:[Swap], btn:[Remove]).
struct SymbolLibraryPanelBody: View {
    @Bindable var model: SymbolLibraryModel

    static func clicking(_ id: OpID, _ model: SymbolLibraryModel) -> () -> Void {
        { model.click(id, modifiers: NSEvent.modifierFlags) }
    }

    static func renaming(_ id: OpID, _ model: SymbolLibraryModel) -> () -> Void {
        { model.beginRename(id) }
    }

    static func sorting(_ column: SymbolLibraryModel.Sort, _ model: SymbolLibraryModel) -> () -> Void {
        { model.sort(by: column) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.showsPreview {
                Group {
                    if let image = model.preview() {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text(model.document == nil ? SymbolLibraryModel.noDocument : "No symbol selected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 120)
                .accessibilityIdentifier("library.preview")
            }
            HStack {
                Button("Name", action: Self.sorting(.name, model)).buttonStyle(.plain).accessibilityIdentifier("library.sort.name")
                Spacer()
                Button("Count", action: Self.sorting(.count, model)).buttonStyle(.plain).accessibilityIdentifier("library.sort.count")
            }
            .font(.caption.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rows) { row in
                        SymbolLibraryRowView(row: row, model: model)
                    }
                }
            }
            .accessibilityIdentifier("library.list")
            HStack {
                Button(action: ColorAction.run(model.newSymbol)) { Image(systemName: "plus.square") }.help("New symbol")
                    .disabled(model.canvasObjects.isEmpty).accessibilityIdentifier("library.newSymbol")
                Button(action: ColorAction.run(model.newFolder)) { Image(systemName: "folder.badge.plus") }.help("New folder")
                    .disabled(model.document == nil).accessibilityIdentifier("library.newFolder")
                Button(action: ColorAction.run(model.swap)) { Image(systemName: "arrow.left.arrow.right") }.help("Swap")
                    .disabled(model.selectedSymbol == nil || model.canvasObjects.isEmpty).accessibilityIdentifier("library.swap")
                Spacer()
                Button(action: ColorAction.run(model.remove)) { Image(systemName: "trash") }.help("Remove")
                    .disabled(model.selectedRows.isEmpty).accessibilityIdentifier("library.remove")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
    }
}

/// One row: disclosure depth, icon, name (a field while renaming) and the count.
struct SymbolLibraryRowView: View {
    let row: SymbolLibraryModel.Row
    @Bindable var model: SymbolLibraryModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind == .folder ? "folder" : "star.square")
            if model.renaming == row.id {
                TextField("Name", text: $model.renameText)
                    .onSubmit(ColorAction.run(model.commitRename))
                    .accessibilityIdentifier("library.rename")
            } else {
                Button(action: SymbolLibraryPanelBody.clicking(row.id, model)) { Text(row.name) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded(SymbolLibraryPanelBody.renaming(row.id, model)))
            }
            Spacer()
            Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.leading, Double(row.depth) * 14)
        .background(model.selected.contains(row.id) ? SwiftUI.Color.accentColor.opacity(0.2) : SwiftUI.Color.clear)
        .accessibilityIdentifier("library.row.\(row.name)")
    }
}

/// The Remove sheet: what to do with the instances of the symbols being removed.
struct RemoveSymbolsSheet: View {
    let model: SymbolLibraryModel

    static func choosing(_ handling: InstanceHandling, _ model: SymbolLibraryModel) -> () -> Void {
        { model.confirmRemove(handling) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove Symbols").font(.headline)
            Text("The symbols have instances in the document.  Release them as ordinary groups, or delete them?").fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: model.cancelRemove).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete Instances", action: Self.choosing(.delete, model)).accessibilityIdentifier("library.remove.delete")
                Button("Release Instances", action: Self.choosing(.release, model)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("library.remove.release")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// The Library panel in place of the catalog's placeholder, and menu:Modify[Symbol]'s *Convert to
/// Symbol* (kbd:[F8]), *Copy to Symbol*, *Release Instance* and *Show in Library*.
@MainActor
enum SymbolLibraryFeatures {
    enum ID {
        static let convert: CommandID = "modify.symbol.convertToSymbol"
        static let copy: CommandID = "modify.symbol.copyToSymbol"
    }

    static let noInstance = "Select an instance"

    static func descriptor(model: SymbolLibraryModel) -> PanelDescriptor {
        PanelDescriptor(id: "library", title: "Library", icon: "books.vertical", defaultGroup: PanelCatalog.Group.assets, menuOrder: 32, helpSlug: "library",
                        optionsMenu: { model.optionsMenu() }) {
            SymbolLibraryPanelBody(model: model)
        }
    }

    /// The selected instances.
    static func instances(_ model: SymbolLibraryModel) -> [OpID] {
        guard let state = model.document?.state else { return [] }
        return model.canvasObjects.filter { state.nodeKind($0) == .instance }
    }

    static func commands(model: SymbolLibraryModel, showLibrary: @escaping @MainActor () -> Void) -> [Command] {
        let menu = MenuPath(ContextMenuCatalog.Menu.modify, "Symbol", section: 4)
        let objects: @MainActor @Sendable () -> CommandValidation = { model.canvasObjects.isEmpty ? .disabled(SymbolLibraryModel.noObjects) : .enabled }
        let instance: @MainActor @Sendable () -> CommandValidation = { instances(model).isEmpty ? .disabled(noInstance) : .enabled }
        return [
            Command(id: ID.convert, title: "Convert to Symbol", key: KeyEquivalent("f8", []), menu: menu, contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["symbol", "library"], validation: objects, action: .perform { model.newSymbol() }),
            Command(id: ID.copy, title: "Copy to Symbol", menu: menu, keywords: ["symbol", "library"], validation: objects, action: .perform { model.copyToSymbol() }),
            Command(id: ContextMenuCatalog.ID.releaseInstance, title: "Release Instance", menu: menu, contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["symbol", "instance", "detach"], validation: instance,
                    action: .perform { model.perform(ReleaseInstances(instances(model))) }),
            Command(id: ContextMenuCatalog.ID.showInLibrary, title: "Show in Library", menu: menu, keywords: ["symbol", "library"], validation: instance,
                    action: .perform {
                        guard let state = model.document?.state else { return }
                        for symbol in instances(model).compactMap({ Symbols.symbol(of: $0, in: state) }) { model.click(symbol, modifiers: .command) }
                        showLibrary()
                    }),
        ]
    }

    /// The Remove sheet through `presenter`.
    static func connectSheets(_ model: SymbolLibraryModel, presenter: SheetPresenter) {
        model.present = { model in presenter.present(RemoveSymbolsSheet(model: model), title: "Remove Symbols", identifier: SymbolLibraryModel.removeSheet) }
        model.dismiss = { presenter.dismiss(SymbolLibraryModel.removeSheet) }
    }

    static func install(commands registry: CommandRegistry, panels: PanelRegistry, model: SymbolLibraryModel, showLibrary: @escaping @MainActor () -> Void) {
        _ = panels.registerIfAbsent(descriptor(model: model))
        for command in commands(model: model, showLibrary: showLibrary) { registry.replace(command) }
    }
}

extension AppDelegate {
    /// The Library panel and the Symbol menu (before `PanelCatalog.register`).
    func installSymbolLibrary() {
        let model = SymbolLibraryModel(selection: activeSelection)
        SymbolLibraryFeatures.connectSheets(model, presenter: SheetPresenter())
        let layout = layout
        SymbolLibraryFeatures.install(commands: commands, panels: panels, model: model) { layout.showPanel("library") }
    }
}
