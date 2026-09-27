import AppKit
import WTModel
import WTText

/// The Text toolbar's font family, style and size (type-tools.adoc, "The Text toolbar"): a combo
/// box of every family that completes as you type (the recent ones first, the document's missing
/// ones in brackets), a pop-up of the family's faces, and a combo box of the preset sizes that
/// takes any size from 1 to 10,000 points.  Each applies to the selected blocks or the Text
/// tool's selection as one change; a value the text does not share shows as *Mixed*.
@MainActor
enum FontToolbarControls {
    static let mixed = TextSectionView.mixed

    /// The makers `ToolbarController.controls` takes.
    static func makers(window: @escaping FontCommands.Window, recents: FontRecentsStore = .shared) -> [CommandID: @MainActor () -> any ToolbarControl] {
        [
            FontCommands.ID.family: { FamilyComboBox(window: window, recents: recents) },
            FontCommands.ID.style: { StylePopUp(window: window) },
            FontCommands.ID.fontSize: { SizeComboBox(window: window) },
        ]
    }
}

/// The family combo box.
@MainActor
final class FamilyComboBox: NSComboBox, ToolbarControl {
    let documentWindow: FontCommands.Window
    let recents: FontRecentsStore
    /// The families listed, as chosen (the titles may carry brackets).
    private(set) var choices: [FontFamilyChoice] = []

    init(window: @escaping FontCommands.Window, recents: FontRecentsStore) {
        self.documentWindow = window
        self.recents = recents
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 24))
        completes = true
        numberOfVisibleItems = 20
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderString = FontToolbarControls.mixed
        target = self
        action = #selector(commit(_:))
        setAccessibilityLabel("Font Family")
        setAccessibilityIdentifier(ToolbarID.text.accessibilityIdentifier(for: FontCommands.ID.family))
        widthAnchor.constraint(equalToConstant: 170).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(willPopUp(_:)), name: NSComboBox.willPopUpNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FamilyComboBox is built in code")
    }

    /// Reads the list again (the recent families and the document's fonts change).
    func reloadChoices() {
        guard let front = documentWindow() else { return }
        choices = FontMenus.familyList(document: front.documentHandle, recents: recents.families).flattened
        removeAllItems()
        addItems(withObjectValues: choices.map(\.title))
    }

    @objc func willPopUp(_ notification: Notification) {
        reloadChoices()
    }

    func refresh() {
        let model = FontCommands.model(documentWindow())
        isEnabled = model != nil
        if choices.isEmpty { reloadChoices() }
        // Leave what the user is typing alone.
        guard currentEditor() == nil else { return }
        stringValue = model?.text?.family.map { family in choices.first { $0.family == family }?.title ?? family } ?? ""
    }

    /// The family a typed or chosen title names: a listed family (by title or name, ignoring
    /// case); nil for anything else.
    func family(for title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return choices.first { $0.title == trimmed || $0.family == trimmed }?.family
            ?? choices.first { $0.family.caseInsensitiveCompare(trimmed) == .orderedSame }?.family
    }

    @objc func commit(_ sender: Any?) {
        if let family = family(for: stringValue), FontCommands.model(documentWindow())?.text?.family != family {
            FontCommands.apply(family: family, window: documentWindow(), recents: recents)
            reloadChoices()
        }
        refresh()
    }
}

/// The face pop-up: the shared family's faces, *Mixed* when the text differs.
@MainActor
final class StylePopUp: NSPopUpButton, ToolbarControl {
    let documentWindow: FontCommands.Window

    init(window: @escaping FontCommands.Window) {
        self.documentWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 24), pullsDown: false)
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        action = #selector(choose(_:))
        setAccessibilityLabel("Font Style")
        setAccessibilityIdentifier(ToolbarID.text.accessibilityIdentifier(for: FontCommands.ID.style))
        widthAnchor.constraint(equalToConstant: 120).isActive = true
    }

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
        guard let front = documentWindow(), let model = FontCommands.model(front), let section = model.text else {
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
        FontCommands.apply(style: title, window: documentWindow())
        refresh()
    }
}

/// The size combo box: the presets, or any size typed.
@MainActor
final class SizeComboBox: NSComboBox, ToolbarControl {
    let documentWindow: FontCommands.Window

    init(window: @escaping FontCommands.Window) {
        self.documentWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
        addItems(withObjectValues: TypeSizes.presets.map(TypeSizes.format))
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderString = FontToolbarControls.mixed
        target = self
        action = #selector(commit(_:))
        setAccessibilityLabel("Font Size")
        setAccessibilityIdentifier(ToolbarID.text.accessibilityIdentifier(for: FontCommands.ID.fontSize))
        widthAnchor.constraint(equalToConstant: 64).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SizeComboBox is built in code")
    }

    func refresh() {
        let model = FontCommands.model(documentWindow())
        isEnabled = model != nil
        guard currentEditor() == nil else { return }
        stringValue = model?.text?.size.map(TypeSizes.format) ?? ""
    }

    @objc func commit(_ sender: Any?) {
        if let size = TypeSizes.parse(stringValue), FontCommands.model(documentWindow())?.text?.size != size {
            FontCommands.apply(size: size, window: documentWindow())
        }
        refresh()
    }
}
