import AppKit
import SwiftUI
import WTGeometry
import WTModel

/// One toolbar's buttons (toolbars.adoc, "Client": `ToolbarView`).  Its placement comes from
/// where it is hosted (`ToolbarPlacement.hosting`): one row in a top or bottom strip, a column in
/// a narrow side strip, and rows that wrap at its width in a panel group, docked or floating --
/// items keep their natural sizes and wide controls (the font family) take a row of their own
/// (`ToolbarFlowLayout`).  Buttons follow the controller; enabled and checked states are re-read
/// after every window update, as `NSToolbar` validates its items.  A drop target for toolbar
/// drags; its buttons are the drag sources.
@MainActor
final class ToolbarView: NSView {
    let controller: ToolbarController
    let toolbar: ToolbarID
    private(set) var buttons: [ToolbarButton] = []
    /// What the toolbar shows for each button: the button, or the command's own control
    /// (`ToolbarController.controls`: the Text toolbar's font family, style and size).
    private(set) var arranged: [NSView] = []
    /// The Info toolbar's readout, before its buttons.
    private(set) var readout: NSHostingView<InfoReadoutView>?
    /// A placement set by the host (the Tools panel's extra buttons); nil reads it from the
    /// panel layout.
    var placementOverride: ToolbarPlacement? {
        didSet { placementDidChange() }
    }
    /// The frames of the last layout pass (for tests and the insertion point).
    private(set) var flow = ToolbarFlowLayout.Result(frames: [], rows: [], size: .zero)
    /// Keeps a scrolling host from squeezing the rows: the height the rows need.
    private var minimumHeight: NSLayoutConstraint?
    private var token: ToolbarController.ObservationToken?
    private var layoutToken: PanelLayoutController.ObservationToken?
    private var windowObserver: NSObjectProtocol?
    private var lastPlacement: ToolbarPlacement?

