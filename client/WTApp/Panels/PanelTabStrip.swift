import AppKit
import SwiftUI

/// A Liquid Glass tab strip (D-077; panels.adoc, "To activate a panel in a group"): a glass
/// track with one tab per item and a glass selection under the front tab.  The tabs of a panel
/// group, and the inner sections of control-dense panels (Transform's Move, Rotate, Scale, Skew,
/// Reflect, through `PanelSectionTabs`), use this one control.
///
/// Accessibility: the strip is a tab group, each tab a tab button (a radio button with the
/// tab-button subrole) whose value and selected state say which is in front; with a tab focused,
/// the arrow keys move to the next or previous tab and select it.
@MainActor
final class PanelTabStrip: NSView {
    /// One tab: its id, the label the *Label panel tabs with* preference chose, and its name.
    struct Item: Equatable {
        var id: PanelID
        var title: String
        var image: NSImage?
        var toolTip: String?
        /// The name VoiceOver reads (the panel's title, even when the tab shows only an icon).
        var accessibilityLabel: String

        init(id: PanelID, title: String, image: NSImage? = nil, toolTip: String? = nil, accessibilityLabel: String? = nil) {
            self.id = id
            self.title = title
            self.image = image
            self.toolTip = toolTip
            self.accessibilityLabel = accessibilityLabel ?? title
        }
    }

    static let height: CGFloat = 26
    /// Between the track's edge and the tabs (the selection's margin).
    static let inset: CGFloat = 2
    static let caretWidth: CGFloat = 2

    let identifierPrefix: String
    private(set) var items: [Item] = []
    private(set) var buttons: [PanelTabButton] = []
    private(set) var selectedID: PanelID?
    /// A tab was chosen by a click or an arrow key.
    var onSelect: ((PanelID) -> Void)?
    /// Hooks every tab gets (panel groups: dragging a tab out, the tab's context menu).
    var onDragTab: ((PanelTabButton, NSEvent) -> Void)? {
        didSet { for button in buttons { button.onDrag = onDragTab } }
    }
    var contextMenu: ((PanelID) -> NSMenu?)? {
        didSet { for button in buttons { button.contextMenu = contextMenu } }
    }

    /// The glass track and the glass selection, rendered together in one container.
    private(set) var track: NSView
    private(set) var thumb: NSView
    private let glassHost = NSView()
    private var glassContainer: NSView!
    /// The insertion caret a tab dragged over the strip shows.
    private(set) var caret = NSView()

