import AppKit
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Styles panel's state and actions (styles.adoc; LIB-020 over LIB-019's commands): the graphic
/// styles in panel order with their previews, counts, highlights and plus signs, then the text
/// styles; a click that applies the style to the selected objects or, with nothing selected, makes
/// it the default attributes; drops that make a style (on the empty area) or ask to redefine one
/// (on a style); in-place renaming; the options menu with *New*, *New from Normal*, *Duplicate*,
/// *Remove*, *Remove Unused*, *Redefine…*, *Style Behavior…* and the three views.  The list is kept
/// current by a `GraphicStyleTracker` per document, so remote redefinitions redraw the previews
/// while a rename's field stays open.
@MainActor
@Observable
final class StylesPanelModel {
    /// How the panel lists styles.
    enum ViewMode: String, CaseIterable, Sendable {
        case compact, large, previewsOnly

        var title: String {
            switch self {
            case .compact: "Compact List View"
            case .large: "Large List View"
            case .previewsOnly: "Previews Only"
            }
        }

        var previewSize: Size { self == .compact ? StylePreview.compact : StylePreview.large }
    }

    /// One graphic style as listed.
    struct Row: Identifiable, Equatable {
        let id: OpID
        let name: String
        let isNormal: Bool
        /// How many objects use it.
        let count: Int
        /// The selected objects use it; with nothing selected, the default attributes mirror it.
        let isHighlighted: Bool
        /// The plus sign: a selected object overrides it, or (nothing selected) the default
        /// attributes differ from it.
        let isModified: Bool
    }

    /// One text style as listed (the TYPE epic's styles, text-styles.adoc).
    struct TextRow: Identifiable, Equatable {
        let id: OpID
        let name: String
        let kind: TextStyleKind
    }

    /// The Redefine sheet's question: `style` takes the look of `source`.
    struct Redefinition: Equatable {
        var style: OpID
        let source: RedefineGraphicStyle.Source
    }

    /// The Style Behavior sheet's working values.
    struct Behavior: Equatable {
        let style: OpID
        var governs: Set<StyleCategory>
        var parent: OpID?
        let isNormal: Bool
        /// What the style has now: only what changes is written.
        let originalGoverns: Set<StyleCategory>
        let originalParent: OpID?
    }

    enum Sheet {
        static let redefine = "styles.redefine-sheet"
        static let behavior = "styles.behavior-sheet"
        static let removeUnused = "styles.remove-unused-sheet"
    }

    static let noDocument = "Open a document to see its styles."

    let selection: ActiveSelection
    var viewMode = ViewMode.compact
    /// The style clicked last in the panel (local view state).
    private(set) var selected: OpID?
    var renaming: OpID?
    var renameText = ""
    /// The drop or *Redefine…* waiting on the Redefine sheet.
    var redefinition: Redefinition?
    /// The Style Behavior sheet's values while it is open.
    var behavior: Behavior?
    /// The styles *Remove Unused* is about to remove, while its sheet is open.
    private(set) var unused: [OpID] = []
    /// Presents and dismisses the sheets; replaceable in tests.
    @ObservationIgnored var presenter = SheetPresenter()
    /// *Auto-apply new styles to selection* (Preferences > Object).
    @ObservationIgnored var autoApply: @MainActor () -> Bool = { true }
    @ObservationIgnored private var trackers: [String: GraphicStyleTracker] = [:]
    @ObservationIgnored private var previews: [OpID: (key: Int, image: CGImage?)] = [:]

    init(selection: ActiveSelection) {
        self.selection = selection
    }

    var document: DocumentHandle? { selection.document }

    /// The tracker of `document`, once its model is open; one per document.
    func tracker(for document: DocumentHandle?) -> GraphicStyleTracker? {
        guard let document, let model = document.model else { return nil }
        if let existing = trackers[document.id], existing.document === model { return existing }
        trackers[document.id]?.stop()
        let created = GraphicStyleTracker(document: model)
        trackers[document.id] = created
        return created
    }

    var tracker: GraphicStyleTracker? { tracker(for: document) }

    private var state: EngineState { document?.state ?? EngineState() }

    /// The window's selection.
    private var selectedIDs: [OpID] { selection.model?.selection.ids.map(\.opID) ?? [] }

    /// The selected canvas objects that can take a style.
    var canvasObjects: [OpID] {
        let state = state
        return selectedIDs.filter { Objects.isObject($0, in: state) }
    }

    // MARK: The list

