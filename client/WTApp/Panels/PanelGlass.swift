import AppKit

/// The materials of the panel framework (D-077, revised after use): the dock and floating groups
/// are Liquid Glass over the canvas, which runs beneath them; on the glass a light *frost* (a
/// wash of the window background colour, `PanelFrost.chrome`) keeps the title bars and tabs
/// legible, and each group's card a heavier one (`PanelFrost.card`) for its control-dense body.
/// Text stays in the label colours.  *Panel transparency* set to Solid, or the system's Reduce
/// Transparency, makes every frost opaque.  On macOS 26 the glass is `NSGlassEffectView`;
/// earlier systems get the closest visual-effect material, so the framework runs on the
/// deployment target.
@MainActor
enum PanelGlass {
    /// Whether the system glass is available (macOS 26 and later).
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// A glass surface with `cornerRadius`, tinted toward `tint` when given.  Content goes in
    /// `setContent(_:of:)`.
    static func surface(cornerRadius: CGFloat, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .followsWindowActiveState
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        return effect
    }

    /// Changes the tint of a surface made by `surface(cornerRadius:tint:)`.
    static func setTint(_ tint: NSColor?, of surface: NSView) {
        if #available(macOS 26, *), let glass = surface as? NSGlassEffectView {
            glass.tintColor = tint
        } else {
            surface.layer?.backgroundColor = tint?.withAlphaComponent(0.25).cgColor
        }
    }

    /// Puts `content` inside `surface`: the glass's content view, or a filling subview.
    static func setContent(_ content: NSView, of surface: NSView) {
        if #available(macOS 26, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = content
            return
        }
        content.frame = surface.bounds
        content.autoresizingMask = [.width, .height]
        surface.addSubview(content)
    }

    /// A container that renders its glass descendants together (`NSGlassEffectContainerView`),
    /// or a plain view before macOS 26.
    static func container(content: NSView) -> NSView {
        if #available(macOS 26, *) {
            let container = NSGlassEffectContainerView()
            container.contentView = content
            return container
        }
        let plain = NSView()
        content.frame = plain.bounds
        content.autoresizingMask = [.width, .height]
        plain.addSubview(content)
        return plain
    }

    /// A standard, opaque material (kept for content that must not show what is behind it).
    static func contentMaterial(cornerRadius: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .withinWindow
        effect.state = .followsWindowActiveState
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        return effect
    }

    /// Whether movement should be kept to a minimum (Reduce Motion).
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Runs `changes` animated (a short ease, like the system's segmented controls), or at once
    /// under Reduce Motion or while nothing is on screen.
    static func animate(in view: NSView, _ changes: @escaping () -> Void) {
        guard view.window?.isVisible == true, !reducesMotion else {
            changes()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            context.allowsImplicitAnimation = true
            changes()
        }
    }
}

/// How much of the window background colour lies over the glass (D-077, revised): enough that
/// label-coloured text keeps a contrast of at least 4.5:1 over any artwork -- white, black or
/// busy -- which `PanelLegibilityTests` measures.  Dark appearances need more (white artwork is
/// the hard case for light text).
enum PanelFrost: Sendable {
    /// Under the title bars and the tab strips: the dock's and a floating group's wash.
    case chrome
    /// A group's card (the selected tab and the body): a heavier wash on top of the chrome's, for
    /// sliders, fields, lists and the Object panel's editors.
    case card

    /// The wash's opacity in the light or dark appearance.
    func opacity(dark: Bool) -> CGFloat {
        switch self {
        case .chrome: dark ? 0.8 : 0.66
        case .card: dark ? 0.6 : 0.62
        }
    }

    /// The wash: the window background colour at `opacity`, or opaque when not `translucent`.
    func color(translucent: Bool) -> NSColor {
        let level = self
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var base = NSColor.windowBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor(white: dark ? 0.2 : 0.93, alpha: 1)
            }
            // Solid: the card still reads as a card, a shade off the chrome.
            if !translucent { return level == .card ? (dark ? base.blended(withFraction: 0.06, of: .white) ?? base : base.blended(withFraction: 0.5, of: .white) ?? base) : base }
            return base.withAlphaComponent(level.opacity(dark: dark))
        }
    }
}

/// A rounded wash of `PanelFrost` (a cluster's, on its glass): drawn, so it shows in bitmaps as
/// on screen.  A docked cluster's wash is square on its attached side (`squareEdge`) and draws a
/// hairline along the others (`strokesOutline`).
@MainActor
final class PanelFrostView: NSView {
    var level: PanelFrost {
        didSet { needsDisplay = true }
    }
    var isTranslucent: Bool {
        didSet { if isTranslucent != oldValue { needsDisplay = true } }
    }
    var cornerRadius: CGFloat {
        didSet { needsDisplay = true }
    }
    /// The side whose corners are square (a docked cluster's window edge).
    var squareEdge: DockEdge? {
        didSet { if squareEdge != oldValue { needsDisplay = true } }
    }
    /// Draws a hairline in the separator colour along the rounded outline (not the square side).
    var strokesOutline = false {
        didSet { if strokesOutline != oldValue { needsDisplay = true } }
    }

