import AppKit
import SwiftUI
import WTRender

/// The page selector's text: a page number, or a page's name as its pop-up lists it.
enum PageSelection {
    /// "Page 1", "Page 2", ... until pages carry names (DOC epic).
    static func name(of index: Int) -> String { "Page \(index + 1)" }

    /// The page index `text` names ("3", "Page 3"); nil when it names no page.
    static func parse(_ text: String, pageCount: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = Int(trimmed) ?? (0..<pageCount).first { name(of: $0).caseInsensitiveCompare(trimmed) == .orderedSame }.map { $0 + 1 }
        guard let number, number >= 1, number <= pageCount else { return nil }
        return number - 1
    }
}

/// The status bar along the bottom of the canvas (workspace.adoc, "The status bar"; BASIC-002):
/// Add Page, the page selector, magnification, view mode, units, the sync indicator, the
/// collaborators and the message area.  Thin: every entry is handed to the window controller.
@MainActor
final class StatusBarView: NSView, NSComboBoxDelegate {
    static let height: CGFloat = 24
    static let fitSelectionTitle = "Fit Selection"
    static let fitPageTitle = "Fit to Page"
    static let fitAllTitle = "Fit All"

    let addPage = NSButton(image: NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Add Page")!, target: nil, action: nil)
    let previousPage = NSButton(title: "<", target: nil, action: nil)
    let pageField = NSComboBox()
    let nextPage = NSButton(title: ">", target: nil, action: nil)
    let magnification = NSComboBox()
    /// The canvas rotation (BASIC-034): hidden while straight; a click straightens.
    let compass = CompassButton()
    let viewMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let units = NSPopUpButton(frame: .zero, pullsDown: false)
    let message = NSTextField(labelWithString: "")
    let model = StatusBarModel()
    private(set) var syncHost: NSHostingView<SyncIndicatorView>!
    private(set) var avatarHost: NSHostingView<AvatarStripView>!
    /// The named views listed after the Fit entries (BASIC-012 supplies them).
    private(set) var namedViews: [String] = []
    private(set) var pageCount = 0
    private(set) var currentPage = 0

    /// Typed text or a chosen preset, as entered.
    var onMagnification: (@MainActor (String) -> Void)?
    var onViewMode: (@MainActor (ViewMode) -> Void)?
    var onAddPage: (@MainActor () -> Void)?
    /// A page chosen by the arrows or the pop-up (index), or typed (text).
    var onPage: (@MainActor (Int) -> Void)?
    var onPageText: (@MainActor (String) -> Void)?
    var onUnits: (@MainActor (DocumentUnits) -> Void)?
    var onResetRotation: (@MainActor () -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("status-bar")

        addPage.isBordered = false
        addPage.target = self
        addPage.action = #selector(addPageClicked(_:))
        addPage.toolTip = "Add Page"
        addPage.setAccessibilityIdentifier("status.addPage")
        for (button, action) in [(previousPage, #selector(previousPageClicked(_:))), (nextPage, #selector(nextPageClicked(_:)))] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        previousPage.setAccessibilityIdentifier("status.page.previous")
        nextPage.setAccessibilityIdentifier("status.page.next")
        configure(pageField, identifier: "status.page", action: #selector(pageEntered(_:)))
        configure(magnification, identifier: "status.magnification", action: #selector(magnificationEntered(_:)))
        magnification.numberOfVisibleItems = 16
        rebuildMagnificationItems()

        for (popUp, identifier, titles, action) in [
            (viewMode, "status.viewMode", ViewMode.allCases.map(\.title), #selector(viewModeChosen(_:))),
            (units, "status.units", DocumentUnits.allCases.map(\.title), #selector(unitsChosen(_:))),
        ] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popUp.addItems(withTitles: titles)
            popUp.target = self
            popUp.action = action
            popUp.setAccessibilityIdentifier(identifier)
        }

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setAccessibilityIdentifier("status.message")
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncHost = NSHostingView(rootView: SyncIndicatorView(model: model))
        avatarHost = NSHostingView(rootView: AvatarStripView(model: model))

        compass.target = self
        compass.action = #selector(compassClicked(_:))
        let stack = NSStackView(views: [addPage, previousPage, pageField, nextPage, magnification, compass, viewMode, units, syncHost, avatarHost, message])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            magnification.widthAnchor.constraint(equalToConstant: 92),
            pageField.widthAnchor.constraint(equalToConstant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBarView is built in code")
    }

    private func configure(_ box: NSComboBox, identifier: String, action: Selector) {
        box.controlSize = .small
        box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        box.isEditable = true
        box.completes = false
        box.target = self
        box.action = action
        box.delegate = self
        box.setAccessibilityIdentifier(identifier)
    }

    /// The magnification pop-up: presets, then the Fit commands, then named views.
    var magnificationItems: [String] {
        MagnificationFormat.presetTitles + [Self.fitSelectionTitle, Self.fitPageTitle, Self.fitAllTitle] + namedViews
    }

    private func rebuildMagnificationItems() {
        magnification.removeAllItems()
        magnification.addItems(withObjectValues: magnificationItems)
    }

    func show(namedViews: [String]) {
        self.namedViews = namedViews
        rebuildMagnificationItems()
    }

    /// Whether `field` is being typed into (a remote change must not overwrite it).
    func isEditing(_ field: NSControl) -> Bool {
        field.currentEditor() != nil
    }

    func show(zoom: Double) {
        magnification.stringValue = MagnificationFormat.string(for: zoom)
    }

    /// The compass: the angle the top of the page points to, hidden at 0°.
    func show(rotation degrees: Double) {
        compass.degrees = degrees
    }

    func show(mode: ViewMode) {
        viewMode.selectItem(at: ViewMode.allCases.firstIndex(of: mode) ?? 0)
    }

    /// The document's units; never takes focus from a field being edited.
    func show(units value: DocumentUnits) {
        units.selectItem(at: DocumentUnits.allCases.firstIndex(of: value) ?? 0)
    }

    func show(message text: String) {
        message.stringValue = text
    }

    /// The page selector for `count` pages with `current` selected.
    func show(pages count: Int, current: Int) {
        if count != pageCount {
            pageField.removeAllItems()
            pageField.addItems(withObjectValues: (0..<count).map(PageSelection.name(of:)))
        }
        pageCount = count
        currentPage = current
        previousPage.isEnabled = current > 0
        nextPage.isEnabled = current < count - 1
        if !isEditing(pageField) { pageField.stringValue = count == 0 ? "" : "\(current + 1)" }
    }

    func show(sync state: SyncState) {
        model.syncState = state
    }

    func show(participants: [RemoteParticipant]) {
        model.participants = participants
    }

    // MARK: Actions

    @objc func addPageClicked(_ sender: Any?) { onAddPage?() }
    @objc func compassClicked(_ sender: Any?) { onResetRotation?() }
    @objc func previousPageClicked(_ sender: Any?) { onPage?(currentPage - 1) }
    @objc func nextPageClicked(_ sender: Any?) { onPage?(currentPage + 1) }

    @objc func pageEntered(_ sender: NSComboBox) {
        onPageText?(sender.stringValue)
    }

    @objc func magnificationEntered(_ sender: NSComboBox) {
        onMagnification?(sender.stringValue)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox else { return }
        let index = box.indexOfSelectedItem
        guard index >= 0 else { return }
        if box === pageField {
            onPage?(index)
        } else if let title = box.itemObjectValue(at: index) as? String {
            onMagnification?(title)
        }
    }

    @objc func viewModeChosen(_ sender: NSPopUpButton) {
        let index = max(sender.indexOfSelectedItem, 0)
        onViewMode?(ViewMode.allCases[index])
    }

    @objc func unitsChosen(_ sender: NSPopUpButton) {
        let index = max(sender.indexOfSelectedItem, 0)
        onUnits?(DocumentUnits.allCases[index])
    }
}

/// The status bar's compass: a needle showing which way the top of the page points and the
/// angle in degrees; hidden while the canvas is straight.  Clicking it resets the rotation.
@MainActor
final class CompassButton: NSButton {
    var degrees: Double = 0 {
        didSet { update() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 18))
        isBordered = false
        imagePosition = .imageLeading
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        image = NSImage(systemSymbolName: "location.north.fill", accessibilityDescription: "Compass")
        toolTip = "Canvas rotation; click to straighten"
        setAccessibilityIdentifier("status.compass")
        setAccessibilityLabel("Canvas rotation")
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CompassButton is built in code")
    }

    private func update() {
        let title = CanvasRotation.compassTitle(degrees)
        isHidden = title == nil
        self.title = title ?? ""
        setAccessibilityValue(title ?? "0°")
        // The needle points where the page's top points: counter-clockwise by the angle.
        image = CompassButton.needle(rotatedBy: degrees)
    }

    /// The north needle turned counter-clockwise by `degrees`.
    static func needle(rotatedBy degrees: Double) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "location.north.fill", accessibilityDescription: "Compass") else { return nil }
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: degrees * .pi / 180)
            symbol.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            return true
        }
    }
}
