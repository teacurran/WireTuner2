import AppKit
import SwiftUI

/// Where each tab of a crowded strip goes (D-077, revised): every tab at its full width when
/// they fit; else the unselected tabs drop their labels to icons; else as many tabs as fit (the
/// selected one always) and an overflow button for the rest.  Pure, so the rules are tested
/// without views.
enum TabStripLayout {
    /// One tab's widths: with its label, and as an icon (nil when it has no icon to fall back to).
    struct Tab: Equatable {
        var full: CGFloat
        var compact: CGFloat?
    }

    struct Result: Equatable {
        /// Each tab's frame, nil when it is in the overflow menu.
        var frames: [CGRect?]
        /// Whether each tab shows its icon only.
        var compact: [Bool]
        /// The overflow button's frame, nil when every tab shows.
        var overflow: CGRect?

        /// The tabs in the overflow menu, in order.
        var hidden: [Int] { frames.indices.filter { frames[$0] == nil } }
    }

    static let spacing: CGFloat = 2
    static let overflowWidth: CGFloat = 24

    /// The layout of `tabs` in a strip `width` wide and `height` tall.  With `fill`, tabs that
    /// fit share the spare width (a panel's inner sections span their strip).
    static func layout(_ tabs: [Tab], selected: Int?, width: CGFloat, height: CGFloat, fill: Bool = false) -> Result {
        guard !tabs.isEmpty else { return Result(frames: [], compact: [], overflow: nil) }
        let selected = selected.flatMap { tabs.indices.contains($0) ? $0 : nil }
        func total(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)) }

        let full = tabs.map(\.full)
        if total(full) <= width {
            let extra = fill ? (width - total(full)) / CGFloat(tabs.count) : 0
            return place(full.map { $0 + extra }, visible: Array(tabs.indices), compact: tabs.map { _ in false }, height: height, overflow: false)
        }
        let compact = tabs.indices.map { $0 != selected && tabs[$0].compact != nil }
        let reduced = tabs.indices.map { compact[$0] ? tabs[$0].compact! : tabs[$0].full }
        if total(reduced) <= width {
            return place(reduced, visible: Array(tabs.indices), compact: compact, height: height, overflow: false)
        }
        // Overflow: the selected tab first, then the others in order while they fit.
        let room = max(0, width - overflowWidth - spacing)
        var widths = reduced
        var visible: [Int] = []
        var used: CGFloat = 0
        let order = (selected.map { [$0] } ?? []) + tabs.indices.filter { $0 != selected }
        for index in order {
            let needed = widths[index] + (visible.isEmpty ? 0 : spacing)
            if used + needed <= room {
                visible.append(index)
                used += needed
            } else if visible.isEmpty {
                // Not even the selected tab fits: it takes what there is.
                widths[index] = room
                visible.append(index)
                used = room
            }
        }
        visible.sort()
        return place(widths, visible: visible, compact: compact, height: height, overflow: visible.count < tabs.count)
    }

    private static func place(_ widths: [CGFloat], visible: [Int], compact: [Bool], height: CGFloat, overflow: Bool) -> Result {
        var frames = [CGRect?](repeating: nil, count: widths.count)
        var x: CGFloat = 0
        for index in visible {
            frames[index] = CGRect(x: x, y: 0, width: widths[index], height: height)
            x += widths[index] + spacing
        }
        let button = overflow ? CGRect(x: x, y: 0, width: overflowWidth, height: height) : nil
        return Result(frames: frames, compact: compact, overflow: button)
    }
}

