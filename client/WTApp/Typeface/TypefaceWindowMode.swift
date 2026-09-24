import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The typeface layout of one document window (typeface-documents.adoc, "How a typeface document
/// differs"; FONT-003).  The window follows the document's kind as read
/// (`DocumentKind.layout`): a typeface shows the *Glyphs* / *Sketches* switch in the title bar
/// and, in Glyphs, the glyph grid over the canvas; Sketches is the ordinary pasteboard.  A glyph
/// tab (a window over a glyph canvas) shows the glyph bar instead, and closes when its glyph is
/// removed or the document stops being a typeface -- the kind switches under every window alike,
/// whoever changed it.  The layout lives until its window closes.
@MainActor
final class TypefaceWindowMode {
    enum View: Int {
        case glyphs, sketches
    }

    private weak var features: TypefaceFeatures?
    let controller: DocumentWindowController
    /// The document's cell images, shared with its other windows.
    private let thumbnails: GlyphThumbnailSource
    /// The layout the window shows.
    private(set) var layout: DocumentKind = .multiPage
    /// Glyphs or Sketches, in a typeface window.
    var view: View = .glyphs {
        didSet { if view != oldValue { update() } }
    }
    /// The grid, once the document has been a typeface in this window.
    private(set) var grid: GlyphGridController?
    /// The glyph bar of a glyph tab.
    private(set) var glyphBar: GlyphBarModel?
    let switcher = NSSegmentedControl(labels: ["Glyphs", "Sketches"], trackingMode: .selectOne, target: nil, action: nil)
    private var switcherAccessory: NSTitlebarAccessoryViewController?
    private var tokens: [DocumentHandle.ObservationToken] = []
    private var closeObserver: NSObjectProtocol?
    /// Closes the window of a glyph tab whose glyph went away (replaced in tests).
    var closeWindow: @MainActor (DocumentWindowController) -> Void = { $0.window?.close() }

    init(controller: DocumentWindowController, features: TypefaceFeatures) {
        self.controller = controller
        self.features = features
        thumbnails = features.thumbnails(for: controller.documentHandle)
        switcher.target = self
        switcher.action = #selector(switchView(_:))
        switcher.selectedSegment = View.glyphs.rawValue
        switcher.setAccessibilityIdentifier("typeface.view")
        let document = controller.documentHandle
        tokens.append(document.observeStructure { [weak self] in self?.update() })
        tokens.append(document.observe { [weak self] _ in self?.contentDidChange() })
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.windowWillClose() }
        }
        if document.canvasNode != nil { configureGlyphCanvas() }
        update()
    }

    /// The window is closing: the layout stops following the document and is forgotten.
    func windowWillClose() {
        for token in tokens { controller.documentHandle.stopObserving(token) }
        tokens = []
        closeObserver.map(NotificationCenter.default.removeObserver)
        closeObserver = nil
        grid?.thumbnails.stop()
        features?.detach(controller)
    }

    @objc private func switchView(_ sender: NSSegmentedControl) {
        view = sender.selectedSegment == View.sketches.rawValue ? .sketches : .glyphs
    }

    private func contentDidChange() {
        if DocumentKind.layout(controller.documentHandle.state) != layout || controller.documentHandle.canvasNode != nil {
            update()
        } else {
            grid?.reload()
        }
    }

    /// Lays the window out for the document's kind as read now.
    func update() {
        let document = controller.documentHandle
        layout = DocumentKind.layout(document.state)
        if let glyph = document.canvasNode {
            // A glyph tab lives only while its glyph does, in a typeface.
            guard layout == .typeface, GlyphIndex(document.state)[glyph] != nil else {
                closeWindow(controller)
                return
            }
            glyphBar?.reload()
            updateScrollBounds()
            return
        }
        let isTypeface = layout == .typeface
        if isTypeface, switcherAccessory == nil { installSwitcher() }
        if !isTypeface, let accessory = switcherAccessory {
            accessory.removeFromParent()
            switcherAccessory = nil
        }
        switcher.selectedSegment = view.rawValue
        let showsGrid = isTypeface && view == .glyphs
        if showsGrid, grid == nil { installGrid() }
        grid?.view.isHidden = !showsGrid
        if showsGrid { grid?.reload() }
    }

    private func installSwitcher() {
        let accessory = NSTitlebarAccessoryViewController()
        switcher.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: switcher.frame.width + 16, height: 28))
        switcher.frame.origin = NSPoint(x: 8, y: 2)
        holder.addSubview(switcher)
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        controller.window?.addTitlebarAccessoryViewController(accessory)
        switcherAccessory = accessory
    }

    private func installGrid() {
        let grid = GlyphGridController(document: controller.documentHandle, thumbnails: thumbnails)
        grid.onOpen = { [weak self] glyph in self?.open(glyph) }
        grid.onAdd = { [weak self] in self?.features?.presentAddGlyph() }
        grid.onRemove = { [weak self] in self?.features?.removeSelectedGlyphs() }
        let view = grid.view
        view.translatesAutoresizingMaskIntoConstraints = false
        controller.window?.contentView?.addSubview(view)
        let host = controller.rulerHost
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        self.grid = grid
    }

    /// Opens `glyph` in a tab of this window.
    @discardableResult
    func open(_ glyph: OpID) -> DocumentWindowController? {
        features?.openGlyph(glyph, from: controller)
    }

    // MARK: Glyph tabs

    /// A glyph tab: the canvas scrolls over the glyph's em, and the glyph bar shows under the
    /// title bar.
    private func configureGlyphCanvas() {
        let model = GlyphBarModel(document: controller.documentHandle, glyph: controller.documentHandle.canvasNode!, perform: controller.typefacePerform)
        model.step = { [weak self] offset in self?.features?.stepGlyph(by: offset) }
        model.showParts = { [weak self] in self?.features?.presentGlyphParts() }
        model.fit = { [weak self] in self?.fitGlyph() }
        glyphBar = model
        let accessory = NSTitlebarAccessoryViewController()
        let hosting = NSHostingView(rootView: GlyphBar(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        accessory.view = hosting
        accessory.layoutAttribute = .bottom
        controller.window?.addTitlebarAccessoryViewController(accessory)
        fitGlyph()
    }

    /// menu:View[Fit Glyph]: the canvas scrolls over the glyph's em and fits it in the window.
    func fitGlyph() {
        guard let frame = updateScrollBounds() else { return }
        controller.setViewport(controller.canvas.navigation.fit(controller.viewport, rect: GlyphCanvas.emBox(frame)))
    }

    /// The scroll area follows the glyph's width and the font's metrics; returns the frame (nil
    /// on the pasteboard, or once the glyph is gone).
    @discardableResult
    private func updateScrollBounds() -> GlyphCanvasFrame? {
        guard let glyph = controller.documentHandle.canvasNode, let frame = GlyphCanvas.frame(for: glyph, in: controller.documentHandle.state) else {
            return nil
        }
        let bounds = GlyphCanvas.scrollBounds(frame)
        if controller.canvas.navigation.scroller.pasteboard != bounds {
            controller.canvas.navigation = CanvasNavigation(scroller: CanvasScrollerModel(pasteboard: bounds))
        }
        return frame
    }
}
