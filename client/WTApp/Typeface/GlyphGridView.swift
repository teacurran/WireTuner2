import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The glyph grid (glyph-grid.adoc, "The glyph grid"; FONT-010): a search field, the sort and
/// cell-size pop-ups and btn:[Add Glyph] over a scrolling grid of cells -- the glyph's thumbnail,
/// its character or name, colour tag and badges.  Click, Shift-click and Command-click select;
/// double-click or Return opens the glyph in a tab; Delete removes; typing jumps.
@MainActor
final class GlyphGridController: NSObject, NSSearchFieldDelegate {
    let document: DocumentHandle
    let model = GlyphGridModel()
    let thumbnails: GlyphThumbnailSource
    let view = NSView()
    let gridView: GlyphGridView
    let scrollView = NSScrollView()
    let searchField = NSSearchField()
    let sortPopUp = NSPopUpButton()
    let sizePopUp = NSPopUpButton()
    let countLabel = NSTextField(labelWithString: "")
    let addButton = NSButton(title: "Add Glyph…", target: nil, action: nil)
    var onOpen: (@MainActor (OpID) -> Void)?
    var onAdd: (@MainActor () -> Void)?
    var onRemove: (@MainActor () -> Void)?
    /// Called after the cells or the selection change (the Object panel follows the selection).
    var didChange: (@MainActor () -> Void)?

    init(document: DocumentHandle, thumbnails: GlyphThumbnailSource) {
        self.document = document
        self.thumbnails = thumbnails
        gridView = GlyphGridView(model: model)
        super.init()
        gridView.image = { [weak self] cell, pixels in self?.image(for: cell, pixels: pixels) }
        gridView.onOpen = { [weak self] glyph in self?.onOpen?(glyph) }
        gridView.onRemove = { [weak self] in self?.onRemove?() }
        model.onChange = { [weak self] in self?.modelDidChange() }
        build()
        thumbnails.follow(document)
        reload()
    }

