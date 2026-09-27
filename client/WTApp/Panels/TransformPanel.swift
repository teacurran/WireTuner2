import Observation
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
    /// *Fills* and *Contents* (transforming.adoc, "The Transform panel"), on by default.
    var fills = true
    var contents = true

    static let strokesKey = "transform.strokes"
    static let fillsKey = "transform.fills"
    static let contentsKey = "transform.contents"

    /// The options as last left, from `defaults` (the three toggles persist; the numbers do not).
    init(defaults: UserDefaults? = nil) {
        guard let defaults else { return }
        strokes = defaults.bool(forKey: Self.strokesKey)
        fills = defaults.object(forKey: Self.fillsKey) as? Bool ?? true
        contents = defaults.object(forKey: Self.contentsKey) as? Bool ?? true
    }

    func saveOptions(to defaults: UserDefaults) {
        defaults.set(strokes, forKey: Self.strokesKey)
        defaults.set(fills, forKey: Self.fillsKey)
        defaults.set(contents, forKey: Self.contentsKey)
    }

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
    func command(nodes: [OpID], state: EngineState, handlesCenter: Point? = nil) -> TransformObjects? {
        guard !nodes.isEmpty, matrix.isInvertible, let selectionCenter = Self.center(of: nodes, in: state) else { return nil }
        let base = handlesCenter ?? selectionCenter
        let center = Point(x: centerX ?? base.x, y: centerY ?? base.y)
        return TransformObjects(nodes, matrix: matrix, about: tab == .move ? nil : center, kind: tab.kind,
                                options: TransformOptions(strokes: strokes, fills: fills, contents: contents), copies: max(0, copies))
    }
}

/// The Transform panel's state, one per app so a menu item or a double-click on a transformation
/// tool can open it on a tab (OBJ-033): the model, the toggles persisted in `defaults`.
@MainActor
@Observable
final class TransformPanelState {
    var model: TransformPanelModel {
        didSet { if let defaults { model.saveOptions(to: defaults) } }
    }

    @ObservationIgnored let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        model = TransformPanelModel(defaults: defaults)
    }

    /// Opens on `tab` (menu:Modify[Transform > Rotate…], a double-click on the Rotate tool).
    func show(_ tab: TransformPanelModel.Tab) {
        model.tab = tab
    }
}

/// The Transform panel body: the five tabs, their fields (units and arithmetic), the centre --
/// the transform handles' centre while they are shown, and typing moves it (OBJ-033) --,
/// *Copies*, *Strokes*, *Fills*, *Contents*, *Apply*, and the last transformation's name.
struct TransformPanelBody: View {
    let selection: ActiveSelection?
    @State private var state: TransformPanelState

    init(selection: ActiveSelection?, state: TransformPanelState? = nil) {
        self.selection = selection
        _state = State(initialValue: state ?? TransformPanelState())
    }

