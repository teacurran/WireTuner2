import CoreGraphics
import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

// The glyph grid's state (glyph-grid.adoc; FONT-010): the cells read from `GlyphIndex` in the
// chosen order, filtered by the search field, with the selection surviving remote changes.

/// One cell of the grid.
struct GlyphCell: Hashable, Identifiable {
    enum Badge: Hashable, CaseIterable {
        /// A name or codepoint collision read-time normalization renamed or unencoded it.
        case collision
        /// Left out of generated fonts.
        case noExport
        /// Built from components.
        case components
    }

    let id: OpID
    let name: String
    /// What the cell's label shows: the character for an encoded glyph, else the name.
    let label: String
    let codepoints: [UInt32]
    let badges: Set<Badge>
    let markColor: Int
    let advanceWidth: Double
    /// Its 1-based position in grid (custom) order.
    let order: Int

    init(_ glyph: Glyph) {
        id = glyph.id
        name = glyph.name
        codepoints = glyph.codepoints
        label = GlyphCell.label(glyph)
        var badges: Set<Badge> = []
        if glyph.hasCollision { badges.insert(.collision) }
        if glyph.skipExport { badges.insert(.noExport) }
        if !glyph.components.isEmpty { badges.insert(.components) }
        self.badges = badges
        markColor = glyph.markColor
        advanceWidth = glyph.advanceWidth
        order = glyph.order
    }

    /// The character a glyph encodes (its first codepoint, when printable), else its name.
    static func label(_ glyph: Glyph) -> String {
        guard let first = glyph.codepoints.first, let scalar = Unicode.Scalar(first),
              !scalar.properties.isWhitespace, scalar.properties.generalCategory != .control else { return glyph.name }
        return String(Character(scalar))
    }

    /// "U+0041" for the first codepoint, "" for an unencoded glyph.
    var unicodeLabel: String {
        codepoints.first.map { String(format: "U+%04X", $0) } ?? ""
    }

    /// Whether the search text `query` finds the cell: its name, its character or its codepoint
    /// ("U+41", "41", "0041"), case-insensitively.
    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(text) || label == text { return true }
        var hex = text.uppercased()
        if hex.hasPrefix("U+") { hex.removeFirst(2) }
        guard let value = UInt32(hex, radix: 16) else { return false }
        return codepoints.contains(value)
    }
}

/// The grid's sort orders (glyph-grid.adoc, "Sorting"): custom order is the document's.
enum GlyphSort: Int, CaseIterable {
    case custom, unicode, name

    var title: String {
        switch self {
        case .custom: "Custom Order"
        case .unicode: "Unicode"
        case .name: "Name"
        }
    }

