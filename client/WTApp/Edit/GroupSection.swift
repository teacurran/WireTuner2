import SwiftUI
import WTCRDT
import WTModel

/// The Object panel's group section (grouping.adoc, "The Object panel"; clipping-paths.adoc, "The
/// Object panel"; OBJ-017 and OBJ-027's UI): *Transform as unit* for the selected groups, the
/// *Contents* row -- how many objects are inside; double-click (or btn:[Select Contents]) subselects
/// them all -- and, for a clip group, its clip path or *No clip path* with *Choose Clip Path…*.
@MainActor
struct GroupSectionModel {
    let panel: ObjectPanelModel
    /// Subselects objects in the front window.
    let select: @MainActor ([OpID]) -> Void

    var state: EngineState { panel.document.state }

    /// Every selected group.
    var groups: [OpID] { panel.objects.map(\.id).filter { state.nodeKind($0) == .group } }

    var transformAsUnit: MixedState { MixedState(groups.map { GroupInspector.transformsAsUnit($0, in: state) }) }

    /// The members the *Contents* row stands for: every selected group's contents.
    var contents: [OpID] { groups.flatMap { GroupInspector.contents(of: $0, in: state) } }

    /// "3 objects".
    var contentsTitle: String {
        let count = contents.count
        return count == 1 ? "1 object" : "\(count) objects"
    }

    /// The one selected clip group, when that is the selection.
    var clipGroup: OpID? {
        let groups = groups
        guard groups.count == 1, ClipGroups.isClipGroup(groups[0], in: state) else { return nil }
        return groups[0]
    }

    /// The clip group's clip path's name, or *No clip path* (dangling or unset).
    var clipPathTitle: String? {
        guard let group = clipGroup else { return nil }
        return ClipGroups.clipPath(of: group, in: state).map { state.displayName(of: $0) } ?? "No clip path"
    }

    /// The clip group's children that could clip, with their names (*Choose Clip Path…*).
    var clipCandidates: [(id: OpID, name: String)] {
        guard let group = clipGroup else { return [] }
        return state.liveChildren(group).filter { ClipGroups.canClip($0, in: state) }.map { ($0, state.displayName(of: $0)) }
    }

    func setTransformAsUnit(_ on: Bool) {
        panel.perform(SetTransformAsUnit(groups, asUnit: on))
    }

    func selectContents() {
        let contents = contents
        if !contents.isEmpty { select(contents) }
    }

    func chooseClipPath(_ path: OpID) {
        guard let group = clipGroup else { return }
        panel.perform(ChooseClipPath(group, path: path))
    }
}

struct GroupSectionView: View {
    let model: GroupSectionModel

    static func asUnit(_ model: GroupSectionModel) -> Binding<Bool> {
        Binding(get: { model.transformAsUnit.isOn }, set: { model.setTransformAsUnit($0) })
    }

    var body: some View {
        Form {
            Toggle("Transform as unit", isOn: Self.asUnit(model))
                .accessibilityIdentifier("object.group.transformAsUnit")
                .accessibilityValue(PathSectionView.accessibilityValue(model.transformAsUnit))
            LabeledContent("Contents", value: model.contentsTitle)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: model.selectContents)
                .accessibilityIdentifier("object.group.contents")
            Button("Select Contents", action: model.selectContents).accessibilityIdentifier("object.group.selectContents")
            if let title = model.clipPathTitle {
                LabeledContent("Clip path", value: title).accessibilityIdentifier("object.group.clipPath")
                Menu("Choose Clip Path…") {
                    ForEach(model.clipCandidates, id: \.id) { candidate in
                        Button(candidate.name) { model.chooseClipPath(candidate.id) }
                    }
                }
                .disabled(model.clipCandidates.isEmpty)
                .accessibilityIdentifier("object.group.chooseClipPath")
            }
        }
        .padding(.horizontal)
    }
}

enum GroupSection {
    /// The section, subselecting through `select`.
    static func section(select: @escaping @MainActor ([OpID]) -> Void) -> InspectorSection {
        InspectorSection(id: "group", order: 45, kinds: [.group]) { panel in
            let model = GroupSectionModel(panel: panel, select: select)
            return model.groups.isEmpty ? nil : AnyView(GroupSectionView(model: model))
        }
    }
}
