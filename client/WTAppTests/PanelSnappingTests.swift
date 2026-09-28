import CoreGraphics
import Foundation
import Testing
@testable import WireTuner

/// The magnetic rules (D-077, magnetic panels): what a dragged cluster clicks to, and where it is
/// drawn meanwhile.  Screen points, origin bottom left.
@Suite struct PanelSnappingTests {
    /// A 1200 x 800 window area at the origin with nothing docked.
    private let window = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func scene(clusters: [PanelSnapScene.Cluster] = [], headers: [PanelSnapScene.Header] = [], strips: [DockEdge: CGRect] = [:]) -> PanelSnapScene {
        PanelSnapScene(window: window, clusters: clusters, headers: headers, strips: strips)
    }

    /// A floating one-column cluster at `frame` with groups splitting it evenly.
    private func floating(_ id: String, _ frame: CGRect, groups: Int = 1) -> PanelSnapScene.Cluster {
        let height = frame.height / CGFloat(groups)
        let frames = (0..<groups).map { CGRect(x: frame.minX, y: frame.maxY - height * CGFloat($0 + 1), width: frame.width, height: height) }
        return PanelSnapScene.Cluster(id: id, edge: nil, frame: frame, columns: [PanelSnapScene.Column(frame: frame, groupFrames: frames)])
    }