/// Our own tab control (D-077, revised after use: the system segmented look did not read as
/// tabs).  The tabs of a panel group are folder tabs: the selected one is a tinted surface joined
/// to the content card below it (the group's `PanelCardView` draws that surface), with an accent
/// bar along its top, a bold label and a full-contrast icon; unselected tabs are dimmer labels
/// with a hover highlight; the keyboard-focused tab shows a focus ring.  A crowded strip drops
/// unselected labels to icons, then overflows into a menu (`TabStripLayout`).  The inner sections
/// of control-dense panels (Transform's Move, Rotate, Scale, Skew, Reflect, through
/// `PanelSectionTabs`) use the secondary-level `.section` variant: the selected tab is a tinted
/// pill of its own with the accent bar under it.
///
/// Accessibility: the strip is a tab group, each tab a tab button (a radio button with the
/// tab-button subrole) whose value and selected state say which is in front; with a tab focused,
/// the arrow keys move to the next or previous tab and select it.
@MainActor
final class PanelTabStrip: NSView {
    enum Variant {
        /// A panel group's tabs: folder tabs over the group's card.
        case group
        /// A panel's inner sections: a secondary-level strip inside a panel body.
        case section
    }

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

    /// A group's strip; a section strip is `sectionHeight`.
    static let height: CGFloat = 28
    static let sectionHeight: CGFloat = 24
    static let caretWidth: CGFloat = 2
    /// The folder tab's top corners.
    static let tabCornerRadius: CGFloat = 7
    /// The accent bar of the selected tab.
    static let accentThickness: CGFloat = 3

    let variant: Variant
    let identifierPrefix: String
    private(set) var items: [Item] = []
    private(set) var buttons: [PanelTabButton] = []
    private(set) var selectedID: PanelID?
    /// The strip's last layout (which tabs show, compact or not, the overflow button).
    private(set) var arrangement = TabStripLayout.Result(frames: [], compact: [], overflow: nil)
    /// The button opening the menu of tabs that do not fit.
    private(set) var overflowButton: NSButton
    /// A tab was chosen by a click, an arrow key or the overflow menu.
    var onSelect: ((PanelID) -> Void)?
    /// The selected tab moved (a click, a relayout): the group redraws its card's folder tab.
    var onSelectionFrameChange: ((CGRect?) -> Void)?
    /// Hooks every tab gets (panel groups: dragging a tab out, the tab's context menu).
    var onDragTab: ((PanelTabButton, NSEvent) -> Void)? {
        didSet { for button in buttons { button.onDrag = onDragTab } }
    }
    var contextMenu: ((PanelID) -> NSMenu?)? {
        didSet { for button in buttons { button.contextMenu = contextMenu } }
    }

    /// The insertion caret a tab dragged over the strip shows.
    private(set) var caret = NSView()
    /// The tab under the pointer (hover highlight).
    private(set) var hoveredID: PanelID? {
        didSet { if hoveredID != oldValue { for button in buttons { button.isHovered = button.panelID == hoveredID } } }
    }

    /// A panel or group dragged over the strip: it takes the accent tint.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
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

    init(items: [Item], selected: PanelID?, variant: Variant = .group, identifierPrefix: String = "panel-tab.", accessibilityLabel: String = "Tabs") {
        self.variant = variant
        self.identifierPrefix = identifierPrefix
        overflowButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More Tabs")!, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: variant == .group ? Self.height : Self.sectionHeight))
        overflowButton.isBordered = false
        overflowButton.contentTintColor = PanelTabButton.unselectedColor
        overflowButton.setAccessibilityLabel("More Tabs")
        overflowButton.setAccessibilityIdentifier("\(identifierPrefix)overflow")
        overflowButton.toolTip = "More tabs"
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow(_:))
        overflowButton.isHidden = true
        addSubview(overflowButton)
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

