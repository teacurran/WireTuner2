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

    /// The point section: exactly one point selected.
    struct PointSection: Equatable {
        var node: OpID
        var contour: OpID
        var point: OpID
        var kind: PointKind
        var automatic: Bool
        /// The anchor in pasteboard coordinates.
        var location: Point
        /// A curve point whose handles a merge left non-collinear.
        var handlesUnlinked: Bool
    }

    let document: DocumentHandle
    let selection: Selection

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
            if case let .points(points) = selection.subSelection(of: id) { return Array(points) }
            return []
        }
        guard references.count == 1, let reference = references.first, let object = document.object(for: SelectionID(reference.node)),
              object.kind == .path, let contour = object.path?.contour(reference.contour),
              let point = contour.drawn.first(where: { $0.id == reference.point }) else { return nil }
        return PointSection(
            node: object.id, contour: contour.id, point: point.id, kind: point.kind, automatic: point.automatic,
            location: object.transform.apply(point.anchor), handlesUnlinked: point.handlesUnlinked
        )
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

    func setKind(_ kind: PointKind) -> (any WTModel.Command)? {
        guard let point else { return nil }
        return SetPointKind(node: point.node, points: [(point.contour, point.point)], kind: kind)
    }

    func retractHandles() -> (any WTModel.Command)? {
        guard let point else { return nil }
        return RetractHandles(node: point.node, points: [(point.contour, point.point)])
    }

    func setAutomatic(_ automatic: Bool) -> (any WTModel.Command)? {
        guard let point else { return nil }
        return SetAutomatic(node: point.node, points: [(point.contour, point.point)], automatic: automatic)
    }

    /// Moves the point to `location` (pasteboard coordinates).
    func setLocation(_ location: Point) -> (any WTModel.Command)? {
        guard let point, location.isFinite, let object = document.object(for: SelectionID(point.node)),
              let local = object.transform.inverted()?.apply(location) else { return nil }
        return MovePoints(node: point.node, contour: point.contour, point: point.point, to: local)
    }

    /// Performs `command` on the document, if there is one.
    @discardableResult
    func perform(_ command: (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        command.map { document.perform($0) }
    }
}

/// The Object panel: the selection summary, then the path section and, with one point selected,
/// the point section.  It observes the active selection and the front document's revision, so a
/// remote change to the selected path updates it; a number field being edited keeps its text
/// until it is committed (client.adoc, "Panels").
struct ObjectPanelBody: View {
    let selection: ActiveSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SelectionSummaryBody(selection: selection)
            if let line = selection?.editingLine {
                Text(line).font(.caption).italic().foregroundStyle(.secondary).padding(.horizontal).accessibilityIdentifier("object.editingBy")
            }
            if let model = model {
                if let path = model.path { PathSectionView(section: path, model: model) }
                if let point = model.point { PointSectionView(section: point, model: model) }
                if let rectangle = model.rectangle { RectangleSectionView(section: rectangle, model: model) }
                if let polygon = model.polygon { PolygonSectionView(section: polygon, model: model) }
                if let common = model.common { CommonSectionView(section: common, model: model) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var model: ObjectPanelModel? {
        guard let document = selection?.document, let selectionModel = selection?.model else { return nil }
        _ = document.model?.revision
        return ObjectPanelModel(document: document, selection: selectionModel.selection)
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

/// The point section: type buttons, Retract handles, Automatic, X and Y.
struct PointSectionView: View {
    let section: ObjectPanelModel.PointSection
    let model: ObjectPanelModel

    static let kinds: [(PointKind, String)] = [(.corner, "Corner"), (.curve, "Curve"), (.connector, "Connector")]

    static func kind(_ section: ObjectPanelModel.PointSection, _ model: ObjectPanelModel) -> Binding<PointKind> {
        Binding(get: { section.kind }, set: { model.perform(model.setKind($0)) })
    }

    static func automatic(_ section: ObjectPanelModel.PointSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.automatic }, set: { model.perform(model.setAutomatic($0)) })
    }

    static func retract(_ model: ObjectPanelModel) -> () -> Void {
        { model.perform(model.retractHandles()) }
    }

    /// Commits a typed X (`horizontal`) or Y at the section's other coordinate.
    static func location(_ section: ObjectPanelModel.PointSection, _ model: ObjectPanelModel, horizontal: Bool) -> (Double) -> Void {
        { value in
            let location = horizontal ? Point(x: value, y: section.location.y) : Point(x: section.location.x, y: value)
            model.perform(model.setLocation(location))
        }
    }

    var body: some View {
        Form {
            Picker("Type", selection: Self.kind(section, model)) {
                ForEach(Self.kinds, id: \.0) { kind, title in Text(title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("object.point.kind")
            if section.handlesUnlinked {
                Text("Handles unlinked").font(.caption).foregroundStyle(.secondary)
            }
            Button("Retract Handles", action: Self.retract(model))
                .accessibilityIdentifier("object.point.retract")
            Toggle("Automatic", isOn: Self.automatic(section, model))
                .accessibilityIdentifier("object.point.automatic")
            CommitField(title: "X", value: section.location.x, identifier: "object.point.x", commit: Self.location(section, model, horizontal: true))
            CommitField(title: "Y", value: section.location.y, identifier: "object.point.y", commit: Self.location(section, model, horizontal: false))
        }
        .padding(.horizontal)
    }
}

/// A number field that holds its text while focused and commits on Return; a value arriving from
/// elsewhere while it edits does not replace the text.
struct CommitField: View {
    let title: String
    let value: Double?
    let identifier: String
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onSubmit { Self.submit(text, commit) }
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { _, new in text = Self.shown(text, new, focused: focused) }
            .accessibilityIdentifier(identifier)
    }

    /// Commits `text` when it is a number; anything else is ignored.
    static func submit(_ text: String, _ commit: (Double) -> Void) {
        Double(text).map(commit)
    }

    /// The text to show after the value changed to `value`: kept while the field is focused.
    static func shown(_ text: String, _ value: Double?, focused: Bool) -> String {
        focused ? text : format(value)
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...3)))
    }
}