    var rows: [Row] {
        guard let document, let tracker else { return [] }
        _ = tracker.revision
        let state = document.state
        let resolver = tracker.resolver
        let index = tracker.index
        let objects = canvasObjects
        let used = Set(objects.compactMap { resolver.style(of: $0, in: state) })
        let overridden = Set(objects.filter { !GraphicStyleDefaults.overrides(of: $0, in: state).isEmpty }.compactMap { resolver.style(of: $0, in: state) })
        let mirrored = objects.isEmpty ? GraphicStyleDefaults.style(in: state) : nil
        let modified = mirrored != nil && GraphicStyleDefaults.isModified(in: state)
        let names = GraphicStyleFields.displayNames(in: state, resolver)
        return GraphicStyleFields.styles(in: state, resolver).map { id in
            Row(id: id, name: names[id] ?? state.props(id).style.common.name, isNormal: resolver.role(of: id) == .normal, count: index.objects(using: id).count,
                isHighlighted: objects.isEmpty ? id == mirrored : used.contains(id),
                isModified: objects.isEmpty ? modified && id == mirrored : overridden.contains(id))
        }
    }

    /// The text styles: paragraph styles, then character styles.
    var textRows: [TextRow] {
        guard document != nil else { return [] }
        _ = tracker?.revision
        let styles = state.textStyles
        return (styles.styles(.paragraph) + styles.styles(.character)).map { TextRow(id: $0.id, name: $0.name, kind: $0.kind) }
    }

    /// The style the options menu acts on: the one clicked last while it is live, else the one the
    /// default attributes mirror (nothing selected) or the first selected object's.
    var targetStyle: OpID? {
        let ids = rows.map(\.id)
        if let selected, ids.contains(selected) { return selected }
        if let object = canvasObjects.first { return tracker?.resolver.style(of: object, in: state) }
        return GraphicStyleDefaults.style(in: state)
    }

    /// A style's preview at the current view's size, cached until its look changes.
    func preview(_ style: OpID) -> CGImage? {
        guard let tracker else { return nil }
        let size = viewMode.previewSize
        let look = StylePreview.appearance(of: style, resolver: tracker.resolver, state: state)
        var hasher = Hasher()
        hasher.combine(try? look.serializedBytes() as [UInt8])
        hasher.combine(size.width)
        hasher.combine(ObjectIdentifier(tracker))
        let key = hasher.finalize()
        if let cached = previews[style], cached.key == key { return cached.image }
        let image = StylePreview.image(look, state: state, size: size)
        previews[style] = (key, image)
        return image
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let editing = selection.editing, editing.document === document { return editing.perform(command) }
        return document?.perform(command)
    }

    /// A click: applies the style to the selected objects (removing their overrides in what it
    /// governs), or with nothing selected makes it the default attributes.
    @discardableResult
    func click(_ style: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        selected = style
        guard let document else { return nil }
        let objects = canvasObjects
        if !objects.isEmpty { return perform(ApplyGraphicStyle(style, to: objects, in: document.state)) }
        return perform(SelectGraphicStyleAsDefaults(style))
    }