    override var isFlipped: Bool { true }
    var stripHeight: CGFloat { variant == .group ? Self.height : Self.sectionHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: stripHeight) }

    /// Replaces the tabs (a panel joined or left, the label preference changed).
    func setItems(_ items: [Item], selected: PanelID?) {
        if items == self.items, !buttons.isEmpty || items.isEmpty {
            select(selected, animated: false)
            return
        }
        for button in buttons { button.removeFromSuperview() }
        self.items = items
        buttons = items.map { item in
            let button = PanelTabButton(panelID: item.id, title: item.title, image: item.image, variant: variant)
            button.setAccessibilityIdentifier("\(identifierPrefix)\(item.id.rawValue)")
            button.toolTip = item.toolTip
            button.setAccessibilityLabel(item.accessibilityLabel)
            button.strip = self
            button.target = self
            button.action = #selector(tabClicked(_:))
            button.onDrag = onDragTab
            button.contextMenu = contextMenu
            addSubview(button, positioned: .below, relativeTo: overflowButton)
            return button
        }
        setAccessibilityTabs(buttons)
        selectedID = nil
        select(selected, animated: false)
        needsLayout = true
    }

    /// Marks `id` as the front tab.
    func select(_ id: PanelID?, animated: Bool) {
        let resolved = id.flatMap { id in items.contains { $0.id == id } ? id : nil } ?? items.first?.id
        let changed = resolved != selectedID
        selectedID = resolved
        for button in buttons { button.isFront = button.panelID == resolved }
        guard changed else { return }
        // The widths depend on which tab is selected (it keeps its label): lay out now.
        if bounds.width > 0 { layoutTabs() } else { needsLayout = true }
    }

    var selectedIndex: Int? { selectedID.flatMap { id in items.firstIndex { $0.id == id } } }

    /// The selected tab's frame in this view, nil when there is none (or it is laid out nowhere).
    var selectedTabFrame: CGRect? {
        guard let index = selectedIndex, arrangement.frames.indices.contains(index) else { return nil }
        return arrangement.frames[index]
    }

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
        choose(next.panelID)
        window?.makeFirstResponder(next)
    }

    /// The first or last tab (Home, End).
    func moveSelection(toEnd end: Bool) {
        guard let target = end ? buttons.last : buttons.first else { return }
        choose(target.panelID)
        window?.makeFirstResponder(target)
    }

    // MARK: Overflow

    /// The menu of the tabs that do not fit: choosing one selects it (and so brings it into the
    /// strip).
    func overflowMenu() -> NSMenu {
        let menu = NSMenu(title: "More Tabs")
        for index in arrangement.hidden {
            let item = NSMenuItem(title: items[index].accessibilityLabel, action: #selector(overflowChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = items[index].image
            item.representedObject = items[index].id.rawValue
            item.identifier = NSUserInterfaceItemIdentifier("\(identifierPrefix)overflow.\(items[index].id.rawValue)")
            menu.addItem(item)
        }
        return menu
    }

    /// Shows the overflow menu under its button (replaceable in tests, which cannot track menus).
    var presentOverflow: @MainActor (NSMenu, NSButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc func showOverflow(_ sender: NSButton) {
        presentOverflow(overflowMenu(), sender)
    }

    @objc func overflowChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        choose(PanelID(rawValue: raw))
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
    }

    /// The pointer at `point` (this view): the tab under it takes the hover highlight.
    func hover(at point: CGPoint?) {
        hoveredID = point.flatMap { point in buttons.first { !$0.isHidden && $0.frame.contains(point) }?.panelID }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// The widths each tab asks for.
    func tabWidths() -> [TabStripLayout.Tab] {
        buttons.map { TabStripLayout.Tab(full: $0.width(compact: false), compact: $0.canBeCompact ? $0.width(compact: true) : nil) }
    }

    private func layoutTabs() {
        let result = TabStripLayout.layout(tabWidths(), selected: selectedIndex, width: bounds.width, height: stripHeight, fill: variant == .section)
        arrangement = result
        for (index, button) in buttons.enumerated() {
            if let frame = result.frames[index] {
                button.isHidden = false
                button.isCompact = result.compact[index]
                if button.frame != frame { button.frame = frame }
            } else {
                button.isHidden = true
                button.frame = .zero
            }
        }
        if let frame = result.overflow {
            overflowButton.frame = frame
            overflowButton.isHidden = false
        } else {
            overflowButton.isHidden = true
        }
        if let insertionIndex {
            let x = caretX(before: insertionIndex)
            caret.frame = CGRect(x: max(0, x - Self.caretWidth / 2), y: 3, width: Self.caretWidth, height: stripHeight - 6)
            caret.isHidden = false
        } else {
            caret.isHidden = true
        }
        onSelectionFrameChange?(selectedTabFrame)
        needsDisplay = true
    }

    /// Where the caret shows for a drop before tab `index`.
    private func caretX(before index: Int) -> CGFloat {
        let shown = arrangement.frames.compactMap { $0 }
        if index < arrangement.frames.count, let frame = arrangement.frames[index] { return frame.minX }
        return shown.last?.maxX ?? 0
    }

    /// The tab index a drop at `x` (in this view) lands before: tabs in the overflow menu count
    /// as lying after the visible ones.
    func tabIndex(atX x: CGFloat) -> Int {
        if arrangement.frames.count != buttons.count { layoutTabs() }
        let end = arrangement.overflow?.midX ?? .greatestFiniteMagnitude
        let middles = arrangement.frames.map { $0?.midX ?? end }
        return PanelDockController.tabIndex(forX: x, frames: middles.map { CGRect(x: $0, y: 0, width: 0, height: 0) })
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTarget else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Self.tabCornerRadius, yRadius: Self.tabCornerRadius).fill()
    }
}

