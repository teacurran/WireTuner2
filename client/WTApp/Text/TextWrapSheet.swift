import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:Text[Flow Around Selection…] (text-effects.adoc, "Wrapping text around objects";
/// TYPE-039): the sheet with btn:[Text wrap] and *Standoff*, and btn:[Remove text wrap].  Every
/// text block behind the selected object wraps around it (`TextWrapping`); groups and blends are
/// refused.  btn:[OK] is one change.
@MainActor
enum TextWrapFeatures {
    static let title = "Flow Around Selection…"
    static let refused = "Groups and blends cannot push text away; draw a path around them and wrap around the path."
    static let noObject = "Select an object"

    /// The objects the sheet edits, or why it cannot.
    static func targets(in window: DocumentWindowController?) -> Result<[OpID], WrapRefusal> {
        guard let window else { return .failure(.nothing) }
        let state = window.documentHandle.state
        let ids = window.selection.selection.ids.map(\.opID)
        guard !ids.isEmpty else { return .failure(.nothing) }
        guard ids.allSatisfy({ TextWrapping.isWrappable($0, in: state) }) else { return .failure(.groupOrBlend) }
        return .success(ids)
    }

    enum WrapRefusal: Error, Equatable {
        case nothing, groupOrBlend
    }

    /// The sheet's starting values: the first object's wrap.
    static func current(_ nodes: [OpID], in state: EngineState) -> (enabled: Bool, standoff: Double) {
        let wrap = nodes.first.flatMap { NavigationFields.common(of: $0, in: state)?.textWrap } ?? Wiretuner_Doc_V1_TextWrap()
        return (wrap.enabled, wrap.standoff)
    }

    /// Opens the sheet on `window`.
    @discardableResult
    static func present(on window: DocumentWindowController, alert: @MainActor (String, String) -> Void = TextStyleFeatures.showAlert) -> NSWindow? {
        switch targets(in: window) {
        case .failure(.groupOrBlend):
            alert("Text cannot wrap around this object", refused)
            return nil
        case .failure:
            return nil
        case .success(let nodes):
            let start = current(nodes, in: window.documentHandle.state)
            let editing = window.objectEditing
            let document = window.documentHandle
            return window.presentSheet("text-wrap") { close in
                TextWrapSheet(enabled: start.enabled, standoff: start.standoff, commit: { enabled, standoff in
                    apply(SetTextWrap(nodes, enabled: enabled, standoff: standoff), editing: editing, document: document)
                    close()
                }, cancel: close)
            }
        }
    }

    /// Performs `command`, then redraws the document: text laid out before the object wrapped did
    /// not depend on it, so the scene is rebuilt once (moves of a wrapping object re-wrap by
    /// dependency from then on).
    @discardableResult
    static func apply(_ command: SetTextWrap, editing: ObjectEditing, document: DocumentHandle) -> Task<Void, Never> {
        let task = editing.perform(command)
        return Task { @MainActor in
            _ = await task.value
            await document.reload().value
        }
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        [Command(id: ContextMenuCatalog.ID.runAround, title: title, menu: MenuPath(ContextMenuCatalog.Menu.text, section: 2),
                 contexts: ContextMenuCatalog.objectContexts, keywords: ["wrap", "run around", "flow around", "standoff"],
                 validation: { if case .failure(.nothing) = targets(in: window()) { return .disabled(noObject) } else { return .enabled } },
                 action: .perform { if let front = window() { present(on: front) } })]
    }
}

/// The sheet.
struct TextWrapSheet: View {
    @State var enabled: Bool
    @State var standoff: Double
    let commit: (Bool, Double) -> Void
    let cancel: () -> Void

    static func committing(_ enabled: Bool, _ standoff: Double, _ commit: @escaping (Bool, Double) -> Void) -> () -> Void {
        { commit(enabled, standoff) }
    }

    static func removing(_ commit: @escaping (Bool, Double) -> Void) -> () -> Void {
        { commit(false, 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flow Around Selection").font(.headline)
            Toggle("Text wrap", isOn: $enabled).toggleStyle(.checkbox).accessibilityIdentifier("textWrap.enabled")
            HStack {
                Text("Standoff")
                TextField("Standoff", value: $standoff, format: .number).frame(width: 70).disabled(!enabled).accessibilityIdentifier("textWrap.standoff")
                Text("pt")
            }
            HStack {
                Button("Remove text wrap", action: Self.removing(commit)).accessibilityIdentifier("textWrap.remove")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(enabled, standoff, commit)).keyboardShortcut(.defaultAction).accessibilityIdentifier("textWrap.ok")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
