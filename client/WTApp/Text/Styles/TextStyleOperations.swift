import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// The Styles panel's text operations (text-styles.adoc, "Creating a text style", "Editing a
/// style", "Style behavior", "Applying a style"; TYPE-035): *New Paragraph Style* and *New
/// Character Style* from the selection -- per *Build text styles based on*, the first paragraph's
/// settings or only those every selected paragraph shares -- or, with nothing selected, as a child
/// of the style chosen; *Redefine…* with its sheet; *Style Behavior…*; and a style dropped on text,
/// which changes the paragraph under the drop or, per *Dragging a text style changes*, the whole
/// block.  They are Text menu items that the Styles panel's menu also lists (the `style` context).
extension ObjectPanelModel {
    /// The settings a style made or redefined from the selection takes: the first targeted
    /// paragraph's (its runs and registers), or what every targeted run and paragraph shares.
    func styleAttributes(firstParagraph: Bool) -> Wiretuner_Doc_V1_TextStyleAttrs {
        guard firstParagraph, let first = targetParagraphs.first else { return sharedTextAttributes }
        let paragraph = first.text.paragraphs[first.index]
        let runs = first.text.runs.filter { $0.range.overlaps(paragraph.range) }.map(\.values)
        return SharedTextAttributes.attrs(runs: runs.isEmpty ? [[]] : runs, paragraphs: [paragraph.props])
    }
}

@MainActor
enum TextStyleOperations {
    enum ID {
        static let newParagraph: CommandID = "text.styles.newParagraph"
        static let newCharacter: CommandID = "text.styles.newCharacter"
        static let redefine: CommandID = "text.styles.redefine"
        static let behavior: CommandID = "text.styles.behavior"
    }

    static let menu = "Styles"
    static let noStyle = "Select text with a style"

    /// Whether *Build text styles based on* asks for the first paragraph.
    static func firstParagraph(_ preferences: PreferenceStore) -> Bool {
        preferences[PreferenceCatalog.Text.styleBasedOn] == "first_paragraph"
    }