    init(level: PanelFrost, translucent: Bool, cornerRadius: CGFloat) {
        self.level = level
        self.isTranslucent = translucent
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelFrostView is built in code")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        level.color(translucent: isTranslucent).setFill()
        PanelShape.path(in: bounds, radius: cornerRadius, squareEdge: squareEdge).fill()
        guard strokesOutline else { return }
        NSColor.separatorColor.setStroke()
        let outline = PanelShape.outline(in: bounds.insetBy(dx: 0.5, dy: 0.5), radius: cornerRadius, squareEdge: squareEdge)
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// A group's card (D-077, revised): the heavier frost under the front panel's body, and -- when
/// the group has tabs -- under its selected tab too, joined to the body like a folder tab, so the
/// selected tab and the content it shows read as one surface.  The body's scroll view clips to
/// the card's rounded corners (`PanelGroupView`).
@MainActor
final class PanelCardView: NSView {
    static let cornerRadius: CGFloat = 8
    /// The concave fillet where the tab meets the body.
    static let filletRadius: CGFloat = 5

    /// The selected tab's rectangle (this view's coordinates, top at 0), nil for no tab.
    var tabRect: CGRect? {
        didSet { if tabRect != oldValue { shapeDidChange() } }
    }
    /// Where the body starts (the tab row's height; 0 without tabs).
    var bodyTop: CGFloat = 0 {
        didSet { if bodyTop != oldValue { shapeDidChange() } }
    }
    var isTranslucent: Bool {
        didSet { if isTranslucent != oldValue { needsDisplay = true } }
    }

    init(translucent: Bool) {
        isTranslucent = translucent
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelCardView is built in code")
    }

    override var isFlipped: Bool { true }

    /// The body's rectangle.
    var bodyRect: CGRect { CGRect(x: 0, y: bodyTop, width: bounds.width, height: max(0, bounds.height - bodyTop)) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        shapeDidChange()
    }

    private func shapeDidChange() {
        needsDisplay = true
    }

    /// The card's outline: the body's rounded rectangle, and the selected tab rising from it with
    /// rounded top corners and concave fillets where it meets the body.
    func shape() -> NSBezierPath {
        let body = bodyRect
        let radius = min(Self.cornerRadius, body.height / 2, body.width / 2)
        guard let tab = tabRect, tab.width > 0, bodyTop > 0 else {
            return NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        }
        let top = PanelTabStrip.tabCornerRadius
        let fillet = Self.filletRadius
        let left = max(0, tab.minX), right = min(bounds.width, tab.maxX)
        let path = NSBezierPath()
        // Flipped: y grows downwards.  Start at the body's top-left corner.
        let leftJoin = left <= radius
        let rightJoin = right >= bounds.width - radius
        path.move(to: CGPoint(x: 0, y: leftJoin ? tab.minY + top : body.minY + radius))
        if leftJoin {
            path.appendArc(withCenter: CGPoint(x: left + top, y: tab.minY + top), radius: top, startAngle: 180, endAngle: 270, clockwise: false)
        } else {
            path.appendArc(withCenter: CGPoint(x: radius, y: body.minY + radius), radius: radius, startAngle: 180, endAngle: 270, clockwise: false)
            path.line(to: CGPoint(x: left - fillet, y: body.minY))
            path.appendArc(withCenter: CGPoint(x: left - fillet, y: body.minY - fillet), radius: fillet, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: CGPoint(x: left, y: tab.minY + top))
            path.appendArc(withCenter: CGPoint(x: left + top, y: tab.minY + top), radius: top, startAngle: 180, endAngle: 270, clockwise: false)
        }
        path.line(to: CGPoint(x: right - top, y: tab.minY))
        path.appendArc(withCenter: CGPoint(x: right - top, y: tab.minY + top), radius: top, startAngle: 270, endAngle: 360, clockwise: false)
        if rightJoin {
            path.line(to: CGPoint(x: bounds.width, y: body.maxY - radius))
        } else {
            path.line(to: CGPoint(x: right, y: body.minY - fillet))
            path.appendArc(withCenter: CGPoint(x: right + fillet, y: body.minY - fillet), radius: fillet, startAngle: 180, endAngle: 90, clockwise: true)
            path.line(to: CGPoint(x: bounds.width - radius, y: body.minY))
            path.appendArc(withCenter: CGPoint(x: bounds.width - radius, y: body.minY + radius), radius: radius, startAngle: 270, endAngle: 360, clockwise: false)
        }
        path.line(to: CGPoint(x: bounds.width, y: body.maxY - radius))
        path.appendArc(withCenter: CGPoint(x: bounds.width - radius, y: body.maxY - radius), radius: radius, startAngle: 0, endAngle: 90, clockwise: false)
        path.line(to: CGPoint(x: radius, y: body.maxY))
        path.appendArc(withCenter: CGPoint(x: radius, y: body.maxY - radius), radius: radius, startAngle: 90, endAngle: 180, clockwise: false)
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = shape()
        PanelFrost.card.color(translucent: isTranslucent).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        let clip = NSBezierPath(rect: bounds)
        clip.setClip()
        path.stroke()
    }
}

/// Calls back when the system's display accessibility options change (Reduce Transparency, for
/// one): panels redraw solid or translucent.  Stops observing when released.
@MainActor
final class AccessibilityDisplayObserver {
    private nonisolated(unsafe) let token: NSObjectProtocol

    init(_ change: @escaping @MainActor @Sendable () -> Void) {
        // No queue: the change runs as the notification is posted (on the main thread, where the
        // system posts it), else on the main actor soon after.
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { change() }
            } else {
                Task { @MainActor in change() }
            }
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
}
