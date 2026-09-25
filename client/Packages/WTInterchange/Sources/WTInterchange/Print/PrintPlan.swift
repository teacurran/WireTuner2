// The print plan (PRINT-003, PRINT-005, PRINT-006, PRINT-008; docs/_includes/printing/printing.adoc,
// "Client"): a pure function of the job -- the captured pages, the print settings, the paper and
// the job parameters -- producing the ordered sheets the print view draws.  Sheets are pages ×
// tiles × plates, ordered page, then tile (row-major), then plate (C, M, Y, K, spots in swatch
// order), so a platesetter receives each page's plates together.  Each sheet carries everything
// drawing needs: the pasteboard region it prints, the pasteboard → paper transform, the clip
// (page plus bleed, within the tile), and its marks and labels in paper space.
//
// Paper space: points, origin at the paper's top-left, y down (the document's orientation).

import Foundation
import WTGeometry
import WTRender

/// What one sheet prints with: every colour, or one plate.
public enum SheetPlate: Hashable, Sendable {
    case composite
    case separation(PrintPlate)

    /// The ink, for a plate.
    public var ink: Ink? {
        if case .separation(let plate) = self { return plate.ink }
        return nil
    }
}

/// One sheet of paper.
public struct OutputSheet: Hashable, Sendable {
    /// Index into `PrintPlan.pages`.
    public var page: Int
    /// The document page number; nil for the output area.
    public var pageNumber: Int?
    /// The tile, when the job tiles.
    public var tile: PrintTile?
    public var plate: SheetPlate
    /// The pasteboard rectangle printed: the page plus bleed, or the tile's part of it.
    public var region: Rect
    /// Pasteboard → paper.
    public var transform: AffineTransform
    /// The printed area on the paper: artwork outside it is clipped.
    public var clip: Rect
    /// The page (or output area) on the paper, before bleed.
    public var trim: Rect
    public var marks: [PrinterMark]
    public var labels: [SheetLabel]
    /// `Page 1, row 2 column 1, Magenta`: the progress and preview name.
    public var name: String
    /// Whether any mark or label falls outside the printable area.
    public var marksClipped: Bool
}

/// The ordered sheets of a job.
public struct PrintPlan: Sendable {
    public let request: PrintRequest
    /// The printed pages, with *Selected objects only* applied to their lists.
    public let pages: [ExportPage]
    public let sheets: [OutputSheet]
    /// The scale each page prints at (after *Fit on paper*), parallel to `pages`.
    public let scales: [(x: Double, y: Double)]

    /// The sheet count the dialog paginates by.
    public var count: Int { sheets.count }

    /// The warning the pane shows beneath the preview when marks or labels will be clipped.
    public var clippingWarning: String? {
        sheets.contains(where: \.marksClipped) ? "Some printer's marks or labels fall outside the printable area and will be clipped." : nil
    }

    /// Plans `request`.
    public init(_ request: PrintRequest) {
        self.request = request
        let options = request.options
        var pages: [ExportPage] = []
        for page in request.scene.pages {
            if case .pages = request.source, let range = request.pageRange, let number = page.number, !range.contains(number) { continue }
            pages.append(request.selection.map { PrintSelection.filter(page, keeping: $0) } ?? page)
        }
        self.pages = pages
        let plates: [SheetPlate] = options.separations ? options.printedPlates.map(SheetPlate.separation) : [.composite]
        var sheets: [OutputSheet] = []
        var scales: [(x: Double, y: Double)] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = request.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: request.date)
        for (index, page) in pages.enumerated() {
            let layout = PageLayout(page: page, request: request)
            scales.append(layout.scale)
            for placement in layout.placements() {
                for plate in plates {
                    sheets.append(layout.sheet(index, placement: placement, plate: plate, stamp: stamp))
                }
            }
        }
        self.sheets = sheets
        self.scales = scales
    }
}

/// One page's placement on the paper: scale, tiles and marks.
struct PageLayout {
    let page: ExportPage
    let request: PrintRequest
    let options: PrintOptions
    /// The page (or output area), pasteboard.
    let trim: Rect
    /// The page plus bleed, pasteboard.
    let content: Rect
    let scale: (x: Double, y: Double)
    /// The paper area artwork may use when tiling (the printable area less the marks' margin).
    let area: Rect

