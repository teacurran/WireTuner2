import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// The Object panel's *Alt text* and *Decorative* (names-notes.adoc, "Describing objects for
/// accessibility"; OBJ-040): the alt text applies as you type (each burst once typing pauses, one
/// change, one undo step; input stops at 512 characters) and is kept, greyed, while *Decorative*
/// is on; text blocks read as their text, so the field shows "Read as its text" and is disabled
/// for them (a group is described like any object).  Mixed selections show `Mixed`.
extension ObjectPanelModel {
    struct DescriptionSection: Equatable {
        let nodes: [OpID]
        /// The alt text the objects share; nil when mixed.
        let alt: String?
        let decorative: MixedState
        /// Every selected object is a text block.
        let readsAsText: Bool
    }

    var description: DescriptionSection? {
        let objects = objects
        guard !objects.isEmpty else { return nil }
        let state = document.state
        let commons = objects.map { NavigationFields.common(of: $0.id, in: state) ?? .init() }
        let alts = Set(commons.map(\.alt))
        return DescriptionSection(nodes: objects.map(\.id), alt: alts.count == 1 ? alts.first : nil, decorative: MixedState(commons.map(\.decorative)),
                                  readsAsText: objects.allSatisfy { $0.object.kind == .text })
    }

    func setAlt(_ alt: String) -> (any WTModel.Command)? {
        description.map { SetAlt($0.nodes, alt: alt) }
    }

    func setDecorative(_ decorative: Bool) -> (any WTModel.Command)? {
        description.map { SetDecorative($0.nodes, decorative: decorative) }
    }
}

/// The fields, on the Object panel's common section (the root row) after *Note*.
struct DescriptionFieldsView: View {
    let section: ObjectPanelModel.DescriptionSection
    let model: ObjectPanelModel

    static let readsAsText = "Read as its text"

    static func alt(_ model: ObjectPanelModel) -> (String) -> Void {
        { model.perform(model.setAlt($0)) }
    }

    static func decorative(_ section: ObjectPanelModel.DescriptionSection, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { section.decorative.isOn }, set: { model.perform(model.setDecorative($0)) })
    }

    var body: some View {
        Group {
            if section.readsAsText {
                TextField("Alt text", text: .constant(""), prompt: Text(Self.readsAsText)).disabled(true).accessibilityIdentifier("object.alt")
            } else {
                IdleTextField(title: "Alt text", value: section.alt, limit: DescriptionFields.maxAlt, multiline: true, identifier: "object.alt",
                              commit: Self.alt(model))
                    .disabled(section.decorative.isOn)
            }
            Toggle("Decorative", isOn: Self.decorative(section, model))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("object.decorative")
                .accessibilityValue(PathSectionView.accessibilityValue(section.decorative))
        }
    }
}

/// VoiceOver on the canvas (names-notes.adoc, OBJ-040): the selection's readable objects described
/// -- a group with alt text as one figure, a text block by its text, decorative objects left out --
/// as the canvas's accessibility help.
enum CanvasDescriptions {
    static func description(of selection: Selection, in state: EngineState) -> String {
        state.readableNodes(Objects.stackingOrder(selection.ids.map(\.opID), in: state))
            .compactMap { state.accessibleDescription(of: $0) ?? state.displayName(of: $0) }
            .joined(separator: "; ")
    }

    @MainActor
    static func update(_ window: DocumentWindowController) {
        let text = description(of: window.selection.selection, in: window.documentHandle.state)
        if window.canvas.accessibilityHelp() != text { window.canvas.setAccessibilityHelp(text) }
    }
}
