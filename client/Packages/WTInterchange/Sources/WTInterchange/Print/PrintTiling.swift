// Tiling (PRINT-005; docs/_includes/printing/printing.adoc, "Tiling").  *Automatic* cuts the
// page (with its bleed) into a grid of paper-sized tiles, each repeating `overlap` of artwork
// along every shared edge, in row-major order; *Manual* prints one tile whose top-left corner is
// the rulers' zero point.  A tile's size on the pasteboard is the area the artwork may use on the
// paper divided by the scale, so tiling and scaling combine (200% of Letter on Letter is a
// two-by-two poster).

import Foundation
import WTGeometry
import WTRender

/// One tile of a page: its place in the grid and the pasteboard rectangle it prints.
public struct PrintTile: Hashable, Sendable {
    /// 0-based row and column.
    public var row: Int
    public var column: Int
    public var rows: Int
    public var columns: Int
    /// The pasteboard rectangle printed on this tile's sheet.
    public var rect: Rect
    /// Whether it came from *Manual* tiling (no grid, no tile marks).
    public var isManual: Bool

    public init(row: Int, column: Int, rows: Int, columns: Int, rect: Rect, isManual: Bool = false) {
        self.row = row
        self.column = column
        self.rows = rows
        self.columns = columns
        self.rect = rect
        self.isManual = isManual
    }

    /// 1-based position in row-major order.
    public var number: Int { row * columns + column + 1 }
    public var count: Int { rows * columns }

    /// `Tile 2 of 6, row 1 column 2`.
    public var label: String {
        "Tile \(number) of \(count), row \(row + 1) column \(column + 1)"
    }
}

public enum PrintTiling {
    /// The automatic grid over `content` (the page plus bleed, pasteboard) with tiles of
    /// `tileSize` (pasteboard units) sharing `overlap` along each edge, row-major.  An overlap of
    /// half a tile or more is reduced to just under half, so the grid always advances.
    public static func automatic(content: Rect, tileSize: Size, overlap: Double) -> [PrintTile] {
        guard tileSize.width > 0, tileSize.height > 0, !content.isEmpty else { return [] }
        let limit = min(tileSize.width, tileSize.height) / 2
        let overlap = min(max(overlap, 0), limit * 0.999)
        func count(_ extent: Double, _ tile: Double) -> Int {
            guard extent > tile + 1e-9 else { return 1 }
            return Int(((extent - overlap) / (tile - overlap) - 1e-9).rounded(.up))
        }
        let columns = count(content.width, tileSize.width)
        let rows = count(content.height, tileSize.height)
        var tiles: [PrintTile] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let rect = Rect(x: content.minX + Double(column) * (tileSize.width - overlap), y: content.minY + Double(row) * (tileSize.height - overlap),
                                width: tileSize.width, height: tileSize.height)
                tiles.append(PrintTile(row: row, column: column, rows: rows, columns: columns, rect: rect))
            }
        }
        return tiles
    }

    /// The one *Manual* tile: `tileSize` with its top-left corner at `zeroPoint`.
    public static func manual(zeroPoint: Point, tileSize: Size) -> PrintTile {
        PrintTile(row: 0, column: 0, rows: 1, columns: 1, rect: Rect(x: zeroPoint.x, y: zeroPoint.y, width: tileSize.width, height: tileSize.height), isManual: true)
    }
}