    init(page: ExportPage, request: PrintRequest) {
        self.page = page
        self.request = request
        options = request.options
        trim = page.bounds
        content = page.bounds.expanded(by: options.bleed)
        let margin = options.marks.isEmpty ? 0 : PrinterMarks.margin
        let imageable = request.paper.imageable
        let usable = imageable.insetBy(dx: min(margin, imageable.width / 4), dy: min(margin, imageable.height / 4))
        area = usable
        if options.scaleMode == .fit, content.width > 0, content.height > 0 {
            let fit = min(usable.width / content.width, usable.height / content.height)
            scale = (fit, fit)
        } else {
            scale = options.fixedScale
        }
    }

    /// Where the page goes: one untiled placement, or one per tile.
    struct Placement {
        var tile: PrintTile?
        /// The pasteboard rectangle printed.
        var region: Rect
        var transform: AffineTransform
    }

    func placements() -> [Placement] {
        let tileSize = Size(width: area.width / scale.x, height: area.height / scale.y)
        let toArea = { (origin: Point) -> AffineTransform in
            AffineTransform.translation(x: -origin.x, y: -origin.y)
                .concatenating(.scale(x: self.scale.x, y: self.scale.y))
                .concatenating(.translation(x: self.area.minX, y: self.area.minY))
        }
        switch options.effectiveTile {
        case .none:
            // Centred on the printable area, then moved by the offset.
            let center = request.paper.imageable.center
            let transform = AffineTransform.translation(x: -trim.midX, y: -trim.midY)
                .concatenating(.scale(x: scale.x, y: scale.y))
                .concatenating(.translation(x: center.x + options.offset.x, y: center.y + options.offset.y))
            return [Placement(tile: nil, region: content, transform: transform)]
        case .automatic:
            return PrintTiling.automatic(content: content, tileSize: tileSize, overlap: options.tileOverlap).map { tile in
                Placement(tile: tile, region: tile.rect.intersection(content), transform: toArea(tile.rect.origin))
            }
        case .manual:
            let zero = page.number.flatMap { request.zeroPoints[$0] } ?? trim.origin
            let tile = PrintTiling.manual(zeroPoint: zero, tileSize: tileSize)
            return [Placement(tile: tile, region: tile.rect.intersection(content), transform: toArea(zero))]
        }
    }

    func sheet(_ index: Int, placement: Placement, plate: SheetPlate, stamp: String) -> OutputSheet {
        let transform = placement.transform
        let trimOnPaper = trim.applying(transform)
        let clip = placement.region.isNull ? Rect(x: 0, y: 0, width: 0, height: 0) : placement.region.applying(transform)
        let tileFrame = placement.tile.map { $0.rect.applying(transform) }
        var marks: [PrinterMark] = []
        let bleed = (x: options.bleed * scale.x, y: options.bleed * scale.y)
        if options.marks.contains(.crop) {
            // A tile carries the page corners that fall on it.
            let frame = tileFrame?.expanded(by: 1e-6)
            marks += PrinterMarks.crop(trim: trimOnPaper, bleed: bleed) { frame?.contains($0) ?? true }
        }
        if options.marks.contains(.registration), !clip.isEmpty {
            marks += PrinterMarks.registration(frame: clip)
        }
        if let tile = placement.tile, !tile.isManual {
            marks += tileMarks(tile, transform: transform, frame: clip)
        }
        var labels: [SheetLabel] = []
        let pageName = page.number.map { "Page \($0)" } ?? "Output area"
        // Labels hug the printed area, inside the gap the marks leave (clear of the targets).
        let below = clip.maxY + PrinterMarks.gap - 0.5
        let above = clip.minY - 1.5
        let leading = clip.minX + PrinterMarks.gap
        if options.marks.contains(.separationNames) {
            let text: String
            switch plate {
            case .composite: text = "Composite"
            case .separation(let plate): text = plate.label(default: options.defaultScreen)
            }
            labels.append(SheetLabel(text: text, anchor: Point(x: leading, y: below)))
        }
        if options.marks.contains(.fileNameDate) {
            labels.append(SheetLabel(text: "\(request.scene.name)  \(pageName)  \(stamp)", anchor: Point(x: leading, y: above)))
        }
        if let tile = placement.tile, !tile.isManual, !options.marks.isEmpty {
            labels.append(SheetLabel(text: tile.label, anchor: Point(x: clip.maxX - PrinterMarks.gap, y: above), alignment: .trailing))
        }
        var name = pageName
        if let tile = placement.tile, !tile.isManual {
            name += ", row \(tile.row + 1) column \(tile.column + 1)"
        }
        if case .separation(let plate) = plate {
            name += ", \(plate.name)"
        }
        let imageable = request.paper.imageable.expanded(by: 1e-6)
        let clipped = marks.contains { !imageable.contains($0.bounds) } || labels.contains { !imageable.contains($0.bounds) }
        return OutputSheet(page: index, pageNumber: page.number, tile: placement.tile, plate: plate, region: placement.region, transform: transform,
                           clip: clip, trim: trimOnPaper, marks: marks, labels: labels, name: name, marksClipped: clipped)
    }

