import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Object panel's blend section (blends.adoc, "Adjusting a blend in the Object panel";
/// FX-028): *Steps*, *Range % First* and *Last*, *Blend type* and *Blend order* (composite paths
/// and groups only), *Show path* and *Rotate on path* (joined blends only).  Values are read from
/// the document on every render, so a remote change shows at once; each edit is one `EditBlend`
/// over every selected blend.
@MainActor
struct BlendSectionModel {
    let document: DocumentHandle
    /// The selected blends.
    let nodes: [OpID]

    static let types: [(Wiretuner_Doc_V1_BlendType, String)] = [(.normal, "Normal"), (.horizontal, "Horizontal"), (.vertical, "Vertical")]
    static let orders: [(Wiretuner_Doc_V1_BlendOrder, String)] = [(.positional, "Positional"), (.stacking, "Stacking")]

    /// The section when every selected object is a blend.
    init?(_ panel: ObjectPanelModel) {
        let objects = panel.objects
        guard !objects.isEmpty, objects.allSatisfy({ $0.object.kind == .blend }) else { return nil }
        document = panel.document
        nodes = objects.map(\.id)
    }

    private var props: [Wiretuner_Doc_V1_BlendProps] { nodes.map { document.state.props($0).blend } }

    /// 0 (never set) is chosen from the colour difference.
    var steps: Double? { shared(props.map { Double($0.steps) }) }
    var rangeFirst: Double? { shared(props.map(\.rangeFirst)) }
    /// 0 (never set) reads 100.
    var rangeLast: Double? { shared(props.map { $0.rangeLast == 0 ? 100 : $0.rangeLast }) }
    var type: Wiretuner_Doc_V1_BlendType? { shared(props.map { $0.type == .unspecified ? .normal : $0.type }) }
    var order: Wiretuner_Doc_V1_BlendOrder? { shared(props.map { $0.order == .unspecified ? .positional : $0.order }) }
    var showPath: MixedState { MixedState(props.map(\.showPath)) }
    var rotateOnPath: MixedState { MixedState(props.map(\.rotateOnPath)) }

    /// Joined blends only: every selected blend follows a path.
    var isJoined: Bool {
        let state = document.state
        return nodes.allSatisfy { node in BlendReading.path(state.props(node).blend, children: state.liveChildren(node), in: state) != nil }
    }

    /// Composite paths and groups only: every selected blend's key objects are composite paths or
    /// groups.
    var isComposite: Bool {
        let state = document.state
        return nodes.allSatisfy { blend in
            BlendReading.keyObjects(blend, in: state).allSatisfy { key in
                state.nodeKind(key) == .group || (state.nodeKind(key) == .path && state.props(key).path.contours.count > 1)
            }
        }
    }

    func edit(_ label: String, _ field: RegisterPath, _ build: (inout Wiretuner_Doc_V1_BlendProps) -> Void) -> any WTModel.Command {
        EditBlend(nodes, label: label, fields: [field], build)
    }

    /// 1 ... 1000.
    func setSteps(_ steps: Double) -> any WTModel.Command { EditBlend.steps(nodes, Int(steps.rounded())) }
    func setRangeFirst(_ value: Double) -> any WTModel.Command { edit("Change range", BlendFields.rangeFirst) { $0.rangeFirst = min(max(value, 0), 100) } }
    func setRangeLast(_ value: Double) -> any WTModel.Command { edit("Change range", BlendFields.rangeLast) { $0.rangeLast = min(max(value, 0), 100) } }
    func setType(_ type: Wiretuner_Doc_V1_BlendType) -> any WTModel.Command { edit("Change blend type", BlendFields.type) { $0.type = type } }
    func setOrder(_ order: Wiretuner_Doc_V1_BlendOrder) -> any WTModel.Command { edit("Change blend order", BlendFields.order) { $0.order = order } }
    func setShowPath(_ on: Bool) -> any WTModel.Command { edit("Show path", BlendFields.showPath) { $0.showPath = on } }
    func setRotateOnPath(_ on: Bool) -> any WTModel.Command { edit("Rotate on path", BlendFields.rotateOnPath) { $0.rotateOnPath = on } }

    func committing<Value>(_ command: @escaping (Value) -> any WTModel.Command) -> (Value) -> Void {
        { [document] value in document.perform(command(value)) }
    }

    func binding(_ state: MixedState, _ command: @escaping (Bool) -> any WTModel.Command) -> Binding<Bool> {
        Binding(get: { state.isOn }, set: { [document] value in document.perform(command(value)) })
    }
}

struct BlendSectionView: View {
    let model: BlendSectionModel

    var body: some View {
        Form {
            CommitField(title: "Steps", value: model.steps, identifier: "object.blend.steps", commit: model.committing(model.setSteps))
            if model.steps == 0 {
                Text("Chosen from the color difference").font(.caption).foregroundStyle(.secondary)
            }
            CommitField(title: "Range % First", value: model.rangeFirst, identifier: "object.blend.range-first", commit: model.committing(model.setRangeFirst))
            CommitField(title: "Last", value: model.rangeLast, identifier: "object.blend.range-last", commit: model.committing(model.setRangeLast))
            AttributePicker(title: "Blend type", value: model.type, choices: BlendSectionModel.types, identifier: "object.blend.type",
                            commit: model.committing(model.setType))
                .disabled(!model.isComposite)
            AttributePicker(title: "Blend order", value: model.order, choices: BlendSectionModel.orders, identifier: "object.blend.order",
                            commit: model.committing(model.setOrder))
                .disabled(!model.isComposite)
            Toggle("Show path", isOn: model.binding(model.showPath, model.setShowPath))
                .accessibilityIdentifier("object.blend.show-path")
                .disabled(!model.isJoined)
            Toggle("Rotate on path", isOn: model.binding(model.rotateOnPath, model.setRotateOnPath))
                .accessibilityIdentifier("object.blend.rotate-on-path")
                .disabled(!model.isJoined)
        }
        .padding(.horizontal)
    }
}