    @Test func aClusterClicksToAFreeWindowEdgeWithinTheThreshold() {
        let moving = CGRect(x: 1200 - 260 - 9, y: 300, width: 260, height: 300)
        let snap = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: moving.midX, y: moving.maxY - 10), groupCount: 2, scene: scene())
        #expect(snap.target == .dock(.right))
        // It is drawn where it will dock: flush with the edge, the height of the window.
        #expect(snap.frame == CGRect(x: 940, y: 0, width: 260, height: 800))
        #expect(snap.guide == .area(CGRect(x: 940, y: 0, width: 260, height: 800)))

        let left = PanelSnapping.snap(moving: CGRect(x: 10, y: 300, width: 84, height: 300), pointer: CGPoint(x: 40, y: 590), groupCount: 1, scene: scene())
        #expect(left.target == .dock(.left) && left.frame.minX == 0)
    }

    @Test func farFromEveryEdgeItFloatsWhereItIs() {
        let moving = CGRect(x: 1200 - 260 - 11, y: 300, width: 260, height: 300)
        let snap = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: moving.midX, y: moving.maxY - 10), groupCount: 1, scene: scene())
        #expect(snap.target == nil && snap.frame == moving && snap.guide == nil)
        // Beyond the threshold by a hair; a custom threshold widens it.
        let wide = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: moving.midX, y: moving.maxY - 10), groupCount: 1, scene: scene(), threshold: 12)
        #expect(wide.target == .dock(.right))
        // Off the window's height it does not dock.
        let below = CGRect(x: 1200 - 260, y: -400, width: 260, height: 300)
        #expect(PanelSnapping.snap(moving: below, pointer: CGPoint(x: 1000, y: -200), groupCount: 1, scene: scene()).target == nil)
    }

    @Test func aTakenEdgeOffersTheDockedClustersInnerSideInstead() {
        let docked = PanelSnapScene.Cluster(id: "right", edge: .right, frame: CGRect(x: 920, y: 0, width: 280, height: 800),
                                            columns: [PanelSnapScene.Column(frame: CGRect(x: 920, y: 0, width: 280, height: 800),
                                                                            groupFrames: [CGRect(x: 920, y: 400, width: 280, height: 400), CGRect(x: 920, y: 0, width: 280, height: 400)])])
        let moving = CGRect(x: 920 - 260 + 6, y: 200, width: 260, height: 300)
        let snap = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 700, y: 480), groupCount: 1, scene: scene(clusters: [docked]))
        #expect(snap.target == .column(cluster: "right", index: 0), "beside it, on the canvas side")
        #expect(snap.frame.maxX == 920 && snap.frame.minY == 200)
        if case let .line(line)? = snap.guide { #expect(abs(line.midX - 920) < 0.01 && line.minY == 200 && line.maxY == 500) } else { Issue.record("a line") }
        // Never outside the window edge it is docked at.
        let outside = CGRect(x: 1200 + 4, y: 200, width: 260, height: 300)
        #expect(PanelSnapping.snap(moving: outside, pointer: CGPoint(x: 1300, y: 480), groupCount: 1, scene: scene(clusters: [docked])).target == nil)
        // The window edge itself is not offered while taken.
        #expect(!PanelSnapScene(window: window, clusters: [docked]).occupiedEdges.isDisjoint(with: [.right]))
    }

    @Test func overADockedColumnItDropsBetweenGroups() {
        let column = PanelSnapScene.Column(frame: CGRect(x: 920, y: 0, width: 280, height: 800),
                                           groupFrames: [CGRect(x: 920, y: 400, width: 280, height: 400), CGRect(x: 920, y: 0, width: 280, height: 400)])
        let docked = PanelSnapScene.Cluster(id: "right", edge: .right, frame: column.frame, columns: [column])
        let moving = CGRect(x: 900, y: 100, width: 260, height: 300)
        let middle = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 1000, y: 500), groupCount: 2, scene: scene(clusters: [docked]))
        #expect(middle.target == .stack(cluster: "right", column: 0, index: 1))
        if case let .line(line)? = middle.guide { #expect(abs(line.midY - 400) < 0.01) } else { Issue.record("an insertion line") }
        #expect(middle.frame == moving, "it is not pulled into line: the line shows where it lands")
        let top = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 1000, y: 790), groupCount: 2, scene: scene(clusters: [docked]))
        #expect(top.target == .stack(cluster: "right", column: 0, index: 0))
        let bottom = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 1000, y: 10), groupCount: 2, scene: scene(clusters: [docked]))
        #expect(bottom.target == .stack(cluster: "right", column: 0, index: 2))
        if case let .line(line)? = bottom.guide { #expect(abs(line.midY) < 0.01) } else { Issue.record("an insertion line") }
        #expect(PanelSnapping.insertionLine(at: 0, in: PanelSnapScene.Column(frame: CGRect(x: 0, y: 0, width: 100, height: 50), groupFrames: [])).midY == 50)
    }

    @Test func clustersClickSideBySideAndLineUpTheirTops() {
        let other = floating("a", CGRect(x: 300, y: 200, width: 260, height: 400))
        // Its left edge 8 points from the other's right edge, tops 6 points apart.
        let moving = CGRect(x: 568, y: 306, width: 200, height: 300)
        let snap = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 600, y: 590), groupCount: 1, scene: scene(clusters: [other]))
        #expect(snap.target == .column(cluster: "a", index: 1))
        #expect(snap.frame == CGRect(x: 560, y: 300, width: 200, height: 300), "flush beside it, tops lined up")
        // On its left.
        let leftSide = CGRect(x: 300 - 200 - 5, y: 100, width: 200, height: 300)
        let left = PanelSnapping.snap(moving: leftSide, pointer: CGPoint(x: 150, y: 390), groupCount: 1, scene: scene(clusters: [other]))
        #expect(left.target == .column(cluster: "a", index: 0) && left.frame.maxX == 300 && left.frame.minY == 100)
        // Side by side needs some shared height.
        let barely = CGRect(x: 568, y: 600 - 10, width: 200, height: 300)
        #expect(PanelSnapping.snap(moving: barely, pointer: CGPoint(x: 600, y: 880), groupCount: 1, scene: scene(clusters: [other])).target == nil)
    }

    @Test func clustersStackAboveAndBelowAFloatingColumn() {
        let other = floating("a", CGRect(x: 300, y: 200, width: 260, height: 400), groups: 2)
        // Its bottom 7 points above the column's top, mostly over it.
        let above = CGRect(x: 320, y: 607, width: 240, height: 200)
        let snapAbove = PanelSnapping.snap(moving: above, pointer: CGPoint(x: 400, y: 790), groupCount: 1, scene: scene(clusters: [other]))
        #expect(snapAbove.target == .stack(cluster: "a", column: 0, index: 0))
        #expect(snapAbove.frame == CGRect(x: 300, y: 600, width: 240, height: 200), "lined up with the column")
        if case let .line(line)? = snapAbove.guide { #expect(abs(line.midY - 600) < 0.01 && line.width == 260) } else { Issue.record("a line") }
        // Its top 9 points under the column's bottom.
        let below = CGRect(x: 290, y: 200 - 9 - 150, width: 260, height: 150)
        let snapBelow = PanelSnapping.snap(moving: below, pointer: CGPoint(x: 400, y: 180), groupCount: 1, scene: scene(clusters: [other]))
        #expect(snapBelow.target == .stack(cluster: "a", column: 0, index: 2))
        #expect(snapBelow.frame.maxY == 200 && snapBelow.frame.minX == 300)
        // Hardly over it horizontally: no stacking.
        let aside = CGRect(x: 520, y: 605, width: 240, height: 200)
        #expect(PanelSnapping.snap(moving: aside, pointer: CGPoint(x: 700, y: 790), groupCount: 1, scene: scene(clusters: [other])).target == nil)
    }

    @Test func theNearestEdgeWins() {
        let a = floating("a", CGRect(x: 300, y: 200, width: 260, height: 400))
        let b = floating("b", CGRect(x: 766, y: 200, width: 260, height: 400))
        // 3 points from b's left edge, 8 from a's right edge.
        let moving = CGRect(x: 568, y: 250, width: 195, height: 300)
        #expect(PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 600, y: 540), groupCount: 1, scene: scene(clusters: [a, b])).target == .column(cluster: "b", index: 0))
    }

    @Test func aLoneGroupOverAHeaderMergesIntoItsTabs() {
        let header = PanelSnapScene.Header(group: "layers", frame: CGRect(x: 300, y: 560, width: 260, height: 60))
        let moving = CGRect(x: 280, y: 300, width: 260, height: 300)
        let snap = PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 400, y: 590), groupCount: 1, scene: scene(headers: [header]))
        #expect(snap.target == .merge(group: "layers") && snap.guide == .header(header.frame) && snap.frame == moving)
        // A cluster of several groups does not merge.
        #expect(PanelSnapping.snap(moving: moving, pointer: CGPoint(x: 400, y: 590), groupCount: 2, scene: scene(headers: [header])).target == nil)
    }

    @Test func overAStripItJoinsTheStrip() {
        let strip = CGRect(x: 0, y: 800, width: 1200, height: 44)
        let snap = PanelSnapping.snap(moving: CGRect(x: 400, y: 600, width: 260, height: 230), pointer: CGPoint(x: 500, y: 820), groupCount: 1, scene: scene(strips: [.top: strip]))
        #expect(snap.target == .strip(.top, index: .max))
        // A hidden (empty) strip is not a target.
        #expect(PanelSnapping.snap(moving: CGRect(x: 400, y: 300, width: 260, height: 230), pointer: CGPoint(x: 500, y: 500), groupCount: 1,
                                   scene: scene(strips: [.top: CGRect(x: 0, y: 800, width: 1200, height: 0)])).target == nil)
    }

    @Test func withoutAWindowOnlyOtherClustersCount() {
        let other = floating("a", CGRect(x: 300, y: 200, width: 260, height: 400))
        let scene = PanelSnapScene(window: nil, clusters: [other])
        #expect(PanelSnapping.snap(moving: CGRect(x: 565, y: 200, width: 200, height: 300), pointer: CGPoint(x: 600, y: 480), groupCount: 1, scene: scene).target == .column(cluster: "a", index: 1))
        #expect(PanelSnapping.overlap(0, 10, 20, 30) < 0)
    }
}
