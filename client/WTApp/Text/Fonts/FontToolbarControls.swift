import AppKit
import WTModel
import WTText

/// The Text toolbar's font family, style and size (type-tools.adoc, "The Text toolbar"): our own
/// family picker (`FontFamilyPicker`: a list sized to the longest name, each family in its own
/// face, filtered as you type; the recent ones first, the document's missing ones marked), a
/// pop-up of the family's faces, and a combo box of the preset sizes that takes any size from 1 to
/// 10,000 points.  Each applies to the selected blocks or the Text tool's selection of the window
/// hosting the toolbar as one change -- a family or face as soon as it is picked, a size when it is
/// picked or typed and entered; a value the text does not share shows as *Mixed*.
@MainActor
enum FontToolbarControls {
    static let mixed = TextSectionView.mixed
    static var controlFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    /// The makers `ToolbarController.controls` takes.
    static func makers(window: @escaping FontCommands.Window, recents: FontRecentsStore = .shared) -> [CommandID: @MainActor () -> any ToolbarControl] {
        [
            FontCommands.ID.family: { FontFamilyPicker(window: window, recents: recents) },
            FontCommands.ID.style: { StylePopUp(window: window) },
            FontCommands.ID.fontSize: { SizeComboBox(window: window) },
        ]
    }
}

/// The face pop-up: the shared family's faces, *Mixed* when the text differs.
@MainActor
final class StylePopUp: NSPopUpButton, ToolbarControl {
    let documentWindow: FontCommands.Window

    init(window: @escaping FontCommands.Window) {
        self.documentWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: Self.naturalWidth, height: 24), pullsDown: false)
        controlSize = .regular
        font = FontToolbarControls.controlFont
        (cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(choose(_:))
        setAccessibilityLabel("Font Style")
        setAccessibilityIdentifier(ToolbarID.text.accessibilityIdentifier(for: FontCommands.ID.style))
    }

    static let naturalWidth: CGFloat = 130
    var toolbarSize: NSSize { NSSize(width: Self.naturalWidth, height: max(fittingSize.height, 24)) }
    var minimumToolbarWidth: CGFloat { 90 }

    /// The document the face goes to: the window hosting the toolbar, else the front one.
    var documentTarget: DocumentWindowController? { hostedDocumentWindow ?? documentWindow() }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StylePopUp is built in code")
    }

    /// The titles the pop-up shows for `section`: *Mixed* first when the face differs, the
    /// family's faces, and the text's own face when the family lacks it.
    static func titles(family: String?, style: String?, faces: (String) -> [String]) -> [String] {
        var titles = family.map(faces) ?? []
        if let style, !titles.contains(style) { titles.insert(style, at: 0) }
        if style == nil { titles.insert(FontToolbarControls.mixed, at: 0) }
        return titles
    }

    func refresh() {
        guard let front = documentTarget, let model = FontCommands.model(front), let section = model.text else {
            isEnabled = false
            return
        }
        isEnabled = true
        let fonts = front.documentHandle.textEngine.fonts
        let titles = Self.titles(family: section.family, style: section.style) { fonts.styles(of: $0) }
        if itemTitles != titles {
            removeAllItems()
            addItems(withTitles: titles)
        }
        selectItem(withTitle: section.style ?? FontToolbarControls.mixed)
    }

    @objc func choose(_ sender: Any?) {
        guard let title = titleOfSelectedItem, title != FontToolbarControls.mixed else { return }
        FontCommands.apply(style: title, window: documentTarget)
    }
}

/// The size combo box: a preset applies as soon as it is picked from the list; a typed size when
/// Return is pressed or editing ends.  (NSComboBox sends its action for a pick before its text
/// changes, so a pick is read from the list, not the text.)
@MainActor
final class SizeComboBox: NSComboBox, ToolbarControl, NSComboBoxDelegate {
    let documentWindow: FontCommands.Window
    static let naturalWidth: CGFloat = 72

    init(window: @escaping FontCommands.Window) {
        self.documentWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: Self.naturalWidth, height: 24))
        addItems(withObjectValues: TypeSizes.presets.map(TypeSizes.format))
        numberOfVisibleItems = TypeSizes.presets.count
        controlSize = .regular
        font = FontToolbarControls.controlFont
        placeholderString = FontToolbarControls.mixed
        target = self
        action = #selector(commit(_:))
        delegate = self
        setAccessibilityLabel("Font Size")
        setAccessibilityIdentifier(ToolbarID.text.accessibilityIdentifier(for: FontCommands.ID.fontSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SizeComboBox is built in code")
    }

    var toolbarSize: NSSize { NSSize(width: Self.naturalWidth, height: max(fittingSize.height, 24)) }
    var minimumToolbarWidth: CGFloat { 60 }

    /// The document the size goes to: the window hosting the toolbar, else the front one.
    var documentTarget: DocumentWindowController? { hostedDocumentWindow ?? documentWindow() }

    /// The size applied since the text was last read: Return and the end of editing that follows
    /// it apply it once.
    private(set) var applied: Double?

    func refresh() {
        let model = FontCommands.model(documentTarget)
        isEnabled = model != nil
        guard currentEditor() == nil else { return }
        applied = nil
        stringValue = model?.text?.size.map(TypeSizes.format) ?? ""
    }

    /// A preset picked from the list.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = indexOfSelectedItem
        guard TypeSizes.presets.indices.contains(index) else { return }
        let size = TypeSizes.presets[index]
        // The text follows the pick now, so an action sent after it reads the same size.
        stringValue = TypeSizes.format(size)
        currentEditor()?.string = TypeSizes.format(size)
        apply(size)
    }

    /// Editing ended (Tab, a click elsewhere): the typed size applies, as Return does.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        commit(nil)
    }

    @objc func commit(_ sender: Any?) {
        guard let size = TypeSizes.parse(stringValue) else {
            refresh()
            return
        }
        apply(size)
    }

    /// Applies `size` when the text does not have it already, and shows it.
    func apply(_ size: Double) {
        guard let model = FontCommands.model(documentTarget) else { return }
        if model.text?.size != size && applied != size { FontCommands.apply(size: size, window: documentTarget) }
        applied = size
        if currentEditor() == nil { stringValue = TypeSizes.format(size) }
    }
}
