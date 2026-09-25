import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Find & Replace tab's object attributes (find-replace.adoc, "Find & Replace tab"; OBJ-023):
/// *Color* (From and To wells taking the document's swatches from their menus or a colour dragged
/// from the Swatches panel or Color Mixer), *Stroke width* (Min, Max; the new width or arithmetic),
/// *Remove*, *Rotate*, *Scale* and *Blend steps* and *Simplify*.  btn:[Change] runs
/// `ReplaceGraphics` over the scope's candidates: one labelled change (split at the op limit into
/// parts performed as one undo step), and the count changed.
@MainActor
@Observable
final class GraphicReplaceState {
    enum Attribute: String, CaseIterable, Identifiable {
        case color, strokeWidth, remove, rotate, scale, simplify, blendSteps
        var id: String { rawValue }
        var title: String {
            switch self {
            case .color: "Color"
            case .strokeWidth: "Stroke width"
            case .remove: "Remove"
            case .rotate: "Rotate"
            case .scale: "Scale"
            case .simplify: "Simplify"
            case .blendSteps: "Blend steps"
            }
        }
    }

    var from: Wiretuner_Doc_V1_ColorRef?
    var to: Wiretuner_Doc_V1_ColorRef?
    var minWidth = ""
    var maxWidth = ""
    /// The new width, or arithmetic (`*2`, `+1`, `/3`).
    var newWidth = ""
    var remove = GraphicEdit.RemoveTarget.invisible
    var angle = ""
    var scaleX = "100"
    var scaleY = "100"
    var uniform = true
    var points = "100"
    var amount = 50.0
    var minSteps = ""
    var maxSteps = ""
    var newSteps = ""
    private(set) var result: String?
    /// The replace in flight (tests await it).
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    init() {}

    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces))
    }

    /// The edit the fields describe; nil while they are incomplete.
    func edit(_ attribute: Attribute) -> GraphicEdit? {
        switch attribute {
        case .color:
            guard let from, let to else { return nil }
            return .color(from: from, to: to)
        case .strokeWidth:
            guard let edit = NumberEdit(newWidth) else { return nil }
            let low = Self.number(minWidth)
            return .strokeWidth(ValueRange(min: low, max: Self.number(maxWidth) ?? low), to: edit)
        case .remove:
            return .remove(remove)
        case .rotate:
            return NumberEdit(angle).map { edit in .rotate(edit.apply(0)) }
        case .scale:
            guard let x = NumberEdit(scaleX)?.apply(100) else { return nil }
            let y = uniform ? x : (NumberEdit(scaleY)?.apply(100) ?? x)
            return .scale(x: x, y: y)
        case .simplify:
            guard let count = Self.number(points) else { return nil }
            return .simplify(points: Int(count), amount: amount)
        case .blendSteps:
            guard let edit = NumberEdit(newSteps) else { return nil }
            return .blendSteps(ValueRange(min: Self.number(minSteps), max: Self.number(maxSteps)), to: edit)
        }
    }

    /// btn:[Change] on the front window: the parts performed in one undo group; the count shown.
    @discardableResult
    func change(_ attribute: Attribute, scope: SearchScope, selection: ActiveSelection?) -> Task<Void, Never>? {
        guard let document = selection?.document, let current = selection?.model?.selection else { return nil }
        guard let edit = edit(attribute) else {
            result = "Fill in From and To"
            return nil
        }
        let state = document.state
        let candidates = AttributeQuery.candidates(Self.scope(scope, selection: current, document: document), in: state)
        let parts = ReplaceGraphics.chunks(edit, candidates: candidates, in: state)
        let count = ReplaceGraphics.matches(edit, in: candidates, state: state).count
        result = count == 1 ? "1 object changed" : "\(count) objects changed"
        guard !parts.isEmpty else { return nil }
        let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> = { selection?.editing?.perform($0) ?? document.perform($0) }
        let task = Task { @MainActor in
            if parts.count > 1 { document.beginGroup() }
            for part in parts { _ = await perform(part).value }
            if parts.count > 1 {
                await document.settle()
                document.endGroup()
            }
        }
        running = task
        return task
    }

    /// The query scope of the panel's *Change in*.
    static func scope(_ scope: SearchScope, selection: Selection, document: DocumentHandle) -> AttributeQuery.Scope {
        switch scope {
        case .selection: .selection(selection.ids.map(\.opID))
        case .page: .page(document.activePage.id)
        case .document: .document
        }
    }
}

