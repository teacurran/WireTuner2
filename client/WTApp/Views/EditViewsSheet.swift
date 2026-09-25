import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Edit Views sheet (document-view.adoc, "Named views"): the document's named views in menu
/// order.  Select one and click btn:[Redefine] to give it the window's current magnification, mode
/// and scroll position ("Redefine View"), rename it in place ("Rename View"), btn:[Delete] it
/// ("Delete View"), or drag it to another place ("Reorder Views"); each is one change as it is
/// made, and btn:[OK] closes the sheet.  A collaborator's change shows while the sheet is open.
@MainActor
@Observable
final class EditViewsModel {
    @ObservationIgnored let window: DocumentWindowController
    @ObservationIgnored let close: @MainActor () -> Void
    /// The selected view.
    var selection: OpID?
    /// Bumped when the document changes, so the list re-reads.
    private(set) var revision = 0

    init(window: DocumentWindowController, close: @escaping @MainActor () -> Void) {
        self.window = window
        self.close = close
    }

    var document: DocumentHandle { window.documentHandle }

    /// The views as listed now.
    var views: [NamedView] {
        _ = revision
        return NamedViews.list(document.state)
    }

    func touch() {
        revision += 1
        if let selection, !views.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// A name typed over `view`'s; an unchanged name writes nothing.
    @discardableResult
    func rename(_ view: OpID, to name: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let current = views.first(where: { $0.id == view }), current.storedName != name else { return nil }
        return window.objectEditing.perform(RenameCustomView(view, to: name))
    }

    /// btn:[Redefine]: the selected view takes the window's current view.
    @discardableResult
    func redefine() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let selection else { return nil }
        return window.objectEditing.perform(RedefineCustomView(selection, target: NamedViewFeatures.target(of: window.viewport, mode: window.viewMode)))
    }

    /// btn:[Delete]: the selected view.
    @discardableResult
    func delete() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let selection else { return nil }
        self.selection = nil
        return window.objectEditing.perform(DeleteCustomView([selection]))
    }

    /// A row dragged from `from` to before row `to`.
    @discardableResult
    func move(from: IndexSet, to: Int) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let views = self.views
        guard let index = from.first, views.indices.contains(index) else { return nil }
        let target = to > index ? to - 1 : to
        guard target != index else { return nil }
        return window.objectEditing.perform(MoveCustomView(views[index].id, to: target))
    }
}

struct EditViewsSheet: View {
    @Bindable var model: EditViewsModel

    static func mover(_ model: EditViewsModel) -> (IndexSet, Int) -> Void {
        { from, to in model.move(from: from, to: to) }
    }

    static func redefine(_ model: EditViewsModel) -> () -> Void { { model.redefine() } }
    static func delete(_ model: EditViewsModel) -> () -> Void { { model.delete() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Views").font(.headline)
            List(selection: $model.selection) {
                ForEach(model.views) { view in
                    EditViewRow(view: view, model: model).tag(view.id)
                }
                .onMove(perform: Self.mover(model))
            }
            .frame(minHeight: 160)
            .accessibilityIdentifier("edit-views.list")
            HStack {
                Button("Redefine", action: Self.redefine(model)).disabled(model.selection == nil).accessibilityIdentifier("edit-views.redefine")
                Button("Delete", action: Self.delete(model)).disabled(model.selection == nil).accessibilityIdentifier("edit-views.delete")
                Spacer()
                Button("OK", action: model.close).keyboardShortcut(.defaultAction).accessibilityIdentifier("edit-views.ok")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// One view in the Edit Views sheet: its name, renamed when the edit is committed, and its
/// magnification.
struct EditViewRow: View {
    let view: NamedView
    let model: EditViewsModel
    @State private var text: String

    init(view: NamedView, model: EditViewsModel) {
        self.view = view
        self.model = model
        _text = State(initialValue: view.storedName)
    }

    static func commit(_ view: NamedView, _ model: EditViewsModel, _ text: Binding<String>) -> () -> Void {
        { model.rename(view.id, to: text.wrappedValue) }
    }

    var body: some View {
        HStack {
            TextField(view.name, text: $text)
                .onSubmit(Self.commit(view, model, $text))
                .accessibilityIdentifier("edit-views.name.\(view.number)")
            Spacer()
            Text(MagnificationFormat.string(for: view.target.magnification)).foregroundStyle(.secondary)
        }
    }
}
