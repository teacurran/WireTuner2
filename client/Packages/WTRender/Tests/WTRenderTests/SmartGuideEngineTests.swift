import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// OBJ-038 "Done when": edge, centre, spacing and size guides; the smart-guide snap kind between
/// ruler guides and the grid; the candidate set's exclusions and cap; the 0.2 ms query budget.
@Suite struct SmartGuideEngineTests {
    static func node(_ n: UInt64) -> NodeID { NodeID(counter: n, replica: 1) }

    static func engine(_ rects: [Rect], pages: [Rect] = []) -> SmartGuideEngine {
        SmartGuideEngine(candidates: rects.enumerated().map { .init(node: node(UInt64($0.offset + 1)), bounds: $0.element) }
            + pages.map { .init(node: nil, bounds: $0, isPage: true) })
    }

    // MARK: Edge and centre

    @Test func leftEdgeNearARightEdgeYieldsAnEdgeGuideSpanningBoth() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 20, height: 20)])
        // Left edge 1.5 from the candidate's right edge (20), well above it.
        let match = engine.guides(moving: Rect(x: 21.5, y: 40, width: 10, height: 10), tolerance: 3)
        #expect(match.snapsX && !match.snapsY)
        #expect(match.offset == Vector(dx: -1.5, dy: 0))
        let edge = match.guides.first { $0.kind == .edge && $0.axis == .vertical }
        #expect(edge?.position == 20)
        #expect(edge?.span == 0...50)
        #expect(edge?.nodes == [Self.node(1)])
        #expect(edge?.value == nil && edge?.gaps == [])
        // The snap line sits where the grab point lands once aligned.
        #expect(match.snapGuides(for: Point(x: 25, y: 45)) == [.vertical(x: 23.5)])
        #expect(match.snapCandidates(for: Point(x: 25, y: 45)) == [.smartGuide(.vertical(x: 23.5))])
        // Out of reach: nothing.
        let far = engine.guides(moving: Rect(x: 30, y: 40, width: 10, height: 10), tolerance: 3)
        #expect(far == SmartGuideMatch())
        #expect(far.snapGuides(for: .zero).isEmpty)
    }

    @Test func centredObjectsYieldACentreGuide() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 40, height: 10)])
        let match = engine.guides(moving: Rect(x: 11, y: 30, width: 20, height: 10), tolerance: 2)
        #expect(match.offset.dx == -1)
        let centre = match.guides.first { $0.kind == .center && $0.axis == .vertical }
        #expect(centre?.position == 20)
        #expect(centre?.nodes == [Self.node(1)])
        // A horizontal edge alignment on the other axis too: tops line up.
        let tops = engine.guides(moving: Rect(x: 60, y: 1, width: 5, height: 6), tolerance: 2)
        #expect(tops.snapsY && tops.offset.dy == -1 && !tops.snapsX)
        #expect(tops.guides.map(\.position) == [0])
        #expect(tops.snapGuides(for: Point(x: 60, y: 5)) == [.horizontal(y: 4)])
    }

    @Test func pagesCountForEdgesAndCentresButNotSpacingOrSize() {
        let engine = Self.engine([], pages: [Rect(x: 0, y: 0, width: 612, height: 792)])
        let match = engine.guides(moving: Rect(x: 296, y: 100, width: 20, height: 20), tolerance: 1)
        #expect(match.guides.contains { $0.kind == .center && $0.position == 306 && $0.nodes.isEmpty })
        #expect(engine.sizeGuides(width: 612, height: 792, tolerance: 1) == SmartGuideSizeMatch())
    }

    @Test func theNearestAlignmentWinsOnEachAxis() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 100, y: 0, width: 13, height: 10)])
        // Left edge 2 from 10, right edge 1 from 113 (width 102).
        let match = engine.guides(moving: Rect(x: 12, y: 50, width: 102, height: 4), tolerance: 3)
        #expect(match.offset.dx == -1)
        #expect(match.guides.contains { $0.position == 113 })
        #expect(engine.guides(moving: .null, tolerance: 3) == SmartGuideMatch())
        #expect(engine.guides(moving: Rect(x: 0, y: 0, width: 1, height: 1), tolerance: -1) == SmartGuideMatch())
    }

    @Test func zeroWidthBoundsProbeOneEdge() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 10, height: 10)])
        let match = engine.guides(moving: Rect(x: 10.5, y: 30, width: 0, height: 5), tolerance: 1)
        #expect(match.guides.filter { $0.axis == .vertical && $0.kind == .edge }.count == 1)
    }

    // MARK: Equal spacing

    @Test func threeEquallySpacedRectanglesYieldSpacingOnTheirAxisOnly() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10), b = Rect(x: 20, y: 0, width: 10, height: 10)
        let engine = Self.engine([a, b])
        // The third, nearly 10 after b: snaps to 40.
        let match = engine.guides(moving: Rect(x: 41, y: 0, width: 10, height: 10), tolerance: 2)
        #expect(match.offset.dx == -1)
        let spacing = match.guides.filter { $0.kind == .spacing }
        #expect(spacing.count == 1)
        #expect(spacing.allSatisfy { $0.axis == .vertical })
        #expect(spacing[0].position == 40 && spacing[0].value == 10)
        #expect(spacing[0].gaps == [10...20, 30...40])
        #expect(spacing[0].nodes == [Self.node(1), Self.node(2)])
        #expect(spacing[0].span == 0...10)
        // Before the row: its mirror.
        let before = engine.guides(moving: Rect(x: -21, y: 0, width: 10, height: 10), tolerance: 2)
        let mirrored = before.guides.first { $0.kind == .spacing }
        #expect(before.offset.dx == 1 && mirrored?.position == -10 && mirrored?.gaps == [-10...0, 10...20])
        // Vertical rows space on y only.
        let column = Self.engine([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 0, y: 30, width: 10, height: 10)])
        let down = column.guides(moving: Rect(x: 50, y: 61, width: 10, height: 10), tolerance: 2)
        #expect(down.guides.filter { $0.kind == .spacing }.isEmpty)   // not in the column's row
        let inColumn = column.guides(moving: Rect(x: 2, y: 61, width: 6, height: 10), tolerance: 2)
        #expect(inColumn.guides.filter { $0.kind == .spacing }.map(\.axis) == [.horizontal])
    }

    @Test func centredBetweenTwoNeighbours() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 50, y: 0, width: 10, height: 10)])
        let match = engine.guides(moving: Rect(x: 26, y: 3, width: 10, height: 4), tolerance: 1.5)
        let spacing = match.guides.first { $0.kind == .spacing }
        #expect(match.offset.dx == -1)
        #expect(spacing?.value == 15 && spacing?.gaps == [10...25, 35...50] && spacing?.span == 3...7)
        // Too wide to fit: no hint.
        #expect(engine.guides(moving: Rect(x: 5, y: 0, width: 50, height: 10), tolerance: 2).guides.allSatisfy { $0.kind != .spacing })
    }

    @Test func spacingBandFallsBackToTheMovingObject() {
        // a and b overlap m on y, but not one another's band with m: the drawn band is m's.
        let engine = Self.engine([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 8, width: 10, height: 10)])
        let match = engine.guides(moving: Rect(x: 40, y: 16, width: 10, height: 10), tolerance: 1)
        #expect(match.guides.first { $0.kind == .spacing }?.span == 16...26)
    }

    // MARK: Size match

    @Test func sizeMatchesNearbyWidthsAndHeights() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 30, height: 12), Rect(x: 100, y: 0, width: 30, height: 50)])
        let match = engine.sizeGuides(width: 31, height: 40, tolerance: 2)
        #expect(match.width == 30 && match.height == nil)
        #expect(match.guides == [SmartGuide(axis: .vertical, position: 30, span: 30...30, kind: .size, nodes: [Self.node(1), Self.node(2)], value: 30)])
        let tall = engine.sizeGuides(width: .nan, height: 49, tolerance: 2)
        #expect(tall.width == nil && tall.height == 50 && tall.guides.map(\.axis) == [.horizontal])
        #expect(Self.engine([]).sizeGuides(width: 1, height: 1, tolerance: 1) == SmartGuideSizeMatch())
    }

    // MARK: Candidates

    static func list(_ rects: [Rect], layers: [LayerSpan] = []) -> DisplayList {
        DisplayList(canvas: "c", items: rects.map { .fill(FillItem(path: DisplayPath(rect: $0), paint: .solid(.black))) },
                    nodeIDs: rects.indices.map { node(UInt64($0 + 1)) }, layers: layers)
    }

    @Test func candidatesLeaveOutTheGestureHiddenLayersGuidesAndWhatIsOutOfView() {
        let rects = (0..<6).map { Rect(x: Double($0) * 20, y: 0, width: 10, height: 10) }
        let hidden = LayerRendering(id: Self.node(90))
        let guides = LayerRendering(id: Self.node(91), isGuides: true)
        let visible = LayerRendering(id: Self.node(92))
        let list = Self.list(rects, layers: [LayerSpan(layer: visible, range: 0..<3), LayerSpan(layer: hidden, range: 3..<4),
                                             LayerSpan(layer: guides, range: 4..<5)])
        let viewport = Rect(x: -5, y: -5, width: 200, height: 20)
        let engine = SmartGuideEngine(displayList: list, viewport: viewport, excludedItems: [1], excludedNodes: [Self.node(3)],
                                      hiddenLayers: [Self.node(90)], pages: [Rect(x: 0, y: 0, width: 50, height: 50), Rect(x: 900, y: 0, width: 5, height: 5)],
                                      start: .zero)
        #expect(engine.candidates.compactMap(\.node) == [Self.node(1), Self.node(6)])
        #expect(engine.candidates.filter(\.isPage).map(\.bounds) == [Rect(x: 0, y: 0, width: 50, height: 50)])
        // Through the hit tester's index, the same set; out of view is out.
        let indexed = SmartGuideEngine(displayList: list, index: HitTester.makeIndex(list), viewport: Rect(x: 45, y: -5, width: 100, height: 20),
                                       hiddenLayers: [Self.node(90)], start: .zero)
        #expect(indexed.candidates.compactMap(\.node) == [Self.node(3), Self.node(6)])
        // Items with no node or no bounds, and non-finite candidates.
        let bare = DisplayList(canvas: "c", items: [.fill(FillItem(path: DisplayPath(rect: rects[0]), paint: .solid(.black))),
                                                    .fill(FillItem(path: DisplayPath(), paint: .solid(.black)))])
        #expect(SmartGuideEngine(displayList: bare, viewport: viewport, start: .zero).candidates.map(\.node) == [nil])
        #expect(SmartGuideEngine(candidates: [.init(node: nil, bounds: .null), .init(node: nil, bounds: Rect(minX: 0, minY: 0, maxX: .infinity, maxY: 1))])
            .candidates.isEmpty)
    }

    @Test func candidatesAreCappedToTheNearestToTheStart() {
        let rects = (0..<20).map { Rect(x: Double($0) * 20, y: 0, width: 10, height: 10) }
        let engine = SmartGuideEngine(displayList: Self.list(rects), viewport: Rect(x: -10, y: -10, width: 1_000, height: 30),
                                      start: Point(x: 205, y: 5), cap: 3)
        #expect(Set(engine.candidates.compactMap(\.node)) == [Self.node(10), Self.node(11), Self.node(12)])
        #expect(SmartGuideEngine(displayList: Self.list(rects), viewport: Rect(x: -10, y: -10, width: 1_000, height: 30), start: .zero, cap: -1)
            .candidates.isEmpty)
        #expect(SmartGuideEngine.candidateCap == 500)
        #expect(SmartGuideEngine.distance(from: Point(x: 3, y: 4), to: Rect(x: 6, y: 8, width: 1, height: 1)) == 5)
    }

    // MARK: Snap priority (GEO-005 with the smart-guide kind)

    static func candidate(of kind: SnapKind) -> SnapCandidate {
        switch kind {
        case .point: return .point(Point(x: 0.5, y: 0))
        case .path: return .segment(CubicBezier(Point(x: 0.7, y: -5), Point(x: 0.7, y: -2), Point(x: 0.7, y: 2), Point(x: 0.7, y: 5)))
        case .guide: return .guide(.vertical(x: 0.9))
        case .smartGuide: return .smartGuide(.vertical(x: 0.3))
        case .grid: return .grid(SnapGrid(origin: Point(x: 0.1, y: 0), size: 100))
        }
    }

    @Test(arguments: SnapKind.allCases)
    func smartGuidesRankBetweenGuidesAndTheGrid(_ other: SnapKind) {
        let snapper = Snapper(snapDistance: 3)
        for candidates in [[Self.candidate(of: .smartGuide), Self.candidate(of: other)], [Self.candidate(of: other), Self.candidate(of: .smartGuide)]] {
            let winner = snapper.resolve(Point(x: 0, y: 0), candidates: candidates)?.kind
            #expect(winner == min(other, .smartGuide))
        }
    }

    @Test func aMatchFeedsTheSnapEngineThroughSnapSources() {
        let engine = Self.engine([Rect(x: 0, y: 0, width: 20, height: 20)])
        let grab = Point(x: 25, y: 45)
        let match = engine.guides(moving: Rect(x: 21.5, y: 40, width: 10, height: 10), tolerance: 3)
        let sources = SnapSources(smartGuides: match.snapGuides(for: grab))
        let result = SnapEngine(toggles: SnapToggles(guides: false, points: false, objects: false)).resolve(grab, sources: sources)
        #expect(result?.kind == .smartGuide && result?.point == Point(x: 23.5, y: 45))
        #expect(SnapFeedback(result!) == .smartGuide(.vertical(x: 23.5)))
        #expect(SnapEngine(toggles: SnapToggles(smartGuides: false)).resolve(grab, sources: sources) == nil)
    }

    // MARK: Budget

    /// 50,000 objects on a grid; the viewport shows about 500 of them.  A move query answers in
    /// under 0.2 ms (a `PerfBudget`, held in the perf run on an idle machine).
    @Test func designPointQueryIsUnderTheBudget() {
        let list = HitTestPerformanceTests.designPoint()
        let tester = HitTester(displayList: list, viewport: Viewport(size: Size(width: 100, height: 100)))
        let viewport = Rect(x: 0, y: 0, width: 268, height: 268)
        let dragged: Set<Int> = [0]
        let engine = SmartGuideEngine(displayList: list, index: tester.index, viewport: viewport, excludedItems: dragged, start: Point(x: 130, y: 130))
        #expect(engine.candidates.count == SmartGuideEngine.candidateCap)
        #expect(!engine.candidates.contains { $0.node != nil })
        var rng = SplitMix64(seed: 7)
        var timings: [Double] = []
        var guided = 0
        for _ in 0..<500 {
            let origin = Point(x: Double.random(in: 20..<240, using: &rng), y: Double.random(in: 20..<240, using: &rng))
            let start = DispatchTime.now().uptimeNanoseconds
            let match = engine.guides(moving: Rect(x: origin.x, y: origin.y, width: 8, height: 8), tolerance: 1.5)
            timings.append(HitTestPerformanceTests.milliseconds(since: start))
            guided += match.guides.isEmpty ? 0 : 1
        }
        timings.sort()
        let median = timings[timings.count / 2]
        print("PERF smart guides, 500 of 50,000 candidates (\(PerfBudget.buildName)): median \(String(format: "%.4f", median)) ms; budget 0.2 ms")
        #expect(guided > 400)
        PerfBudget.expect(.microseconds(Int(median * 1000)), within: .microseconds(200), "median of 500 move queries")
    }
}
