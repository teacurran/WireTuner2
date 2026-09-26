import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// What the colour panels share (swatches.adoc, color-mixer.adoc, tints.adoc; COLOR-007 onwards):
/// the front window's document and selection (through `ActiveSelection`), one `SwatchesModel`
/// per open document, the Fill / Stroke / Both choice the Swatches, Mixer and Tints panels
/// apply with, the colour preferences, and where sheets go.  Panels and commands act through it
/// so a view never reaches the document itself.
@MainActor
@Observable
final class ColorWorkspace {
    let selection: ActiveSelection
    /// The app's preferences; the front window's (`ActiveSelection.preferences`) when nil.
    @ObservationIgnored var preferences: PreferenceStore?
    /// What a click in the Swatches list, the Mixer's and the Tints panel's btn:[Apply] colour:
    /// the Fill, Stroke or Both selector.
    var target = ColorTarget.fill
    /// Presents a sheet over the front window; replaceable in tests.
    @ObservationIgnored var presentSheet: @MainActor (NSWindow) -> Void = ColorWorkspace.beginSheet
    /// The sheets showing, by identifier.
    @ObservationIgnored private(set) var sheets: [String: NSWindow] = [:]
    @ObservationIgnored private var models: [String: SwatchesModel] = [:]

    init(selection: ActiveSelection, preferences: PreferenceStore? = nil) {
        self.selection = selection
        self.preferences = preferences
    }

    // MARK: The front document

    /// The front window's document.
    var document: DocumentHandle? { selection.document }

    /// The colour list of `document`, once its model is open; one per document, kept current by
    /// every change the document applies.
    func swatches(for document: DocumentHandle?) -> SwatchesModel? {
        guard let document, let model = document.model else { return nil }
        if let existing = models[document.id], existing.document === model { return existing }
        models[document.id]?.stop()
        let created = SwatchesModel(document: model)
        models[document.id] = created
        return created
    }

    /// The front document's colour list.
    var swatches: SwatchesModel? { swatches(for: document) }

    /// The selected objects of the front window, in selection order.
    var selectedNodes: [OpID] { selection.model?.selection.ids.map(\.opID) ?? [] }

    // MARK: Preferences

    private var store: PreferenceStore? { preferences ?? selection.preferences }

    /// *Auto-rename colors* (swatches.adoc, "Names").
    var autoRename: Bool { store?[PreferenceCatalog.Colors.autoRename] ?? true }

    /// *Default color space for new colors* (color-mixer.adoc): Display P3 unless set to sRGB.
    var defaultSpace: RenderColor.Space {
        store?[PreferenceCatalog.Colors.defaultColorSpace] == "srgb" ? .sRGB : .displayP3
    }

    /// *Color Mixer and Tints panels use split color box*.
    var splitColorBox: Bool { store?[PreferenceCatalog.Colors.splitColorBox] ?? true }

    // MARK: Acting

    /// Performs `command` on the front document (as one change); nil without a document.
    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        document?.perform(command)
    }

    /// Applies `ref` to the selected objects' `target` (applying-color.adoc): one change,
    /// `Apply "Grape" to 12 objects`.  Nil when nothing is selected.
    @discardableResult
    func apply(_ ref: Wiretuner_Doc_V1_ColorRef, name: String = "", target: ColorTarget? = nil) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return nil }
        // Picked chart elements take overrides (DRAW-034); text blocks the colour per *Swatches
        // apply color to* (TYPE-030).
        if let command = ChartElementStyling.colorCommand(document, selection: nodes, target: target ?? self.target, color: ref) { return perform(command) }
        if let state = document?.state, let command = TextSwatchTarget.command(nodes, target: target ?? self.target, color: ref, name: name, state: state,
                                                                                 appliesTo: TextSwatchTarget.appliesTo(store)) {
            return perform(command)
        }
        return perform(ApplyColor(nodes, target: target ?? self.target, color: ref, name: name))
    }

    /// Shows `content` as a sheet over the front window.
    func present<Content: View>(_ content: Content, title: String, identifier: String) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        // Without a front window it shows as a closable window of its own; `sheets` owns it.
        window.isReleasedWhenClosed = false
        sheets[identifier] = window
        presentSheet(window)
    }

    /// Ends the sheet `identifier` if it is showing.
    func dismiss(_ identifier: String) {
        guard let sheet = sheets.removeValue(forKey: identifier) else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }

    /// The app's presentation: a sheet on the front window, or a window of its own without one.
    static func beginSheet(_ sheet: NSWindow) {
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow {
            parent.beginSheet(sheet)
        } else {
            sheet.makeKeyAndOrderFront(nil)
        }
    }
}

/// Buttons and key handlers take `() -> Void`; the colour models' actions return their change's
/// task (tests await it).  `run` adapts one to the other.
enum ColorAction {
    static func run<T>(_ action: @escaping @MainActor () -> T) -> @MainActor () -> Void {
        { _ = action() }
    }
}