    func sorted(_ cells: [GlyphCell]) -> [GlyphCell] {
        switch self {
        case .custom:
            return cells
        case .unicode:
            // Encoded glyphs by codepoint, then the unencoded in custom order.
            let encoded = cells.filter { !$0.codepoints.isEmpty }.sorted { $0.codepoints.min()! < $1.codepoints.min()! }
            return encoded + cells.filter(\.codepoints.isEmpty)
        case .name:
            return cells.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

/// What the grid lays out: a glyph's cell, or an encoding placeholder -- a faint cell for a character no glyph
/// encodes yet (glyph-grid.adoc, "Ordering and encodings").
enum GlyphGridItem: Hashable {
    case glyph(GlyphCell)
    case placeholder(UInt32)

    var glyph: GlyphCell? {
        if case .glyph(let cell) = self { return cell }
        return nil
    }

    /// The character a placeholder stands for, and its codepoint.
    static func label(of codepoint: UInt32) -> (character: String, codepoint: String) {
        (Unicode.Scalar(codepoint).map { String(Character($0)) } ?? "", String(format: "U+%04X", codepoint))
    }
}

/// The glyph grid's cells, order, filter and selection.
@MainActor
final class GlyphGridModel {
    private(set) var index = GlyphIndex(EngineState())
    /// The cells shown, in the chosen order and filtered by `search`.
    private(set) var cells: [GlyphCell] = []
    /// The cells and the placeholders in layout order: in Unicode order each placeholder sits among the encoded
    /// glyphs by its codepoint, in the other orders after every glyph.
    private(set) var items: [GlyphGridItem] = []
    /// menu:View[Encoding]: the character sets whose empty slots show as placeholders (none by default).
    var encodings: Set<GlyphEncoding> = [] {
        didSet { if encodings != oldValue { rebuild() } }
    }
    /// The selected glyphs, in the order they were selected.
    private(set) var selection: [OpID] = []
    /// Where a Shift-click extends from.
    private(set) var anchor: OpID?
    var sort: GlyphSort = .custom {
        didSet { if sort != oldValue { rebuild() } }
    }
    var search = "" {
        didSet { if search != oldValue { rebuild() } }
    }
    var cellSize: GlyphThumbnail.CellSize = .medium
    /// Called after the cells or the selection change.
    var onChange: (@MainActor () -> Void)?

    /// Reads the glyphs from `state`; selected glyphs still live stay selected.
    func reload(_ state: EngineState) {
        index = GlyphIndex(state)
        rebuild()
    }

    private func rebuild() {
        cells = sort.sorted(index.glyphs.map(GlyphCell.init)).filter { $0.matches(search) }
        let placeholders = GlyphEncoding.placeholders(encodings, in: index).filter { Self.placeholder($0, matches: search) }
        items = Self.layout(cells, placeholders: placeholders, sort: sort)
        let live = Set(index.glyphs.map(\.id))
        selection.removeAll { !live.contains($0) }
        if let anchor, !live.contains(anchor) { self.anchor = selection.last }
        onChange?()
    }

    func position(of glyph: OpID) -> Int? {
        cells.firstIndex { $0.id == glyph }
    }

    /// Where the cell of `glyph` is laid out (an index into `items`).
    func itemPosition(of glyph: OpID) -> Int? {
        items.firstIndex { $0.glyph?.id == glyph }
    }

    /// `cells` and `placeholders` in layout order.
    static func layout(_ cells: [GlyphCell], placeholders: [UInt32], sort: GlyphSort) -> [GlyphGridItem] {
        guard sort == .unicode, !placeholders.isEmpty else { return cells.map(GlyphGridItem.glyph) + placeholders.map(GlyphGridItem.placeholder) }
        var result: [GlyphGridItem] = []
        var pending = placeholders[...]
        for cell in cells {
            if let first = cell.codepoints.min() {
                while let next = pending.first, next < first {
                    result.append(.placeholder(next))
                    pending = pending.dropFirst()
                }
            } else {
                // The unencoded glyphs come last: every placeholder goes before them.
                result += pending.map(GlyphGridItem.placeholder)
                pending = []
            }
            result.append(.glyph(cell))
        }
        return result + pending.map(GlyphGridItem.placeholder)
    }

    /// Whether the search text finds a placeholder: its character or its codepoint.
    static func placeholder(_ codepoint: UInt32, matches query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        if GlyphGridItem.label(of: codepoint).character == text { return true }
        var hex = text.uppercased()
        if hex.hasPrefix("U+") { hex.removeFirst(2) }
        return UInt32(hex, radix: 16) == codepoint
    }

    /// Whether cells can be dragged to a new place: in Custom order, unfiltered.
    var canReorder: Bool { sort == .custom && search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The grid position (1-based, counted without the selection) a drop before item `item` moves the selection
    /// to; a drop past the end moves it to the end.
    func dropOrder(before item: Int) -> Int {
        let moving = Set(selection)
        let before = items.prefix(max(0, min(item, items.count))).compactMap(\.glyph).filter { !moving.contains($0.id) }.count
        return before + 1
    }

    func isSelected(_ glyph: OpID) -> Bool { selection.contains(glyph) }

    /// A click on the cell at `position`: selects it alone; with Shift, the range from the anchor;
    /// with Command, toggles it.  A click past the cells clears the selection.
    func click(at position: Int?, extend: Bool = false, toggle: Bool = false) {
        guard let position, cells.indices.contains(position) else {
            if !extend, !toggle { select([]) }
            return
        }
        let glyph = cells[position].id
        if toggle {
            if let at = selection.firstIndex(of: glyph) { selection.remove(at: at) } else { selection.append(glyph) }
            anchor = glyph
        } else if extend, let anchor, let start = self.position(of: anchor) {
            let range = min(start, position)...max(start, position)
            selection = cells[range].map(\.id)
        } else {
            selection = [glyph]
            anchor = glyph
        }
        onChange?()
    }

    func select(_ glyphs: [OpID]) {
        selection = glyphs.filter { position(of: $0) != nil }
        anchor = selection.last
        onChange?()
    }

    func selectAll() { select(cells.map(\.id)) }

    /// The arrow keys: the selection moves by `offset` cells (a row is `columns` cells), clamped.
    func move(by offset: Int, extend: Bool = false) {
        guard !cells.isEmpty else { return }
        let current = selection.last.flatMap(position(of:)) ?? (offset > 0 ? -1 : cells.count)
        let target = min(max(current + offset, 0), cells.count - 1)
        click(at: target, extend: extend)
    }

    /// Type-to-jump: selects the first cell whose character is `text` or whose name starts with it.
    @discardableResult
    func jump(to text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let found = cells.firstIndex { $0.label == text } ?? cells.firstIndex { $0.name.lowercased().hasPrefix(text.lowercased()) }
        guard let found else { return false }
        click(at: found)
        return true
    }
}

/// Glyph cell images for one document: the thumbnail cache, a version per glyph advanced when a
/// change reaches it (`GlyphInvalidation`), and the flattener input read once per state.
@MainActor
final class GlyphThumbnailSource {
    let cache = GlyphThumbnailCache()
    private var versions: [OpID: UInt64] = [:]
    private var generation: UInt64 = 0
    /// The flattener input as of the last change (dropped by every change).
    private var sources: [NodeID: GlyphSource]?
    private var observation: (model: WTModel.Document, token: WTModel.Document.ObservationToken)?

    /// `glyph`'s image at `pixels` in `state` with `font`'s em.
    func image(for glyph: OpID, advanceWidth: Double, in state: EngineState, font: WTModel.FontInfo.Metrics, pixels: Int,
               color: CGColor = CGColor(gray: 0, alpha: 1)) -> CGImage? {
        let version = generation &+ (versions[glyph] ?? 0) &* 0x1_0000
        return cache.image(for: NodeID(glyph), version: version, pixels: pixels) {
            let outline = GlyphFlattener.outline(of: NodeID(glyph), sources: sources(in: state))
            return GlyphThumbnail.image(outline.path, advanceWidth: advanceWidth, ascender: font.ascender, descender: font.descender, pixels: pixels, color: color)
        }
    }

    private func sources(in state: EngineState) -> [NodeID: GlyphSource] {
        if let sources { return sources }
        let read = GlyphOutlines.sources(in: state)
        sources = read
        return read
    }

    /// Follows `document`'s changes once its model is open.
    @discardableResult
    func follow(_ document: DocumentHandle) -> Task<Void, Never> {
        Task { [weak self] in
            guard let model = await document.openedModel(), let self, self.observation == nil else { return }
            let token = model.observe { [weak self] event in self?.apply(event) }
            self.observation = (model, token)
        }
    }

    /// Stops following the document.
    func stop() {
        if let observation { observation.model.stopObserving(observation.token) }
        observation = nil
    }

    /// A change was applied: the glyphs it reached draw again; a font-level change (the em)
    /// redraws them all.
    func apply(_ event: DocumentEvent) {
        sources = nil
        guard event.origin != .reload, !event.change.ops.contains(where: { Self.touchesSettings($0) }) else {
            invalidateAll()
            return
        }
        invalidate(GlyphInvalidation.glyphs(touchedBy: event.change, before: event.before, after: event.after))
    }

    static func touchesSettings(_ op: Wiretuner_Doc_V1_Op) -> Bool {
        if case .set(let set)? = op.op { return OpID(set.node) == WellKnown.settings }
        return false
    }

    func invalidate(_ glyphs: Set<OpID>) {
        for glyph in glyphs { versions[glyph, default: 0] &+= 1 }
        cache.invalidate(Set(glyphs.map(NodeID.init)))
    }

    func invalidateAll() {
        generation &+= 1
        cache.removeAll()
    }
}
