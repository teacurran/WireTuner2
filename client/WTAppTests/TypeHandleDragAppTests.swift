import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTText
@testable import WireTuner

/// TYPE-018: the leading and kerning drags of the text block handles.
@Suite(.serialized) @MainActor struct TypeHandleDragAppTests {
    static func leading(_ world: TypeWorld, _ node: OpID) -> [WTText.Leading?] {
        let text = world.state.textNode(node)!
        return (0..<text.length).map { TextLayoutReading.attributes(text.values(at: $0)).leading }
    }

    static func kerning(_ world: TypeWorld, _ node: OpID) -> Set<Double> {
        let text = world.state.textNode(node)!
        return Set((0..<text.length).map { TextLayoutReading.attributes(text.values(at: $0)).rangeKerning })
    }

    @Test func theBottomAndTopHandlesDragLeadingInOneChange() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await TypeExtrasTests.fixedBlock(world, "One line of text")
        let context = TypeExtrasTests.context(world)
        let handles = TextBlockHandles()
        let frame = try #require(handles.frames(context).first)
        let lines = try #require(world.document.textLayout(for: node)).lineCount
        let bottom = frame.point(.bottom)
        let before = world.document.changeCount
        #expect(handles.press(TypeExtrasTests.event(world, bottom), context: context))
        // Within the threshold nothing previews.
        handles.drag(TypeExtrasTests.event(world, Point(x: bottom.x, y: bottom.y + 0.5)), context: context)
        #expect(handles.typeDrag?.value == nil && handles.typeDrag?.kind == .leading)
        handles.drag(TypeExtrasTests.event(world, Point(x: bottom.x, y: bottom.y + 12)), context: context)
        let preview = try #require(handles.typeDrag?.value)
        #expect(TypeHandleDrag.readout(preview).hasPrefix("Leading"))
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        handles.release(TypeExtrasTests.event(world, Point(x: bottom.x, y: bottom.y + 12)), context: context)
        await world.settle()
        #expect(world.document.changeCount == before + 1, "one change")
        #expect(world.document.undoTitle == "Undo Leading")
        // Auto (120%) at 12 pt opened by 12 points over the lines.
        let expected = ((120 + 12 / Double(lines) / 12 * 100) * 10).rounded() / 10
        #expect(Set(Self.leading(world, node)) == [WTText.Leading(mode: .percent, value: expected)])
        // The top handle, dragged toward the centre with Shift: whole percent, tighter.
        let top = try #require(handles.frames(context).first).point(.top)
        #expect(handles.press(TypeExtrasTests.event(world, top), context: context))
        handles.release(TypeExtrasTests.event(world, Point(x: top.x, y: top.y + 6.3), .shift), context: context)
        await world.settle()
        let tightened = try #require(Self.leading(world, node).first ?? nil)
        #expect(tightened.value < expected && tightened.value == tightened.value.rounded())
        #expect(world.document.changeCount == before + 2)
    }

    @Test func theSideHandlesDragRangeKerning() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await TypeExtrasTests.fixedBlock(world, "Kerning")
        let context = TypeExtrasTests.context(world)
        let handles = TextBlockHandles()
        let right = try #require(handles.frames(context).first).point(.right)
        #expect(handles.press(TypeExtrasTests.event(world, right), context: context))
        #expect(handles.typeDrag?.kind == .kerning)
        handles.drag(TypeExtrasTests.event(world, Point(x: right.x + 20, y: right.y), .shift), context: context)
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        handles.release(TypeExtrasTests.event(world, Point(x: right.x + 20, y: right.y), .shift), context: context)
        await world.settle()
        let spread = try #require(Self.kerning(world, node).first)
        #expect(Self.kerning(world, node).count == 1 && spread > 0 && spread == spread.rounded())
        #expect(world.document.undoTitle == "Undo Kern")
        // The left handle toward the centre tightens.
        let left = try #require(handles.frames(context).first).point(.left)
        #expect(handles.press(TypeExtrasTests.event(world, left), context: context))
        handles.release(TypeExtrasTests.event(world, Point(x: left.x + 10, y: left.y)), context: context)
        await world.settle()
        #expect(try #require(Self.kerning(world, node).first) < spread)
    }

    @Test func aPressThatDoesNotMoveWritesNothingAndDoubleClicksStillToggle() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await TypeExtrasTests.fixedBlock(world, "Toggle")
        let context = TypeExtrasTests.context(world)
        let handles = TextBlockHandles()
        let right = try #require(handles.frames(context).first).point(.right)
        let before = world.document.changeCount
        #expect(handles.press(TypeExtrasTests.event(world, right), context: context))
        handles.release(TypeExtrasTests.event(world, right), context: context)
        #expect(handles.press(TypeExtrasTests.event(world, right, clicks: 2), context: context))
        #expect(handles.typeDrag == nil)
        await world.settle()
        #expect(world.document.changeCount == before + 1 && world.state.props(node).text.block.autoWidth, "only the toggle")
        // Esc abandons a type drag.
        #expect(handles.press(TypeExtrasTests.event(world, try #require(handles.frames(context).first).point(.bottom)), context: context))
        handles.cancel(context: context)
        #expect(handles.typeDrag == nil)
    }
}