    init(controller: ToolbarController, toolbar: ToolbarID, placement: ToolbarPlacement? = nil) {
        self.controller = controller
        self.toolbar = toolbar
        self.placementOverride = placement
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("\(toolbar.title) toolbar")
        setAccessibilityIdentifier("toolbar.\(toolbar.rawValue)")
        let minimum = heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minimum.isActive = true
        minimumHeight = minimum
        if toolbar == .info {
            let readout = NSHostingView(rootView: InfoReadoutView(model: controller.info))
            addSubview(readout)
            self.readout = readout
        }
        registerForDraggedTypes([.string])
        token = controller.observe { [weak self] in self?.reload() }
        layoutToken = controller.layout.observe { [weak self] _ in self?.placementDidChange() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolbarView is built in code")
    }

    isolated deinit {
        if let token { controller.stopObserving(token) }
        if let layoutToken { controller.layout.stopObserving(layoutToken) }
    }

    override var isFlipped: Bool { true }

    /// Rebuilds the buttons from the controller and refreshes their states.
    func reload() {
        let items = controller.items(toolbar)
        // Rebuilt when the items change, or when a command gained or lost its own control.
        let stale = zip(buttons, arranged).contains { button, view in (controller.controls[button.command] == nil) != (view === button) }
        if buttons.map(\.command) != items || stale {
            for view in arranged { view.removeFromSuperview() }
            buttons = items.map { ToolbarButton(command: $0, toolbarView: self) }
            arranged = buttons.map { button in controller.controls[button.command].map { $0() } ?? button }
            for view in arranged { addSubview(view) }
            placementDidChange()
        }
        refreshStates()
    }

    /// Enabled, checked, highlighted and tooltip of every button.
    func refreshStates() {
        for button in buttons {
            let validation = controller.validation(of: button.command)
            button.isEnabled = validation.isEnabled
            button.state = validation.isChecked ? .on : .off
            button.toolTip = validation.isEnabled ? controller.tooltip(for: button.command) : validation.reason
            button.isHighlightedForCustomizing = controller.highlighted == button.command
        }
        for case let control as any ToolbarControl in arranged { control.refresh() }
    }

    // MARK: Layout

    /// Where the toolbar is hosted decides how it lays out.
    var placement: ToolbarPlacement {
        placementOverride ?? ToolbarPlacement.hosting(toolbar, in: controller.layout.layout)
    }

    /// Whether the items run in rows (a strip or a panel) rather than a column.
    var isHorizontal: Bool { placement != .column }

    /// Every shown view, readout first, with its natural size and minimum width.
    var layoutViews: [NSView] { (readout.map { [$0] } ?? []) + arranged }

    func layoutItems() -> [ToolbarFlowLayout.Item] {
        layoutViews.map { view in
            if let control = view as? any ToolbarControl {
                return ToolbarFlowLayout.Item(size: control.toolbarSize, minimumWidth: control.minimumToolbarWidth, fullRow: control.takesFullRow)
            }
            let fitting = view.fittingSize
            if view is ToolbarButton { return ToolbarFlowLayout.Item(size: CGSize(width: max(fitting.width, 26), height: max(fitting.height, 24))) }
            return ToolbarFlowLayout.Item(size: fitting)
        }
    }

    /// The layout at `width` (the host's proposal).
    func flow(width: CGFloat) -> ToolbarFlowLayout.Result {
        ToolbarFlowLayout.layout(layoutItems(), placement: placement, width: width)
    }

    private func placementDidChange() {
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        placementDidChange()
    }

    override func layout() {
        let placement = placement
        let result = flow(width: bounds.width)
        flow = result
        for (view, frame) in zip(layoutViews, result.frames) where view.frame != frame { view.frame = frame }
        // A row is clipped by its strip; a flow or a column asks its host for its height.
        let needed = placement == .row ? 0 : result.size.height
        if minimumHeight?.constant != needed { minimumHeight?.constant = needed }
        if placement != lastPlacement {
            lastPlacement = placement
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    override var intrinsicContentSize: NSSize {
        let result = flow(width: bounds.width)
        switch placement {
        case .row, .column: return result.size
        case .flow: return NSSize(width: NSView.noIntrinsicMetric, height: result.size.height)
        }
    }

    override func setFrameSize(_ size: NSSize) {
        let widthChanged = size.width != frame.width
        super.setFrameSize(size)
        if widthChanged && placement == .flow { invalidateIntrinsicContentSize() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStates() }
        }
    }

    // MARK: Dropping

    /// The button index a drop at `point` (this view's coordinates, y down) inserts before: in
    /// reading order, the first item on the point's row (or a later row) whose middle is past it.
    func insertionIndex(at point: NSPoint) -> Int {
        for (index, view) in arranged.enumerated() {
            let frame = view.frame
            if placement == .column {
                if point.y < frame.midY { return index }
            } else if point.y < frame.minY || (point.y <= frame.maxY && point.x < frame.midX) {
                return index
            }
        }
        return buttons.count
    }

    static func payload(from pasteboard: NSPasteboard) -> ToolbarDragPayload? {
        pasteboard.string(forType: .string).flatMap(ToolbarDragPayload.init(string:))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.payload(from: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = Self.payload(from: sender.draggingPasteboard) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        return controller.drop(payload, on: toolbar, at: insertionIndex(at: point), modifiers: KeyEquivalentResolver.modifiers(NSEvent.modifierFlags))
    }
}

/// A toolbar item drawn as its own control instead of a button (the Text toolbar's font family,
/// style and size); it re-reads the selection after every window update, as buttons revalidate.
/// The toolbar lays it out at its natural size, never narrower than its minimum; a full-row
/// control takes a row of its own when the toolbar flows in a panel.
@MainActor
protocol ToolbarControl: NSView {
    func refresh()
    var toolbarSize: NSSize { get }
    var minimumToolbarWidth: CGFloat { get }
    var takesFullRow: Bool { get }
}

extension ToolbarControl {
    var toolbarSize: NSSize { fittingSize }
    var minimumToolbarWidth: CGFloat { toolbarSize.width }
    var takesFullRow: Bool { false }
}

/// One toolbar button: its command's symbol (or title), a tooltip with the shortcut, and the
/// drag source for customizing.
@MainActor
final class ToolbarButton: NSButton, NSDraggingSource {
    let command: CommandID
    unowned let toolbarView: ToolbarView
    var isHighlightedForCustomizing = false {
        didSet { layer?.borderWidth = isHighlightedForCustomizing ? 2 : 0 }
    }

    init(command: CommandID, toolbarView: ToolbarView) {
        self.command = command
        self.toolbarView = toolbarView
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        let controller = toolbarView.controller
        let title = controller.title(of: command)
        if let symbol = controller.symbol(for: command), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            self.image = image
            imagePosition = .imageOnly
        } else {
            self.title = title
        }
        setButtonType(.pushOnPushOff)
        bezelStyle = .toolbar
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        target = self
        action = #selector(pressed(_:))
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(toolbarView.toolbar.accessibilityIdentifier(for: command))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolbarButton is built in code")
    }

    var payload: ToolbarDragPayload { ToolbarDragPayload(command: command, source: toolbarView.toolbar) }

    @objc func pressed(_ sender: Any?) {
        toolbarView.controller.press(command)
        toolbarView.refreshStates()
    }

    /// A kbd:[Cmd]-click that did not become a drag.
    func commandPressed() {
        toolbarView.controller.commandPress(command)
        toolbarView.refreshStates()
    }

    /// A drag starts when the controller allows it (customizing, or Command held); otherwise
    /// the press is an ordinary click.
    override func mouseDown(with event: NSEvent) {
        guard toolbarView.controller.canDrag(command, modifiers: KeyEquivalentResolver.modifiers(event.modifierFlags)) else {
            super.mouseDown(with: event)
            return
        }
        guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged else {
            commandPressed()
            return
        }
        beginDrag(with: event)
    }

    @discardableResult
    func beginDrag(with event: NSEvent) -> NSDraggingSession {
        let item = NSPasteboardItem()
        item.setString(payload.string, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: image)
        return beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    static let sourceOperations: NSDragOperation = [.move, .copy, .delete]

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.sourceOperations
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded(operation: operation)
    }

    /// Dropped where nothing took it: off the toolbar, which removes the button.
    func dragEnded(operation: NSDragOperation) {
        toolbarView.controller.dragEnded(payload, accepted: !operation.isEmpty && operation != .delete)
    }
}

/// The Info toolbar's readout: only the fields the current tool sets, in points.
struct InfoReadoutView: View {
    let model: InfoToolbarModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(InfoReadout.fields(model.info, frame: model.document.map(InfoReadout.frame(of:))), id: \.id) { field in
                Text("\(field.label) \(field.value)")
                    .font(.system(size: 11).monospacedDigit())
                    .accessibilityIdentifier("toolbar.info.\(field.id)")
            }
        }
        .padding(.horizontal, 4)
        .frame(minWidth: 120, alignment: .leading)
    }
}

