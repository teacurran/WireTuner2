import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTText

// DATA-019: the merge engine (data-merge.adoc, "Merge engine"): which records go on which output
// page and where, the finishing options (blank lines, shrink-to-fit) and the report.  Two
// consumers read a plan: `MergeToPages` (document writes) and `MergeOutput` (PDF and print,
// nothing written).

/// *Records*: *All*, or a list of ranges typed in the merge sheet (`1-50`, `51-`, `3, 7, 12`).
public struct MergeRange: Hashable, Sendable {
    /// Inclusive 1-based ranges; an open end is `Int.max`.  Empty means all.
    public var ranges: [ClosedRange<Int>]

    public static let all = MergeRange(ranges: [])

    public init(ranges: [ClosedRange<Int>]) {
        self.ranges = ranges
    }

    /// Parses the sheet's text; nil when it is not a list of numbers and ranges.  An empty text
    /// is *All*.
    public init?(_ text: String) {
        var ranges: [ClosedRange<Int>] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            switch bounds.count {
            case 1:
                guard let value = Int(bounds[0]), value >= 1 else { return nil }
                ranges.append(value...value)
            case 2:
                guard let low = Int(bounds[0]), low >= 1 else { return nil }
                if bounds[1].isEmpty {
                    ranges.append(low...Int.max)
                } else {
                    guard let high = Int(bounds[1]), high >= low else { return nil }
                    ranges.append(low...high)
                }
            default:
                return nil
            }
        }
        self.ranges = ranges
    }

    /// The 0-based record indices selected out of `count`, in the order given (duplicates kept
    /// out).
    public func indices(count: Int) -> [Int] {
        guard !ranges.isEmpty else { return Array(0..<count) }
        var seen: Set<Int> = []
        var result: [Int] = []
        for range in ranges {
            guard range.lowerBound <= count else { continue }
            for number in range.lowerBound...min(range.upperBound, count) where seen.insert(number).inserted {
                result.append(number - 1)
            }
        }
        return result
    }
}

/// The merge sheet's layout choice.
public enum MergeLayout: Hashable, Sendable {
    public enum Order: Hashable, Sendable {
        case acrossThenDown, downThenAcross
    }

    /// The template page (or pages) copied once per record.
    case onePerPage
    /// A grid of copies of the selected objects' bounds on each page.
    case grid(columns: Int, rows: Int, gap: Double, margins: Double, order: Order)

    /// Records per output page (or set of pages).
    public var perPage: Int {
        switch self {
        case .onePerPage: 1
        case .grid(let columns, let rows, _, _, _): max(1, columns) * max(1, rows)
        }
    }
}

/// The finishing options shared by every target.
public struct MergeOptions: Hashable, Sendable {
    public var records: MergeRange
    public var layout: MergeLayout
    /// *Remove blank lines* (on by default).
    public var removeBlankLines: Bool
    /// *Shrink to fit* with its *Minimum size*; nil is *Leave and report*.
    public var shrinkToFit: Double?

    public init(records: MergeRange = .all, layout: MergeLayout = .onePerPage, removeBlankLines: Bool = true, shrinkToFit: Double? = nil) {
        self.records = records
        self.layout = layout
        self.removeBlankLines = removeBlankLines
        self.shrinkToFit = shrinkToFit
    }
}

/// One output page of a merge: the template page it is made from and, per copy on it, the
/// record and the translation from the template.
public struct MergedPage: Hashable, Sendable {
    public struct Placement: Hashable, Sendable {
        /// 0-based index into the record set.
        public var record: Int
        /// From the template's position to the copy's.
        public var offset: Vector
    }

    /// The template page this output page copies (for a set of template pages, one output page
    /// per template page per record).
    public var template: OpID
    public var placements: [Placement]
}

public enum MergeEngine {
    /// The translations of the cells of a `columns` × `rows` grid of `cell`-sized copies laid in
    /// `page` inside `margins`, `gap` apart, in `order`, relative to a template whose objects'
    /// union bounds start at `origin`.
    public static func cells(page: Rect, cell: Size, origin: Point, columns: Int, rows: Int, gap: Double, margins: Double,
                             order: MergeLayout.Order) -> [Vector] {
        let columns = max(1, columns)
        let rows = max(1, rows)
        var result: [Vector] = []
        for index in 0..<(columns * rows) {
            let (column, row) = order == .acrossThenDown ? (index % columns, index / columns) : (index / rows, index % rows)
            let x = page.minX + margins + Double(column) * (cell.width + gap)
            let y = page.minY + margins + Double(row) * (cell.height + gap)
            result.append(Vector(dx: x - origin.x, dy: y - origin.y))
        }
        return result
    }

    /// How many output pages `records` records need at `perPage` per page (per template page).
    public static func pageCount(records: Int, perPage: Int) -> Int {
        records == 0 ? 0 : (records + max(perPage, 1) - 1) / max(perPage, 1)
    }

    /// The output pages of merging the records `indices` through `templates` (one or more
    /// template pages, in order) with `layout`.  For a grid, `selection` is the union bounds of
    /// the selected objects on the (first) template page and `page` its rectangle; each page
    /// holds `columns × rows` copies.  One-per-page output places each record's copy of every
    /// template page at the template's own position (offset zero): the consumer positions the
    /// page.
    public static func plan(templates: [OpID], indices: [Int], layout: MergeLayout, page: Rect = .zero, selection: Rect = .zero) -> [MergedPage] {
        switch layout {
        case .onePerPage:
            return indices.flatMap { record in
                templates.map { MergedPage(template: $0, placements: [MergedPage.Placement(record: record, offset: Vector(dx: 0, dy: 0))]) }
            }
        case .grid(let columns, let rows, let gap, let margins, let order):
            let offsets = cells(page: page, cell: selection.size, origin: selection.origin, columns: columns, rows: rows, gap: gap,
                                margins: margins, order: order)
            let template = templates.first ?? .zero
            return stride(from: 0, to: indices.count, by: offsets.count).map { start in
                let chunk = indices[start..<min(start + offsets.count, indices.count)]
                return MergedPage(template: template, placements: zip(chunk, offsets).map { MergedPage.Placement(record: $0, offset: $1) })
            }
        }
    }

    /// *Shrink to fit*: `text` re-laid in 0.5 pt steps of its largest size, down to `minimum`,
    /// until `fits` says it fits.  Returns the text to place and whether it still overflows (a
    /// report row).
    public static func shrink(_ text: MergeText, minimum: Double, fits: (MergeText) -> Bool) -> (text: MergeText, overflows: Bool) {
        if fits(text) { return (text, false) }
        let largest = text.largestSize
        var size = largest - 0.5
        while size >= minimum, size > 0 {
            let candidate = text.scaled(by: size / largest)
            if fits(candidate) { return (candidate, false) }
            size -= 0.5
        }
        let floor = max(minimum, 0.5)
        return (floor < largest ? text.scaled(by: floor / largest) : text, true)
    }

    /// Whether `text` fits text node `node`'s block when laid out with `engine` (WTText's
    /// overflow test).
    @MainActor
    public static func fits(_ text: MergeText, in node: TextNode, engine: TextLayoutEngine) -> Bool {
        !engine.layout(text.content(), in: [TextLayoutReading.container(node)]).overflows
    }

    /// The merge report's rows, sorted by record then as found.
    public static func report(_ issues: [MergeIssue]) -> [MergeIssue] {
        issues.enumerated().sorted { a, b in a.element.record != b.element.record ? a.element.record < b.element.record : a.offset < b.offset }.map(\.element)
    }
}
