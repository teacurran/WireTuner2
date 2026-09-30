import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// A checkbox value over several objects: all on, all off, or mixed.
enum MixedState: Equatable, Sendable {
    case on, off, mixed

    init(_ values: [Bool]) {
        if values.allSatisfy({ $0 }) {
            self = .on
        } else if values.allSatisfy({ !$0 }) {
            self = .off
        } else {
            self = .mixed
        }
    }

    var isOn: Bool { self == .on }
}

/// What the Object panel's path and point sections show for the front window's selection
/// (vector-basics.adoc, "Path properties in the Object panel"; DRAW-004), and the commands its
/// controls perform.  A value computed from the document and the selection on every read, so the
/// panel never caches document state and a remote change shows at once.
@MainActor
struct ObjectPanelModel {
    /// The path section: every selected path (rectangles and ellipses have their own section).
    struct PathSection: Equatable {
        var nodes: [OpID]
        var closed: MixedState
        var evenOdd: MixedState
        /// The flatness all selected paths share; nil when they differ.
        var flatness: Double?
        var points: Int
    }

    /// One selected point: its object, contour and id.
    struct PointTarget: Hashable {
        var node: OpID
        var contour: OpID
        var point: OpID
    }

    /// The point section: every selected point of the selected paths and live shapes (D-078).
    struct PointSection: Equatable {
        var points: [PointTarget]
        /// The type every selected point has; nil when they differ.
        var kind: PointKind?
        /// The types the selected points have (the menus' dash on the types some have).
        var kinds: Set<PointKind>
        var automatic: MixedState
        /// The anchor in pasteboard coordinates; nil when more than one point is selected.
        var location: Point?
        /// A curve point whose handles a merge left non-collinear.
        var handlesUnlinked: Bool

        /// The one selected point, when only one is.
        var single: PointTarget? { points.count == 1 ? points[0] : nil }
    }

    let document: DocumentHandle
    let selection: Selection
    /// The front window's Text tool session, if it is editing (the Text section formats its
    /// selection).
    var textSession: TextEditingSession?

    /// The selected path objects with their geometry.
    private var paths: [(id: OpID, props: VectorPath)] {
        selection.ids.compactMap { id in
            guard let object = document.object(for: id), object.kind == .path, let path = object.path else { return nil }
            return (id.opID, path)
        }
    }

    var path: PathSection? {
        let paths = paths
        guard !paths.isEmpty else { return nil }
        let contours = paths.flatMap(\.props.contours)
        let flatness = Set(paths.map(\.props.flatness))
        return PathSection(
            nodes: paths.map(\.id), closed: MixedState(contours.map(\.closed)), evenOdd: MixedState(paths.map(\.props.evenOdd)),
            flatness: flatness.count == 1 ? flatness.first : nil, points: paths.reduce(0) { $0 + $1.props.pointCount }
        )
    }

    var point: PointSection? {
        let references = selection.ids.flatMap { id -> [PointReference] in
            if case let .points(points) = selection.subSelection(of: id) { return points.sorted() }
            return []
        }
        var targets: [PointTarget] = []
        var values: [(point: VectorPoint, location: Point)] = []
        for reference in references {
            guard let object = document.object(for: SelectionID(reference.node)), PointEditing.editsPoints(of: object),
                  let contour = object.path?.contour(reference.contour),
                  let point = contour.drawn.first(where: { $0.id == reference.point }) else { continue }
            targets.append(PointTarget(node: object.id, contour: contour.id, point: point.id))
            values.append((point, object.transform.apply(point.anchor)))
        }
        guard !targets.isEmpty else { return nil }
        let kinds = Set(values.map(\.point.kind))
        return PointSection(
            points: targets, kind: kinds.count == 1 ? kinds.first : nil, kinds: kinds, automatic: MixedState(values.map(\.point.automatic)),
            location: values.count == 1 ? values[0].location : nil, handlesUnlinked: values.contains { $0.point.handlesUnlinked }
        )
    }

    /// One command per object over the selected points (`make` gets the object and its points),
    /// batched as one change labelled `label` when the points are on several objects.
    private func pointCommand(
        _ label: String, _ make: (OpID, [(contour: OpID, point: OpID)]) -> any WTModel.Command
    ) -> (any WTModel.Command)? {
        guard let point else { return nil }
        var order: [OpID] = []
        var byNode: [OpID: [(contour: OpID, point: OpID)]] = [:]
        for target in point.points {
            if byNode[target.node] == nil { order.append(target.node) }
            byNode[target.node, default: []].append((target.contour, target.point))
        }
        let commands = order.map { make($0, byNode[$0] ?? []) }
        return commands.count == 1 ? commands[0] : CommandBatch(label, commands)
    }

    // MARK: Commands (one change each)

    func setClosed(_ closed: Bool) -> (any WTModel.Command)? {
        guard let path else { return nil }
        return CommandBatch(closed ? "Close Path" : "Open Path", path.nodes.map { SetClosed(node: $0, closed: closed) })
    }

    func setEvenOdd(_ evenOdd: Bool) -> (any WTModel.Command)? {
        guard let path else { return nil }
        return CommandBatch("Even/Odd Fill", path.nodes.map { SetEvenOdd(node: $0, evenOdd: evenOdd) })
    }

    func setFlatness(_ flatness: Double) -> (any WTModel.Command)? {
        guard let path, flatness >= 0, flatness.isFinite else { return nil }
        return CommandBatch("Flatness", path.nodes.map { SetFlatness(node: $0, flatness: flatness) })
    }

