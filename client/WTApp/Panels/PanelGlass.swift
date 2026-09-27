import AppKit

/// The materials of the panel framework (D-077): Liquid Glass for the navigation and control
/// layer -- the dock, tab strips, floating groups -- and a standard material under panel content,
/// as the HIG asks.  On macOS 26 the glass is `NSGlassEffectView`; earlier systems get the
/// closest visual-effect material, so the framework runs on the deployment target.
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

    /// The standard material panel content sits on (a group's body): never glass.
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
