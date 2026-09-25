import CoreGraphics
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// menu:Modify[Combine] (OBJ-025, combining-paths.adoc).
@Suite struct CombineCommandTests {
    typealias Op = CombineCommand.Operation

    /// An appearance of one basic fill of grey `level` and no stroke.
    static func filled(_ level: Double) -> Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: level, green: level, blue: level)]
        return appearance
    }

    static func square(_ a: inout Replica, x: Double, y: Double = 0, size: Double = 20, level: Double = 0.5,
                       transform: AffineTransform? = nil) throws -> OpID {
        try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: size, height: size),
                                            transform: transform ?? .translation(x: x, y: y), appearance: filled(level)), on: &a)
    }

    /// The fill grey of `node`'s first fill.
    static func level(_ node: OpID, in state: EngineState) -> Double? {
        state.props(node).path.appearance.fills.first?.settings.basic.color.inline.rgb.r
    }

    /// The filled area of a result path.
    static func area(_ node: OpID, in state: EngineState) -> Double {
        CombineCommand.region(node, in: state).signedArea()
    }

    @Test func unionTakesTheBackmostsAttributesAtTheFrontmostsSlot() throws {
        var a = Replica(0xA)
        let back = try Self.square(&a, x: 0, level: 0.1)
        let middle = try Self.square(&a, x: 10, level: 0.2)
        let front = try Self.square(&a, x: 100, level: 0.3)
        let above = try Self.square(&a, x: 300, level: 0.4)
        let change = try #require(try a.perform(CombineCommand(.union, [front, back, middle])))
        #expect(change.label == "Union 3 paths")
        let result = try #require(change.createdObjects.first)
        #expect(change.createdObjects.count == 1)
        #expect(Self.level(result, in: a.state) == 0.1)
        let props = a.state.props(result).path
        #expect(!props.common.hasTransform && !props.evenOdd)
        #expect(props.contours.count == 2, "the far square is a sub-path")
        #expect(abs(Self.area(result, in: a.state) - (600 + 400)) < 1e-6)
        #expect([back, middle, front].allSatisfy { !a.state.isLive($0) })
        let layer = try #require(Objects.parent(of: result, in: a.state))
        #expect(a.state.liveChildren(layer).suffix(2) == [result, above], "at the frontmost input's slot, below what was above it")
        // Undo restores the inputs and deletes the result.
        a.undo()
        #expect([back, middle, front].allSatisfy { a.state.isLive($0) } && !a.state.isLive(result))
    }

    @Test func intersectKeepsTheCommonAreaAndDeletesTheSelectionWhenThereIsNone() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0, level: 0.1)
        let two = try Self.square(&a, x: 10, y: 10, level: 0.2)
        let result = try #require(try a.perform(CombineCommand(.intersect, [one, two]))?.createdObjects.first)
        #expect(abs(Self.area(result, in: a.state) - 100) < 1e-6 && Self.level(result, in: a.state) == 0.1)
        let far = try Self.square(&a, x: 500)
        let empty = try #require(try a.perform(CombineCommand(.intersect, [result, far])))
        #expect(empty.createdObjects.isEmpty && !a.state.isLive(result) && !a.state.isLive(far))
        // Kept originals and nothing in common: no change at all.
        let three = try Self.square(&a, x: 0)
        let four = try Self.square(&a, x: 900)
        #expect(try a.perform(CombineCommand(.intersect, [three, four], keepOriginals: true)) == nil)
    }

    @Test func punchAndCropCutEveryTargetWithTheFrontmostAndKeepTheirAttributes() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0, level: 0.1)
        let two = try Self.square(&a, x: 30, level: 0.2)
        let covered = try Self.square(&a, x: 60, y: 5, size: 5, level: 0.3)
        let cutter = try Self.square(&a, x: 15, y: 0, size: 60, level: 0.9, transform: AffineTransform.scale(x: 1, y: 0.5).concatenating(.translation(x: 15, y: 5)))
        let punched = try #require(try a.perform(CombineCommand(.punch, [one, two, covered, cutter]))).createdObjects
        #expect(punched.count == 2, "the fully covered target makes nothing")
        #expect(punched.map { Self.level($0, in: a.state) } == [0.1, 0.2])
        #expect(abs(Self.area(punched[0], in: a.state) - (400 - 5 * 15)) < 1e-6)
        #expect(Self.area(punched[1], in: a.state) > 0)
        #expect(!a.state.isLive(cutter) && !a.state.isLive(covered))
        a.undo()
        let cropped = try #require(try a.perform(CombineCommand(.crop, [one, two, covered, cutter], keepOriginals: true))).createdObjects
        #expect(cropped.count == 3)
        #expect(abs(Self.area(cropped[0], in: a.state) - 5 * 15) < 1e-6 && abs(Self.area(cropped[2], in: a.state) - 25) < 1e-6)
        #expect([one, two, covered, cutter].allSatisfy { a.state.isLive($0) }, "kept")
    }

    @Test func divideGroupsItsPiecesWithTheFrontmostCoveringAttributes() throws {
        var a = Replica(0xA)
        let back = try Self.square(&a, x: 0, level: 0.1)
        let front = try Self.square(&a, x: 10, level: 0.2)
        let open = try LayerFixture.object(PathFixture.open([(100, 0), (120, 0), (120, 20)]), on: &a)
        let change = try #require(try a.perform(CombineCommand(.divide, [back, front, open])))
        let group = try #require(change.createdObjects.first)
        #expect(a.state.nodeKind(group) == .group)
        let pieces = a.state.liveChildren(group)
        #expect(pieces.count == 4, "back only, both, front only, and the open path closed by its chord")
        let levels = pieces.map { Self.level($0, in: a.state) }
        #expect(levels.filter { $0 == 0.1 }.count == 1 && levels.filter { $0 == 0.2 }.count == 2)
        let total: Double = pieces.map { Self.area($0, in: a.state) }.reduce(0, +)
        #expect(abs(total - 800) < 1e-6)
        // The pieces of the front input stack above the back input's.
        #expect(levels.first == 0.1)
        #expect(!a.state.isLive(back) && !a.state.isLive(open))
    }

    @Test func menuValidationTitlesAndPreference() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        let two = try Self.square(&a, x: 10)
        let open = try LayerFixture.object(PathFixture.open([(0, 0), (20, 0)]), on: &a)
        let locked = try Self.square(&a, x: 5)
        try a.perform(SetLocked([locked], locked: true))
        #expect(CombineCommand.canPerform(.union, [one, two], in: a.state))
        #expect(!CombineCommand.canPerform(.union, [one], in: a.state))
        #expect(!CombineCommand.canPerform(.union, [one, open], in: a.state), "open paths only divide")
        #expect(CombineCommand.canPerform(.divide, [one, open], in: a.state))
        #expect(!CombineCommand.canPerform(.intersect, [one, locked], in: a.state))
        #expect(try a.perform(CombineCommand(.union, [one, open])) == nil)
        #expect(CombineCommand.keepsOriginals(consumePreference: true, shift: false) == false)
        #expect(CombineCommand.keepsOriginals(consumePreference: true, shift: true))
        #expect(CombineCommand.keepsOriginals(consumePreference: false, shift: false))
        #expect(!CombineCommand.keepsOriginals(consumePreference: false, shift: true))
        #expect(CombineCommand.title(.union, keepOriginals: true) == "Union (keep originals)")
        #expect(Op.allCases.map { CombineCommand.title($0, keepOriginals: false) } == ["Union", "Divide", "Intersect", "Punch", "Crop"])
    }

    @Test func resultsInsideATransformedGroupStayInPlace() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a, x: 0)
        let two = try Self.square(&a, x: 10)
        let group = try a.perform(GroupObjects([one, two]))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: AffineTransform.scale(x: 2, y: 1).concatenating(.translation(x: 50, y: 50)), kind: .scale))
        let before = try #require(Objects.bounds(of: group, in: a.state))
        let result = try #require(try a.perform(CombineCommand(.union, [one, two]))?.createdObjects.first)
        #expect(Objects.parent(of: result, in: a.state) == group)
        let after = try #require(Objects.bounds(of: result, in: a.state))
        #expect(abs(after.minX - before.minX) < 1e-6 && abs(after.maxX - before.maxX) < 1e-6 && abs(after.maxY - before.maxY) < 1e-6)
    }

    /// RGBA bytes of the scene over `region` at 2×.
    static func pixels(_ state: EngineState, region: Rect) -> [UInt8] {
        var scene = DocumentDisplayListBuilder(canvas: "test")
        let list = scene.rebuild(state).displayList
        let viewport = Viewport(scrollOrigin: region.origin, zoom: 2, size: Size(width: region.width * 2, height: region.height * 2))
        let image = CoreGraphicsRenderer().renderBitmap(list, viewport: viewport)!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test func unionOfARotatedRectangleAndAnEllipseDrawsLikeItsInputs() throws {
        var a = Replica(0xA)
        let rotated = AffineTransform.rotation(radians: .pi / 7).concatenating(.translation(x: 20, y: 10))
        _ = try Self.square(&a, x: 0, size: 40, level: 0.2, transform: rotated)
        _ = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 50, height: 30), transform: .translation(x: 35, y: 30),
                                                appearance: Self.filled(0.2)), on: &a)
        let inputs = LayerOrder(a.state).objects(on: LayerOrder(a.state).defaultLayer!, in: a.state)
        let region = Rect(x: -20, y: -20, width: 130, height: 110)
        let before = Self.pixels(a.state, region: region)
        let result = try #require(try a.perform(CombineCommand(.union, inputs))?.createdObjects.first)
        #expect(!a.state.props(result).path.common.hasTransform)
        let after = Self.pixels(a.state, region: region)
        #expect(CombineExpandTests.difference(before, after) < 0.002)
    }

    // MARK: Merge and undo

    @Test func concurrentCombinesOfOverlappingSelectionsKeepBothResults() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 10)
        let three = try Self.square(&pair.a, x: 20)
        pair.sync()
        let left = try #require(try pair.a.perform(CombineCommand(.union, [one, two]))?.createdObjects.first)
        let right = try #require(try pair.b.perform(CombineCommand(.intersect, [two, three]))?.createdObjects.first)
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(left) && replica.state.isLive(right))
            #expect([one, two, three].allSatisfy { !replica.state.isLive($0) })
        }
    }

    @Test func undoAfterARemoteRedeletionLeavesTheInputDeleted() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 10)
        pair.sync()
        let result = try #require(try pair.a.perform(CombineCommand(.union, [one, two]))?.createdObjects.first)
        pair.sync()
        // B restores one input and deletes it again.
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.setDeleted(one, false)]))
        try pair.b.perform(DeleteNodes([one]))
        pair.sync()
        pair.a.undo()
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(!pair.a.state.isLive(result))
        #expect(!pair.a.state.isLive(one), "someone else deleted it since")
        #expect(pair.a.state.isLive(two))
    }

    @Test func combineVersusEditOfAnInputLandsOnTheDeletedInput() throws {
        var pair = Pair()
        let one = try Self.square(&pair.a, x: 0)
        let two = try Self.square(&pair.a, x: 10)
        pair.sync()
        try pair.a.perform(CombineCommand(.union, [one, two]))
        try pair.b.perform(MoveObjects([one], by: Vector(dx: 5, dy: 5)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(!pair.a.state.isLive(one))
        #expect(Objects.transform(of: one, in: pair.a.state) == .translation(x: 5, y: 5), "the move is retained on the deleted input")
    }

    // MARK: Corpus

    /// 200 two-operand cases in the manner of GEO-002's corpus (which lives in WTGeometry's test
    /// target): squares, ellipses and triangles at offsets that overlap, touch along an edge, meet
    /// at a corner, nest, coincide and miss, some rotated.
    static let corpus: [(String, CreateShape, CreateShape)] = {
        var cases: [(String, CreateShape, CreateShape)] = []
        let offsets: [(Double, Double)] = [(0, 0), (10, 0), (20, 0), (20, 20), (5, 5), (40, 0), (10, 10), (0, 20), (15, 3), (2.5, 7.5)]
        let angles: [Double] = [0, .pi / 4, .pi / 6, .pi / 2, .pi / 9]
        let kinds: [CreateShape.Kind] = [.rectangle(CornerRadii()), .ellipse]
        for (i, offset) in offsets.enumerated() {
            for (j, angle) in angles.enumerated() {
                for (k, first) in kinds.enumerated() {
                    for (l, second) in kinds.enumerated() {
                        let a = CreateShape(first, size: Size(width: 20, height: 20), appearance: filled(0.1))
                        let rotation = AffineTransform.translation(x: -10, y: -10).concatenating(.rotation(radians: angle))
                            .concatenating(.translation(x: 10 + offset.0, y: 10 + offset.1))
                        let b = CreateShape(second, size: Size(width: 20, height: 20), transform: rotation, appearance: filled(0.2))
                        cases.append(("\(i)-\(j)-\(k)\(l)", a, b))
                    }
                }
            }
        }
        return cases
    }()

    @Test func corpusIsLargeEnough() {
        #expect(Self.corpus.count >= 200)
    }

    @Test(arguments: 0..<200)
    func corpusCase(_ index: Int) throws {
        let (_, first, second) = Self.corpus[index]
        var base = Replica(0xA)
        let a = try LayerFixture.object(first, on: &base)
        let b = try LayerFixture.object(second, on: &base)
        let regions = [CombineCommand.region(a, in: base.state), CombineCommand.region(b, in: base.state)]
        let union = Boolean.union(regions), intersection = Boolean.intersection(regions)
        for operation in Op.allCases {
            var replica = base
            let change = try #require(try replica.perform(CombineCommand(operation, [a, b])))
            let results = change.createdObjects
            #expect(!replica.state.isLive(a) && !replica.state.isLive(b))
            let paths = operation == .divide ? results.flatMap { replica.state.liveChildren($0) } : results
            let area: Double = paths.map { Self.area($0, in: replica.state) }.reduce(0, +)
            let tolerance: Double = 1e-6 * 800
            switch operation {
            case .union:
                #expect(results.count == 1 && abs(area - union.signedArea()) <= tolerance)
                #expect(Self.level(results[0], in: replica.state) == 0.1)
                #expect(replica.state.props(results[0]).path.contours.count == union.contours.count)
            case .intersect:
                #expect(results.count == (intersection.isEmpty ? 0 : 1) && abs(area - intersection.signedArea()) <= tolerance)
            case .punch:
                let expected = Boolean.subtracting(regions[0], regions[1])
                #expect(results.count == (expected.isEmpty ? 0 : 1) && abs(area - expected.signedArea()) <= tolerance)
                #expect(results.allSatisfy { Self.level($0, in: replica.state) == 0.1 })
            case .crop:
                #expect(abs(area - intersection.signedArea()) <= tolerance)
            case .divide:
                let pieces = Boolean.divide(regions)
                #expect(paths.count == pieces.count && abs(area - union.signedArea()) <= tolerance)
                #expect(paths.allSatisfy { Self.level($0, in: replica.state) != nil })
            }
        }
    }
}