    /// Sets every selected point's type, one change "Set Point Type".
    func setKind(_ kind: PointKind) -> (any WTModel.Command)? {
        pointCommand("Set Point Type") { SetPointKind(node: $0, points: $1, kind: kind) }
    }

    /// Retracts both handles of every selected point, one change "Retract Handles".
    func retractHandles() -> (any WTModel.Command)? {
        pointCommand("Retract Handles") { RetractHandles(node: $0, points: $1) }
    }

    /// Sets every selected point's *Automatic*, one change "Automatic".
    func setAutomatic(_ automatic: Bool) -> (any WTModel.Command)? {
        pointCommand("Automatic") { SetAutomatic(node: $0, points: $1, automatic: automatic) }
    }

    /// Moves the point to `location` (pasteboard coordinates).
    func setLocation(_ location: Point) -> (any WTModel.Command)? {
        guard let point = point?.single, location.isFinite, let object = document.object(for: SelectionID(point.node)),
              let local = object.transform.inverted()?.apply(location) else { return nil }
        return MovePoints(node: point.node, contour: point.contour, point: point.point, to: local)
    }

    /// Performs `command` on the document, if there is one.
    @discardableResult
    func perform(_ command: (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        command.map { document.perform($0) }
    }
}

/// The path section: Closed, Even/odd fill, Flatness, Points.
struct PathSectionView: View {
    let section: ObjectPanelModel.PathSection
    let model: ObjectPanelModel

    /// *Closed*: reads the section, writes one change through the model.
    static func closed(_ section: ObjectPanelModel.PathSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.closed.isOn }, set: { model.perform(model.setClosed($0)) })
    }

    static func evenOdd(_ section: ObjectPanelModel.PathSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.evenOdd.isOn }, set: { model.perform(model.setEvenOdd($0)) })
    }

    static func flatness(_ model: ObjectPanelModel) -> (Double) -> Void {
        { model.perform(model.setFlatness($0)) }
    }

    /// The accessibility value of a mixed-state checkbox.
    static func accessibilityValue(_ state: MixedState) -> String {
        switch state {
        case .on: "on"
        case .off: "off"
        case .mixed: "mixed"
        }
    }

    var body: some View {
        Form {
            Toggle("Closed", isOn: Self.closed(section, model))
                .accessibilityIdentifier("object.path.closed")
                .accessibilityValue(Self.accessibilityValue(section.closed))
            Toggle("Even/odd fill", isOn: Self.evenOdd(section, model))
                .accessibilityIdentifier("object.path.even-odd")
            CommitField(title: "Flatness", value: section.flatness, identifier: "object.path.flatness", commit: Self.flatness(model))
            LabeledContent("Points", value: "\(section.points)")
                .accessibilityIdentifier("object.path.points")
        }
        .padding(.horizontal)
    }
}

/// The point section: type buttons, Retract handles, Automatic, and X and Y for one point.  With
/// several points selected a value they do not share shows as mixed (no type button chosen, the
/// Automatic box with a dash) and a control sets it on all of them.
struct PointSectionView: View {
    let section: ObjectPanelModel.PointSection
    let model: ObjectPanelModel

    static let kinds: [(PointKind, String)] = PointTypeCommands.kinds.map { ($0.kind, $0.title) }

    /// The type buttons: the shared type, or none chosen when the points differ.
    static func kind(_ section: ObjectPanelModel.PointSection, _ model: ObjectPanelModel) -> Binding<PointKind?> {
        Binding(get: { section.kind }, set: { kind in if let kind { model.perform(model.setKind(kind)) } })
    }

    /// *Automatic*: on when every point has it; setting it from mixed turns it on for all.
    static func automatic(_ section: ObjectPanelModel.PointSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.automatic.isOn }, set: { model.perform(model.setAutomatic($0)) })
    }

    static func retract(_ model: ObjectPanelModel) -> () -> Void {
        { model.perform(model.retractHandles()) }
    }

    /// Commits a typed X (`horizontal`) or Y at the section's other coordinate.
    static func location(_ section: ObjectPanelModel.PointSection, _ model: ObjectPanelModel, horizontal: Bool) -> (Double) -> Void {
        { value in
            guard let current = section.location else { return }
            let location = horizontal ? Point(x: value, y: current.y) : Point(x: current.x, y: value)
            model.perform(model.setLocation(location))
        }
    }

    var body: some View {
        Form {
            Picker("Type", selection: Self.kind(section, model)) {
                ForEach(Self.kinds, id: \.0) { kind, title in Text(title).tag(Optional(kind)) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("object.point.kind")
            .accessibilityValue(section.kind == nil ? "mixed" : "")
            if section.handlesUnlinked {
                Text("Handles unlinked").font(.caption).foregroundStyle(.secondary)
            }
            Button("Retract Handles", action: Self.retract(model))
                .accessibilityIdentifier("object.point.retract")
            Toggle("Automatic", isOn: Self.automatic(section, model))
                .accessibilityIdentifier("object.point.automatic")
                .accessibilityValue(PathSectionView.accessibilityValue(section.automatic))
            if let location = section.location {
                CommitField(title: "X", value: location.x, identifier: "object.point.x", commit: Self.location(section, model, horizontal: true))
                CommitField(title: "Y", value: location.y, identifier: "object.point.y", commit: Self.location(section, model, horizontal: false))
            } else {
                LabeledContent("Points", value: "\(section.points.count)")
                    .accessibilityIdentifier("object.point.count")
            }
        }
        .padding(.horizontal)
    }
}