    /// A panel or group dragged over the strip: the track takes the accent tint.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            PanelGlass.setTint(isDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.35) : nil, of: track)
            setAccessibilityValue(isDropTarget ? "Drop target" : nil)
        }
    }

    /// Where a dragged tab would land (before tab `insertionIndex`); nil hides the caret.
    var insertionIndex: Int? {
        didSet {
            guard insertionIndex != oldValue else { return }
            needsLayout = true
        }
    }

    init(items: [Item], selected: PanelID?, identifierPrefix: String = "panel-tab.", accessibilityLabel: String = "Tabs") {
        self.identifierPrefix = identifierPrefix
        track = PanelGlass.surface(cornerRadius: Self.height / 2)
        thumb = PanelGlass.surface(cornerRadius: (Self.height - 2 * Self.inset) / 2, tint: Self.selectionTint)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        glassHost.addSubview(track)
        glassHost.addSubview(thumb)
        glassContainer = PanelGlass.container(content: glassHost)
        glassContainer.setAccessibilityElement(false)
        addSubview(glassContainer)
        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        caret.layer?.cornerRadius = Self.caretWidth / 2
        caret.isHidden = true
        addSubview(caret)

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(accessibilityLabel)
        setItems(items, selected: selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelTabStrip is built in code")
    }

    /// The selection's glass: lighter than the track in either appearance.
    static let selectionTint = NSColor(name: "panelTabSelection") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.7)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    /// Replaces the tabs (a panel joined or left, the label preference changed).
    func setItems(_ items: [Item], selected: PanelID?) {
        if items == self.items, !buttons.isEmpty || items.isEmpty {
            select(selected, animated: false)
            return
        }
        for button in buttons { button.removeFromSuperview() }
        self.items = items
        buttons = items.map { item in
            let button = PanelTabButton(panelID: item.id, title: item.title, image: item.image)
            button.setAccessibilityIdentifier("\(identifierPrefix)\(item.id.rawValue)")
            button.toolTip = item.toolTip
            button.setAccessibilityLabel(item.accessibilityLabel)
            button.strip = self
            button.target = self
            button.action = #selector(tabClicked(_:))
            button.onDrag = onDragTab
            button.contextMenu = contextMenu
            addSubview(button, positioned: .below, relativeTo: caret)
            return button
        }
        setAccessibilityTabs(buttons)
        selectedID = nil
        select(selected, animated: false)
        needsLayout = true
    }

    /// Marks `id` as the front tab, the glass selection sliding to it when `animated`.
    func select(_ id: PanelID?, animated: Bool) {
        let resolved = id.flatMap { id in items.contains { $0.id == id } ? id : nil } ?? items.first?.id
        let changed = resolved != selectedID
        selectedID = resolved
        for button in buttons { button.isFront = button.panelID == resolved }
        thumb.isHidden = resolved == nil
        guard changed else { return }
        if animated {
            PanelGlass.animate(in: self) { self.layoutTabs(animated: true) }
        } else {
            needsLayout = true
        }
    }

    var selectedIndex: Int? { selectedID.flatMap { id in items.firstIndex { $0.id == id } } }

    @objc func tabClicked(_ sender: PanelTabButton) {
        choose(sender.panelID)
    }

    /// A tab chosen by the user: selected here at once, then reported.
    func choose(_ id: PanelID) {
        select(id, animated: true)
        onSelect?(id)
    }

    /// The arrow keys: the tab `offset` places from `button` (wrapping) becomes the front tab and
    /// takes the focus.
    func moveSelection(from button: PanelTabButton, by offset: Int) {
        guard let index = buttons.firstIndex(of: button), !buttons.isEmpty else { return }
        let next = buttons[(index + offset + buttons.count) % buttons.count]
        window?.makeFirstResponder(next)
        choose(next.panelID)
    }

    /// The first or last tab (Home, End).
    func moveSelection(toEnd end: Bool) {
        guard let target = end ? buttons.last : buttons.first else { return }
        window?.makeFirstResponder(target)
        choose(target.panelID)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    /// Each tab's frame: the strip's width shared equally, as a segmented control.
    func tabFrames(in width: CGFloat) -> [CGRect] {
        guard !buttons.isEmpty else { return [] }
        let usable = max(0, width - 2 * Self.inset)
        let each = usable / CGFloat(buttons.count)
        return buttons.indices.map { CGRect(x: Self.inset + CGFloat($0) * each, y: Self.inset, width: each, height: Self.height - 2 * Self.inset) }
    }

    private func layoutTabs(animated: Bool) {
        glassContainer.frame = bounds
        glassHost.frame = glassContainer.bounds
        track.frame = glassHost.bounds
        let frames = tabFrames(in: bounds.width)
        for (button, frame) in zip(buttons, frames) { button.frame = frame }
        if let index = selectedIndex, frames.indices.contains(index) {
            (animated ? thumb.animator() : thumb).frame = frames[index]
        }
        if let insertionIndex, !frames.isEmpty {
            let x = insertionIndex < frames.count ? frames[insertionIndex].minX : frames[frames.count - 1].maxX
            caret.frame = CGRect(x: max(0, x - Self.caretWidth / 2), y: 1, width: Self.caretWidth, height: Self.height - 2)
            caret.isHidden = false
        } else {
            caret.isHidden = true
        }
    }

    /// The tab index a drop at `x` (in this view) lands before.
    func tabIndex(atX x: CGFloat) -> Int {
        let frames = buttons.isEmpty ? [] : (bounds.width > 0 ? tabFrames(in: bounds.width) : buttons.map(\.frame))
        return PanelDockController.tabIndex(forX: x, frames: frames)
    }
}

