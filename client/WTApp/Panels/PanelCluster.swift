import Foundation

/// One column of a cluster: groups stacked top first, sharing the column's height through
/// dividers (D-077, magnetic panels).
struct PanelColumn: Codable, Equatable, Sendable {
    var groups: [PanelGroup]
    /// Points wide.
    var width: Double

    init(groups: [PanelGroup], width: Double) {
        self.groups = groups
        self.width = width
    }
}

/// Panel groups that move as one (panels.adoc, "Docking and floating"; D-077, revised again): one
/// or more columns side by side, left to right, each a stack of groups.  A cluster is *docked* at
/// the window's left or right edge -- it runs the height of the content area, moves and resizes
/// with the window, and the canvas's safe area leaves it out -- or *floating* at `frame` (screen
/// points, over the canvas or on another display).  Dragging any of its groups moves the whole
/// cluster; Option-dragging one pulls it out into a cluster of its own.
struct PanelCluster: Codable, Equatable, Sendable, Identifiable {
    /// Between two columns: a thin divider (drawn as a hairline) that resizes the column on its left.
    static let columnDividerWidth: Double = 5
    /// The narrowest a column may be.
    static let minimumColumnWidth: Double = 44

    var id: String
    /// `.left` or `.right` when docked; nil when floating.
    var edge: DockEdge?
    var columns: [PanelColumn]
    /// A floating cluster's frame in screen points (origin bottom left); nil when docked.
    var frame: LayoutRect?
    /// The display a floating cluster's frame is on; nil after being moved onto the main display.
    var display: String?

    init(id: String, edge: DockEdge? = nil, columns: [PanelColumn], frame: LayoutRect? = nil, display: String? = nil) {
        self.id = id
        self.edge = edge
        self.columns = columns
        self.frame = frame
        self.display = display
    }

    /// A floating cluster of one group at `frame`.
    static func floating(_ group: PanelGroup, id: String, frame: LayoutRect, display: String? = nil) -> PanelCluster {
        PanelCluster(id: id, columns: [PanelColumn(groups: [group], width: frame.width)], frame: frame, display: display)
    }

    var isDocked: Bool { edge != nil }

    /// Every group, column by column, top first.
    var groups: [PanelGroup] { columns.flatMap(\.groups) }

    /// The columns' widths and the dividers between them.
    var width: Double {
        columns.reduce(0) { $0 + $1.width } + Self.columnDividerWidth * Double(max(0, columns.count - 1))
    }

    /// The column at the window edge (docked right: the last; docked left and floating: the first).
    var edgeColumnIndex: Int { edge == .right ? max(0, columns.count - 1) : 0 }

    /// The column beside the canvas (docked right: the first; docked left: the last).  The dock
    /// handle resizes it.
    var innerColumnIndex: Int { edge == .right ? 0 : max(0, columns.count - 1) }

    /// Where group `id` is: column and index in it.
    func position(of id: PanelGroup.ID) -> (column: Int, index: Int)? {
        for (column, entry) in columns.enumerated() {
            if let index = entry.groups.firstIndex(where: { $0.id == id }) { return (column, index) }
        }
        return nil
    }
}
