import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

extension LengthUnit {
    /// The nearest `MeasureUnit` (the older field parser's): kyus read as millimetres and a
    /// custom unit as points.  Fields that know the document read `Units` instead
    /// (`MeasureField(units:)`, the `documentUnits` environment value), which has every unit.
    var measureUnit: MeasureUnit {
        switch self {
        case .points, .custom: .points
        case .picas: .picas
        case .inches: .inches
        case .decimalInches: .decimalInches
        case .millimeters, .kyus: .millimeters
        case .centimeters: .centimeters
        case .pixels: .pixels
        }
    }
}

/// The value several objects share, or nil when they differ (the `Mixed` display rule,
/// object-panel.adoc "Mixed selections").
func shared<T: Equatable>(_ values: [T]) -> T? {
    guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
    return first
}

/// The Object panel's root-row sections (OBJ-002, OBJ-003, DRAW-009, DRAW-012): the common
/// attributes of every selected object, and the rectangle and polygon sections when every selected
/// object is one.  Values are read from the document on every access; edits are one change each,
/// fanned out over the selection.
extension ObjectPanelModel {
    /// X, Y, W, H (the bounding box, pasteboard space), name, note, locked.
    struct CommonSection: Equatable {
        var nodes: [OpID]
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var name: String?
        var note: String?
        var locked: MixedState
    }

    /// Every selected rectangle's corners.
    struct RectangleSection: Equatable {
        var nodes: [OpID]
        /// The top-left radius (what Uniform shows for every corner); nil when mixed.
        var radius: Double?
        var uniform: MixedState
        var topLeft: Double?
        var topRight: Double?
        var bottomRight: Double?
        var bottomLeft: Double?
    }

    /// Every selected polygon's fields (rotation in degrees).
    struct PolygonSection: Equatable {
        var nodes: [OpID]
        var sides: Int?
        var star: MixedState
        var radius: Double?
        var innerRadius: Double?
        var automatic: MixedState
        var rotationDegrees: Double?
    }

    /// The selected objects, top-level or subselected members.
    var objects: [(id: OpID, object: SceneObject)] {
        selection.ids.compactMap { id in document.object(for: id).map { (id.opID, $0) } }
    }

    var common: CommonSection? {
        let objects = objects
        guard !objects.isEmpty else { return nil }
        let state = document.state
        let bounds = objects.map { Objects.bounds(of: $0.id, in: state) }
        let props = objects.map { PanelProps.common(state.props($0.id)) }
        return CommonSection(
            nodes: objects.map(\.id), x: shared(bounds.map { $0?.minX }) ?? nil, y: shared(bounds.map { $0?.minY }) ?? nil,
            width: shared(bounds.map { $0?.width }) ?? nil, height: shared(bounds.map { $0?.height }) ?? nil,
            name: shared(props.map(\.name)), note: shared(props.map(\.note)), locked: MixedState(props.map(\.locked))
        )
    }

    var rectangle: RectangleSection? {
        let objects = objects
        guard !objects.isEmpty, objects.allSatisfy({ $0.object.kind == .rect }) else { return nil }
        let corners = objects.map { document.state.props($0.id).rect.corners }
        return RectangleSection(
            nodes: objects.map(\.id), radius: shared(corners.map(\.topLeft)), uniform: MixedState(corners.map(\.uniform)),
            topLeft: shared(corners.map(\.topLeft)), topRight: shared(corners.map { $0.uniform ? $0.topLeft : $0.topRight }),
            bottomRight: shared(corners.map { $0.uniform ? $0.topLeft : $0.bottomRight }),
            bottomLeft: shared(corners.map { $0.uniform ? $0.topLeft : $0.bottomLeft })
        )
    }

    var polygon: PolygonSection? {
        let objects = objects
        guard !objects.isEmpty, objects.allSatisfy({ $0.object.kind == .polygon }) else { return nil }
        let shapes = objects.map { PolygonShape(document.state.props($0.id).polygon) }
        return PolygonSection(
            nodes: objects.map(\.id), sides: shared(shapes.map(\.sides)), star: MixedState(shapes.map(\.star)), radius: shared(shapes.map(\.radius)),
            innerRadius: shared(shapes.map(\.innerRadius)), automatic: MixedState(shapes.map(\.autoInner)),
            rotationDegrees: shared(shapes.map { $0.rotation * 180 / .pi })
        )
    }

    /// The document's unit for the numeric fields.
    var unit: MeasureUnit { document.units.measureUnit }

    // MARK: Common edits

