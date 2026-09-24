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
        countLabel.stringValue = model.cells.count == count ? "\(count) glyphs" : "\(model.cells.count) of \(count) glyphs"
        gridView.relayout(width: scrollView.contentView.bounds.width)
        gridView.needsDisplay = true
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
final class GlyphGridView: NSView {
    let model: GlyphGridModel
    var image: (@MainActor (GlyphCell, Int) -> CGImage?)?
    var onOpen: (@MainActor (OpID) -> Void)?
    var onRemove: (@MainActor () -> Void)?
    /// Characters typed in quick succession jump together.
    private var typed = ""
    private var lastTyped = Date.distantPast

    static let labelHeight = 18.0
    static let spacing = 6.0
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

    var rows: Int { (model.cells.count + columns - 1) / columns }

    /// Sizes the view to its rows at `width`.
    func relayout(width: Double) {
        setFrameSize(NSSize(width: max(width, cellSize.width), height: frame.height))
        let height = Double(rows) * cellSize.height
        setFrameSize(NSSize(width: frame.width, height: max(height, superview?.bounds.height ?? 0)))
        setAccessibilityValue("\(model.cells.count) glyphs")
    }

    /// The rectangle of the cell at `position`.
    func rect(of position: Int) -> NSRect {
        let size = cellSize
        return NSRect(x: Double(position % columns) * size.width, y: Double(position / columns) * size.height, width: size.width, height: size.height)
    }

    /// The cell position under view point `point`, nil past the cells.
    func position(at point: NSPoint) -> Int? {
        let size = cellSize
        let column = Int(point.x / size.width), row = Int(point.y / size.height)
        guard point.x >= 0, point.y >= 0, column < columns else { return nil }
        let position = row * columns + column
        return model.cells.indices.contains(position) ? position : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let context = NSGraphicsContext.current!.cgContext
        let scale = window?.backingScaleFactor ?? 2
        for (position, cell) in model.cells.enumerated() {
            let frame = rect(of: position)
            guard frame.intersects(dirtyRect) else { continue }
            draw(cell, in: frame, context: context, scale: scale)
        }
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
        let point = convert(event.locationInWindow, from: nil)
        let position = position(at: point)
        if event.clickCount >= 2, let position {
            onOpen?(model.cells[position].id)
            return
        }
        model.click(at: position, extend: event.modifierFlags.contains(.shift), toggle: event.modifierFlags.contains(.command))
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
        if let last = model.selection.last, let position = model.position(of: last) { scrollToVisible(rect(of: position)) }
        return true
    }
}