    /// Performs *Apply* for `model` on the front window's selection, about the handles' centre
    /// when they are shown and no centre was typed.
    @discardableResult
    static func apply(_ model: TransformPanelModel, selection: ActiveSelection?, link: TransformCenterLink = .shared) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let document = selection?.document, let ids = selection?.model?.selection.ids,
              let command = model.command(nodes: ids.map(\.opID), state: document.state, handlesCenter: link.center(for: document)) else { return nil }
        return selection?.editing?.perform(command) ?? document.perform(command)
    }

    /// The centre the fields show: the typed one, the handles' or the selection's bounds centre.
    static func center(_ model: TransformPanelModel, selection: ActiveSelection?, link: TransformCenterLink = .shared) -> Point? {
        guard let document = selection?.document else { return nil }
        let ids = selection?.model?.selection.ids.map(\.opID) ?? []
        guard let base = link.center(for: document) ?? TransformPanelModel.center(of: ids, in: document.state) else { return nil }
        return Point(x: model.centerX ?? base.x, y: model.centerY ?? base.y)
    }

    /// A typed centre coordinate: moves the handles' centre when they are shown, else is kept
    /// for *Apply*.
    static func setCenter(_ value: Double, horizontal: Bool, state: TransformPanelState, selection: ActiveSelection?, link: TransformCenterLink = .shared) {
        guard let current = center(state.model, selection: selection, link: link) else { return }
        let point = horizontal ? Point(x: value, y: current.y) : Point(x: current.x, y: value)
        if let document = selection?.document, link.move(to: point, for: document) {
            state.model.centerX = nil
            state.model.centerY = nil
        } else {
            state.model.centerX = point.x
            state.model.centerY = point.y
        }
    }

    /// The y the centre field shows for stored `y`: font y (upward) on a glyph canvas (FONT-004).
    static func shownY(_ y: Double, selection: ActiveSelection?) -> Double {
        selection?.document.map { GlyphCanvasUnits.shown(y: y, in: $0) } ?? y
    }

    /// The stored y for a typed centre `y`.
    static func storedY(_ y: Double, selection: ActiveSelection?) -> Double {
        selection?.document.map { GlyphCanvasUnits.stored(y: y, in: $0) } ?? y
    }

    /// A number field bound to one of the model's values.
    static func field(_ title: String, _ value: Binding<Double>, unit: MeasureUnit, identifier: String) -> MeasureField {
        MeasureField(title: title, value: value.wrappedValue, unit: unit, identifier: identifier) { value.wrappedValue = $0 }
    }

    /// A length field bound to one of the model's values, in the document's units.
    static func field(_ title: String, _ value: Binding<Double>, units: Units, identifier: String) -> MeasureField {
        MeasureField(title: title, value: value.wrappedValue, units: units, identifier: identifier) { value.wrappedValue = $0 }
    }

    /// *Apply*.
    func applyNow() {
        Self.apply(state.model, selection: selection)
    }

    var body: some View {
        @Bindable var state = state
        let units = selection?.document?.unitConverter ?? Units()
        let _ = TransformCenterLink.shared.revision
        let center = Self.center(state.model, selection: selection)
        VStack(alignment: .leading, spacing: 10) {
            PanelSectionTabs(
                label: "Transform", options: TransformPanelModel.Tab.allCases.map { ($0, $0.id, $0.title) }, selection: $state.model.tab,
                identifier: "transform.tab"
            )
            .frame(height: PanelTabStrip.height)
            Form {
                switch state.model.tab {
                case .move:
                    Self.field("X", $state.model.moveX, units: units, identifier: "transform.move.x")
                    Self.field("Y", $state.model.moveY, units: units, identifier: "transform.move.y")
                case .rotate:
                    Self.field("Angle", $state.model.angle, unit: .points, identifier: "transform.rotate.angle")
                case .scale:
                    Toggle("Uniform", isOn: $state.model.uniform).accessibilityIdentifier("transform.scale.uniform")
                    Self.field(state.model.uniform ? "Scale %" : "H %", $state.model.scaleX, unit: .points, identifier: "transform.scale.x")
                    if !state.model.uniform { Self.field("V %", $state.model.scaleY, unit: .points, identifier: "transform.scale.y") }
                case .skew:
                    Self.field("H", $state.model.skewX, unit: .points, identifier: "transform.skew.x")
                    Self.field("V", $state.model.skewY, unit: .points, identifier: "transform.skew.y")
                case .reflect:
                    Self.field("Axis", $state.model.axis, unit: .points, identifier: "transform.reflect.axis")
                }
                if state.model.tab != .move {
                    MeasureField(title: "Center X", value: center?.x, units: units, identifier: "transform.center.x") {
                        Self.setCenter($0, horizontal: true, state: state, selection: selection)
                    }
                    MeasureField(title: "Center Y", value: center.map { Self.shownY($0.y, selection: selection) }, units: units, identifier: "transform.center.y") {
                        Self.setCenter(Self.storedY($0, selection: selection), horizontal: false, state: state, selection: selection)
                    }
                }
                Stepper("Copies: \(state.model.copies)", value: $state.model.copies, in: 0...1000).accessibilityIdentifier("transform.copies")
                Toggle("Contents", isOn: $state.model.contents).accessibilityIdentifier("transform.contents")
                Toggle("Fills", isOn: $state.model.fills).accessibilityIdentifier("transform.fills")
                if state.model.tab == .scale {
                    Toggle("Strokes", isOn: $state.model.strokes).accessibilityIdentifier("transform.strokes")
                }
            }
            Button("Apply", action: applyNow)
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
    static func descriptor(selection: ActiveSelection?, state: TransformPanelState? = nil) -> PanelDescriptor {
        PanelDescriptor(id: "transform", title: "Transform", icon: "arrow.up.left.and.arrow.down.right", defaultGroup: PanelCatalog.Group.alignTransform,
                        menuOrder: 51, helpSlug: "transforming") {
            TransformPanelBody(selection: selection, state: state)
        }
    }
}