    /// Typing X or Y: each object moves so its box starts there -- one `transform` write each,
    /// labelled "Move" (or "Move N objects").
    func setPosition(x: Double? = nil, y: Double? = nil) -> (any WTModel.Command)? {
        let state = document.state
        let moves = objects.compactMap { entry -> (any WTModel.Command)? in
            guard let bounds = Objects.bounds(of: entry.id, in: state) else { return nil }
            let delta = Vector(dx: x.map { $0 - bounds.minX } ?? 0, dy: y.map { $0 - bounds.minY } ?? 0)
            return MoveObjects([entry.id], by: delta)
        }
        guard !moves.isEmpty else { return nil }
        return CompositeCommand(Objects.label("Move", count: moves.count), moves)
    }

    /// Typing W or H: each object scales about its box's top-left corner; with the proportion lock
    /// both dimensions scale together.
    func setSize(width: Double? = nil, height: Double? = nil, proportional: Bool) -> (any WTModel.Command)? {
        let state = document.state
        let scales = objects.compactMap { entry -> (any WTModel.Command)? in
            guard let bounds = Objects.bounds(of: entry.id, in: state), bounds.width > 0 || bounds.height > 0 else { return nil }
            var sx = width.map { bounds.width > 0 ? max($0, Measure.resolution) / bounds.width : 1 } ?? 1
            var sy = height.map { bounds.height > 0 ? max($0, Measure.resolution) / bounds.height : 1 } ?? 1
            if proportional { (sx, sy) = width != nil ? (sx, sx) : (sy, sy) }
            return TransformObjects([entry.id], matrix: .scale(x: sx, y: sy), about: Point(x: bounds.minX, y: bounds.minY), kind: .scale)
        }
        guard !scales.isEmpty else { return nil }
        return CompositeCommand(Objects.label("Scale", count: scales.count), scales)
    }

    func setName(_ name: String) -> (any WTModel.Command)? {
        common.map { SetNameOrNote($0.nodes, .name, name) }
    }

    func setNote(_ note: String) -> (any WTModel.Command)? {
        common.map { SetNameOrNote($0.nodes, .note, note) }
    }

    func setLocked(_ locked: Bool) -> (any WTModel.Command)? {
        common.map { SetLocked($0.nodes, locked: locked) }
    }

    // MARK: Rectangle edits

    /// *Radius*: every corner of every rectangle (with Uniform, what Uniform shows).
    func setRadius(_ radius: Double, corners: [Corner] = Corner.allCases) -> (any WTModel.Command)? {
        guard let rectangle, radius >= 0, radius.isFinite else { return nil }
        return SetCornerRadius(rectangle.nodes, radius: radius, corners: corners)
    }

    /// *Uniform*: on writes all four radii from the top-left one.
    func setUniform(_ uniform: Bool) -> (any WTModel.Command)? {
        guard let rectangle else { return nil }
        return SetCornerRadius(rectangle.nodes, radius: uniform ? rectangle.topLeft ?? 0 : nil, uniform: uniform)
    }

    // MARK: Polygon edits

    func setPolygon(_ values: SetPolygonFields.Values, label: String) -> (any WTModel.Command)? {
        polygon.map { SetPolygonFields($0.nodes, values, label: $0.nodes.count > 1 ? "\(label) of \($0.nodes.count) objects" : label) }
    }
}

enum PanelProps {
    /// The common props the panel shows, empty for a node without them.
    static func common(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_CommonProps {
        switch props.kind {
        case .path(let path)?: path.common
        case .rect(let rect)?: rect.common
        case .ellipse(let ellipse)?: ellipse.common
        case .polygon(let polygon)?: polygon.common
        case .group(let group)?: group.common
        default: Wiretuner_Doc_V1_CommonProps()
        }
    }
}

/// The common attributes: X, Y, W, H with the proportion lock, Name, Note, Locked.
struct CommonSectionView: View {
    let section: ObjectPanelModel.CommonSection
    let model: ObjectPanelModel
    @State private var proportional = false

    static func position(_ model: ObjectPanelModel, horizontal: Bool) -> (Double) -> Void {
        { value in model.perform(horizontal ? model.setPosition(x: value) : model.setPosition(y: value)) }
    }

    static func size(_ model: ObjectPanelModel, horizontal: Bool, proportional: Bool) -> (Double) -> Void {
        { value in
            model.perform(horizontal ? model.setSize(width: value, proportional: proportional) : model.setSize(height: value, proportional: proportional))
        }
    }

    static func name(_ model: ObjectPanelModel) -> (String) -> Void {
        { model.perform(model.setName($0)) }
    }

    static func note(_ model: ObjectPanelModel) -> (String) -> Void {
        { model.perform(model.setNote($0)) }
    }