    /// Tile marks: where each neighbouring tile's artwork begins (the inner edge of the overlap),
    /// as short ticks outside the printed area on the sides crossing that edge.
    func tileMarks(_ tile: PrintTile, transform: AffineTransform, frame: Rect) -> [PrinterMark] {
        guard !frame.isEmpty else { return [] }
        let overlap = overlapWidth(tile)
        let start = PrinterMarks.gap, end = PrinterMarks.gap + PrinterMarks.length / 2
        var marks: [PrinterMark] = []
        func vertical(_ x: Double) {
            let px = transform.apply(Point(x: x, y: 0)).x
            guard px > frame.minX, px < frame.maxX else { return }
            marks.append(.line(from: Point(x: px, y: frame.minY - start), to: Point(x: px, y: frame.minY - end)))
            marks.append(.line(from: Point(x: px, y: frame.maxY + start), to: Point(x: px, y: frame.maxY + end)))
        }
        func horizontal(_ y: Double) {
            let py = transform.apply(Point(x: 0, y: y)).y
            guard py > frame.minY, py < frame.maxY else { return }
            marks.append(.line(from: Point(x: frame.minX - start, y: py), to: Point(x: frame.minX - end, y: py)))
            marks.append(.line(from: Point(x: frame.maxX + start, y: py), to: Point(x: frame.maxX + end, y: py)))
        }
        if tile.column > 0 { vertical(tile.rect.minX + overlap) }
        if tile.column < tile.columns - 1 { vertical(tile.rect.maxX - overlap) }
        if tile.row > 0 { horizontal(tile.rect.minY + overlap) }
        if tile.row < tile.rows - 1 { horizontal(tile.rect.maxY - overlap) }
        return marks
    }

    /// The overlap the grid used (the setting, reduced as `PrintTiling.automatic` reduces it).
    func overlapWidth(_ tile: PrintTile) -> Double {
        let limit = min(tile.rect.width, tile.rect.height) / 2
        return min(options.tileOverlap, limit * 0.999)
    }
}

/// *Selected objects only* (printing.adoc, "Choosing what to print"): a page keeping only the
/// selected objects, in place.  An object is kept whole when it or an enclosing object is
/// selected; a group (a layer's run, a group) is kept with those of its members that are.
enum PrintSelection {
    static func filter(_ page: ExportPage, keeping selected: Set<NodeID>) -> ExportPage {
        var items: [DisplayItem] = []
        var ids: [NodeID?] = []
        var nested: [[Int]: NodeID] = [:]

        /// The kept part of the item at `oldPath`, recorded at `newPath`; nil when nothing is kept.
        func keep(_ item: DisplayItem, oldPath: [Int], newPath: [Int]) -> DisplayItem? {
            if let node = page.nodeID(at: oldPath), selected.contains(node) {
                copyIDs(from: oldPath, to: newPath)
                return item
            }
            guard case .group(var group) = item else { return nil }
            var children: [DisplayItem] = []
            for (index, child) in group.children.enumerated() {
                if let kept = keep(child, oldPath: oldPath + [index], newPath: newPath + [children.count]) {
                    children.append(kept)
                }
            }
            guard !children.isEmpty else { return nil }
            group.children = children
            if newPath.count > 1, let node = page.nodeID(at: oldPath) { nested[newPath] = node }
            return .group(group)
        }

        /// The ids of everything under `oldPath`, moved to `newPath`.
        func copyIDs(from oldPath: [Int], to newPath: [Int]) {
            if newPath.count > 1, let node = page.nodeID(at: oldPath) { nested[newPath] = node }
            for (path, node) in page.nestedNodeIDs where path.count > oldPath.count && path.starts(with: oldPath) {
                nested[newPath + path.dropFirst(oldPath.count)] = node
            }
        }

        for (index, item) in page.displayList.items.enumerated() {
            if let kept = keep(item, oldPath: [index], newPath: [items.count]) {
                items.append(kept)
                ids.append(page.displayList.nodeIDs.indices.contains(index) ? page.displayList.nodeIDs[index] : nil)
            }
        }
        var result = page
        result.displayList = DisplayList(canvas: page.displayList.canvas, items: items, nodeIDs: ids.contains { $0 != nil } ? ids : [])
        result.nestedNodeIDs = nested
        return result
    }
}
