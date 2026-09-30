import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// LIB-010 and LIB-026: instances through cached symbol sub-lists, overrides, placeholders.
@Suite struct SymbolRenderingTests {
    typealias F = FeatureCorpus

    static func instance(_ symbol: NodeID?, x: Double = 0, y: Double = 0, overrides: [InstanceOverride] = []) -> SymbolInstance {
        SymbolInstance(symbol: symbol, transform: .translation(x: x, y: y), overrides: overrides)
    }

    @Test func instancesPlaceTheOriginAtTheirTranslation() throws {
        let renderer = SymbolRenderer(typesetter: F.labels)
        let item = renderer.item(for: Self.instance(F.id(100), x: 50, y: 40), in: F.library)
        // The star's origin (10, 10) is its centre: the instance's bounds centre on (50, 40).
        let bounds = try #require(item.ownBounds)
        let star = try #require(F.starPath(center: Point(x: 10, y: 10), radius: 10).controlBounds)
        #expect(approx(bounds, star.applying(.translation(x: 40, y: 30)), tolerance: 1e-9))
        guard case .group(let group) = item else {
            Issue.record("an instance is a group")
            return
        }
        #expect(group.atomic)
    }

    /// A thousand instances of one symbol cost one build; overrides build their own sub-list,
    /// shared by instances with equal overrides.
    @Test func instancesShareOneBuildPerSymbolAndOverrides() {
        let renderer = SymbolRenderer(typesetter: F.labels)
        for index in 0..<1000 {
            _ = renderer.item(for: Self.instance(F.id(100), x: Double(index), y: 0), in: F.library)
        }
        #expect(renderer.buildCount == 1)
        for index in 0..<100 {
            _ = renderer.item(for: Self.instance(F.id(100), x: Double(index), overrides: [.fill(F.id(101), F.blue)]), in: F.library)
        }
        #expect(renderer.buildCount == 2)
        _ = renderer.item(for: Self.instance(F.id(100), overrides: [.hidden(F.id(103))]), in: F.library)
        #expect(renderer.buildCount == 3)
        // A new symbol version rebuilds; the hosts of a nested symbol see its version too.
        var edited = F.star
        edited.version = 2
        let library = SymbolLibrary([edited, F.badge])
        _ = renderer.item(for: Self.instance(F.id(100)), in: library)
        #expect(renderer.buildCount == 4)
        #expect(library.closureVersions[F.id(110)] != F.library.closureVersions[F.id(110)])
        #expect(library.closureVersions[F.id(100)] != F.library.closureVersions[F.id(100)])
    }

    @Test func overridesApplyToTheirNodesOnly() throws {
        let renderer = SymbolRenderer(typesetter: F.labels)
        let items = renderer.artworkItems(F.badge, overrides: [.fill(F.id(111), F.blue), .stroke(F.id(111), F.red), .image(F.id(113), assetID: "swapped")], in: F.library)
        guard case .path(let frame) = items[0], case .image(let image) = items[2] else {
            Issue.record("the badge's frame and image")
            return
        }
        #expect(frame.appearance.fills.first?.paint == .solid(F.blue))
        #expect(frame.appearance.strokes.first?.paint == .solid(F.red))
        #expect(image.assetID == "swapped")
        // The nested star is untouched by an override of its own node id: overrides reach one
        // level.
        let nested = renderer.artworkItems(F.badge, overrides: [.hidden(F.id(101))], in: F.library)
        #expect(nested.count == 4)
        // Hidden subtree inside a group; text replaced.
        let star = renderer.artworkItems(F.star, overrides: [.hidden(F.id(103))], in: F.library)
        guard case .group(let group) = star[1] else {
            Issue.record("the star's group")
            return
        }
        #expect(group.children.isEmpty)
        let replaced = renderer.artworkItems(F.badge, overrides: [.text(F.id(114), [])], in: F.library)
        #expect(replaced.count == 3)
        let hiddenGroup = renderer.artworkItems(F.star, overrides: [.hidden(F.id(102))], in: F.library)
        #expect(hiddenGroup.count == 1)
    }

    /// Every text run in `item` with its pasteboard baseline origin, depth first.
    static func runs(_ item: DisplayItem) -> [(text: String, origin: Point)] {
        switch item {
        case .text(let run): [(run.text, run.transform.apply(run.origin))]
        case .group(let group): group.children.flatMap { runs($0) }
        default: []
        }
    }

