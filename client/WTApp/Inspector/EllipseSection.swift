import SwiftUI
import WTCRDT
import WTModel

/// The Object panel's ellipse row (DRAW-061, object-panel.adoc "Properties by kind",
/// rectangles-ellipses-lines.adoc "Arcs"): *Start angle* and *End angle* in degrees and *Closed*,
/// each written as its own register on every selected ellipse (`SetEllipseArc`).
extension ObjectPanelModel {
    struct EllipseSection: Equatable {
        var nodes: [OpID]
        var start: Double?
        var end: Double?
        var closed: MixedState
    }

    /// The ellipse section when every selected object is an ellipse.
    var ellipse: EllipseSection? {
        let objects = objects
        guard !objects.isEmpty, objects.allSatisfy({ $0.object.kind == .ellipse }) else { return nil }
        let arcs = objects.map { EllipseArc(document.state.props($0.id).ellipse) }
        return EllipseSection(nodes: objects.map(\.id), start: shared(arcs.map(\.start)), end: shared(arcs.map(\.end)),
                              closed: MixedState(arcs.map { !$0.open }))
    }

    func setArc(start: Double? = nil, end: Double? = nil, open: Bool? = nil) -> (any WTModel.Command)? {
        guard let section = ellipse else { return nil }
        return SetEllipseArc(section.nodes, start: start, end: end, open: open)
    }
}

struct EllipseSectionView: View {
    let section: ObjectPanelModel.EllipseSection
    let model: ObjectPanelModel

    static func angle(_ model: ObjectPanelModel, end: Bool) -> (Double) -> Void {
        { model.perform(end ? model.setArc(end: $0) : model.setArc(start: $0)) }
    }

    static func closed(_ section: ObjectPanelModel.EllipseSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.closed.isOn }, set: { model.perform(model.setArc(open: !$0)) })
    }

    var body: some View {
        Form {
            CommitField(title: "Start angle", value: section.start, identifier: "object.ellipse.start", commit: Self.angle(model, end: false))
            CommitField(title: "End angle", value: section.end, identifier: "object.ellipse.end", commit: Self.angle(model, end: true))
            Toggle("Closed", isOn: Self.closed(section, model)).accessibilityIdentifier("object.ellipse.closed")
        }
        .padding(.horizontal)
    }
}