    /// *New Paragraph Style* / *New Character Style*: from the selection's text, or a child of
    /// `parent` (the style selected in the panel with nothing selected in the document).
    @discardableResult
    static func newStyle(_ kind: TextStyleKind, model: ObjectPanelModel, firstParagraph: Bool, parent: OpID? = nil) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard model.text != nil else {
            guard let parent else { return nil }
            return model.perform(CreateTextStyle(kind, attrs: Wiretuner_Doc_V1_TextStyleAttrs(), basedOn: parent))
        }
        var attrs = model.styleAttributes(firstParagraph: firstParagraph)
        if kind == .character { attrs.clearParagraph() }
        return model.perform(CreateTextStyle(kind, attrs: attrs, basedOn: kind == .paragraph ? model.textStyle?.paragraphStyle : nil))
    }

    /// *Redefine…*'s btn:[OK]: `style` takes the selection's settings.
    @discardableResult
    static func redefine(_ style: OpID, model: ObjectPanelModel, firstParagraph: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard model.text != nil, let current = model.document.state.textStyles.style(style) else { return nil }
        var attrs = model.styleAttributes(firstParagraph: firstParagraph)
        if current.kind == .character { attrs.clearParagraph() }
        let fields = SharedTextAttributes.fields(attrs)
        guard !fields.isEmpty else { return nil }
        return model.perform(EditTextStyle(style, attrs: attrs, fields: fields, name: current.name))
    }

    /// The style the Behavior and Redefine sheets start with: the selection's paragraph style,
    /// else Normal Text.
    static func currentStyle(_ model: ObjectPanelModel) -> OpID? {
        model.textStyle?.paragraphStyle ?? model.document.state.textStyles.normalText
    }

    /// A text style dropped on `window` at `point` (pasteboard): applied to the paragraph under the
    /// drop, or with `wholeBlock` to the block; nil off text.
    @discardableResult
    static func drop(_ style: OpID, at point: Point, on window: DocumentWindowController, wholeBlock: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let document = window.documentHandle
        let state = document.state
        let view = window.viewport.toView(point)
        guard let hit = window.selection.hitTester(viewport: window.viewport, subselect: true).hitTest(viewPoint: view).first,
              let id = document.selectionID(atItemPath: hit.itemPath), let text = state.textNode(id.opID),
              let kind = state.textStyles.style(style)?.kind else { return nil }
        var from = Anchor.start, to = Anchor.end
        if !wholeBlock, let layout = document.textLayout(for: id.opID),
           let local = Objects.pasteboardTransform(of: id.opID, in: state).inverted()?.apply(point),
           let offset = layout.offset(at: local, inContainer: 0) {
            let paragraph = text.paragraphs[text.paragraphIndex(at: offset)]
            from = text.anchor(at: paragraph.range.lowerBound)
            to = text.anchor(at: max(paragraph.range.upperBound - (paragraph.terminator == nil ? 0 : 1), paragraph.range.lowerBound))
        }
        let command: any WTModel.Command = kind == .paragraph ? ApplyParagraphStyle(node: id.opID, from: from, to: to, style: style)
            : ApplyCharacterStyle(node: id.opID, from: from, to: to, style: style)
        return window.objectEditing.perform(command)
    }

    /// Opens the Style Behavior sheet for `style` on `window`.
    @discardableResult
    static func presentBehavior(_ style: OpID, on window: DocumentWindowController) -> NSWindow? {
        guard let current = window.documentHandle.state.textStyles.style(style) else { return nil }
        let model = TextStyleBehaviorModel(style: current, in: window.documentHandle.state)
        let editing = window.objectEditing
        return window.presentSheet("text-style-behavior") { close in
            TextStyleBehaviorSheet(model: model, commit: { command in
                if let command { editing.perform(command) }
                close()
            }, cancel: close)
        }
    }

    /// Opens the Redefine sheet on `window`.
    @discardableResult
    static func presentRedefine(on window: DocumentWindowController, model: ObjectPanelModel, firstParagraph: Bool) -> NSWindow? {
        let styles = window.documentHandle.state.textStyles
        let all = styles.styles(.paragraph) + styles.styles(.character)
        return window.presentSheet("text-style-redefine") { close in
            RedefineTextStyleSheet(styles: all, selected: currentStyle(model), commit: { style in
                redefine(style, model: model, firstParagraph: firstParagraph)
                close()
            }, cancel: close)
        }
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?, preferences: PreferenceStore) -> [Command] {
        let text = ContextMenuCatalog.Menu.text
        let model: @MainActor () -> ObjectPanelModel? = { TextFeatures.model(window()) }
        let hasText: @MainActor @Sendable () -> CommandValidation = { model()?.text == nil ? .disabled(TextFeatures.noText) : .enabled }
        let hasStyle: @MainActor @Sendable () -> CommandValidation = { model().flatMap(currentStyle) == nil ? .disabled(noStyle) : .enabled }
        return [
            Command(id: ID.newParagraph, title: "New Paragraph Style", menu: MenuPath(text, menu, section: 1), contexts: [.style, .text],
                    keywords: ["style", "paragraph"], validation: hasText,
                    action: .perform { if let model = model() { newStyle(.paragraph, model: model, firstParagraph: firstParagraph(preferences)) } }),
            Command(id: ID.newCharacter, title: "New Character Style", menu: MenuPath(text, menu, section: 1), contexts: [.style, .text],
                    keywords: ["style", "character"], validation: hasText,
                    action: .perform { if let model = model() { newStyle(.character, model: model, firstParagraph: firstParagraph(preferences)) } }),
            Command(id: ID.redefine, title: "Redefine Style…", menu: MenuPath(text, menu, section: 1), contexts: [.style], keywords: ["style", "redefine"],
                    validation: hasText,
                    action: .perform {
                        if let front = window(), let model = model() { presentRedefine(on: front, model: model, firstParagraph: firstParagraph(preferences)) }
                    }),
            Command(id: ID.behavior, title: "Style Behavior…", menu: MenuPath(text, menu, section: 1), contexts: [.style], keywords: ["style", "behavior"],
                    validation: hasStyle,
                    action: .perform { if let front = window(), let model = model(), let style = currentStyle(model) { presentBehavior(style, on: front) } }),
        ]
    }
}
