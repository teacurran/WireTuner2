import AppKit
import WTModel
import WTText

/// What the Text toolbar's family list shows and where its selection is (type-tools.adoc, "The
/// Text toolbar"): with no search, the recently used families, the document's missing fonts, then
/// every family -- the Font menu's groups (`FontFamilyList`); with a search, the families that
/// match it (`FontFilter`: those that start with it first).  The selection is always on a family;
/// the arrow keys move it and skip the headings.  AppKit-free.
@MainActor
final class FontFamilyPickerModel {
    enum Entry: Equatable {
        case header(String)
        case family(FontFamilyChoice)

        var choice: FontFamilyChoice? {
            if case let .family(choice) = self { return choice }
            return nil
        }
    }

    static let recentHeader = "Recently Used"
    static let missingHeader = "Missing Fonts"
    static let allHeader = "All Fonts"

    let list: FontFamilyList
    /// The family the text shares (nil when mixed): selected when the list opens.
    let current: String?
    private(set) var query = ""
    private(set) var entries: [Entry] = []
    /// An index of `entries` holding a family; nil when nothing matches.
    private(set) var selection: Int?

    init(list: FontFamilyList, current: String?) {
        self.list = list
        self.current = current
        rebuild()
        selection = current.flatMap { family in entries.firstIndex { $0.choice?.family == family } } ?? firstFamily
    }

    /// Every family listed, in order (a family recently used is listed again under All Fonts).
    var choices: [FontFamilyChoice] { entries.compactMap(\.choice) }

    var selectedFamily: String? { selection.flatMap { entries[$0].choice?.family } }

    private var firstFamily: Int? { entries.firstIndex { $0.choice != nil } }

    /// Filters as the search field changes; the best match is selected.
    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        rebuild()
        selection = firstFamily
    }

    private func rebuild() {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let unique = list.flattened
            let byFamily = Dictionary(unique.map { ($0.family, $0) }, uniquingKeysWith: { first, _ in first })
            entries = FontFilter.filter(unique.map(\.family), matching: query).compactMap { byFamily[$0].map(Entry.family) }
            return
        }
        var result: [Entry] = []
        func group(_ title: String, _ choices: [FontFamilyChoice]) {
            guard !choices.isEmpty else { return }
            result.append(.header(title))
            result += choices.map(Entry.family)
        }
        group(Self.recentHeader, list.recent)
        group(Self.missingHeader, list.missing)
        group(Self.allHeader, list.all)
        entries = result
    }

    /// Whether row `index` can be selected (headings cannot).
    func isSelectable(_ index: Int) -> Bool {
        entries.indices.contains(index) && entries[index].choice != nil
    }

    /// Selects row `index` when it holds a family.
    func select(_ index: Int) {
        if isSelectable(index) { selection = index }
    }

    /// The arrow keys: `delta` families down (up when negative), stopping at the ends.
    func move(by delta: Int) {
        let families = entries.indices.filter(isSelectable)
        guard !families.isEmpty else { return }
        guard let selection, let position = families.firstIndex(of: selection) else {
            self.selection = delta < 0 ? families.last : families.first
            return
        }
        self.selection = families[min(max(position + delta, 0), families.count - 1)]
    }

    /// Type-ahead: the first family (after the recent ones) whose name starts with `prefix`,
    /// ignoring case and accents.  Returns the row it selected.
    @discardableResult
    func typeAhead(_ prefix: String) -> Int? {
        let needle = prefix.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        let allStart = entries.firstIndex(of: .header(Self.allHeader)) ?? 0
        let order = Array(entries.indices[allStart...]) + Array(entries.indices[..<allStart])
        guard let found = order.first(where: { entries[$0].choice?.family.range(of: needle, options: options) != nil }) else { return nil }
        selection = found
        return found
    }
}

/// How the family list draws a family: its own face at a legible size, with the plain name in the
/// system font beside it when its own face cannot show its name (a symbol font, or one without
/// the letters).  Measured once per family.
@MainActor
enum FontFamilyFaces {
    static let size: CGFloat = 15
    static let plainSize: CGFloat = 13
    static let rowHeight: CGFloat = 26
    static let iconWidth: CGFloat = 16
    static let gap: CGFloat = 8
    static let horizontalInset: CGFloat = 10
    static let minimumListWidth: CGFloat = 260

