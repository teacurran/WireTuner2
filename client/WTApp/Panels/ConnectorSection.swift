import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Object panel's connector section (connectors.adoc, "Object panel"; DRAW-036): with one
/// connector selected, its two ends -- the object each is attached to and the side, or "Free" --
/// and a pop-up per attached end to pick the side (Automatic is the side facing the other end).
/// Picking a side writes the whole end, one change.
extension ObjectPanelModel {
    struct ConnectorSection: Equatable {
        struct End: Equatable {
            let which: ConnectorEndName
            /// The object the end is attached to; nil for a free end (never attached, or its
            /// object gone).
            let node: OpID?
            /// The attached object's name.
            let object: String?
            /// The chosen side; nil for Automatic.
            let side: ConnectorSide?
            /// The end's stored point: where it sits when free.
            let point: Point
        }

        let node: OpID
        let start: End
        let end: End
    }

    /// The section, when exactly one connector is selected.
    var connector: ConnectorSection? {
        guard selection.ids.count == 1, let id = selection.ids.first, document.object(for: id)?.kind == .connector else { return nil }
        let state = document.state
        let layers = LayerOrder(state)
        let props = Connectors.props(id.opID, in: state)
        func end(_ which: ConnectorEndName, _ stored: Wiretuner_Doc_V1_ConnectorEnd) -> ConnectorSection.End {
            let (node, side, point) = Connectors.storedEnd(stored)
            guard let node, Connectors.isAttachable(node, in: state, layers: layers) else {
                return .init(which: which, node: nil, object: nil, side: nil, point: point)
            }
            return .init(which: which, node: node, object: ObjectNaming.name(of: node, in: state), side: side, point: point)
        }
        return ConnectorSection(node: id.opID, start: end(.start, props.start), end: end(.end, props.end))
    }

    /// Attaches end `which` of the selected connector to `side` of its object (nil: Automatic),
    /// with the point there now as the end's free position.  Nil for a free end.
    func setConnectorSide(_ which: ConnectorEndName, _ side: ConnectorSide?) -> (any WTModel.Command)? {
        guard let section = connector else { return nil }
        let (end, other) = which == .start ? (section.start, section.end) : (section.end, section.start)
        guard let node = end.node else { return nil }
        return Connectors.attachmentPoint(of: node, side: side, toward: other.point, in: document.scene).map {
            SetConnectorEnd(section.node, which, to: ConnectorEnd(node: NodeID(node), side: side, point: $0))
        }
    }
}

/// The connector section: Start and End, each the object and a side pop-up, or "Free".
struct ConnectorSectionView: View {
    let section: ObjectPanelModel.ConnectorSection
    let model: ObjectPanelModel

    /// The pop-up's choices: Automatic, then the four sides.
    static let sides: [(side: ConnectorSide?, title: String)] = [(nil, "Automatic"), (.top, "Top"), (.bottom, "Bottom"), (.left, "Left"), (.right, "Right")]

    static func title(_ side: ConnectorSide?) -> String {
        sides.first { $0.side == side }!.title
    }

    /// The side pop-up of `end`: reads the section, writes one change through the model.
    static func side(_ end: ObjectPanelModel.ConnectorSection.End, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { title(end.side) }, set: { chosen in
            model.perform(model.setConnectorSide(end.which, sides.first { $0.title == chosen }.flatMap(\.side)))
        })
    }

    static func label(_ which: ConnectorEndName) -> String { which == .start ? "Start" : "End" }

    var body: some View {
        Form {
            ForEach([section.start, section.end], id: \.which) { end in
                if let object = end.object {
                    LabeledContent(Self.label(end.which), value: object)
                        .accessibilityIdentifier("object.connector.\(end.which).object")
                    Picker("Side", selection: Self.side(end, model)) {
                        ForEach(Self.sides, id: \.title) { Text($0.title).tag($0.title) }
                    }
                    .accessibilityIdentifier("object.connector.\(end.which).side")
                } else {
                    LabeledContent(Self.label(end.which), value: "Free")
                        .accessibilityIdentifier("object.connector.\(end.which).object")
                }
            }
        }
        .padding(.horizontal)
    }
}