/// The attribute's fields.
struct GraphicReplaceFields: View {
    @Bindable var state: GraphicReplaceState
    let attribute: GraphicReplaceState.Attribute
    let swatches: [Swatch]
    let resolver: ColorResolver?

    static let none = "Choose"

    /// A colour well: the document's swatches in a pop-up; a dropped colour sets it.
    static func colorBinding(_ value: Binding<Wiretuner_Doc_V1_ColorRef?>, swatches: [Swatch], resolver: ColorResolver?) -> Binding<String> {
        Binding(get: {
            guard let ref = value.wrappedValue, case .swatch(let node)? = ref.ref else { return value.wrappedValue == nil ? none : "Color" }
            return swatches.first { $0.id == OpID(node.id) }?.name ?? "Color"
        }, set: { name in
            if let swatch = swatches.first(where: { $0.name == name }), let resolver { value.wrappedValue = resolver.reference(to: swatch.id) }
        })
    }

    /// A drop of a colour on a well.
    static func dropping(into value: Binding<Wiretuner_Doc_V1_ColorRef?>) -> ([NSItemProvider]) -> Bool {
        { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: ColorRefPasteboard.typeIdentifier) { data, _ in
                guard let data, let payload = ColorRefPasteboard(data: data) else { return }
                Task { @MainActor in value.wrappedValue = payload.ref }
            }
            return true
        }
    }

    @ViewBuilder
    func well(_ title: String, _ value: Binding<Wiretuner_Doc_V1_ColorRef?>) -> some View {
        Picker(title, selection: Self.colorBinding(value, swatches: swatches, resolver: resolver)) {
            Text(Self.none).tag(Self.none)
            Text("Color").tag("Color")
            ForEach(swatches) { Text($0.name).tag($0.name) }
        }
        .onDrop(of: [ColorDrag.utType], isTargeted: nil, perform: Self.dropping(into: value))
        .accessibilityIdentifier("findReplace.color.\(title.lowercased())")
    }

    var body: some View {
        switch attribute {
        case .color:
            well("From", $state.from)
            well("To", $state.to)
        case .strokeWidth:
            TextField("Min", text: $state.minWidth).accessibilityIdentifier("findReplace.width.min")
            TextField("Max", text: $state.maxWidth).accessibilityIdentifier("findReplace.width.max")
            TextField("New width", text: $state.newWidth, prompt: Text("2, *2, +1")).accessibilityIdentifier("findReplace.width.to")
        case .remove:
            Picker("Remove", selection: $state.remove) {
                Text("Invisible objects").tag(GraphicEdit.RemoveTarget.invisible)
                Text("Custom halftones").tag(GraphicEdit.RemoveTarget.halftones)
            }
            .accessibilityIdentifier("findReplace.remove")
        case .rotate:
            TextField("Angle", text: $state.angle).accessibilityIdentifier("findReplace.angle")
        case .scale:
            TextField("X %", text: $state.scaleX).accessibilityIdentifier("findReplace.scaleX")
            TextField("Y %", text: $state.scaleY).disabled(state.uniform).accessibilityIdentifier("findReplace.scaleY")
            Toggle("Uniform", isOn: $state.uniform).accessibilityIdentifier("findReplace.uniform")
        case .simplify:
            TextField("Points", text: $state.points).accessibilityIdentifier("findReplace.points")
            Slider(value: $state.amount, in: 1...100) { Text("Allowable change") }.accessibilityIdentifier("findReplace.amount")
        case .blendSteps:
            TextField("Min steps", text: $state.minSteps).accessibilityIdentifier("findReplace.steps.min")
            TextField("Max steps", text: $state.maxSteps).accessibilityIdentifier("findReplace.steps.max")
            TextField("Steps", text: $state.newSteps).accessibilityIdentifier("findReplace.steps.to")
        }
    }
}

/// menu:Edit[Find and Replace > Graphics…] (kbd:[Cmd+Option+F]): the panel forward.
@MainActor
enum GraphicReplaceCommands {
    static let id: CommandID = "edit.findReplace.graphics"

    static func command(show: @escaping @MainActor () -> Void) -> Command {
        Command(id: id, title: "Graphics…", key: KeyEquivalent("f", [.command, .option]), menu: MenuPath(StandardCommands.Menu.edit, FindTextFeatures.menu, section: 5),
                keywords: ["find", "replace", "recolor"], action: .perform(show))
    }
}