    private func build() {
        view.setAccessibilityIdentifier("typeface.grid")
        // The grid covers the canvas and its rulers: opaque.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        searchField.placeholderString = "Search glyphs"
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("typeface.grid.search")
        for sort in GlyphSort.allCases { sortPopUp.addItem(withTitle: sort.title) }
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged(_:))
        for size in GlyphThumbnail.CellSize.allCases { sizePopUp.addItem(withTitle: Self.title(of: size)) }
        sizePopUp.selectItem(withTitle: Self.title(of: model.cellSize))
        sizePopUp.target = self
        sizePopUp.action = #selector(sizeChanged(_:))
        addButton.target = self
        addButton.action = #selector(add(_:))
        countLabel.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [searchField, sortPopUp, sizePopUp, countLabel, NSView(), addButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        scrollView.documentView = gridView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        let stack = NSStackView(views: [bar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidResize(_:)), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
    }

    static func title(of size: GlyphThumbnail.CellSize) -> String {
        switch size {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Reads the glyphs again (a change was applied).
    func reload() {
        model.reload(document.state)
    }

    private func modelDidChange() {
        let count = model.index.count
        countLabel.stringValue = Self.countText(shown: model.cells.count, of: count, missing: model.items.count - model.cells.count)
        gridView.relayout(width: scrollView.contentView.bounds.width)
        gridView.needsDisplay = true
        didChange?()
    }

    /// "12 glyphs", "3 of 12 glyphs", with "· 40 missing" while placeholders show.
    static func countText(shown: Int, of count: Int, missing: Int) -> String {
        let glyphs = shown == count ? "\(count) glyphs" : "\(shown) of \(count) glyphs"
        return missing > 0 ? "\(glyphs) · \(missing) missing" : glyphs
    }

    @objc private func clipDidResize(_ note: Notification) {
        gridView.relayout(width: scrollView.contentView.bounds.width)
    }

    @objc func sortChanged(_ sender: NSPopUpButton) {
        model.sort = GlyphSort.allCases[max(sender.indexOfSelectedItem, 0)]
    }

    @objc func sizeChanged(_ sender: NSPopUpButton) {
        model.cellSize = GlyphThumbnail.CellSize.allCases[max(sender.indexOfSelectedItem, 0)]
        modelDidChange()
    }

    @objc func add(_ sender: Any?) { onAdd?() }

    func controlTextDidChange(_ note: Notification) {
        model.search = searchField.stringValue
    }

    /// The cell image of `cell` at `pixels` (device pixels).
    func image(for cell: GlyphCell, pixels: Int) -> CGImage? {
        let state = document.state
        // Glyphs draw in the label colour, so they read in dark mode too.
        var color = CGColor(gray: 0, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        return thumbnails.image(for: cell.id, advanceWidth: cell.advanceWidth, in: state, font: WTModel.FontInfo(state).metrics, pixels: pixels,
                                color: color)
    }
}

/// The grid's cells, drawn in rows (flipped: row 0 at the top).
@MainActor
final class GlyphGridView: NSView, NSMenuItemValidation {
    let model: GlyphGridModel
    var image: (@MainActor (GlyphCell, Int) -> CGImage?)?
    var onOpen: (@MainActor (OpID) -> Void)?
    var onRemove: (@MainActor () -> Void)?
    /// A double-click on an encoding placeholder: the glyph is made and opened.
    var onCreate: (@MainActor (UInt32) -> Void)?
    /// A drag of the selection in Custom order dropped at grid position `order` (1-based, without the selection).
    var onReorder: (@MainActor ([OpID], Int) -> Void)?
    /// menu:Edit[Copy] and menu:Edit[Paste] with the grid focused (FONT-008).
    var onCopy: (@MainActor () -> Void)?
    var onPaste: (@MainActor () -> Void)?
    var canPaste: @MainActor () -> Bool = { false }
    /// Characters typed in quick succession jump together.
    private var typed = ""
    private var lastTyped = Date.distantPast
    /// A press on a selected cell that may become a drag: where it started and the item pressed.
    private var pressed: (point: NSPoint, item: Int)?
    /// While dragging cells: the item the drop goes before (`items.count`: the end).
    private(set) var dropItem: Int?

    static let labelHeight = 18.0
    static let spacing = 6.0
    /// How far a press on a selected cell moves before it drags the selection.
    static let dragThreshold = 4.0
    static let markColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal,
                                        .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown]

    init(model: GlyphGridModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        setAccessibilityIdentifier("typeface.grid.cells")
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GlyphGridView is built in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var cellSize: NSSize {
        let side = Double(model.cellSize.rawValue)
        return NSSize(width: side + Self.spacing * 2, height: side + Self.labelHeight + Self.spacing * 2)
    }

    var columns: Int { max(1, Int(bounds.width / cellSize.width)) }

    var rows: Int { (model.items.count + columns - 1) / columns }

    /// Sizes the view to its rows at `width`.
    func relayout(width: Double) {
        setFrameSize(NSSize(width: max(width, cellSize.width), height: frame.height))
        let height = Double(rows) * cellSize.height
        setFrameSize(NSSize(width: frame.width, height: max(height, superview?.bounds.height ?? 0)))
        setAccessibilityValue("\(model.cells.count) glyphs")
    }

    /// The rectangle of the item at `position`.
    func rect(of position: Int) -> NSRect {
        let size = cellSize
        return NSRect(x: Double(position % columns) * size.width, y: Double(position / columns) * size.height, width: size.width, height: size.height)
    }

    /// The item position under view point `point`, nil past the items.
    func position(at point: NSPoint) -> Int? {
        let size = cellSize
        let column = Int(point.x / size.width), row = Int(point.y / size.height)
        guard point.x >= 0, point.y >= 0, column < columns else { return nil }
        let position = row * columns + column
        return model.items.indices.contains(position) ? position : nil
    }

    /// The item a drop at `point` goes before: the cell under it (its right half: the next one), the end past the
    /// cells.
    func dropPosition(at point: NSPoint) -> Int {
        guard let position = position(at: point) else { return model.items.count }
        return point.x > rect(of: position).midX ? position + 1 : position
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let context = NSGraphicsContext.current!.cgContext
        let scale = window?.backingScaleFactor ?? 2
        for (position, item) in model.items.enumerated() {
            let frame = rect(of: position)
            guard frame.intersects(dirtyRect) else { continue }
            switch item {
            case .glyph(let cell): draw(cell, in: frame, context: context, scale: scale)
            case .placeholder(let codepoint): drawPlaceholder(codepoint, in: frame)
            }
        }
        if let dropItem { drawDropMarker(before: dropItem) }
    }

    private func draw(_ cell: GlyphCell, in frame: NSRect, context: CGContext, scale: Double) {
        let selected = model.isSelected(cell.id)
        let inner = frame.insetBy(dx: Self.spacing / 2, dy: Self.spacing / 2)
        (selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : NSColor.controlBackgroundColor).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4).fill()
        (selected ? NSColor.selectedContentBackgroundColor : NSColor.separatorColor).setStroke()
        NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4).stroke()
        let side = Double(model.cellSize.rawValue)
        let imageRect = NSRect(x: frame.minX + Self.spacing, y: frame.minY + Self.spacing, width: side, height: side)
        if let image = image?(cell, Int(side * scale)) {
            context.saveGState()
            // The view is flipped: draw the image upright.
            context.translateBy(x: imageRect.minX, y: imageRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageRect.width, height: imageRect.height))
            context.restoreGState()
        }
        if cell.markColor > 0 {
            Self.markColors[(cell.markColor - 1) % Self.markColors.count].setFill()
            NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 3).fill()
        }
        let label = NSAttributedString(string: cell.label, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: Self.centred,
        ])
        label.draw(with: NSRect(x: frame.minX + 2, y: imageRect.maxY + 2, width: frame.width - 4, height: Self.labelHeight - 2),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        var badgeX = inner.maxX - 8
        for badge in GlyphCell.Badge.allCases where cell.badges.contains(badge) {
            Self.color(of: badge).setFill()
            NSBezierPath(ovalIn: NSRect(x: badgeX, y: inner.minY + 4, width: 5, height: 5)).fill()
            badgeX -= 7
        }
    }

