import CoreGraphics

/// What a dragged cluster joins when it is released (D-077, magnetic panels).
enum PanelSnapTarget: Equatable, Sendable {
    /// The window's free left or right edge: the cluster docks there.
    case dock(DockEdge)
    /// Beside another cluster: its columns are inserted among that cluster's at `index`.
    case column(cluster: PanelCluster.ID, index: Int)
    /// Above, below or between the groups of one of another cluster's columns: its groups are
    /// inserted there at `index`.
    case stack(cluster: PanelCluster.ID, column: Int, index: Int)
    /// A lone group dropped on another group's title bar or tab strip joins its tabs.
    case merge(group: PanelGroup.ID)
    /// The top or bottom strip, before group `index`.
    case strip(DockEdge, index: Int)
}

/// Where everything a dragged cluster can click to is, in screen points (origin bottom left).
/// Built from the document window and its floating clusters (`PanelSnapScene.make`), or by hand
/// in tests.
struct PanelSnapScene: Equatable, Sendable {
    struct Column: Equatable, Sendable {
        var frame: CGRect
        /// The column's groups, top first.
        var groupFrames: [CGRect]
    }

    struct Cluster: Equatable, Sendable {
        var id: PanelCluster.ID
        /// Docked at a side edge, or nil when floating.
        var edge: DockEdge?
        var frame: CGRect
        var columns: [Column]
    }

    struct Header: Equatable, Sendable {
        var group: PanelGroup.ID
        /// The title bar and tab strip.
        var frame: CGRect
    }

    /// The window's area beside the top strip: its left and right edges are where clusters dock.
    var window: CGRect?
    /// Every other cluster, docked and floating (never the one being dragged).
    var clusters: [Cluster] = []
    /// Every other group's header, for merging a lone group into its tabs.
    var headers: [Header] = []
    /// The top and bottom strips where they show (a hidden strip's edge is the window's).
    var strips: [DockEdge: CGRect] = [:]

    /// The side edges a docked cluster already takes.
    var occupiedEdges: Set<DockEdge> { Set(clusters.compactMap(\.edge)) }
}

/// The outcome of snapping one position of a drag: what the cluster would join, where it is
/// drawn meanwhile (pulled into line with what it clicks to), and the preview to show.
struct PanelSnap: Equatable, Sendable {
    enum Guide: Equatable, Sendable {
        /// A line along the edges that join.
        case line(CGRect)
        /// The area the cluster will take (docking at a window edge).
        case area(CGRect)
        /// A header that lights up (merging into its tabs).
        case header(CGRect)
    }

    var target: PanelSnapTarget?
    var frame: CGRect
    var guide: Guide?
}

/// The magnetic rules (D-077, revised again; panels.adoc, "Docking and floating"): pure geometry,
/// so they are tested without windows.  A dragged cluster at frame `moving` with the pointer at
/// `pointer`:
///
/// 1. A lone group whose pointer is over another group's header merges into its tabs.
/// 2. With the pointer over a docked column, it drops between that column's groups (the dock's
///    insertion line), as dragging into the dock always did.
/// 3. With the pointer over a strip, it joins the end of the strip.
/// 4. Otherwise it clicks to the nearest edge within `threshold` points: a free window side
///    (dock), another cluster's side (a new column beside it; its tops line up when they are
///    close), or the top or bottom of a floating column (it stacks there, lined up with it).
enum PanelSnapping {
    /// How close edges must come to click together.
    static let threshold: CGFloat = 10
    /// How much two edges must overlap along their length to join side by side.
    static let minimumOverlap: CGFloat = 24
    /// The thickness of a preview line.
    static let guideThickness: CGFloat = 4