/// A tab of a `PanelTabStrip`, drawn by itself: its label (icon and name, or the icon alone when
/// the strip is crowded), the hover highlight, the accent bar of the selected tab (and, in a
/// section strip, its tinted pill) and the keyboard focus ring.  A click selects it; a drag hands
/// the panel to the host's dragging session; the arrow keys move between the strip's tabs.
@MainActor
final class PanelTabButton: NSButton {
    let panelID: PanelID
    let variant: PanelTabStrip.Variant
    var onDrag: ((PanelTabButton, NSEvent) -> Void)?
    /// The tab's context menu (secondary click or Control-click).
    var contextMenu: ((PanelID) -> NSMenu?)?
    weak var strip: PanelTabStrip?

    static let padding: CGFloat = 9
    static let iconSize: CGFloat = 14
    static let iconGap: CGFloat = 5
    /// The label of an unselected tab: dimmer than the selected tab's, and still legible over
    /// the frosted panel chrome (`PanelLegibilityTests` measures it).
    static let unselectedColor = NSColor(name: "panelTabUnselected") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.72)
    }
    /// A section strip's selected pill.
    static let sectionSelectionColor = NSColor(name: "panelSectionSelection") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 1, alpha: 0.9)
    }

    init(panelID: PanelID, title: String, image: NSImage? = nil, variant: PanelTabStrip.Variant = .group) {
        self.panelID = panelID
        self.variant = variant
        super.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        isBordered = false
        setButtonType(.pushOnPushOff)
        font = Self.font(front: false, variant: variant)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        imageScaling = .scaleProportionallyDown
        // The tab draws its own ring (inside its shape, and in bitmaps too).
        focusRingType = .none
        setAccessibilityIdentifier("panel-tab.\(panelID.rawValue)")
        applyFrontStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelTabButton is built in code")
    }

    static func font(front: Bool, variant: PanelTabStrip.Variant) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: front ? .bold : .regular)
    }

    /// Whether this is the strip's front tab: the button's state, its weight and colour.
    /// Reapplied on every selection: a click toggles a push-on-push-off button's state.
    var isFront: Bool = false {
        didSet { applyFrontStyle() }
    }

    /// Under the pointer (unselected tabs show a highlight).
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    /// The strip is crowded: an unselected tab shows its icon only.
    var isCompact = false {
        didSet { if isCompact != oldValue { needsDisplay = true } }
    }

    /// Whether the tab has an icon to fall back to when crowded (and a label to drop).
    var canBeCompact: Bool { image != nil && !title.isEmpty }

    private func applyFrontStyle() {
        state = isFront ? .on : .off
        contentTintColor = isFront ? .labelColor : Self.unselectedColor
        font = Self.font(front: isFront, variant: variant)
        needsDisplay = true
    }

    /// The width the tab asks for: padding, icon, gap and the name set in bold (so selecting a
    /// tab does not change the strip's widths).
    func width(compact: Bool) -> CGFloat {
        let showsTitle = !title.isEmpty && !(compact && image != nil)
        let text = showsTitle ? ceil((title as NSString).size(withAttributes: [.font: Self.font(front: true, variant: variant)]).width) : 0
        let icon = image != nil ? Self.iconSize : 0
        let gap = icon > 0 && showsTitle ? Self.iconGap : 0
        return 2 * Self.padding + icon + gap + text
    }

    /// Whether the keyboard focus ring shows: the tab has the focus, in the key window (or in a
    /// window that is not on screen, as when rendered in a test).
    var showsFocus: Bool {
        guard let window, window.firstResponder === self else { return false }
        return window.isKeyWindow || !window.isVisible
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        needsDisplay = true
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let radius = PanelTabStrip.tabCornerRadius
        if isFront {
            if variant == .section {
                Self.sectionSelectionColor.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius).fill()
                NSColor.separatorColor.setStroke()
                let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                outline.lineWidth = 1
                outline.stroke()
            }
            NSColor.controlAccentColor.setFill()
            let bar = PanelTabStrip.accentThickness - (variant == .section ? 1 : 0)
            let inset = min(8, bounds.width / 4)
            // A folder tab's bar runs along its top; a section's under it.
            let y = variant == .group ? 1 : bounds.height - bar - 1
            NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: max(0, bounds.width - 2 * inset), height: bar), xRadius: bar / 2, yRadius: bar / 2).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: radius - 1, yRadius: radius - 1).fill()
        }
        drawLabel(in: bounds)
        if showsFocus {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 2.5), xRadius: radius - 1, yRadius: radius - 1)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    /// The icon and the name, centred, in the label colour (selected) or the dimmer one.
    private func drawLabel(in bounds: NSRect) {
        let color = isFront ? NSColor.labelColor : Self.unselectedColor
        let showsTitle = !title.isEmpty && !(isCompact && image != nil)
        let font = Self.font(front: isFront, variant: variant)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = showsTitle ? (title as NSString).size(withAttributes: attributes) : .zero
        let icon: CGFloat = image != nil ? Self.iconSize : 0
        let gap = icon > 0 && showsTitle ? Self.iconGap : 0
        let available = max(0, bounds.width - 2 * Self.padding)
        let textWidth = min(textSize.width, max(0, available - icon - gap))
        let content = icon + gap + textWidth
        var x = bounds.minX + max(Self.padding, (bounds.width - content) / 2)
        // A group tab's label sits a little below centre, clear of the accent bar.
        let middle = bounds.midY + (variant == .group ? 1 : 0)
        if let image {
            let rect = NSRect(x: x, y: middle - icon / 2, width: icon, height: icon)
            Self.tinted(image, color: color).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += icon + gap
        }
        if showsTitle, textWidth > 0 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var truncated = attributes
            truncated[.paragraphStyle] = style
            (title as NSString).draw(with: NSRect(x: x, y: middle - textSize.height / 2, width: textWidth, height: textSize.height),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: truncated)
        }
    }

    /// `image` filled with `color` (symbol images are templates).
    static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
            let size = image.size
            let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
            let fitted = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
            image.draw(in: fitted)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
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

/// The tab control in SwiftUI, for a panel's inner sections (D-077: Transform's Move, Rotate,
/// Scale, Skew, Reflect): the `.section` variant of the `PanelTabStrip` a panel group's tabs use.
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
        let strip = PanelTabStrip(items: items(), selected: selectedID(), variant: .section, identifierPrefix: "\(identifier).", accessibilityLabel: label)
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
        CGSize(width: proposal.width ?? CGFloat(options.count) * 64, height: PanelTabStrip.sectionHeight)
    }
}