/// A tab of a `PanelTabStrip`.  A click selects it; a drag hands the panel to the host's
/// dragging session; the arrow keys move between the strip's tabs.  Borderless: the strip's
/// glass selection marks the front tab.
@MainActor
final class PanelTabButton: NSButton {
    let panelID: PanelID
    var onDrag: ((PanelTabButton, NSEvent) -> Void)?
    /// The tab's context menu (secondary click or Control-click).
    var contextMenu: ((PanelID) -> NSMenu?)?
    weak var strip: PanelTabStrip?

    init(panelID: PanelID, title: String, image: NSImage? = nil) {
        self.panelID = panelID
        super.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        isBordered = false
        setButtonType(.pushOnPushOff)
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        imageScaling = .scaleProportionallyDown
        focusRingType = .default
        setAccessibilityIdentifier("panel-tab.\(panelID.rawValue)")
        applyFrontStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelTabButton is built in code")
    }

    /// Whether this is the strip's front tab: the button's state, its weight and colour.
    var isFront: Bool = false {
        didSet { applyFrontStyle() }
    }

    private func applyFrontStyle() {
        state = isFront ? .on : .off
        contentTintColor = isFront ? .labelColor : .secondaryLabelColor
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: isFront ? .semibold : .regular)
    }

    // MARK: Accessibility: a tab button in a tab group

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { Self.tabSubrole }
    /// `NSAccessibilityTabButtonSubrole`.
    static let tabSubrole = NSAccessibility.Subrole(rawValue: "AXTabButton")
    override func accessibilityValue() -> Any? { NSNumber(value: state == .on ? 1 : 0) }
    override func isAccessibilitySelected() -> Bool { state == .on }
    override func accessibilityRoleDescription() -> String? { "tab" }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let strip else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?, .upArrow?: strip.moveSelection(from: self, by: -1)
        case .rightArrow?, .downArrow?: strip.moveSelection(from: self, by: 1)
        case .home?: strip.moveSelection(toEnd: false)
        case .end?: strip.moveSelection(toEnd: true)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?(panelID)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = contextMenu?(panelID) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        guard let window,
            let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true)
        else { return }
        if next.type == .leftMouseDragged, let onDrag {
            onDrag(self, event)
        } else {
            performClick(nil)
        }
    }
}

/// The glass tab strip in SwiftUI, for a panel's inner sections (D-077: Transform's Move,
/// Rotate, Scale, Skew, Reflect).  The same `PanelTabStrip` a panel group's tabs use.
struct PanelSectionTabs<Value: Hashable>: NSViewRepresentable {
    let label: String
    let options: [(value: Value, id: String, title: String)]
    @Binding var selection: Value
    /// The strip's accessibility identifier; each tab's is `<identifier>.<id>`.
    let identifier: String

    func items() -> [PanelTabStrip.Item] {
        options.map { PanelTabStrip.Item(id: PanelID($0.id), title: $0.title) }
    }

    func selectedID() -> PanelID? {
        options.first { $0.value == selection }.map { PanelID($0.id) }
    }

    func makeNSView(context: Context) -> PanelTabStrip {
        let strip = PanelTabStrip(items: items(), selected: selectedID(), identifierPrefix: "\(identifier).", accessibilityLabel: label)
        strip.setAccessibilityIdentifier(identifier)
        updateNSView(strip, context: context)
        return strip
    }

    func updateNSView(_ strip: PanelTabStrip, context: Context) {
        strip.setItems(items(), selected: selectedID())
        let options = options
        let binding = $selection
        strip.onSelect = { id in
            if let option = options.first(where: { $0.id == id.rawValue }) { binding.wrappedValue = option.value }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelTabStrip, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? CGFloat(options.count) * 64, height: PanelTabStrip.height)
    }
}