/// Formats `ToolInfo` for the Info toolbar.
enum InfoReadout {
    struct Field: Equatable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// How positions read: from a zero point, y upward, in a document's units.
    struct Frame {
        var units: Units
        var zero: Point
    }

    /// `document`'s frame: its active page's zero point and its units.
    @MainActor
    static func frame(of document: DocumentHandle) -> Frame {
        Frame(units: document.unitConverter, zero: document.activePage.zeroPoint)
    }

    static func fields(_ info: ToolInfo, frame: Frame? = nil) -> [Field] {
        var fields: [Field] = []
        // Picas carry their unit in the `NpM` form.
        let suffix = frame.map { $0.units.documentUnit == .picas ? "" : " " + $0.units.suffix(of: $0.units.documentUnit) } ?? ""
        if let position = info.position {
            if let frame {
                let units = frame.units
                fields.append(Field(id: "position", label: "X/Y",
                                    value: "\(units.format(position.x - frame.zero.x)), \(units.format(frame.zero.y - position.y))\(suffix)"))
            } else {
                fields.append(Field(id: "position", label: "X/Y", value: "\(number(position.x)), \(number(position.y)) pt"))
            }
        }
        if let delta = info.delta {
            if let units = frame?.units {
                fields.append(Field(id: "delta", label: "Δ", value: "\(units.format(delta.dx)), \(units.format(-delta.dy))\(suffix)"))
            } else {
                fields.append(Field(id: "delta", label: "Δ", value: "\(number(delta.dx)), \(number(delta.dy)) pt"))
            }
        }
        if let angle = info.angle { fields.append(Field(id: "angle", label: "∠", value: "\(number(angle))°")) }
        if let center = info.center {
            fields.append(Field(id: "center", label: "Center", value: "\(number(center.x)), \(number(center.y)) pt"))
        }
        if let radius = info.radius { fields.append(Field(id: "radius", label: "Radius", value: "\(number(radius)) pt")) }
        if let sides = info.sides { fields.append(Field(id: "sides", label: "Sides", value: "\(sides)")) }
        if let kind = info.objectKind { fields.append(Field(id: "object", label: "Object", value: kind)) }
        return fields
    }
}

/// A toolbar's buttons inside SwiftUI (the Tools panel's customized buttons): rows that wrap
/// at the width SwiftUI offers, one row when it offers any width.
struct ToolbarViewRepresentable: NSViewRepresentable {
    let controller: ToolbarController
    let toolbar: ToolbarID

    func makeNSView(context: Context) -> ToolbarView {
        ToolbarView(controller: controller, toolbar: toolbar, placement: .flow)
    }

    func updateNSView(_ view: ToolbarView, context: Context) {
        view.reload()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ToolbarView, context: Context) -> CGSize? {
        Self.size(of: view, proposedWidth: proposal.width)
    }

    /// The size at `width`; nil or infinite lays everything in one row.
    static func size(of view: ToolbarView, proposedWidth width: CGFloat?) -> CGSize {
        guard let width, width.isFinite else { return ToolbarFlowLayout.layout(view.layoutItems(), placement: .row, width: 0).size }
        return view.flow(width: width).size
    }
}
