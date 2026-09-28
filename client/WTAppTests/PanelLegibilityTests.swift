import AppKit
import Testing
@testable import WireTuner

/// D-077, revised after use: panels are frosted glass over the canvas, and their text keeps a
/// contrast of at least 4.5:1 (WCAG AA) over the worst artwork -- white, black and a busy pattern
/// -- in both appearances.  Rendered as a bitmap, the glass and any backdrop blur do not draw, so
/// the frost alone is measured: on screen the glass only adds to it.  Solid mode and Reduce
/// Transparency draw opaque panels.
@Suite @MainActor struct PanelLegibilityTests {
    /// What lies behind the panel.
    enum Artwork: CaseIterable {
        case white, black, busy
    }

    /// Draws the artwork: flat white or black, or diagonal stripes of black, white and strong
    /// colours.
    final class ArtworkView: NSView {
        let artwork: Artwork
        init(_ artwork: Artwork, frame: NSRect) {
            self.artwork = artwork
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            switch artwork {
            case .white: NSColor.white.setFill(); bounds.fill()
            case .black: NSColor.black.setFill(); bounds.fill()
            case .busy:
                let colors: [NSColor] = [.black, .white, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0.35, blue: 1, alpha: 1),
                                         NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 1)]
                let stripe: CGFloat = 9
                var index = 0
                var x = -bounds.height
                while x < bounds.width {
                    colors[index % colors.count].setFill()
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: x, y: 0))
                    path.line(to: NSPoint(x: x + stripe, y: 0))
                    path.line(to: NSPoint(x: x + stripe + bounds.height, y: bounds.height))
                    path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
                    path.close()
                    path.fill()
                    x += stripe
                    index += 1
                }
            }
        }
    }

    /// A docked group as the dock shows it -- the chrome's frost over the artwork, the group on
    /// it -- with a label in its body.
    struct Scene {
        let container: FlippedView
        let group: PanelGroupView
        let bodyLabel: NSTextField
        let frost: PanelFrostView
    }

    private func scene(_ artwork: Artwork, appearance: NSAppearance.Name, translucent: Bool = true) -> Scene {
        let size = NSRect(x: 0, y: 0, width: 280, height: 220)
        let container = FlippedView(frame: size)
        container.appearance = NSAppearance(named: appearance)
        container.addSubview(ArtworkView(artwork, frame: size))
        let frost = PanelFrostView(level: .chrome, translucent: translucent, cornerRadius: PanelDockController.cornerRadius)
        frost.frame = size
        container.addSubview(frost)
        let label = NSTextField(labelWithString: "Stroke width 2 pt")
        label.textColor = .labelColor
        let body = FlippedView()
        label.frame = NSRect(x: 12, y: 16, width: 200, height: 18)
        body.addSubview(label)
        let group = PanelGroup(id: "properties", name: "Properties", panels: ["object", "document", "layers"], activePanel: "document")
        let icons = ["object": "slider.horizontal.3", "document": "doc", "layers": "square.3.layers.3d"]
        let view = PanelGroupView(
            group: group, title: { $0.rawValue.capitalized }, icon: { icons[$0.rawValue] ?? "square" }, body: { _ in body },
            appearance: PanelAppearance(labelStyle: .textAndIcon, showsTooltips: true, isTranslucent: translucent)
        )
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = size
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        return Scene(container: container, group: view, bodyLabel: label, frost: frost)
    }

    /// The contrast of the text drawn in `rect`: `with` is the scene with the text, `without` the
    /// same scene with it hidden.  Pixels the text changed are grouped by the luminance behind
    /// them; in each group the strongest pixel (a glyph's core) gives that background's contrast,
    /// and the worst background counts.
    private func contrast(with: TestBitmap, without: TestBitmap, in rect: CGRect) -> CGFloat {
        var best: [Int: CGFloat] = [:]
        var counts: [Int: Int] = [:]
        for (x, y) in with.pixels(in: rect) {
            let text = with.luminance(x, y), back = without.luminance(x, y)
            guard abs(text - back) > 0.02 else { continue }
            let ratio = (max(text, back) + 0.05) / (min(text, back) + 0.05)
            let bucket = Int(back * 20)
            best[bucket] = max(best[bucket] ?? 0, ratio)
            counts[bucket, default: 0] += 1
        }
        let measured = best.filter { (counts[$0.key] ?? 0) >= 16 }.values
        return measured.min() ?? 0
    }

    /// Each text of the scene and its contrast.
    private func measure(_ artwork: Artwork, appearance: NSAppearance.Name) -> [(String, CGFloat)] {
        let scene = scene(artwork, appearance: appearance)
        let group = scene.group
        var results: [(String, CGFloat)] = []
        func text(_ name: String, _ view: NSView, band: CGRect? = nil) {
            let full = TestBitmap(of: scene.container)
            // A tab is taken out rather than hidden: the strip shows its tabs again when it lays out.
            let parent = view.superview
            if view is PanelTabButton { view.removeFromSuperview() } else { view.isHidden = true }
            let bare = TestBitmap(of: scene.container)
            if view is PanelTabButton { parent?.addSubview(view) } else { view.isHidden = false }
            let frame = scene.container.convert(band ?? view.bounds, from: view)
            results.append((name, contrast(with: full, without: bare, in: frame)))
        }
        text("title", group.titleLabel)
        let selected = group.tabStrip.buttons[1], unselected = group.tabStrip.buttons[2]
        #expect(selected.isFront && !unselected.isFront)
        // The label band of a tab, clear of the accent bar along its top.
        let band = { (button: PanelTabButton) in CGRect(x: 0, y: PanelTabStrip.accentThickness + 3, width: button.bounds.width, height: button.bounds.height - PanelTabStrip.accentThickness - 5) }
        text("selected tab", selected, band: band(selected))
        text("unselected tab", unselected, band: band(unselected))
        text("body label", scene.bodyLabel)
        return results
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func textKeepsItsContrastOverAnyArtwork(_ appearance: NSAppearance.Name) {
        for artwork in Artwork.allCases {
            for (name, ratio) in measure(artwork, appearance: appearance) {
                print("LEGIBILITY \(appearance.rawValue) \(artwork) \(name): \(String(format: "%.1f", ratio)):1")
                #expect(ratio >= 4.5, "\(name) over \(artwork) artwork in \(appearance.rawValue): \(ratio):1")
            }
        }
    }

    @Test func theFrostLetsTheArtworkShowThrough() {
        // Translucent: what is behind shows (the whites and blacks differ under the chrome and the
        // card alike); Solid: nothing does.
        let white = scene(.white, appearance: .aqua), black = scene(.black, appearance: .aqua)
        let chrome = CGRect(x: 170, y: 6, width: 8, height: 8)
        let card = white.container.convert(white.group.bodyCard.frame, from: white.group).insetBy(dx: 20, dy: 60)
        let whiteBitmap = TestBitmap(of: white.container), blackBitmap = TestBitmap(of: black.container)
        #expect(whiteBitmap.meanDifference(to: blackBitmap, in: chrome) > 0.05, "the chrome is translucent")
        #expect(whiteBitmap.meanDifference(to: blackBitmap, in: card) > 0.02, "the card is frosted, not opaque")
        #expect(whiteBitmap.meanDifference(to: blackBitmap, in: chrome) > whiteBitmap.meanDifference(to: blackBitmap, in: card), "the card's frost is heavier")
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func solidPanelsHideTheArtwork(_ appearance: NSAppearance.Name) {
        let white = scene(.white, appearance: appearance, translucent: false), black = scene(.black, appearance: appearance, translucent: false)
        #expect(!white.group.isTranslucent && !white.frost.isTranslucent)
        let inside = white.container.bounds.insetBy(dx: 16, dy: 16)
        #expect(TestBitmap(of: white.container).maximumDifference(to: TestBitmap(of: black.container), in: inside) < 0.01)
    }

    @Test func reduceTransparencyAndThePreferenceMakePanelsSolid() {
        let original = PanelAppearance.reducesTransparency
        defer { PanelAppearance.reducesTransparency = original }
        #expect(PanelAppearance.translucent(preference: "translucent", reduceTransparency: false))
        #expect(!PanelAppearance.translucent(preference: "solid", reduceTransparency: false))
        #expect(!PanelAppearance.translucent(preference: "translucent", reduceTransparency: true))
        #expect(PanelAppearance.isAppearancePreference(PreferenceCatalog.Panels.transparency.id))
        #expect(PreferenceCatalog.Panels.transparency.defaultValue == "translucent")

        let environment = TestEnvironment()
        #expect(PanelAppearance(preferences: environment.preferences).isTranslucent == !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        PanelAppearance.reducesTransparency = { true }
        #expect(!PanelAppearance(preferences: environment.preferences).isTranslucent, "Reduce Transparency wins")
        PanelAppearance.reducesTransparency = { false }
        #expect(PanelAppearance(preferences: environment.preferences).isTranslucent)

        // The window's dock follows the preference live.
        let controller = DocumentWindowController(document: .memory(id: UUID().uuidString, title: "Doc"), environment: environment.document)
        defer { controller.close() }
        #expect(controller.dock.frost?.isTranslucent == true)
        #expect(controller.dock.groupViews.allSatisfy { $0.isTranslucent })
        _ = environment.preferences.set("solid", for: PreferenceCatalog.Panels.transparency)
        #expect(controller.dock.frost?.isTranslucent == false)
        #expect(controller.dock.groupViews.allSatisfy { !$0.isTranslucent }, "every group redraws solid")
        _ = environment.preferences.set("translucent", for: PreferenceCatalog.Panels.transparency)
        #expect(controller.dock.frost?.isTranslucent == true)
        // Reduce Transparency switched on while the window is open.
        PanelAppearance.reducesTransparency = { true }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(controller.dock.frost?.isTranslucent == false)
    }

    @Test func floatingGroupsWearTheSameFrost() throws {
        let group = PanelGroup(id: "f", name: "Float", panels: ["a", "b"])
        let translucent = PanelGroupView(group: group, title: { $0.rawValue }, body: { _ in NSView() }, isFloating: true)
        translucent.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
        translucent.layoutSubtreeIfNeeded()
        let frost = try #require(translucent.frost)
        #expect(frost.isTranslucent && frost.level == .chrome && frost.frame == translucent.bounds)
        #expect(frost.hitTest(NSPoint(x: 5, y: 5)) == nil)
        let solid = PanelGroupView(group: group, title: { $0.rawValue }, body: { _ in NSView() },
                                   appearance: PanelAppearance(labelStyle: .text, showsTooltips: false, isTranslucent: false), isFloating: true)
        #expect(solid.frost?.isTranslucent == false && !solid.isTranslucent)
        #expect(PanelFrost.card.opacity(dark: true) > 0 && PanelFrost.chrome.opacity(dark: false) < 1)
    }
}
