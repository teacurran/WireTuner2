import AppKit

/// One group (panels.adoc, "Docking and floating"; D-077, revised after use): the title bar -- a
/// close button when floating, the gripper, the disclosure triangle, the title (or the rename
/// field), the Options button -- then, when the group has more than one panel, our tab strip,
/// whose selected tab is joined to the card below it like a folder tab; then the front panel's
/// body on the card's heavier frost.  A group with one panel shows no strip (it drags by its
/// title).  The body scrolls when it is taller than the group, and the group clips it, so it
/// never draws over its neighbour.  A collapsed group is its title bar only.  Floating, the whole
/// group sits on the system glass with the chrome's frost.  Reports gestures through closures and
/// never touches the layout itself.
@MainActor
final class PanelGroupView: NSView, NSTextFieldDelegate {
    static let titleHeight: CGFloat = 28
    /// The tab row: the strip, whose selected tab runs straight into the card.
    static let tabRowHeight: CGFloat = PanelTabStrip.height
    /// Around the card.
    static let margin: CGFloat = 6
    static let bodyCornerRadius: CGFloat = PanelCardView.cornerRadius

    /// Whether `group` shows a tab strip: only with more than one panel.
    static func showsTabs(_ group: PanelGroup) -> Bool { group.panels.count > 1 }

    /// The group's height without its body: the title bar, and when expanded the tab row (with
    /// tabs) and the margin under the card.
    static func chromeHeight(collapsed: Bool, tabs: Bool = true) -> CGFloat {
        collapsed ? titleHeight : titleHeight + (tabs ? tabRowHeight : 0) + margin
    }

    /// The group's height with a body `content` points tall.
    static func height(forContent content: CGFloat, collapsed: Bool, tabs: Bool = true) -> CGFloat {
        collapsed ? titleHeight : chromeHeight(collapsed: false, tabs: tabs) + max(0, content)
    }

    /// `group`'s chrome height.
    static func chromeHeight(of group: PanelGroup) -> CGFloat {
        chromeHeight(collapsed: group.collapsed, tabs: showsTabs(group))
    }

    private(set) var group: PanelGroup
    let isFloating: Bool
    let panelAppearance: PanelAppearance
    private let titles: (PanelID) -> String
    private(set) var titleLabel: NSTextField
    private(set) var renameField: NSTextField?
    private(set) var disclosure: NSButton
    private(set) var optionsButton: NSButton
    private(set) var closeButton: NSButton?
    private(set) var gripper: GripperView
    private(set) var tabStrip: PanelTabStrip
    /// The card under the selected tab and the body, and the scroll view the body is in.
    private(set) var bodyCard: PanelCardView
    private(set) var bodyScroll: NSScrollView
    /// The scroll view's document: holds the front panel's body.
    private(set) var contentView = PanelBodyView()
    private(set) var titleBar: PanelTitleBar
    /// The glass under a floating group.
    private(set) var background: NSView?
    /// The chrome's frost on a floating group's glass.
    private(set) var frost: PanelFrostView?
    /// A panel or group dragged over this group's title (a group without a strip shows it there).
    private(set) var isDropTarget = false
    /// The dock this group is docked in; drags over its body go to the dock (to dock between
    /// groups) rather than joining the group.
    weak var dock: PanelDockController?

    var onSelectTab: ((PanelID) -> Void)?
    var onToggleCollapse: (() -> Void)?
    /// A panel or group dropped on the tab strip, before tab `index` (nil: at the end).
    var onDrop: ((PanelDragPayload, Int?) -> Void)?
    var onDragTab: ((PanelTabButton, NSEvent) -> Void)?
    /// A tab's context menu.
    var tabMenu: ((PanelID) -> NSMenu?)?
    var onDragGroup: ((NSEvent) -> Void)?
    var onRename: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onOptions: ((NSButton) -> Void)?