    struct Face {
        /// Nil when the family is missing on this Mac.
        let font: NSFont?
        /// Whether `font` shows the family's name as letters.
        let isReadable: Bool
    }

    private static var faces: [String: Face] = [:]
    private static var widths: [String: CGFloat] = [:]

    static func face(_ family: String) -> Face {
        if let cached = faces[family] { return cached }
        let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
        let face = Face(font: font, isReadable: font.map { isReadable(family, in: $0) } ?? true)
        faces[family] = face
        return face
    }

    /// False for a symbol or ornament font, and for one missing a glyph of `text`.
    static func isReadable(_ text: String, in font: NSFont) -> Bool {
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.classSymbolic) || traits.contains(.classOrnamentals) { return false }
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
    }

    static var plainFont: NSFont { .systemFont(ofSize: plainSize) }

    /// The name as the row draws it: in the family's own face, or the system font when missing.
    static func title(_ choice: FontFamilyChoice) -> NSAttributedString {
        let font = choice.isMissing ? nil : face(choice.family).font
        return NSAttributedString(string: choice.title, attributes: [.font: font ?? NSFont.systemFont(ofSize: size)])
    }

    /// Whether the row adds the plain name beside the family's own face.
    static func showsPlainName(_ choice: FontFamilyChoice) -> Bool {
        !choice.isMissing && !face(choice.family).isReadable
    }

    static func plainTitle(_ choice: FontFamilyChoice) -> NSAttributedString {
        NSAttributedString(string: choice.family, attributes: [.font: plainFont, .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// The width a row needs to show `choice` whole.
    static func rowWidth(_ choice: FontFamilyChoice) -> CGFloat {
        if let cached = widths[choice.title] { return cached }
        var width = horizontalInset + iconWidth + gap + ceil(title(choice).size().width) + 4
        if showsPlainName(choice) { width += gap + ceil(plainTitle(choice).size().width) + 4 }
        width += horizontalInset
        widths[choice.title] = width
        return width
    }

    /// The list's width: its longest row (not the button's width), within the screen.
    static func listWidth(_ choices: [FontFamilyChoice], screenWidth: CGFloat = NSScreen.main?.visibleFrame.width ?? 1_440) -> CGFloat {
        let longest = choices.map(rowWidth).max() ?? 0
        return min(max(minimumListWidth, longest), max(minimumListWidth, screenWidth * 0.9))
    }
}

/// The popover's content: a search field that filters as you type over the families, each in its
/// own face.  The arrow keys move the selection (from the search field too), Return chooses,
/// Escape closes; typing in the list jumps to a family.
@MainActor
final class FontFamilyListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let searchHeight: CGFloat = 28
    static let maximumHeight: CGFloat = 440
    static let columnID = NSUserInterfaceItemIdentifier("family")

    let model: FontFamilyPickerModel
    let onChoose: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void
    let search = NSSearchField()
    let table = FontFamilyTable()
    let scroll = NSScrollView()
    /// The width of the list's widest row (with room for a scroller).
    let listWidth: CGFloat

    init(model: FontFamilyPickerModel, onChoose: @escaping @MainActor (String) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.model = model
        self.onChoose = onChoose
        self.onCancel = onCancel
        listWidth = FontFamilyFaces.listWidth(model.list.flattened)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FontFamilyListController is built in code")
    }

    /// The popover's size: as wide as the longest family, as tall as the list up to a limit.
    var contentSize: NSSize {
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let rows = CGFloat(max(model.entries.count, 1)) * FontFamilyFaces.rowHeight
        return NSSize(width: listWidth + scroller + 8, height: min(Self.maximumHeight, rows + Self.searchHeight + 16))
    }

    override func loadView() {
        let size = contentSize
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.setAccessibilityIdentifier("toolbar.text.fontFamily.list")
        search.placeholderString = "Search Fonts"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("toolbar.text.fontFamily.search")
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: Self.columnID)
        column.width = listWidth
        column.minWidth = listWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = FontFamilyFaces.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.list = self
        table.setAccessibilityIdentifier("toolbar.text.fontFamily.table")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        preferredContentSize = size
        syncSelection()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { !model.isSelectable(row) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { model.isSelectable(row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        cell(forRow: row)
    }

    /// The view of row `row`: a heading, or a family in its own face.
    func cell(forRow row: Int) -> NSView {
        switch model.entries[row] {
        case let .header(title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case let .family(choice):
            return FontFamilyRowView(choice: choice, width: listWidth)
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        model.entries[row].choice?.family
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        model.select(table.selectedRow)
    }

    @objc func clicked(_ sender: Any?) {
        guard model.isSelectable(table.clickedRow) else { return }
        model.select(table.clickedRow)
        choose()
    }

    /// Puts the table's selection on the model's, scrolled into view.
    func syncSelection() {
        guard isViewLoaded else { return }
        if let selection = model.selection {
            table.selectRowIndexes([selection], byExtendingSelection: false)
            table.scrollRowToVisible(selection)
        } else {
            table.deselectAll(nil)
        }
    }

    // MARK: Search and keys

    func controlTextDidChange(_ notification: Notification) {
        filter(search.stringValue)
    }

    /// The search field's text changed: the list filters and the best match is selected.
    func filter(_ query: String) {
        model.setQuery(query)
        table.reloadData()
        syncSelection()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handle(selector)
    }

    /// The keys the list takes from the search field and the table: the arrows, Return, Escape.
    @discardableResult
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
    }

    func move(by delta: Int) {
        model.move(by: delta)
        syncSelection()
    }

    /// Type-ahead in the list.
    func typeAhead(_ prefix: String) {
        model.typeAhead(prefix)
        syncSelection()
    }

    /// Chooses the selected family.
    func choose() {
        guard let family = model.selectedFamily else { return }
        onChoose(family)
    }
}

/// The family list's table: Return chooses and Escape closes, as in the search field.
@MainActor
final class FontFamilyTable: NSTableView {
    weak var list: FontFamilyListController?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: list?.handle(#selector(NSResponder.insertNewline(_:)))
        case 53: list?.handle(#selector(NSResponder.cancelOperation(_:)))
        default: super.keyDown(with: event)
        }
    }
}

/// One family: a mark for a missing font or one the document uses, the name in its own face, and
/// the plain name beside it when the face shows symbols.
@MainActor
final class FontFamilyRowView: NSTableCellView {
    let choice: FontFamilyChoice
    let name = NSTextField(labelWithString: "")
    let plain = NSTextField(labelWithString: "")
    let mark = NSImageView()

    init(choice: FontFamilyChoice, width: CGFloat) {
        self.choice = choice
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: FontFamilyFaces.rowHeight))
        identifier = NSUserInterfaceItemIdentifier("toolbar.text.fontFamily.row.\(choice.family)")
        name.attributedStringValue = FontFamilyFaces.title(choice)
        name.lineBreakMode = .byClipping
        name.setAccessibilityLabel(choice.family)
        textField = name
        if choice.isMissing {
            mark.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Missing on this Mac")
            toolTip = "Missing on this Mac: drawn in a substitute"
        } else if choice.inDocument {
            mark.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Used in this document")
            toolTip = "Used in this document"
        }
        imageView = mark
        addSubview(mark)
        addSubview(name)
        if FontFamilyFaces.showsPlainName(choice) {
            plain.attributedStringValue = FontFamilyFaces.plainTitle(choice)
            plain.lineBreakMode = .byClipping
            addSubview(plain)
        }
        layoutRow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FontFamilyRowView is built in code")
    }

    override func layout() {
        super.layout()
        layoutRow()
    }

    /// Mark, name and plain name side by side at their natural widths, centred vertically.
    func layoutRow() {
        let height = bounds.height
        var x = FontFamilyFaces.horizontalInset
        mark.frame = NSRect(x: x, y: (height - FontFamilyFaces.iconWidth) / 2, width: FontFamilyFaces.iconWidth, height: FontFamilyFaces.iconWidth)
        x += FontFamilyFaces.iconWidth + FontFamilyFaces.gap
        let nameSize = name.intrinsicContentSize
        name.frame = NSRect(x: x, y: ((height - nameSize.height) / 2).rounded(.down), width: ceil(nameSize.width), height: min(nameSize.height, height))
        x += ceil(nameSize.width) + FontFamilyFaces.gap
        if plain.superview != nil {
            let plainSize = plain.intrinsicContentSize
            plain.frame = NSRect(x: x, y: ((height - plainSize.height) / 2).rounded(.down), width: ceil(plainSize.width), height: plainSize.height)
        }
    }

    /// Whether every label is shown whole inside the row.
    var showsWholeNames: Bool {
        let labels = [name] + (plain.superview == nil ? [] : [plain])
        return labels.allSatisfy { $0.frame.width >= ceil($0.intrinsicContentSize.width) && $0.frame.maxX <= bounds.width + 0.5 }
    }
}

/// The Text toolbar's font family control: a button showing the family the text shares
/// (truncated, with the whole name as its tooltip; *Mixed* when the text differs) that opens the
/// family list in a popover.  Choosing a family applies it at once, as one change labelled
/// "Font", to the document of the window hosting the toolbar.
@MainActor
final class FontFamilyPicker: NSButton, ToolbarControl {
    static let naturalWidth: CGFloat = 200
    static let minimumWidth: CGFloat = 120

    let documentWindow: FontCommands.Window
    let recents: FontRecentsStore
    /// The family shown; nil when mixed or nothing is selected.
    private(set) var family: String?
    private(set) var popover: NSPopover?
    private(set) var list: FontFamilyListController?

    init(window: @escaping FontCommands.Window, recents: FontRecentsStore) {
        self.documentWindow = window
        self.recents = recents
        super.init(frame: NSRect(x: 0, y: 0, width: Self.naturalWidth, height: 24))
        bezelStyle = .push
        controlSize = .regular
        font = .systemFont(ofSize: NSFont.systemFontSize)
        alignment = .left
        image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        imagePosition = .imageTrailing
        imageHugsTitle = false
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        (cell as? NSButtonCell)?.truncatesLastVisibleLine = true
        title = ""
        target = self
        action = #selector(openList(_:))
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Font Family")
        setAccessibilityIdentifier(ToolbarID.text.accessibilityIdentifier(for: FontCommands.ID.family))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FontFamilyPicker is built in code")
    }

    var toolbarSize: NSSize { NSSize(width: Self.naturalWidth, height: max(fittingSize.height, 24)) }
    var minimumToolbarWidth: CGFloat { Self.minimumWidth }
    var takesFullRow: Bool { true }

    /// The document the choice goes to: the window hosting the toolbar (docked, or floating over
    /// it), else the front document window.
    var documentTarget: DocumentWindowController? { hostedDocumentWindow ?? documentWindow() }

    func refresh() {
        let model = FontCommands.model(documentTarget)
        isEnabled = model != nil
        family = model?.text?.family
        let shown = model == nil ? "" : family ?? FontToolbarControls.mixed
        if title != shown { title = shown }
        toolTip = model == nil ? nil : family.map { "Font Family: \($0)" } ?? "Font Family: \(FontToolbarControls.mixed)"
        setAccessibilityValue(shown)
    }

    /// The families the list shows now (the recent ones and the document's fonts change).
    func makeModel() -> FontFamilyPickerModel? {
        guard let front = documentTarget else { return nil }
        return FontFamilyPickerModel(list: FontMenus.familyList(document: front.documentHandle, recents: recents.families), current: family)
    }

    /// Opens the list under the button; its search field has the keyboard.
    @discardableResult
    @objc func openList(_ sender: Any?) -> FontFamilyListController? {
        closeList()
        refresh()
        guard isEnabled, let model = makeModel() else { return nil }
        let list = FontFamilyListController(model: model, onChoose: { [weak self] in self?.choose($0) }, onCancel: { [weak self] in self?.closeList() })
        self.list = list
        _ = list.view
        guard window != nil else { return list }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = list
        popover.contentSize = list.contentSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: isFlipped ? .maxY : .minY)
        list.view.window?.makeFirstResponder(list.search)
        self.popover = popover
        return list
    }

    func closeList() {
        popover?.close()
        popover = nil
        list = nil
    }

    /// A family chosen from the list: applied, remembered among the recent ones, shown.
    func choose(_ family: String) {
        closeList()
        guard let model = FontCommands.model(documentTarget) else { return }
        if model.text?.family != family { FontCommands.apply(family: family, window: documentTarget, recents: recents) }
        // Shown at once; the next refresh reads it back from the document.
        self.family = family
        title = family
        toolTip = "Font Family: \(family)"
        setAccessibilityValue(family)
    }
}

extension NSView {
    /// The document window hosting this view: its own window's, or the window a floating panel
    /// floats over.
    @MainActor
    var hostedDocumentWindow: DocumentWindowController? {
        var current = window
        while let candidate = current {
            if let controller = candidate.windowController as? DocumentWindowController { return controller }
            current = candidate.parent
        }
        return nil
    }
}
