import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// PRINT-011: the output area register (output-area.adoc, "Merge semantics"); PRINT-010: object
/// halftone screens (halftones.adoc, "Merge semantics").
@Suite struct OutputAreaTests {
    static let area = Rect(x: 10, y: 20, width: 300, height: 200)

    @Test func defineMoveResizeAndRemoveEachWriteTheOneRegister() throws {
        var a = Replica(0xA)
        #expect(OutputArea.read(a.state) == nil)
        let defined = try #require(try a.perform(SetOutputArea(Self.area)))
        #expect(defined.label == "Define output area" && defined.ops.count == 1)
        #expect(OutputArea.read(a.state) == Self.area)
        let moved = Rect(x: 40, y: 20, width: 300, height: 200)
        #expect(try a.perform(SetOutputArea(moved, kind: .move))?.label == "Move output area")
        #expect(OutputArea.read(a.state) == moved)
        #expect(SetOutputArea(moved, kind: .resize).label == "Resize output area")
        let removed = try #require(try a.perform(SetOutputArea(nil)))
        #expect(removed.label == "Remove output area")
        #expect(OutputArea.read(a.state) == nil)
        a.undo()
        #expect(OutputArea.read(a.state) == moved)
        #expect(throws: PrintSettingsError.invalidValue("output area")) { try a.perform(SetOutputArea(Rect(x: 0, y: 0, width: 0, height: 5))) }
        #expect(throws: PrintSettingsError.invalidValue("output area")) { try a.perform(SetOutputArea(Rect(x: .nan, y: 0, width: 5, height: 5))) }
    }

    @Test func readNormalizesDegenerateAndOffPasteboardRectangles() {
        var stored = Wiretuner_Doc_V1_Rect()
        stored.width = 0
        stored.height = 10
        #expect(OutputArea.normalized(stored) == nil)
        stored.width = 10
        stored.height = -1
        #expect(OutputArea.normalized(stored) == nil)
        stored.height = 10
        stored.x = .infinity
        #expect(OutputArea.normalized(stored) == nil)
        stored.x = -500
        stored.y = 20_000
        #expect(OutputArea.normalized(stored) == Rect(x: 0, y: OutputArea.pasteboard.maxY - 10, width: 10, height: 10))
        stored.x = 5
        stored.y = 5
        #expect(OutputArea.normalized(stored) == Rect(x: 5, y: 5, width: 10, height: 10))
    }

    @Test func concurrentMoveAndResizeLeaveOneWholeRectangle() throws {
        var pair = Pair()
        try pair.a.perform(SetOutputArea(Self.area))
        pair.sync()
        try pair.a.perform(SetOutputArea(Rect(x: 50, y: 20, width: 300, height: 200), kind: .move))
        try pair.b.perform(SetOutputArea(Rect(x: 10, y: 20, width: 100, height: 100), kind: .resize))
        pair.sync()
        let left = OutputArea.read(pair.a.state), right = OutputArea.read(pair.b.state)
        #expect(left == right)
        #expect([Rect(x: 50, y: 20, width: 300, height: 200), Rect(x: 10, y: 20, width: 100, height: 100)].contains(left!))
        // A concurrent remove and move converge to the later op on both replicas.
        try pair.a.perform(SetOutputArea(nil))
        try pair.b.perform(SetOutputArea(Self.area, kind: .move))
        pair.sync()
        #expect(OutputArea.read(pair.a.state) == OutputArea.read(pair.b.state))
    }

    // MARK: Object halftones

    static func screen(_ shape: Wiretuner_Doc_V1_HalftoneShape, angle: Double, frequency: Double) -> Wiretuner_Doc_V1_Halftone {
        var halftone = Wiretuner_Doc_V1_Halftone()
        halftone.shape = shape
        halftone.angle = angle
        halftone.frequency = frequency
        return halftone
    }

    @Test func applyingAScreenWritesOneAtomicRegisterPerObjectAndUseDocumentSettingsUnsets() throws {
        var a = Replica(0xA)
        let objects = try ArrangeTests.row(3, on: &a)
        let line = Self.screen(.line, angle: 45, frequency: 40)
        let change = try #require(try a.perform(SetObjectHalftone(objects, halftone: line)))
        #expect(change.label == "Change halftone of 3 objects" && change.ops.count == 3)
        #expect(objects.allSatisfy { ObjectHalftones.own($0, in: a.state) == line })
        let cleared = try #require(try a.perform(SetObjectHalftone(objects, halftone: nil)))
        #expect(cleared.ops.count == 3)
        #expect(objects.allSatisfy { ObjectHalftones.own($0, in: a.state) == nil })
        #expect(SetObjectHalftone([objects[0]], halftone: nil).label == "Change halftone")
        // Out of range values are refused; locked objects are skipped.
        #expect(throws: PrintSettingsError.invalidValue("halftone")) { try a.perform(SetObjectHalftone(objects, halftone: Self.screen(.round, angle: 400, frequency: 10))) }
        try a.perform(SetLocked([objects[0]], locked: true))
        #expect(try a.perform(SetObjectHalftone([objects[0]], halftone: line)) == nil)
        #expect(ObjectHalftones.own(OpID(counter: 9, replica: 9), in: a.state) == nil)
    }

    @Test func aGroupsScreenResolvesToMembersWithoutTheirOwn() throws {
        var a = Replica(0xA)
        let members = try ArrangeTests.row(2, on: &a)
        let group = try a.perform(GroupObjects(members))!.createdObjects[0]
        let coarse = Self.screen(.line, angle: 45, frequency: 20)
        let fine = Self.screen(.round, angle: 15, frequency: 150)
        #expect(ObjectHalftones.effective(members[0], in: a.state) == nil)
        try a.perform(SetObjectHalftone([group], halftone: coarse))
        #expect(ObjectHalftones.effective(members[0], in: a.state) == coarse)
        try a.perform(SetObjectHalftone([members[1]], halftone: fine))
        #expect(ObjectHalftones.effective(members[1], in: a.state) == fine)
        #expect(ObjectHalftones.effective(members[0], in: a.state) == coarse)
        #expect(ObjectHalftones.effective(group, in: a.state) == coarse)
    }

    @Test func concurrentAngleAndFrequencyEditsConvergeToOneWholeScreen() throws {
        var pair = Pair()
        let object = try ArrangeTests.row(1, on: &pair.a)[0]
        pair.sync()
        try pair.a.perform(SetObjectHalftone([object], halftone: Self.screen(.line, angle: 30, frequency: 40)))
        try pair.b.perform(SetObjectHalftone([object], halftone: Self.screen(.line, angle: 45, frequency: 85)))
        pair.sync()
        let left = try #require(ObjectHalftones.own(object, in: pair.a.state))
        #expect(left == ObjectHalftones.own(object, in: pair.b.state))
        #expect((left.angle, left.frequency) == (30, 40) || (left.angle, left.frequency) == (45, 85))
    }
}