    /// A placeholder: a dashed, faint cell with the character large and its codepoint as the label.
    private func drawPlaceholder(_ codepoint: UInt32, in frame: NSRect) {
        let inner = frame.insetBy(dx: Self.spacing / 2, dy: Self.spacing / 2)
        let outline = NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4)
        outline.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        outline.stroke()
        let side = Double(model.cellSize.rawValue)
        let (character, label) = GlyphGridItem.label(of: codepoint)
        let glyph = NSAttributedString(string: character, attributes: [
            .font: NSFont.systemFont(ofSize: side * 0.5), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.centred,
        ])
        let height = glyph.size().height
        glyph.draw(with: NSRect(x: frame.minX, y: frame.minY + Self.spacing + (side - height) / 2, width: frame.width, height: height),
                   options: [.usesLineFragmentOrigin])
        NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.centred,
        ]).draw(with: NSRect(x: frame.minX + 2, y: frame.minY + Self.spacing + side + 2, width: frame.width - 4, height: Self.labelHeight - 2),
                options: [.usesLineFragmentOrigin])
    }

    /// The insertion line a drag of cells would drop at.
    private func drawDropMarker(before item: Int) {
        let frame = item < model.items.count ? rect(of: item) : model.items.isEmpty ? rect(of: 0) : rect(of: model.items.count - 1).offsetBy(dx: cellSize.width, dy: 0)
        NSColor.controlAccentColor.setFill()
        NSRect(x: frame.minX - 1, y: frame.minY + 2, width: 2, height: frame.height - 4).fill()
    }

    static let centred: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    static func color(of badge: GlyphCell.Badge) -> NSColor {
        switch badge {
        case .collision: .systemRed
        case .noExport: .systemGray
        case .components: .systemBlue
        }
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        released(at: convert(event.locationInWindow, from: nil))
    }

    /// A press at `point`: a double-click opens the glyph (or makes a placeholder's); a press on a selected cell
    /// in Custom order may start a drag (it selects that cell alone on release when it does not); otherwise the
    /// click selects.
    func press(at point: NSPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        pressed = nil
        let position = position(at: point)
        let item = position.map { model.items[$0] }
        if clickCount >= 2, let item {
            switch item {
            case .glyph(let cell): onOpen?(cell.id)
            case .placeholder(let codepoint): onCreate?(codepoint)
            }
            return
        }
        let extend = modifiers.contains(.shift), toggle = modifiers.contains(.command)
        if let position, let cell = item?.glyph, model.isSelected(cell.id), !extend, !toggle, model.canReorder {
            pressed = (point, position)
            return
        }
        click(item: position, extend: extend, toggle: toggle)
    }

    /// A click on item `position`: a glyph cell selects (by the model's rules); a placeholder or no item clears.
    private func click(item position: Int?, extend: Bool = false, toggle: Bool = false) {
        guard let position, let cell = model.items[position].glyph else {
            model.click(at: nil, extend: extend, toggle: toggle)
            return
        }
        model.click(at: model.position(of: cell.id), extend: extend, toggle: toggle)
    }

    func dragged(to point: NSPoint) {
        guard let pressed else { return }
        guard dropItem != nil || hypot(point.x - pressed.point.x, point.y - pressed.point.y) >= Self.dragThreshold else { return }
        dropItem = dropPosition(at: point)
        needsDisplay = true
    }

    func released(at point: NSPoint) {
        defer {
            pressed = nil
            dropItem = nil
            needsDisplay = true
        }
        guard let pressed else { return }
        guard dropItem != nil else {
            click(item: pressed.item)
            return
        }
        let order = model.dropOrder(before: dropPosition(at: point))
        onReorder?(model.selection, order)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event.charactersIgnoringModifiers!, characters: event.characters!, shift: event.modifierFlags.contains(.shift)) {
            super.keyDown(with: event)
        }
    }

    /// The grid's keys: arrows move the selection (Shift extends), Return opens it, Delete removes
    /// it, anything else printable jumps to the glyph it names.
    @discardableResult
    func handleKey(_ key: String, characters: String, shift: Bool = false, now: Date = Date()) -> Bool {
        switch key {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): model.move(by: -1, extend: shift)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): model.move(by: 1, extend: shift)
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): model.move(by: -columns, extend: shift)
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): model.move(by: columns, extend: shift)
        case "\r":
            for glyph in model.selection { onOpen?(glyph) }
        case "\u{7F}", String(UnicodeScalar(NSDeleteFunctionKey)!):
            onRemove?()
        default:
            guard !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value >= 0x20 && $0.value < 0xF700 }) else {
                return false
            }
            typed = now.timeIntervalSince(lastTyped) < 1 ? typed + characters : characters
            lastTyped = now
            if !model.jump(to: typed) { model.jump(to: characters) }
        }
        if let last = model.selection.last, let position = model.itemPosition(of: last) { scrollToVisible(rect(of: position)) }
        return true
    }

    // MARK: Edit menu (responder chain)

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
    @objc override func selectAll(_ sender: Any?) { model.selectAll() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): !model.selection.isEmpty
        case #selector(paste(_:)): canPaste()
        case #selector(selectAll(_:)): !model.cells.isEmpty
        default: true
        }
    }
}
