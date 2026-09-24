import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Transform panel's settings (transforming.adoc, "The Transform panel"; OBJ-033): which tab,
/// the numbers on each, the centre, the copies and the *Strokes* option.  A value type the view keeps
/// in `@State`; `command(...)` turns it into the one change *Apply* performs.
struct TransformPanelModel: Equatable {
    enum Tab: String, CaseIterable, Identifiable {
        case move, rotate, scale, skew, reflect
        var id: String { rawValue }
        var kind: TransformKind { TransformKind(rawValue: rawValue)! }
        var title: String { kind.title }
    }

    var tab = Tab.move
    /// Move: points, positive right and *up* (the pasteboard is y down).
    var moveX = 0.0
    var moveY = 0.0
    /// Rotate: degrees, counter-clockwise.
    var angle = 0.0
    /// Scale: percent; `uniform` uses `scaleX` for both.
    var uniform = true
    var scaleX = 100.0
    var scaleY = 100.0
    /// Skew: degrees.
    var skewX = 0.0
    var skewY = 0.0
    /// Reflect: the axis angle, degrees (90° flips left to right, 0° top to bottom).
    var axis = 90.0
    /// The centre, pasteboard space; nil uses the selection's centre.
    var centerX: Double?
    var centerY: Double?
    var copies = 0
    var strokes = false

    /// The pasteboard-space matrix of the current tab (about the origin).
    var matrix: WTGeometry.AffineTransform {
        switch tab {
        case .move: return .translation(x: moveX, y: -moveY)
        case .rotate: return .rotation(radians: -angle * .pi / 180)
        case .scale:
            let sx = scaleX / 100, sy = (uniform ? scaleX : scaleY) / 100
            return .scale(x: sx, y: sy)
        case .skew: return .shear(x: tan(skewX * .pi / 180), y: tan(skewY * .pi / 180))
        case .reflect:
            let phi = -axis * .pi / 180
            return WTGeometry.AffineTransform(a: cos(2 * phi), b: sin(2 * phi), c: sin(2 * phi), d: -cos(2 * phi), tx: 0, ty: 0)
        }
    }

    /// The selection's centre (its geometry bounds' centre), when anything with geometry is selected.
    static func center(of nodes: [OpID], in state: EngineState) -> Point? {
        let bounds = nodes.compactMap { Objects.bounds(of: $0, in: state) }
        guard let first = bounds.first else { return nil }
        return bounds.dropFirst().reduce(first) { $0.union($1) }.center
    }

    /// *Apply*: one `TransformObjects` of the selected objects (with copies when asked, "Rotate
    /// with 3 copies"); nil with nothing selected or a matrix that cannot be inverted.
    func command(nodes: [OpID], state: EngineState) -> TransformObjects? {
        guard !nodes.isEmpty, matrix.isInvertible, let selectionCenter = Self.center(of: nodes, in: state) else { return nil }
        let center = Point(x: centerX ?? selectionCenter.x, y: centerY ?? selectionCenter.y)
        return TransformObjects(nodes, matrix: matrix, about: tab == .move ? nil : center, kind: tab.kind,
                                options: TransformOptions(strokes: strokes), copies: max(0, copies))
    }
}

/// The Transform panel body: the five tabs, their fields (units and arithmetic), the centre,
/// *Copies*, *Strokes*, *Apply*, and the last transformation's name.
struct TransformPanelBody: View {
    let selection: ActiveSelection?
    @State private var model = TransformPanelModel()

    /// Performs *Apply* for `model` on the front window's selection.
    @discardableResult
    static func apply(_ model: TransformPanelModel, selection: ActiveSelection?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let document = selection?.document, let ids = selection?.model?.selection.ids,
              let command = model.command(nodes: ids.map(\.opID), state: document.state) else { return nil }
        return selection?.editing?.perform(command) ?? document.perform(command)
    }

    /// A number field bound to one of the model's values.
    static func field(_ title: String, _ value: Binding<Double>, unit: MeasureUnit, identifier: String) -> some View {
        MeasureField(title: title, value: value.wrappedValue, unit: unit, identifier: identifier) { value.wrappedValue = $0 }
    }

    /// A length field bound to one of the model's values, in the document's units.
    static func field(_ title: String, _ value: Binding<Double>, units: Units, identifier: String) -> some View {
        MeasureField(title: title, value: value.wrappedValue, units: units, identifier: identifier) { value.wrappedValue = $0 }
    }

    var body: some View {
        let units = selection?.document?.unitConverter ?? Units()
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transform", selection: $model.tab) {
                ForEach(TransformPanelModel.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("transform.tab")
            Form {
                switch model.tab {
                case .move:
                    Self.field("X", $model.moveX, units: units, identifier: "transform.move.x")
                    Self.field("Y", $model.moveY, units: units, identifier: "transform.move.y")
                case .rotate:
                    Self.field("Angle", $model.angle, unit: .points, identifier: "transform.rotate.angle")
                case .scale:
                    Toggle("Uniform", isOn: $model.uniform).accessibilityIdentifier("transform.scale.uniform")
                    Self.field(model.uniform ? "Scale %" : "H %", $model.scaleX, unit: .points, identifier: "transform.scale.x")
                    if !model.uniform { Self.field("V %", $model.scaleY, unit: .points, identifier: "transform.scale.y") }
                case .skew:
                    Self.field("H", $model.skewX, unit: .points, identifier: "transform.skew.x")
                    Self.field("V", $model.skewY, unit: .points, identifier: "transform.skew.y")
                case .reflect:
                    Self.field("Axis", $model.axis, unit: .points, identifier: "transform.reflect.axis")
                }
                Stepper("Copies: \(model.copies)", value: $model.copies, in: 0...1000).accessibilityIdentifier("transform.copies")
                Toggle("Strokes", isOn: $model.strokes).accessibilityIdentifier("transform.strokes")
            }
            Button("Apply") { Self.apply(model, selection: selection) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("transform.apply")
            if let last = selection?.editing?.lastTransform {
                Text("Last: \(last.kind.title)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("transform.last")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

/// The Transform panel's registration (it replaces the catalog's placeholder).
enum TransformPanel {
    static func descriptor(selection: ActiveSelection?) -> PanelDescriptor {
        PanelDescriptor(id: "transform", title: "Transform", icon: "arrow.up.left.and.arrow.down.right", defaultGroup: PanelCatalog.Group.alignTransform,
                        menuOrder: 51, helpSlug: "transforming") {
            TransformPanelBody(selection: selection)
        }
    }
}
