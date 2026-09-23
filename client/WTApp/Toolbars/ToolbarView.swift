import AppKit
import SwiftUI

/// One toolbar's buttons (toolbars.adoc, "Client": `ToolbarView`, an `NSStackView` row of
/// `NSButton`s): a row when its host is wider than tall, a column otherwise.  Buttons follow
/// the controller; enabled and checked states are re-read after every window update, as
/// `NSToolbar` validates its items.  A drop target for toolbar drags; its buttons are the drag
/// sources.
@MainActor
final class ToolbarView: NSView {
    let controller: ToolbarController
    let toolbar: ToolbarID
    let stack = NSStackView()
    private(set) var buttons: [ToolbarButton] = []
    /// The Info toolbar's readout, before its buttons.
    private(set) var readout: NSHostingView<InfoReadoutView>?
    private var token: ToolbarController.ObservationToken?
    private var windowObserver: NSObjectProtocol?

    init(controller: ToolbarController, toolbar: ToolbarID) {
        self.controller = controller
        self.toolbar = toolbar
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("\(toolbar.title) toolbar")
        setAccessibilityIdentifier("toolbar.\(toolbar.rawValue)")
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        if toolbar == .info {
            let readout = NSHostingView(rootView: InfoReadoutView(model: controller.info))
            stack.addArrangedSubview(readout)
            self.readout = readout
        }
        registerForDraggedTypes([.string])
        token = controller.observe { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolbarView is built in code")
    }

    isolated deinit {
        if let token { controller.stopObserving(token) }
    }

    /// Rebuilds the buttons from the controller and refreshes their states.
    func reload() {
        let items = controller.items(toolbar)
        if buttons.map(\.command) != items {
            for button in buttons { button.removeFromSuperview() }
            buttons = items.map { ToolbarButton(command: $0, toolbarView: self) }
            for button in buttons { stack.addArrangedSubview(button) }
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
    }

    /// Row when wider than tall.
    var isHorizontal: Bool { bounds.width >= bounds.height }

    override func layout() {
        stack.orientation = isHorizontal ? .horizontal : .vertical
        super.layout()
    }

    override var intrinsicContentSize: NSSize { stack.fittingSize }

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

    /// The button index a drop at `point` (this view's coordinates) inserts before.
    func insertionIndex(at point: NSPoint) -> Int {
        let horizontal = stack.orientation == .horizontal
        for (index, button) in buttons.enumerated() {
            let frame = convert(button.bounds, from: button)
            if horizontal ? point.x < frame.midX : point.y > frame.midY { return index }
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

    /// A drag starts when the controller allows it (customizing, or Command held); otherwise
    /// the press is an ordinary click.
    override func mouseDown(with event: NSEvent) {
        guard toolbarView.controller.canDrag(command, modifiers: KeyEquivalentResolver.modifiers(event.modifierFlags)) else {
            super.mouseDown(with: event)
            return
        }
        guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged else {
            pressed(nil)
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
            ForEach(InfoReadout.fields(model.info), id: \.id) { field in
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

    static func fields(_ info: ToolInfo) -> [Field] {
        var fields: [Field] = []
        if let position = info.position {
            fields.append(Field(id: "position", label: "X/Y", value: "\(number(position.x)), \(number(position.y)) pt"))
        }
        if let delta = info.delta {
            fields.append(Field(id: "delta", label: "Δ", value: "\(number(delta.dx)), \(number(delta.dy)) pt"))
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

/// A toolbar's buttons inside SwiftUI (the Tools panel's customized buttons).
struct ToolbarViewRepresentable: NSViewRepresentable {
    let controller: ToolbarController
    let toolbar: ToolbarID

    func makeNSView(context: Context) -> ToolbarView {
        ToolbarView(controller: controller, toolbar: toolbar)
    }

    func updateNSView(_ view: ToolbarView, context: Context) {
        view.reload()
    }
}
