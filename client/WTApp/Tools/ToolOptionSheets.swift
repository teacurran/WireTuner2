import AppKit
import SwiftUI

/// The options sheets the selection and drawing tools open on a double-click in the Tools panel
/// (selecting.adoc "Marquee behavior", polygons-stars.adoc, spirals-arcs.adoc, freeform.adoc): each
/// lists the tool's own preferences with the Preferences window's rows, stored on change.
@MainActor
enum ToolOptionSheets {
    /// The keys each tool's sheet shows.
    static let keys: [ToolID: [AnyPreferenceKey]] = {
        typealias P = DrawingToolPreferences
        let pointer = [SelectionToolOptions.contactSensitive.erased]
        return [
            .pointer: pointer,
            PointerTool.subselectID: pointer,
            LassoTool.id: [SelectionToolOptions.lassoContactSensitive.erased],
            PolygonTool.id: [P.polygonStar.erased, P.polygonSides.erased, P.polygonAutomatic.erased, P.polygonSharpness.erased],
            SpiralTool.id: [P.spiralExpanding.erased, P.spiralExpansion.erased, P.spiralByIncrements.erased, P.spiralRotations.erased,
                            P.spiralIncrement.erased, P.spiralStartingRadius.erased, P.spiralDrawFrom.erased, P.spiralClockwise.erased],
            ArcTool.id: [P.arcOpen.erased, P.arcFlipped.erased, P.arcConcave.erased],
            PencilTool.id: [P.pencilPrecision.erased, P.pencilDotted.erased],
        ]
    }()

    /// The sheet for `title` over `keys`, stored in `store`.
    static func controller(title: String, keys: [AnyPreferenceKey], store: PreferenceStore) -> NSViewController {
        let controller = NSHostingController(rootView: ToolOptionsSheet(title: title, keys: keys, store: store, dismiss: {}))
        controller.rootView = ToolOptionsSheet(title: title, keys: keys, store: store) { [weak controller] in
            ToolOptionsPlaceholder.close(controller?.view.window)
        }
        controller.title = "\(title) Options"
        return controller
    }

    /// Gives every tool with keys its sheet over `store`.
    static func install(into tools: ToolRegistry, store: PreferenceStore) {
        for (id, keys) in keys {
            guard var descriptor = tools.descriptor(for: id) else { continue }
            let title = descriptor.title
            descriptor.options = { controller(title: title, keys: keys, store: store) }
            tools.replace(descriptor)
        }
    }
}

/// A tool's options: its preference rows and btn:[Done].
struct ToolOptionsSheet: View {
    let title: String
    let keys: [AnyPreferenceKey]
    let store: PreferenceStore
    let dismiss: @MainActor () -> Void

    var body: some View {
        let bindings = PreferenceBindings(store: store)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) Options").font(.headline)
            Form {
                ForEach(keys.map(PreferenceFormRow.init(key:))) { row in
                    PreferenceRowView(row: row, bindings: bindings)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("tool-options.done")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
