import CoreGraphics

/// How a toolbar lays out its items (toolbars.adoc, "Showing, hiding, docking"; D-077): decided by
/// where it is hosted, never by its aspect ratio.
enum ToolbarPlacement: Equatable, Sendable {
    /// One row that never wraps: a strip at the top or bottom of the window.
    case row
    /// One item under another: a narrow strip at the left or right edge of the window.
    case column
    /// Rows that wrap at the host's width: a panel group, docked or floating.  Wide controls
    /// (the font family) take a row of their own.
    case flow

    /// A side dock narrower than this is a vertical strip, not a column of panels.
    static let columnDockWidth: Double = 140

    /// The placement of `toolbar`'s panel in `layout`: a row in a top or bottom strip, a column in
    /// a narrow side strip, a flow in a panel group at a side or floating, and a flow when it is
    /// not in the layout at all (hosted by another view).
    static func hosting(_ toolbar: ToolbarID, in layout: PanelLayout) -> ToolbarPlacement {
        guard let group = layout.group(containing: toolbar.panelID), let edge = layout.edge(of: group.id) else { return .flow }
        if !edge.isVertical { return .row }
        let width = layout.dockWidth[edge] ?? PanelLayout.defaultDockWidth[edge] ?? columnDockWidth
        return width < columnDockWidth ? .column : .flow
    }
}

/// Where each of a toolbar's items goes (`ToolbarView` places them; tested without views).
/// Coordinates are flipped: y grows downward from the top edge.
enum ToolbarFlowLayout {
    /// One item: its natural size, the narrowest it may be, and whether it takes a row of its own
    /// when the toolbar flows.
    struct Item: Equatable, Sendable {
        var size: CGSize
        var minimumWidth: CGFloat
        var fullRow: Bool

        init(size: CGSize, minimumWidth: CGFloat? = nil, fullRow: Bool = false) {
            self.size = size
            self.minimumWidth = min(minimumWidth ?? size.width, size.width)
            self.fullRow = fullRow
        }
    }

    struct Result: Equatable, Sendable {
        var frames: [CGRect]
        /// The items of each row, top first (a column has one item per row).
        var rows: [[Int]]
        /// Everything, insets included.
        var size: CGSize
    }

    static let spacing: CGFloat = 4
    static let rowSpacing: CGFloat = 4
    static let insets = (top: CGFloat(4), left: CGFloat(6), bottom: CGFloat(4), right: CGFloat(6))

    /// The frames of `items` in a toolbar `width` wide (ignored by a row and a column).
    static func layout(_ items: [Item], placement: ToolbarPlacement, width: CGFloat) -> Result {
        let available = max(width - insets.left - insets.right, 0)
        var rows: [[Int]] = []
        switch placement {
        case .row:
            rows = items.isEmpty ? [] : [Array(items.indices)]
        case .column:
            rows = items.indices.map { [$0] }
        case .flow:
            var current: [Int] = []
            var used: CGFloat = 0
            for (index, item) in items.enumerated() {
                if item.fullRow {
                    if !current.isEmpty { rows.append(current) }
                    rows.append([index])
                    current = []
                    used = 0
                    continue
                }
                let needed = current.isEmpty ? item.size.width : used + spacing + item.size.width
                if !current.isEmpty && needed > available {
                    rows.append(current)
                    current = [index]
                    used = item.size.width
                } else {
                    current.append(index)
                    used = needed
                }
            }
            if !current.isEmpty { rows.append(current) }
        }
        var frames = Array(repeating: CGRect.zero, count: items.count)
        var y = insets.top
        var widest: CGFloat = 0
        for row in rows {
            let height = row.map { items[$0].size.height }.max() ?? 0
            var x = insets.left
            for index in row {
                let item = items[index]
                var itemWidth = item.size.width
                // A full row stretches to the toolbar's width, never under its minimum.
                if placement == .flow && item.fullRow { itemWidth = max(item.minimumWidth, available) }
                frames[index] = CGRect(x: x, y: y + ((height - item.size.height) / 2).rounded(.down), width: itemWidth, height: item.size.height)
                x += itemWidth + spacing
            }
            widest = max(widest, x - spacing - insets.left)
            y += height + rowSpacing
        }
        let contentHeight = rows.isEmpty ? 0 : y - rowSpacing - insets.top
        let contentWidth = placement == .flow ? max(available, widest) : widest
        return Result(frames: frames, rows: rows,
                      size: CGSize(width: contentWidth + insets.left + insets.right, height: contentHeight + insets.top + insets.bottom))
    }
}
