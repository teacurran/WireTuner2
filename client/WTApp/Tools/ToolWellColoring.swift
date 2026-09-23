import AppKit
import WTCRDT
import WTModel
import WTProto
import WTRender

extension ActiveWell {
    /// The paint a well colours.
    var target: ColorTarget { self == .fill ? .fill : .stroke }
}

/// The Tools panel wells' view of the colour panels (applying-color.adoc, "The color wells";
/// COLOR-011): what a well's pop-up palette shows -- the selection's colour on its topmost Basic
/// row (mixed when the objects differ), or the current colour with nothing selected -- and where
/// a pick or a dropped colour goes: the selection's fill or stroke as one change, or with nothing
/// selected the current colour.
@MainActor
struct ToolWellColoring {
    /// The Swatches panel's model, whose Fill and Stroke wells read the selection the same way.
    let swatches: SwatchesPanelModel

    var workspace: ColorWorkspace { swatches.workspace }

    /// The well's model, over the front document's swatches; nil without a document.
    func model(_ well: ActiveWell, current: Paint) -> ColorWellModel? {
        guard let document = workspace.document else { return nil }
        if let selected = swatches.well(well.target) { return selected }
        return ColorWellModel(ref: Self.reference(current), state: document.state, documentID: document.id)
    }

    /// A current colour as an unnamed reference.
    static func reference(_ paint: Paint) -> Wiretuner_Doc_V1_ColorRef {
        paint.color.map(ColorResolver.inline) ?? ColorResolver.none
    }

    /// The colour `ref` shows in the front document; nil for *None*.
    func color(of ref: Wiretuner_Doc_V1_ColorRef) -> RenderColor? {
        SwatchList(workspace.document?.state ?? EngineState()).resolver.color(ref)
    }

    /// Applies `ref` to the selection's `well` paint; false (nothing written) with nothing
    /// selected.
    func apply(_ ref: Wiretuner_Doc_V1_ColorRef, name: String, to well: ActiveWell) -> Bool {
        workspace.apply(ref, name: name, target: well.target) != nil
    }

    /// The colour a drag carries, in the front document's terms (a swatch from another document
    /// is created here first, `ColorDrop`): delivered to `use`.  False when the drag carries no
    /// colour.
    func read(_ pasteboard: NSPasteboard, _ use: @escaping @MainActor (Wiretuner_Doc_V1_ColorRef, String, RenderColor?) -> Void) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: workspace.defaultSpace) else { return false }
        guard let document = workspace.document else {
            use(payload.ref, payload.name, payload.color)
            return true
        }
        Task { @MainActor in
            let ref = await ColorDrop.reference(for: payload, in: document)
            use(ref, payload.name, payload.color)
        }
        return true
    }
}
