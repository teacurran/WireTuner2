import SwiftUI
import WTGeometry
import WTModel

/// The Object panel while the Output Area tool is active with an area defined (output-area.adoc,
/// "Client"; PRINT-012): X, Y, W and H of the area in the document's unit, with the fields'
/// arithmetic, in place of the selection.  Every commit writes the one register -- X and Y as
/// "Move output area", W and H as "Resize output area" -- and the canvas overlay follows the
/// document.
@MainActor
struct OutputAreaEditorModel {
    enum Field: CaseIterable {
        case x, y, width, height
    }

    let document: DocumentHandle
    let perform: @MainActor (any WTModel.Command) -> Void

    /// The area as the document reads it (nil: none defined).
    var area: Rect? { OutputArea.read(document.state) }

    func value(_ field: Field) -> Double? {
        guard let area else { return nil }
        switch field {
        case .x: return area.minX
        case .y: return area.minY
        case .width: return area.width
        case .height: return area.height
        }
    }

    /// The command a typed `value` in `field` makes; nil when there is no area or the value
    /// cannot make one (a width or height of zero or less).
    func command(_ field: Field, _ value: Double) -> SetOutputArea? {
        guard let area, value.isFinite else { return nil }
        switch field {
        case .x: return SetOutputArea(Rect(x: value, y: area.minY, width: area.width, height: area.height), kind: .move)
        case .y: return SetOutputArea(Rect(x: area.minX, y: value, width: area.width, height: area.height), kind: .move)
        case .width:
            guard value > 0 else { return nil }
            return SetOutputArea(Rect(x: area.minX, y: area.minY, width: value, height: area.height), kind: .resize)
        case .height:
            guard value > 0 else { return nil }
            return SetOutputArea(Rect(x: area.minX, y: area.minY, width: area.width, height: value), kind: .resize)
        }
    }

    func commit(_ field: Field) -> (Double) -> Void {
        { value in if let command = command(field, value) { perform(command) } }
    }

    /// The panel's model for the front window when the Output Area tool is active and the
    /// document has an area; nil otherwise (the panel shows the selection).
    static func model(_ selection: ActiveSelection?) -> OutputAreaEditorModel? {
        guard let selection, selection.activeToolID == OutputAreaTool.id, let document = selection.document else { return nil }
        _ = document.model?.revision
        let editing = selection.editing
        let model = OutputAreaEditorModel(document: document) { command in
            if let editing { editing.perform(command) } else { document.perform(command) }
        }
        return model.area == nil ? nil : model
    }
}

struct OutputAreaEditor: View {
    let model: OutputAreaEditorModel

    static let titles: [(OutputAreaEditorModel.Field, String, String)] = [
        (.x, "X", "outputArea.x"), (.y, "Y", "outputArea.y"), (.width, "W", "outputArea.w"), (.height, "H", "outputArea.h"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Area").font(.headline).accessibilityIdentifier("outputArea.title")
            Form {
                ForEach(Self.titles, id: \.2) { field, title, identifier in
                    MeasureField(title: title, value: model.value(field), units: model.document.unitConverter, identifier: identifier, commit: model.commit(field))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Registers the editor with the Object panel.
    static func register(into registry: InspectorRegistry) {
        registry.registerReplacement(id: "outputArea") { selection in
            OutputAreaEditorModel.model(selection).map { AnyView(OutputAreaEditor(model: $0)) }
        }
    }
}