    init(
        group: PanelGroup, title: @escaping (PanelID) -> String, icon: (PanelID) -> String = { _ in "square.dashed" }, body: (PanelID) -> NSView,
        appearance: PanelAppearance = .standard, isFloating: Bool = false
    ) {
        self.group = group
        self.isFloating = isFloating
        self.panelAppearance = appearance
        self.titles = title
        titleLabel = NSTextField(labelWithString: group.displayName(titles: title))
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = group.collapsed ? .off : .on
        disclosure.setAccessibilityLabel(group.collapsed ? "Expand" : "Collapse")
        optionsButton = Self.chromeButton(symbol: "ellipsis", label: "Options")
        gripper = GripperView()
        titleBar = PanelTitleBar()
        let items = group.panels.map { panel in
            let label = appearance.tabLabel(title: title(panel), icon: icon(panel))
            return PanelTabStrip.Item(id: panel, title: label.title, image: label.image, toolTip: appearance.showsTooltips ? title(panel) : nil, accessibilityLabel: title(panel))
        }
        tabStrip = PanelTabStrip(items: items, selected: group.effectiveActivePanel, accessibilityLabel: group.displayName(titles: title))
        bodyCard = PanelCardView(translucent: appearance.isTranslucent)
        bodyScroll = NSScrollView()
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 320))

        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityIdentifier("panel-group.\(group.id)")
        registerForDraggedTypes([PanelDragPayload.panelType, PanelDragPayload.groupType])
        if isFloating {
            let glass = PanelGlass.surface(cornerRadius: FloatingPanelWindow.cornerRadius)
            glass.setAccessibilityElement(false)
            addSubview(glass)
            background = glass
            let wash = PanelFrostView(level: .chrome, translucent: appearance.isTranslucent, cornerRadius: FloatingPanelWindow.cornerRadius)
            addSubview(wash)
            frost = wash
        }

        disclosure.target = self
        disclosure.action = #selector(toggleCollapse(_:))
        disclosure.setAccessibilityIdentifier("panel-group.\(group.id).disclosure")
        optionsButton.target = self
        optionsButton.action = #selector(showOptions(_:))
        optionsButton.setAccessibilityIdentifier("panel-group.\(group.id).options")
        optionsButton.toolTip = appearance.showsTooltips ? "Options" : nil
        gripper.onDrag = { [weak self] event in self?.onDragGroup?(event) }
        gripper.setAccessibilityIdentifier("panel-group.\(group.id).gripper")
        gripper.toolTip = appearance.showsTooltips ? "Drag to dock, float or join another group" : nil

        var titleViews: [NSView] = []
        if isFloating {
            let close = Self.chromeButton(symbol: "xmark", label: "Close Group")
            close.target = self
            close.action = #selector(closeGroup(_:))
            close.setAccessibilityIdentifier("panel-group.\(group.id).close")
            closeButton = close
            titleViews.append(close)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        titleViews += [gripper, disclosure, titleLabel, spacer, optionsButton]
        titleBar.setViews(titleViews, in: .leading)
        titleBar.orientation = .horizontal
        titleBar.spacing = 4
        titleBar.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)
        titleBar.onClick = { [weak self] in self?.onToggleCollapse?() }
        // Docked, dragging the title drags the group (as the gripper does): a group without a
        // tab strip is dragged by its title.
        titleBar.onDrag = { [weak self] event in self?.onDragGroup?(event) }
        // A narrow (or hidden, zero-width) dock clips the title bar rather than breaking it.
        titleBar.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleBar)

        tabStrip.onSelect = { [weak self] panel in self?.onSelectTab?(panel) }
        tabStrip.onDragTab = { [weak self] button, event in self?.onDragTab?(button, event) }
        tabStrip.contextMenu = { [weak self] id in self?.tabMenu?(id) }
        tabStrip.setAccessibilityIdentifier("panel-group.\(group.id).tabs")
        tabStrip.onSelectionFrameChange = { [weak self] _ in self?.updateCardShape() }

        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.hasVerticalScroller = true
        bodyScroll.hasHorizontalScroller = false
        bodyScroll.autohidesScrollers = true
        bodyScroll.horizontalScrollElasticity = .none
        bodyScroll.setAccessibilityIdentifier("panel-group.\(group.id).body")
        contentView.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.documentView = contentView
        let clip = bodyScroll.contentView
        let fill = contentView.heightAnchor.constraint(equalTo: clip.heightAnchor)
        fill.priority = .init(250)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: clip.topAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            fill,
        ])
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.cornerRadius = Self.bodyCornerRadius
        bodyScroll.layer?.masksToBounds = true
        bodyCard.addSubview(bodyScroll)
        addSubview(bodyCard)
        // Over the card, so the selected tab's label sits on the card's folder tab.
        addSubview(tabStrip)
        show(group.effectiveActivePanel, body: body)
        applyCollapsed(group.collapsed)
        layoutParts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelGroupView is built in code")
    }

    /// A small round button of the title bar (glass on macOS 26).
    static func chromeButton(symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        button.setAccessibilityLabel(label)
        button.controlSize = .small
        if #available(macOS 26, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.isBordered = false
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    override var isFlipped: Bool { true }

    var tabButtons: [PanelTabButton] { tabStrip.buttons }
    var isCollapsed: Bool { bodyCard.isHidden }
    /// Whether the strip shows (expanded, with more than one panel).
    var showsTabs: Bool { !tabStrip.isHidden }

    // MARK: Updating in place

    /// Whether this view can show `group` by updating itself: the same group with the same
    /// panels, drawn with the same appearance.
    func canShow(_ group: PanelGroup, appearance: PanelAppearance) -> Bool {
        group.id == self.group.id && group.panels == self.group.panels && appearance == panelAppearance && renameField == nil
    }

    /// Shows `group` (the same panels as now): the name, the front tab, collapsed or not.
    func show(_ group: PanelGroup, body: (PanelID) -> NSView) {
        self.group = group
        titleLabel.stringValue = group.displayName(titles: titles)
        setAccessibilityLabel(titleLabel.stringValue)
        tabStrip.setAccessibilityLabel(titleLabel.stringValue)
        tabStrip.select(group.effectiveActivePanel, animated: true)
        show(group.effectiveActivePanel, body: body)
        applyCollapsed(group.collapsed)
    }

    /// Puts `panel`'s body in the scroll view.  The body fills the group's height and grows past
    /// it (and scrolls) only as far as its own minimum height asks.
    private func show(_ panel: PanelID?, body: (PanelID) -> NSView) {
        let current = contentView.subviews.first
        guard let panel else {
            current?.removeFromSuperview()
            return
        }
        let view = body(panel)
        guard view !== current else { return }
        current?.removeFromSuperview()
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .vertical)
        view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        bodyScroll.contentView.scroll(to: .zero)
    }

    private func applyCollapsed(_ collapsed: Bool) {
        disclosure.state = collapsed ? .off : .on
        disclosure.setAccessibilityLabel(collapsed ? "Expand" : "Collapse")
        tabStrip.isHidden = collapsed || !Self.showsTabs(group)
        bodyCard.isHidden = collapsed
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutParts()
    }

    private func layoutParts() {
        background?.frame = bounds
        frost?.frame = bounds
        let width = bounds.width
        let inner = max(0, width - 2 * Self.margin)
        titleBar.frame = NSRect(x: 0, y: 0, width: width, height: Self.titleHeight)
        let tabs = Self.showsTabs(group)
        tabStrip.frame = NSRect(x: Self.margin, y: Self.titleHeight, width: inner, height: PanelTabStrip.height)
        bodyCard.frame = NSRect(x: Self.margin, y: Self.titleHeight, width: inner, height: max(0, bounds.height - Self.titleHeight - Self.margin))
        bodyCard.bodyTop = tabs ? Self.tabRowHeight : 0
        bodyScroll.frame = bodyCard.bodyRect
        updateCardShape()
    }

    /// The card's folder tab follows the strip's selected tab.
    private func updateCardShape() {
        guard Self.showsTabs(group), let tab = tabStrip.selectedTabFrame else {
            bodyCard.tabRect = nil
            return
        }
        bodyCard.tabRect = bodyCard.convert(tab, from: tabStrip)
    }

    // MARK: Transparency

    /// Solid or translucent (the *Panel transparency* preference, Reduce Transparency).
    var isTranslucent: Bool { bodyCard.isTranslucent }

    @objc func selectTab(_ sender: PanelTabButton) {
        onSelectTab?(sender.panelID)
    }

    @objc func toggleCollapse(_ sender: Any?) {
        onToggleCollapse?()
    }

    @objc func showOptions(_ sender: NSButton) {
        onOptions?(sender)
    }

    @objc func closeGroup(_ sender: Any?) {
        onClose?()
    }

    // MARK: Renaming

    /// *Rename Panel Group…*: the title becomes a field holding the current name.
    func beginRename() {
        guard renameField == nil else { return }
        let field = NSTextField(string: titleLabel.stringValue)
        field.font = titleLabel.font
        field.controlSize = .small
        field.delegate = self
        field.setAccessibilityIdentifier("panel-group.\(group.id).rename")
        renameField = field
        titleLabel.isHidden = true
        titleBar.insertView(field, at: (titleBar.views.firstIndex(of: titleLabel) ?? 0) + 1, in: .leading)
        window?.makeFirstResponder(field)
    }

    /// Ends renaming: commits a non-empty name when `committed`, otherwise changes nothing.
    func endRename(committed: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        field.delegate = nil
        titleBar.removeView(field)
        titleLabel.isHidden = false
        if case let .commit(name) = GroupRename.outcome(text: field.stringValue, committed: committed) {
            titleLabel.stringValue = name
            onRename?(name)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename(committed: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(committed: false)
            return true
        default:
            return false
        }
    }

    /// Clicking anywhere else cancels.
    func controlTextDidEndEditing(_ notification: Notification) {
        endRename(committed: false)
    }

    // MARK: Drops

    /// The tab index a drop at `point` (in this view) lands before.
    func tabIndex(at point: CGPoint) -> Int {
        tabStrip.tabIndex(atX: tabStrip.convert(point, from: self).x)
    }

    /// Whether a drop at `point` (in this view) joins this group: anywhere on a floating group
    /// or one outside a dock, else on the title bar and tab strip.  Over a docked group's body
    /// the drop goes to the dock, to dock between groups.
    func joins(at point: CGPoint) -> Bool {
        dock == nil || isFloating || point.y < Self.titleHeight + (showsTabs ? Self.tabRowHeight : 0)
    }

    private func dockPoint(_ sender: NSDraggingInfo) -> CGPoint? {
        guard let dock else { return nil }
        return dock.view.convert(sender.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard PanelDragPayload.read(from: sender.draggingPasteboard) != nil else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        if joins(at: point) {
            setDropTarget(true)
            tabStrip.insertionIndex = showsTabs ? tabIndex(at: point) : nil
            dock?.showInsertion(atDockPoint: nil)
        } else {
            clearDropHighlight()
            dock?.showInsertion(atDockPoint: dockPoint(sender))
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropHighlight()
        dock?.showInsertion(atDockPoint: nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropHighlight()
    }

    func clearDropHighlight() {
        setDropTarget(false)
        tabStrip.insertionIndex = nil
    }

    /// The strip takes the accent tint; a group without a strip tints its title bar instead.
    private func setDropTarget(_ on: Bool) {
        isDropTarget = on
        tabStrip.isDropTarget = on
        titleBar.wantsLayer = true
        titleBar.layer?.cornerRadius = 7
        titleBar.layer?.backgroundColor = on && !showsTabs ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = PanelDragPayload.read(from: sender.draggingPasteboard) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        clearDropHighlight()
        if joins(at: point) {
            onDrop?(payload, tabIndex(at: point))
        } else if let dock, let dockPoint = dockPoint(sender) {
            dock.handleDrop(payload, atDockPoint: dockPoint)
        }
        return true
    }
}

/// The scroll view's document inside a group: flipped, so a body starts at the top.
@MainActor
final class PanelBodyView: NSView {
    override var isFlipped: Bool { true }
}

/// A group's title bar.  A click on the title (or the empty bar) expands or collapses the group;
/// dragging it moves a floating group's window.  The buttons and the gripper keep their clicks.
@MainActor
final class PanelTitleBar: NSStackView {
    /// A drag shorter than this (points) is a click.
    static let clickSlop: CGFloat = 3
    var onClick: (() -> Void)?
    /// A drag of a docked group's title (it drags the group, as the gripper does).
    var onDrag: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let field = hit as? NSTextField, !field.isEditable { return self }
        if let hit, hit !== self, !(hit is NSControl), !(hit is GripperView), !(hit.superview is NSControl) { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            onClick?()
            return
        }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                onClick?()
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= Self.clickSlop {
                if window is FloatingPanelWindow {
                    window.performDrag(with: event)
                } else {
                    onDrag?(event)
                }
                return
            }
        }
    }
}

/// The textured area at the left of a group's title bar: dragging it moves the group between
/// the dock and the pasteboard.
@MainActor
final class GripperView: NSImageView {
    var onDrag: ((NSEvent) -> Void)?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Gripper")
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        setAccessibilityLabel("Gripper")
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GripperView is built in code")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event)
    }
}