    /// A text override's laid-out runs replace the master's words, placed through the instance's
    /// transform like the rest of the artwork (LIB-025/026); instances with the same override
    /// text share a build, a different text builds its own.
    @Test func textOverridesPlaceTheLaidOutRunsInsteadOfTheMastersWords() throws {
        let renderer = SymbolRenderer(typesetter: F.labels)
        let transform = AffineTransform.rotation(degrees: 30).concatenating(.translation(x: 40, y: 10))
        let plain = renderer.item(for: SymbolInstance(symbol: F.id(120), transform: transform), in: F.textLibrary)
        #expect(Self.runs(plain).map(\.text) == ["Buy", " now"])
        let item = renderer.item(for: SymbolInstance(symbol: F.id(120), transform: transform, overrides: [.text(F.id(122), F.cardText)]), in: F.textLibrary)
        let runs = Self.runs(item)
        #expect(runs.map(\.text) == ["Sale", " ends", "today"])
        let placement = AffineTransform.translation(x: -22, y: -14).concatenating(transform)
        let expected = [Point(x: 4, y: 11), Point(x: 22, y: 11), Point(x: 4, y: 21)].map { placement.apply($0) }
        for (run, point) in zip(runs, expected) {
            #expect(abs(run.origin.x - point.x) < 1e-9 && abs(run.origin.y - point.y) < 1e-9)
        }
        #expect(renderer.buildCount == 2)
        _ = renderer.item(for: SymbolInstance(symbol: F.id(120), transform: .identity, overrides: [.text(F.id(122), F.cardText)]), in: F.textLibrary)
        #expect(renderer.buildCount == 2, "the same override text shares the sub-list")
        _ = renderer.item(for: SymbolInstance(symbol: F.id(120), overrides: [.text(F.id(122), [F.run("Other", F.regular, at: Point(x: 4, y: 11), .black)])]), in: F.textLibrary)
        #expect(renderer.buildCount == 3)
        // A nested instance draws its own text override inside its host.
        let host = renderer.item(for: SymbolInstance(symbol: F.id(130)), in: F.textLibrary)
        #expect(Self.runs(host).map(\.text) == ["Sale", " ends", "today"])
    }

