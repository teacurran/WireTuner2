import AppKit

/// The status bar along the bottom of the canvas (workspace.adoc, "The status bar"): page
/// selector, magnification field, view mode pop-up and the message area.  BASIC-002 fills in
/// Add Page, typed page navigation, units, the sync indicator and avatars; the page selector
/// here is a disabled placeholder showing page 1.
@MainActor
final class StatusBarView: NSView, NSComboBoxDelegate {
    static let height: CGFloat = 24
    static let fitSelectionTitle = "Fit Selection"
    static let fitPageTitle = "Fit to Page"
    static let fitAllTitle = "Fit All"

    let previousPage = NSButton(title: "<", target: nil, action: nil)
    let pageField = NSTextField(labelWithString: "1")
    let nextPage = NSButton(title: ">", target: nil, action: nil)
    let magnification = NSComboBox()
    let viewMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let message = NSTextField(labelWithString: "")

    /// Typed text or a chosen preset, as entered.
    var onMagnification: (@MainActor (String) -> Void)?
    var onViewMode: (@MainActor (ViewMode) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("status-bar")

        for button in [previousPage, nextPage] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.isEnabled = false
        }
        previousPage.setAccessibilityIdentifier("status.page.previous")
        nextPage.setAccessibilityIdentifier("status.page.next")
        pageField.setAccessibilityIdentifier("status.page")
        pageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pageField.toolTip = "Page selection arrives with the page model"

        magnification.controlSize = .small
        magnification.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        magnification.isEditable = true
        magnification.completes = false
        magnification.numberOfVisibleItems = 16
        magnification.addItems(withObjectValues: MagnificationFormat.presetTitles + [Self.fitSelectionTitle, Self.fitPageTitle, Self.fitAllTitle])
        magnification.target = self
        magnification.action = #selector(magnificationEntered(_:))
        magnification.delegate = self
        magnification.setAccessibilityIdentifier("status.magnification")

        viewMode.controlSize = .small
        viewMode.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        viewMode.addItems(withTitles: ViewMode.allCases.map(\.title))
        viewMode.target = self
        viewMode.action = #selector(viewModeChosen(_:))
        viewMode.setAccessibilityIdentifier("status.viewMode")

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setAccessibilityIdentifier("status.message")
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [previousPage, pageField, nextPage, magnification, viewMode, message])
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
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBarView is built in code")
    }

    func show(zoom: Double) {
        magnification.stringValue = MagnificationFormat.string(for: zoom)
    }

    func show(mode: ViewMode) {
        viewMode.selectItem(at: ViewMode.allCases.firstIndex(of: mode) ?? 0)
    }

    func show(message text: String) {
        message.stringValue = text
    }

    @objc func magnificationEntered(_ sender: NSComboBox) {
        onMagnification?(sender.stringValue)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = magnification.indexOfSelectedItem
        guard index >= 0, let title = magnification.itemObjectValue(at: index) as? String else { return }
        onMagnification?(title)
    }

    @objc func viewModeChosen(_ sender: NSPopUpButton) {
        let index = max(sender.indexOfSelectedItem, 0)
        onViewMode?(ViewMode.allCases[index])
    }
}
