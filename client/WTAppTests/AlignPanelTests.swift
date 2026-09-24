import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// OBJ-019: the Align panel.
@Suite(.serialized) @MainActor struct AlignPanelTests {
    /// Boxes as (minX, minY, width, height).
    static let corpus: [[Rect]] = [
        [Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 30, y: 20, width: 20, height: 5), Rect(x: 70, y: 5, width: 5, height: 30)],
        (0..<6).map { (i: Int) -> Rect in
            let x = Double(i * i) * 7, y = Double((i * 13) % 17)
            return Rect(x: x, y: y, width: Double(4 + i), height: Double(9 - i))
        },
        (0..<10).map { (i: Int) -> Rect in
            let x = Double((i * 37) % 101), y = Double((i * 53) % 97)
            return Rect(x: x, y: y, width: Double(3 + i % 4), height: Double(2 + i % 5))
        },
    ]

    /// The expected minimum coordinate of each box on one axis after `option` (spans are
    /// (min, max)), computed independently of `AlignLayout`.
    static func expected(_ spans: [(Double, Double)], _ option: AlignOption) -> [Double] {
        let low = spans.map(\.0).min()!, high = spans.map(\.1).max()!
        let widths = spans.map { $0.1 - $0.0 }
        switch option {
        case .none: return spans.map(\.0)
        case .minEdge: return spans.map { _ in low }
        case .maxEdge: return widths.map { high - $0 }
        case .center: return widths.map { (low + high) / 2 - $0 / 2 }
        case .distributeMin, .distributeCenter, .distributeMax:
            func key(_ index: Int) -> Double {
                option == .distributeMin ? spans[index].0 : option == .distributeMax ? spans[index].1 : (spans[index].0 + spans[index].1) / 2
            }
            let order = spans.indices.sorted { key($0) < key($1) }
            let first = key(order.first!), last = key(order.last!)
            var result = spans.map(\.0)
            for (rank, index) in order.enumerated() {
                let target = first + (last - first) * Double(rank) / Double(order.count - 1)
                result[index] = spans[index].0 + target - key(index)
            }
            return result
        case .distributeGaps:
            let order = spans.indices.sorted { spans[$0].0 < spans[$1].0 }
            let total = widths.reduce(0, +)
            let gap = (high - low - total) / Double(order.count - 1)
            var cursor = low
            var result = spans.map(\.0)
            for index in order {
                result[index] = cursor
                cursor += widths[index] + gap
            }
            return result
        }
    }

    @Test func everyOptionCombinationMatchesTheExpectedPositions() {
        for boxes in Self.corpus {
            for horizontal in AlignOption.allCases {
                for vertical in AlignOption.allCases {
                    let settings = AlignSettings(horizontal: horizontal, vertical: vertical)
                    let offsets = AlignLayout.offsets(boxes.map { AlignLayout.Item(box: $0) }, settings: settings, page: nil)
                    let xs = Self.expected(boxes.map { ($0.minX, $0.maxX) }, horizontal)
                    let ys = Self.expected(boxes.map { ($0.minY, $0.maxY) }, vertical)
                    for (index, box) in boxes.enumerated() {
                        #expect(abs(box.minX + offsets[index].dx - xs[index]) < 0.001, "\(horizontal) x")
                        #expect(abs(box.minY + offsets[index].dy - ys[index]) < 0.001, "\(vertical) y")
                    }
                }
            }
        }
    }

    @Test func toThePageAndAroundLockedAnchors() {
        let boxes = Self.corpus[0].map { AlignLayout.Item(box: $0) }
        let page = Rect(x: -100, y: -50, width: 400, height: 300)
        let left = AlignLayout.offsets(boxes, settings: AlignSettings(horizontal: .minEdge, toPage: true), page: page)
        #expect(zip(boxes, left).allSatisfy { abs($0.box.minX + $1.dx + 100) < 1e-9 })
        let bottoms = AlignLayout.offsets(boxes, settings: AlignSettings(vertical: .maxEdge, toPage: true), page: page)
        #expect(zip(boxes, bottoms).allSatisfy { abs($0.box.maxY + $1.dy - 250) < 1e-9 })
        for option in [AlignOption.distributeMin, .distributeCenter, .distributeMax, .distributeGaps] {
            let spread = AlignLayout.offsets(boxes, settings: AlignSettings(horizontal: option, toPage: true), page: page)
            let moved = zip(boxes, spread).map { $0.box.offset(by: Vector(dx: $1.dx, dy: 0)) }
            #expect(abs(moved.map(\.minX).min()! + 100) < 1e-6 && abs(moved.map(\.maxX).max()! - 300) < 1e-6, "\(option) spans the page")
        }
        // A locked box stays put and the others align to it.
        var anchored = boxes
        anchored[1].fixed = true
        let right = AlignLayout.offsets(anchored, settings: AlignSettings(horizontal: .maxEdge), page: nil)
        #expect(right[1] == .zero)
        #expect(zip(anchored, right).allSatisfy { abs($0.box.maxX + $1.dx - 50) < 1e-9 })
        let spreadAnchored = AlignLayout.offsets(anchored, settings: AlignSettings(vertical: .distributeGaps), page: nil)
        #expect(spreadAnchored[1] == .zero)
        #expect(AlignLayout.offsets([], settings: AlignSettings(horizontal: .center), page: nil).isEmpty)
        let lone = AlignLayout.offsets([AlignLayout.Item(box: Rect(x: 5, y: 5, width: 1, height: 1))], settings: AlignSettings(horizontal: .distributeMin, vertical: .distributeGaps), page: nil)
        #expect(lone == [.zero])
        #expect(AlignOption.allCases.map { $0.title(horizontal: true) }.count == 8 && AlignOption.distributeGaps.title(horizontal: false) == "Distribute heights")
    }

    @Test func applyWritesOneChangeAndLockedObjectsAreAnchors() async throws {
        let document = DocumentHandle.memory(title: "Align")
        let rects = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 40, y: 20, width: 20, height: 5), Rect(x: 90, y: 5, width: 5, height: 30)])
        let target = AlignTarget(document: document, selection: Selection(rects))
        let align = try #require(target.command(AlignSettings(horizontal: .minEdge)))
        let change = try #require(await document.perform(align).value)
        #expect(change.label == "Align 2 objects")
        let lefts = rects.map { Objects.bounds(of: $0.opID, in: document.state)!.minX }
        #expect(lefts.allSatisfy { abs($0 - 0) < 1e-9 })
        #expect(target.command(AlignSettings(horizontal: .minEdge)) == nil, "already aligned: nothing moves")
        _ = await document.perform(SetLocked([rects[2].opID], locked: true)).value
        let bottomAlign = try #require(AlignTarget(document: document, selection: Selection(rects)).command(AlignSettings(vertical: .maxEdge)))
        _ = await document.perform(bottomAlign).value
        let bottoms = rects.map { Objects.bounds(of: $0.opID, in: document.state)!.maxY }
        #expect(bottoms.allSatisfy { abs($0 - 35) < 1e-9 }, "the locked rectangle's bottom is the anchor")
        #expect(AlignTarget(document: document, selection: .empty).command(AlignSettings(horizontal: .center)) == nil)
    }

    @Test func pointsDistributeByPositionKeepingTheirHandles() async throws {
        let document = DocumentHandle.memory(title: "Points")
        let change = await document.perform(CreatePath(contours: [NewContour(points: [
            VectorPoint(anchor: Point(x: 0, y: 0)), VectorPoint(anchor: Point(x: 7, y: 10), inHandle: Vector(dx: -2, dy: 0), outHandle: Vector(dx: 2, dy: 0), kind: .curve),
            VectorPoint(anchor: Point(x: 30, y: 0)),
        ])])).value
        let node = try #require(change?.createdObjects.first)
        await document.settle()
        let path = try #require(document.path(SelectionID(node)))
        let contour = path.contours[0]
        let references = Set(contour.points.map { PointReference(node: NodeID(node), contour: contour.id, point: $0.id) })
        var selection = Selection([SelectionID(node)])
        selection = selection.applying([SelectionID(node)], sub: [SelectionID(node): .points(references)], mode: .replace)
        let target = AlignTarget(document: document, selection: selection)
        #expect(target.points.count == 3)
        let command = try #require(target.command(AlignSettings(horizontal: .distributeCenter)))
        #expect(command.label == "Align 1 point")
        _ = await document.perform(command).value
        let after = try #require(document.path(SelectionID(node))?.contours[0])
        let middle = try #require(after.points.first { $0.id == contour.points[1].id })
        #expect(abs(middle.anchor.x - 15) < 1e-9 && middle.anchor.y == 10)
        #expect(middle.inHandle == Vector(dx: -2, dy: 0) && middle.outHandle == Vector(dx: 2, dy: 0), "handles keep their offsets")
    }

    @Test func alignConcurrentWithARemoteMoveKeepsTheLaterMatrix() async throws {
        let document = DocumentHandle.memory(title: "Merge")
        let rects = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 40, y: 20, width: 10, height: 10), Rect(x: 90, y: 5, width: 10, height: 10)])
        // A collaborator moves the middle rectangle from the state before the alignment.
        var remote = DocumentCore(state: document.state, replica: 0xFFFF_FFFF)
        let move = try #require(try remote.perform(MoveObjects([rects[1].opID], by: Vector(dx: 0, dy: 100)), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let command = try #require(AlignTarget(document: document, selection: Selection(rects)).command(AlignSettings(vertical: .minEdge)))
        let local = try #require(await document.perform(command).value)
        _ = await document.receive(move).value
        await document.settle()
        let tops = rects.map { Objects.bounds(of: $0.opID, in: document.state)!.minY }
        #expect(tops[0] == 0 && tops[2] == 0, "the others stay aligned")
        // The middle one has whichever matrix is later: the remote move (from y 20) or the alignment.
        let remoteLater = OpID(counter: move.startCounter, replica: move.replica) > OpID(counter: local.startCounter, replica: local.replica)
        #expect(tops[1] == (remoteLater ? 120 : 0))
    }

    @Test func thePanelRemembersItsSettingsAndTheMenuAligns() async throws {
        let defaults = TestDefaults()
        defer { defaults.remove() }
        let state = AlignPanelState(defaults: defaults.defaults)
        state.click(at: CGPoint(x: 2, y: 88), in: CGSize(width: 100, height: 90))
        #expect(state.settings.horizontal == .minEdge && state.settings.vertical == .maxEdge)
        state.click(at: CGPoint(x: 50, y: 45), in: CGSize(width: 100, height: 90))
        #expect(state.settings.horizontal == .center && state.settings.vertical == .center)
        state.click(at: CGPoint(x: 99, y: 1), in: CGSize(width: 100, height: 90))
        #expect(state.settings.horizontal == .maxEdge && state.settings.vertical == .minEdge)
        #expect(AlignPreview.options(at: .zero, in: .zero) == (AlignOption.none, AlignOption.none))
        AlignPanelBody.toPage(state).wrappedValue = true
        AlignPanelBody.option(state, horizontal: true).wrappedValue = .distributeGaps
        AlignPanelBody.option(state, horizontal: false).wrappedValue = .distributeCenter
        #expect(AlignPanelBody.option(state, horizontal: true).wrappedValue == .distributeGaps && AlignPanelBody.toPage(state).wrappedValue)
        let reopened = AlignPanelState(defaults: defaults.defaults)
        #expect(reopened.settings == AlignSettings(horizontal: .distributeGaps, vertical: .distributeCenter, toPage: true), "remembered")
        #expect(AlignPreview.boxes(reopened.settings).count == 4 && AlignPreview.boxes(AlignSettings()).count == 3)
        #expect(AlignPanelState().settings == AlignSettings())
        // Apply on the front window's selection.
        let document = DocumentHandle.memory(title: "Apply")
        let rects = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 40, y: 20, width: 20, height: 5)])
        let selection = ActiveSelection(model: SelectionModel(Selection(rects)), document: document)
        let panel = AlignPanelState()
        panel.settings = AlignSettings(horizontal: .center)
        _ = await panel.apply(selection)?.value
        let centers = rects.map { Objects.bounds(of: $0.opID, in: document.state)!.center.x }
        #expect(abs(centers[0] - centers[1]) < 1e-9)
        #expect(panel.apply(nil) == nil)
        _ = AlignPanelBody(selection: selection, state: panel).body
        _ = AlignPanel.descriptor(selection: selection, state: panel).makeView()
        // menu:Modify[Align].
        let editing = ObjectEditing(document: document, selection: SelectionController(document: document))
        editing.selection.model.set(Selection(rects))
        let commands = AlignPanel.commands { editing }
        #expect(commands.count == 6 && commands.allSatisfy { $0.validation() == .enabled })
        let top = try #require(commands.first { $0.id == ContextMenuCatalog.ID.alignTop })
        if case .perform(let run) = top.action { run() }
        await document.settle()
        #expect(rects.map { Objects.bounds(of: $0.opID, in: document.state)!.minY }.allSatisfy { $0 == 0 })
        #expect(AlignPanel.commands { nil }.allSatisfy { $0.validation() == .disabled(ObjectMenuCommands.noSelection) })
        for command in AlignPanel.commands(target: { nil }) { if case .perform(let run) = command.action { run() } }
    }
}