    @Test func recolouringReachesTextAndGroupsButNotOtherPaints() {
        let gradient = Paint.gradient(Gradient(from: .black, to: .white))
        let item = DisplayItem.group(GroupItem(children: [
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black))),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: gradient)),
            .text(TextRunItem(text: "a", origin: .zero, bounds: Rect(x: 0, y: 0, width: 1, height: 1))),
            .image(ImageItem(assetID: "i", rect: Rect(x: 0, y: 0, width: 1, height: 1))),
        ]))
        guard case .group(let recolored) = item.recolored(fill: F.red, stroke: F.blue) else { return }
        #expect(recolored.children[0] == .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(F.red))))
        #expect(recolored.children[1] == item.recolored(fill: nil, stroke: nil).groupChildren[1])
        guard case .text(let text) = recolored.children[2] else { return }
        #expect(text.color == F.red)
        guard case .text(let unchanged) = item.recolored(fill: nil, stroke: F.blue).groupChildren[2] else { return }
        #expect(unchanged.color == .black)
        #expect(item.replacingImage(with: "x").groupChildren[3] == .image(ImageItem(assetID: "x", rect: Rect(x: 0, y: 0, width: 1, height: 1))))
        #expect(item.replacingImage(with: "x").groupChildren[0] == item.groupChildren[0])
        let strokeItem = DisplayItem.stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.black)))
        #expect(strokeItem.recolored(fill: nil, stroke: F.blue) == .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(F.blue))))
    }

    @Test func missingSymbolsAndCyclesDrawThePlaceholder() throws {
        let renderer = SymbolRenderer(typesetter: F.labels)
        let missing = renderer.item(for: SymbolInstance(symbol: nil, transform: .translation(x: 36, y: 36), placeholderName: "Lost"), in: F.library)
        #expect(missing.ownBounds.map { approx($0, Rect(x: 0, y: 0, width: 72, height: 72), tolerance: 1e-9) } == true)
        guard case .group(let group) = missing else { return }
        #expect(group.atomic)
        #expect(group.children.contains { if case .text = $0 { return true } else { return false } }, "labelled with the name")
        // A symbol holding an instance of itself: the inner one is cut.
        let loop = SymbolArtwork(symbol: F.id(120), name: "Loop", version: 1, nodes: [
            SymbolNode(id: F.id(121), content: .item(ReferenceCorpus.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 10)), [ReferenceCorpus.fill(.black)]))),
            SymbolNode(id: F.id(122), content: .instance(SymbolInstance(symbol: F.id(120), transform: .translation(x: 20, y: 0), placeholderRect: Rect(x: 0, y: 0, width: 10, height: 10)))),
        ])
        let library = SymbolLibrary([loop])
        let item = renderer.item(for: SymbolInstance(symbol: F.id(120)), in: library)
        guard case .group(let outer) = item, case .group(let inner) = outer.children[1] else {
            Issue.record("the cut instance is a placeholder group")
            return
        }
        #expect(inner.atomic)
        #expect(outer.children.count == 2)
        let named = renderer.item(for: SymbolInstance(symbol: F.id(100)), in: SymbolLibrary([]))
        #expect(named.ownBounds != nil)
    }

    /// Hit testing treats an instance as one object, even with Subselect.
    @Test func instancesHitAsOneObject() {
        let list = FeatureCorpus.instances
        let viewport = Viewport(size: ReferenceCorpus.viewSize)
        let subselect = HitTester(displayList: list, viewport: viewport, options: HitOptions(subselect: true))
        let hits = subselect.hitTest(viewPoint: Point(x: 16, y: 16))
        #expect(hits.map(\.itemPath) == [[0]])
        let plain = HitTester(displayList: list, viewport: viewport)
        #expect(plain.hitTest(viewPoint: Point(x: 16, y: 16)).map(\.itemPath) == [[0]])
        let marquee = subselect.hitTest(marquee: Rect(x: 0, y: 0, width: 40, height: 40))
        #expect(marquee.map(\.itemPath) == [[0]])
        #expect(marquee.first?.anchors.isEmpty == true)
        #expect(subselect.hitTest(marquee: Rect(x: 0, y: 0, width: 40, height: 40), contactSensitive: true).map(\.itemPath).contains([0]))
        #expect(subselect.hitTest(marquee: Rect(x: 0, y: 0, width: 12, height: 12)).isEmpty, "a partly enclosed instance is not selected")
        #expect(plain.hitTest(marquee: Rect(x: 0, y: 0, width: 40, height: 40)).first?.anchors.isEmpty == true)
        #expect(subselect.atomicPrefix([99, 1]) == [99, 1])
    }

    /// Editing a point in a symbol repaints only its instances; editing an override repaints
    /// only that instance.
    @Test func symbolEditsRepaintEveryInstanceAndOverridesOnlyTheirOwn() {
        var index = DependencyIndex()
        F.library.addDependencies(of: F.id(1000), on: F.id(100), to: &index)
        F.library.addDependencies(of: F.id(1001), on: F.id(110), to: &index)
        F.library.addDependencies(of: F.id(1002), on: F.id(199), to: &index)
        var summary = ChangeSummary(origin: .remote)
        summary.touch(F.id(103))
        let expanded = summary.touchingDependents(in: index)
        #expect(expanded.touchedNodes.isSuperset(of: [F.id(1000), F.id(1001)]), "the star's instances and the badge nesting it")
        #expect(!expanded.touchedNodes.contains(F.id(1002)))
        var override = ChangeSummary(origin: .local)
        override.touch(F.id(1000), fields: [FieldPath(fields: 153, 3)])
        #expect(override.touchingDependents(in: index).touchedNodes == [F.id(1000)])
        // The mapper repaints where the touched instances are.
        let renderer = SymbolRenderer(typesetter: F.labels)
        let list = DisplayList(canvas: "s", items: [
            renderer.item(for: Self.instance(F.id(100), x: 20, y: 20), in: F.library),
            renderer.item(for: Self.instance(F.id(110), x: 60, y: 20), in: F.library),
            renderer.item(for: Self.instance(F.id(100), x: 20, y: 80), in: F.library),
        ], nodeIDs: [F.id(1000), F.id(1001), F.id(1003)])
        let region = InvalidationMapper().dirtyRegion(for: override.touchingDependents(in: index), before: [list], after: [list])
        #expect(region.rects(for: "s") == [list.itemBounds[0]!])
        index.remove(dependent: F.id(1000))
        #expect(index.directDependents(of: F.id(100)) == [F.id(110)])
        #expect(!index.isEmpty)
        index.add(F.id(5), dependsOn: F.id(5))
        #expect(index.directDependents(of: F.id(5)).isEmpty)
    }

    /// 1,000 instances of one symbol are built into the display list in under 16 ms after the
    /// first build, reusing one sub-list (a `PerfBudget`: the perf run holds it).  The reference
    /// renderer's full-view draw of them is reported beside it: drawing is the tile renderers'
    /// budget, not the instance machinery's.
    @Test func aThousandInstancesRenderWithinAFrame() throws {
        let renderer = SymbolRenderer(typesetter: F.labels)
        let plain = SymbolArtwork(symbol: F.id(130), name: "Plain", version: 1, origin: Point(x: 10, y: 10), nodes: [
            SymbolNode(id: F.id(131), content: .item(ReferenceCorpus.path(F.starPath(center: Point(x: 10, y: 10), radius: 10), [ReferenceCorpus.fill(F.orange), ReferenceCorpus.stroke(.black, width: 1)]))),
        ])
        let library = SymbolLibrary([plain])
        func build() -> DisplayList {
            DisplayList(canvas: "s", items: (0..<1000).map { index in
                renderer.item(for: Self.instance(F.id(130), x: Double(index % 40) * 22 + 11, y: Double(index / 40) * 22 + 11), in: library)
            })
        }
        // The first build and frame fill the caches (the sub-list, the stroke outline).
        _ = CoreGraphicsRenderer(background: .white).renderBitmap(build(), viewport: Viewport(size: Size(width: 880, height: 550)))
        let start = Date()
        let list = build()
        let built = Date()
        let image = CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: Viewport(size: Size(width: 880, height: 550)))
        let milliseconds = Date().timeIntervalSince(start) * 1000
        print("PERF instances: 1,000 instances built in \(String(format: "%.1f", built.timeIntervalSince(start) * 1000)) ms, built and rendered in \(String(format: "%.1f", milliseconds)) ms")
        #expect(image != nil)
        #expect(renderer.buildCount == 1)
        PerfBudget.expect(.seconds(built.timeIntervalSince(start)), within: .milliseconds(16), "build")
    }

    /// LIB-026's budget: of 1,000 instances, 100 carry overrides of their own (a fill each, all
    /// different).  The 900 plain ones share the symbol's sub-list; each overridden one builds its
    /// own once, so the list costs the plain budget plus 100 sub-list builds -- measured here as
    /// 100 overridden instances built alone by a fresh renderer -- and, once built, the plain
    /// budget again.
    @Test func aHundredOverriddenInstancesCostAHundredSubListBuilds() throws {
        let plain = SymbolArtwork(symbol: F.id(130), name: "Plain", version: 1, origin: Point(x: 10, y: 10), nodes: [
            SymbolNode(id: F.id(131), content: .item(ReferenceCorpus.path(F.starPath(center: Point(x: 10, y: 10), radius: 10), [ReferenceCorpus.fill(F.orange), ReferenceCorpus.stroke(.black, width: 1)]))),
        ])
        let library = SymbolLibrary([plain])
        func overrides(_ index: Int) -> [InstanceOverride] {
            index % 10 == 0 ? [.fill(F.id(131), Color(red: Double(index) / 1000, green: 0.5, blue: 0.5))] : []
        }
        func build(_ renderer: SymbolRenderer, _ indices: some Sequence<Int>) -> DisplayList {
            DisplayList(canvas: "s", items: indices.map { index in
                renderer.item(for: Self.instance(F.id(130), x: Double(index % 40) * 22 + 11, y: Double(index / 40) * 22 + 11,
                                                 overrides: overrides(index)), in: library)
            })
        }
        // The 100 sub-list builds on their own.
        let alone = SymbolRenderer(typesetter: F.labels)
        let aloneStart = Date()
        _ = build(alone, stride(from: 0, to: 1000, by: 10))
        let hundredBuilds = Date().timeIntervalSince(aloneStart)
        #expect(alone.buildCount == 100)
        // The symbol's own sub-list is warm, as after the first frame.
        let renderer = SymbolRenderer(typesetter: F.labels)
        _ = build(renderer, (0..<1000).filter { $0 % 10 != 0 })
        #expect(renderer.buildCount == 1)
        let start = Date()
        let list = build(renderer, 0..<1000)
        let mixed = Date().timeIntervalSince(start)
        #expect(list.items.count == 1000 && renderer.buildCount == 101, "one sub-list per overridden instance, the rest shared")
        let againStart = Date()
        _ = build(renderer, 0..<1000)
        let again = Date().timeIntervalSince(againStart)
        #expect(renderer.buildCount == 101, "built once")
        print("PERF overrides: 1,000 instances with 100 overridden built in \(String(format: "%.1f", mixed * 1000)) ms (100 sub-lists alone \(String(format: "%.1f", hundredBuilds * 1000)) ms), again in \(String(format: "%.1f", again * 1000)) ms")
        PerfBudget.expect(.seconds(mixed), within: .milliseconds(16) + .seconds(hundredBuilds), "first build")
        PerfBudget.expect(.seconds(again), within: .milliseconds(16), "built")
    }
}

extension DisplayItem {
    var groupChildren: [DisplayItem] {
        if case .group(let group) = self { return group.children }
        return []
    }
}