    /// A click on a text style: applies it to every selected text block, whole.
    @discardableResult
    func clickText(_ row: TextRow) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let state = state
        let blocks = selectedIDs.filter { state.textNode($0) != nil }
        guard !blocks.isEmpty else { return nil }
        let commands: [any WTModel.Command] = blocks.map { node -> any WTModel.Command in
            if row.kind == .paragraph { return ApplyParagraphStyle(node: node, from: .start, to: .end, style: row.id) }
            return ApplyCharacterStyle(node: node, from: .start, to: .end, style: row.id)
        }
        return perform(CommandBatch("Apply style", commands))
    }

    // MARK: Drops

    /// What was dropped on the panel.
    enum DropSource: Equatable {
        /// Objects dragged from the canvas: the window's selection.
        case objects
        /// A style dragged from the panel.
        case style(OpID)
    }

    /// A drop on the empty area makes a style (from the selected object, taking it when
    /// *Auto-apply new styles to selection* is on; or a child of the dropped style); a drop on a
    /// style asks, in the Redefine sheet, to redefine it from the object or the dropped style.
    @discardableResult
    func drop(_ source: DropSource, on target: OpID?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard document != nil else { return nil }
        let objects = canvasObjects
        switch (source, target) {
        case (.objects, nil):
            guard let object = objects.first else { return nil }
            return perform(CreateGraphicStyle(.selection(object), applyTo: autoApply() ? objects : []))
        case (.style(let style), nil):
            return perform(CreateGraphicStyle(.style(style)))
        case (.objects, let target?):
            guard let object = objects.first else { return nil }
            askToRedefine(target, from: .object(object))
        case (.style(let style), let target?):
            guard style != target else { return nil }
            askToRedefine(target, from: .style(style))
        }
        return nil
    }

    /// A drop read from the drag pasteboard: a style of this document, or objects dragged out of
    /// this document's window.
    @discardableResult
    func drop(from pasteboard: NSPasteboard, on target: OpID?) -> Bool {
        guard let document else { return false }
        if let payload = StyleDrag.read(from: pasteboard) {
            guard payload.document == document.id else { return false }
            drop(.style(payload.style), on: target)
            return true
        }
        guard let bytes = SystemObjectPasteboard(pasteboard).read(), let payload = ClipboardPayload(decoding: bytes), payload.sourceDocument == document.id else {
            return false
        }
        drop(.objects, on: target)
        return true
    }

    /// Dragging a style's preview carries the style.
    func dragPayload(_ style: OpID) -> StyleDrag? {
        document.map { StyleDrag(document: $0.id, style: style) }
    }

    // MARK: Redefine

    private func askToRedefine(_ style: OpID, from source: RedefineGraphicStyle.Source) {
        redefinition = Redefinition(style: style, source: source)
        presenter.present(RedefineStyleSheet(model: self), title: "Redefine Style", identifier: Sheet.redefine)
    }

    /// *Redefine…*: the style the defaults mirror (or the one clicked) takes the selected object's
    /// look, or with nothing selected the default attributes; the sheet confirms the style.
    func beginRedefine() {
        guard let style = targetStyle else { return }
        askToRedefine(style, from: canvasObjects.first.map { .object($0) } ?? .defaults)
    }

    /// The sheet's btn:[Redefine].
    @discardableResult
    func confirmRedefine() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let redefinition else { return nil }
        cancelRedefine()
        return perform(RedefineGraphicStyle(redefinition.style, from: redefinition.source, in: state))
    }

    func cancelRedefine() {
        redefinition = nil
        presenter.dismiss(Sheet.redefine)
    }

    /// What the sheet says is being redefined from.
    func sourceDescription(_ source: RedefineGraphicStyle.Source) -> String {
        switch source {
        case .object: "the selected object"
        case .style(let style): "the style \u{201C}\(name(of: style))\u{201D}"
        case .defaults: "the default attributes"
        }
    }

    func name(of style: OpID) -> String {
        state.props(style).style.common.name
    }

    // MARK: Renaming

    /// A double-click on a name (in the views that show names).
    func beginRename(_ style: OpID) {
        guard viewMode != .previewsOnly, rows.contains(where: { $0.id == style }) else { return }
        renaming = style
        renameText = name(of: style)
    }

    /// kbd:[Return] in the field.
    @discardableResult
    func commitRename() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        defer { renaming = nil }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let style = renaming, !name.isEmpty, name != self.name(of: style) else { return nil }
        return perform(RenameGraphicStyle(style, to: name))
    }

    func cancelRename() {
        renaming = nil
    }

    // MARK: Options menu

    /// *New*: from the selected object (switching it to the style when *Auto-apply* is on); with
    /// nothing selected, from the default attributes when they differ from their style, else a
    /// child of the style they mirror.
    @discardableResult
    func newStyle() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard document != nil else { return nil }
        let objects = canvasObjects
        if let object = objects.first { return perform(CreateGraphicStyle(.selection(object), applyTo: autoApply() ? objects : [])) }
        let state = state
        if !GraphicStyleDefaults.isModified(in: state), let style = GraphicStyleDefaults.style(in: state) { return perform(CreateGraphicStyle(.style(style))) }
        return perform(CreateGraphicStyle(.defaults))
    }

    @discardableResult
    func newFromNormal() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        document == nil ? nil : perform(CreateGraphicStyle(.normal))
    }

    @discardableResult
    func duplicate() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard canvasObjects.isEmpty, let style = targetStyle else { return nil }
        return perform(DuplicateGraphicStyle(style))
    }

    /// Whether *Remove* applies: a style other than Normal, with nothing selected on the canvas.
    var canRemove: Bool {
        guard canvasObjects.isEmpty, let style = targetStyle else { return false }
        return rows.first { $0.id == style }?.isNormal == false
    }

    /// *Remove* / kbd:[Delete]: objects keep their look on the parent style (or Normal).
    @discardableResult
    func remove() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard canRemove, let style = targetStyle else { return nil }
        if selected == style { selected = nil }
        return perform(RemoveGraphicStyle(style, in: state))
    }

    /// *Remove Unused*: the sheet lists the styles about to go.
    func beginRemoveUnused() {
        guard document != nil else { return }
        unused = RemoveUnusedGraphicStyles.unused(in: state)
        presenter.present(RemoveUnusedStylesSheet(model: self), title: "Remove Unused Styles", identifier: Sheet.removeUnused)
    }

    /// The sheet's btn:[Remove].
    @discardableResult
    func confirmRemoveUnused() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let count = unused.count
        cancelRemoveUnused()
        return count == 0 ? nil : perform(RemoveUnusedGraphicStyles())
    }

    func cancelRemoveUnused() {
        unused = []
        presenter.dismiss(Sheet.removeUnused)
    }

    /// *Style Behavior…*: the sheet for the style, with nothing selected on the canvas.
    func beginBehavior() {
        guard canvasObjects.isEmpty, let style = targetStyle, let resolver = tracker?.resolver else { return }
        let governs = resolver.governs(style)
        let parent = resolver.parent(of: style)
        behavior = Behavior(style: style, governs: governs, parent: parent, isNormal: resolver.role(of: style) == .normal,
                             originalGoverns: governs, originalParent: parent)
        presenter.present(StyleBehaviorSheet(model: self), title: "Style Behavior", identifier: Sheet.behavior)
    }

    /// The *Parent* pop-up: the styles that would not form a loop.
    var parentCandidates: [OpID] {
        guard let behavior else { return [] }
        return SetGraphicStyleParent.candidates(for: behavior.style, in: state).filter { $0 != behavior.style }
    }

    /// Checks or unchecks a category; the last checked one stays.
    func toggle(_ category: StyleCategory) {
        guard var behavior else { return }
        if behavior.governs.contains(category) {
            guard behavior.governs.count > 1 else { return }
            behavior.governs.remove(category)
        } else {
            behavior.governs.insert(category)
        }
        self.behavior = behavior
    }

    func setParent(_ parent: OpID?) {
        guard !(behavior?.isNormal ?? true) else { return }
        behavior?.parent = parent
    }

    /// The sheet's btn:[OK]: one change with what changed.
    @discardableResult
    func confirmBehavior() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let behavior else { return nil }
        cancelBehavior()
        var commands: [any WTModel.Command] = []
        if behavior.governs != behavior.originalGoverns { commands.append(SetGraphicStyleBehavior(behavior.style, governs: behavior.governs)) }
        if behavior.parent != behavior.originalParent { commands.append(SetGraphicStyleParent(behavior.style, parent: behavior.parent)) }
        return commands.isEmpty ? nil : perform(CommandBatch("Style behavior", commands))
    }

    func cancelBehavior() {
        behavior = nil
        presenter.dismiss(Sheet.behavior)
    }

    func setView(_ mode: ViewMode) {
        viewMode = mode
        if mode == .previewsOnly { renaming = nil }
    }

    /// The panel's Options menu (styles.adoc, "The Styles panel").  *Import…* and *Export…* are
    /// LIB-022's and stay disabled until it lands.
    func optionsMenu() -> [PanelMenuItem] {
        let hasDocument = document != nil
        let nothingSelected = canvasObjects.isEmpty
        let style = targetStyle
        var items = [
            PanelMenuItem(title: "New", isEnabled: hasDocument) { [weak self] in self?.newStyle() },
            PanelMenuItem(title: "New from Normal", isEnabled: hasDocument) { [weak self] in self?.newFromNormal() },
            PanelMenuItem(title: "Duplicate", isEnabled: nothingSelected && style != nil) { [weak self] in self?.duplicate() },
            PanelMenuItem(title: "Remove", isEnabled: canRemove) { [weak self] in self?.remove() },
            PanelMenuItem(title: "Remove Unused", isEnabled: hasDocument) { [weak self] in self?.beginRemoveUnused() },
            PanelMenuItem(title: "Redefine…", isEnabled: style != nil) { [weak self] in self?.beginRedefine() },
            PanelMenuItem(title: "Style Behavior…", isEnabled: nothingSelected && style != nil) { [weak self] in self?.beginBehavior() },
            PanelMenuItem(title: "Import…", isEnabled: false) {},
            PanelMenuItem(title: "Export…", isEnabled: false) {},
        ]
        for mode in ViewMode.allCases {
            items.append(PanelMenuItem(title: mode.title, isEnabled: viewMode != mode) { [weak self] in self?.setView(mode) })
        }
        return items
    }
}