    static func snap(moving: CGRect, pointer: CGPoint, groupCount: Int, scene: PanelSnapScene, threshold: CGFloat = PanelSnapping.threshold) -> PanelSnap {
        if groupCount == 1, let header = scene.headers.first(where: { $0.frame.contains(pointer) }) {
            return PanelSnap(target: .merge(group: header.group), frame: moving, guide: .header(header.frame))
        }
        for cluster in scene.clusters where cluster.edge != nil {
            for (index, column) in cluster.columns.enumerated() where column.frame.contains(pointer) {
                let at = insertionIndex(forY: pointer.y, groupFrames: column.groupFrames)
                return PanelSnap(target: .stack(cluster: cluster.id, column: index, index: at), frame: moving, guide: .line(insertionLine(at: at, in: column)))
            }
        }
        for (edge, strip) in scene.strips.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where strip.height > 0 && strip.contains(pointer) {
            return PanelSnap(target: .strip(edge, index: .max), frame: moving, guide: .line(CGRect(x: strip.minX, y: strip.midY - guideThickness / 2, width: strip.width, height: guideThickness)))
        }
        var best: (distance: CGFloat, snap: PanelSnap)?
        func offer(_ distance: CGFloat, _ snap: PanelSnap) {
            guard distance <= threshold, best.map({ distance < $0.distance }) ?? true else { return }
            best = (distance, snap)
        }
        if let window = scene.window, overlap(moving.minY, moving.maxY, window.minY, window.maxY) >= minimumOverlap {
            for edge in [DockEdge.left, .right] where !scene.occupiedEdges.contains(edge) {
                let distance = edge == .left ? abs(moving.minX - window.minX) : abs(moving.maxX - window.maxX)
                let x = edge == .left ? window.minX : window.maxX - moving.width
                let area = CGRect(x: x, y: window.minY, width: moving.width, height: window.height)
                offer(distance, PanelSnap(target: .dock(edge), frame: area, guide: .area(area)))
            }
        }
        for cluster in scene.clusters {
            let frame = cluster.frame
            let span = overlap(moving.minY, moving.maxY, frame.minY, frame.maxY)
            if span >= minimumOverlap {
                let low = max(moving.minY, frame.minY), high = min(moving.maxY, frame.maxY)
                // Tops that nearly line up are lined up.
                let y = abs(moving.maxY - frame.maxY) <= threshold ? frame.maxY - moving.height : moving.minY
                if cluster.edge != .right {
                    let placed = CGRect(x: frame.maxX, y: y, width: moving.width, height: moving.height)
                    offer(abs(moving.minX - frame.maxX), PanelSnap(target: .column(cluster: cluster.id, index: cluster.columns.count), frame: placed,
                                                             guide: .line(CGRect(x: frame.maxX - guideThickness / 2, y: low, width: guideThickness, height: high - low))))
                }
                if cluster.edge != .left {
                    let placed = CGRect(x: frame.minX - moving.width, y: y, width: moving.width, height: moving.height)
                    offer(abs(moving.maxX - frame.minX), PanelSnap(target: .column(cluster: cluster.id, index: 0), frame: placed,
                                                             guide: .line(CGRect(x: frame.minX - guideThickness / 2, y: low, width: guideThickness, height: high - low))))
                }
            }
            guard cluster.edge == nil else { continue }
            for (index, column) in cluster.columns.enumerated() {
                let column = column.frame
                guard overlap(moving.minX, moving.maxX, column.minX, column.maxX) >= min(moving.width, column.width) / 2 else { continue }
                let line = { (y: CGFloat) in CGRect(x: column.minX, y: y - guideThickness / 2, width: column.width, height: guideThickness) }
                offer(abs(moving.minY - column.maxY), PanelSnap(target: .stack(cluster: cluster.id, column: index, index: 0),
                                                               frame: CGRect(x: column.minX, y: column.maxY, width: moving.width, height: moving.height), guide: .line(line(column.maxY))))
                let count = cluster.columns[index].groupFrames.count
                offer(abs(moving.maxY - column.minY), PanelSnap(target: .stack(cluster: cluster.id, column: index, index: count),
                                                               frame: CGRect(x: column.minX, y: column.minY - moving.height, width: moving.width, height: moving.height), guide: .line(line(column.minY))))
            }
        }
        return best?.snap ?? PanelSnap(target: nil, frame: moving, guide: nil)
    }

    /// The length two ranges share (negative when apart).
    static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        min(a1, b1) - max(a0, b0)
    }

    /// The group index a drop at `y` lands before: the number of groups whose middle is above
    /// it (screen y points up; the first group is at the top).
    static func insertionIndex(forY y: CGFloat, groupFrames: [CGRect]) -> Int {
        groupFrames.filter { $0.midY > y }.count
    }

    /// The preview line of an insertion before group `index` of `column`.
    static func insertionLine(at index: Int, in column: PanelSnapScene.Column) -> CGRect {
        let y: CGFloat
        if index < column.groupFrames.count {
            y = column.groupFrames[index].maxY
        } else {
            y = column.groupFrames.last?.minY ?? column.frame.maxY
        }
        return CGRect(x: column.frame.minX + 8, y: y - guideThickness / 2, width: max(0, column.frame.width - 16), height: guideThickness)
    }
}