    static func locked(_ section: ObjectPanelModel.CommonSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.locked.isOn }, set: { model.perform(model.setLocked($0)) })
    }

    var body: some View {
        Form {
            MeasureField(title: "X", value: section.x, unit: model.unit, identifier: "object.x", commit: Self.position(model, horizontal: true))
            MeasureField(title: "Y", value: section.y, unit: model.unit, identifier: "object.y", commit: Self.position(model, horizontal: false))
            MeasureField(title: "W", value: section.width, unit: model.unit, identifier: "object.w", commit: Self.size(model, horizontal: true, proportional: proportional))
            MeasureField(title: "H", value: section.height, unit: model.unit, identifier: "object.h", commit: Self.size(model, horizontal: false, proportional: proportional))
            Toggle("Keep proportions", isOn: $proportional).accessibilityIdentifier("object.proportional")
            CommitTextField(title: "Name", value: section.name, identifier: "object.name", commit: Self.name(model))
            CommitTextField(title: "Note", value: section.note, identifier: "object.note", commit: Self.note(model))
            Toggle("Locked", isOn: Self.locked(section, model))
                .accessibilityIdentifier("object.locked")
                .accessibilityValue(PathSectionView.accessibilityValue(section.locked))
        }
        .padding(.horizontal)
    }
}

/// The rectangle section: Radius, Uniform and the four corners.
struct RectangleSectionView: View {
    let section: ObjectPanelModel.RectangleSection
    let model: ObjectPanelModel

    static func radius(_ model: ObjectPanelModel, corners: [Corner] = Corner.allCases) -> (Double) -> Void {
        { model.perform(model.setRadius($0, corners: corners)) }
    }

    static func uniform(_ section: ObjectPanelModel.RectangleSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.uniform.isOn }, set: { model.perform(model.setUniform($0)) })
    }

    var body: some View {
        Form {
            MeasureField(title: "Radius", value: section.radius, unit: model.unit, identifier: "object.rect.radius", commit: Self.radius(model))
            Toggle("Uniform", isOn: Self.uniform(section, model)).accessibilityIdentifier("object.rect.uniform")
            if !section.uniform.isOn {
                MeasureField(title: "Top left", value: section.topLeft, unit: model.unit, identifier: "object.rect.top-left", commit: Self.radius(model, corners: [.topLeft]))
                MeasureField(title: "Top right", value: section.topRight, unit: model.unit, identifier: "object.rect.top-right", commit: Self.radius(model, corners: [.topRight]))
                MeasureField(title: "Bottom right", value: section.bottomRight, unit: model.unit, identifier: "object.rect.bottom-right",
                             commit: Self.radius(model, corners: [.bottomRight]))
                MeasureField(title: "Bottom left", value: section.bottomLeft, unit: model.unit, identifier: "object.rect.bottom-left",
                             commit: Self.radius(model, corners: [.bottomLeft]))
            }
        }
        .padding(.horizontal)
    }
}

/// The polygon section: Sides, Star, Radius, Inner radius with Automatic, Rotation.
struct PolygonSectionView: View {
    let section: ObjectPanelModel.PolygonSection
    let model: ObjectPanelModel

    static func sides(_ model: ObjectPanelModel) -> (Double) -> Void {
        { model.perform(model.setPolygon(.init(sides: Int($0.rounded())), label: "Change sides")) }
    }

    static func star(_ section: ObjectPanelModel.PolygonSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.star.isOn }, set: { model.perform(model.setPolygon(.init(star: $0), label: "Star")) })
    }

    static func automatic(_ section: ObjectPanelModel.PolygonSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.automatic.isOn }, set: { model.perform(model.setPolygon(.init(autoInner: $0), label: "Automatic")) })
    }

    static func radius(_ model: ObjectPanelModel, inner: Bool) -> (Double) -> Void {
        { value in
            model.perform(model.setPolygon(inner ? .init(innerRadius: value) : .init(radius: value), label: inner ? "Change inner radius" : "Change radius"))
        }
    }

    static func rotation(_ model: ObjectPanelModel) -> (Double) -> Void {
        { model.perform(model.setPolygon(.init(rotation: $0 * .pi / 180), label: "Change rotation")) }
    }

    var body: some View {
        Form {
            CommitField(title: "Sides", value: section.sides.map(Double.init), identifier: "object.polygon.sides", commit: Self.sides(model))
            Toggle("Star", isOn: Self.star(section, model)).accessibilityIdentifier("object.polygon.star")
            MeasureField(title: "Radius", value: section.radius, unit: model.unit, identifier: "object.polygon.radius", commit: Self.radius(model, inner: false))
            if section.star.isOn {
                MeasureField(title: "Inner radius", value: section.innerRadius, unit: model.unit, identifier: "object.polygon.inner-radius",
                             commit: Self.radius(model, inner: true))
                Toggle("Automatic", isOn: Self.automatic(section, model)).accessibilityIdentifier("object.polygon.automatic")
            }
            CommitField(title: "Rotation", value: section.rotationDegrees, identifier: "object.polygon.rotation", commit: Self.rotation(model))
        }
        .padding(.horizontal)
    }
}
