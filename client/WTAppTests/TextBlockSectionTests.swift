import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText
@testable import WireTuner

/// Puts path `path` under text `text` with `on_path` set, as TYPE-041's attach will (a test stand-in).
struct AttachTextToPath: WTModel.Command {
    let text: OpID
    let path: OpID
    var props = Wiretuner_Doc_V1_TextOnPathProps.with { $0.top = .baseline; $0.bottom = .baseline }
    var label: String { "Attach to Path" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.move(path, parent: text, position: [0x80]))
        var values = Wiretuner_Doc_V1_NodeProps()
        values.text.onPath = props
        builder.append(Ops.set(text, [SetTextOnPath.base.child(4), SetTextOnPath.base.child(5)], values: values))
    }
}

/// TYPE-006 (the Text Block section) and TYPE-043 (the Text on path section and its handle).
@Suite(.serialized) @MainActor struct TextBlockSectionTests {
    static func model(_ document: DocumentHandle, _ nodes: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: document, selection: Selection(nodes.map { SelectionID($0) }))
    }

    @Test func mixedBlocksShowMixedValuesAndAnEditWritesOnlyItsRegister() async throws {
        let document = DocumentHandle.memory(title: "Blocks")
        let fixed = try #require(await document.addText("Body copy", frame: .area(Rect(x: 20, y: 20, width: 120, height: 60))))
        let auto = try #require(await document.addText("Label", at: Point(x: 20, y: 200)))
        let section = try #require(Self.model(document, [fixed, auto]).textBlock)
        #expect(section.nodes == [fixed, auto])
        #expect(section.autoWidth == .mixed && section.autoHeight == .mixed && section.width == nil && section.height == nil)
        #expect(section.insetLeft == 0 && section.displayBorder == .off && section.direction == .horizontal)
        let one = try #require(Self.model(document, [fixed]).textBlock)
        #expect(one.width == 120 && one.height == 60 && one.autoWidth == .off)
        #expect(InspectorRegistry.standard.views(for: Self.model(document, [fixed])).map(\.id).contains("textBlock"))
        // Inset left on both: one change writing only [130, 3, 5, 1] on each block.
        let change = try #require(await Self.model(document, [fixed, auto]).perform(Self.model(document, [fixed, auto]).setInset(.left, 6))?.value)
        #expect(change.label == "Inset" && change.ops.count == 2)
        for op in change.ops {
            guard case .set(let set)? = op.op else { Issue.record("set"); continue }
            #expect(set.paths.map { RegisterPath($0) } == [RegisterPath([130, 3, 5, 1])])
        }
        let after = try #require(Self.model(document, [fixed, auto]).textBlock)
        #expect(after.insetLeft == 6 && after.insetRight == 0)
        #expect(document.undoTitle == "Undo Inset")
        // Every other register, one at a time.
        let fixedModel = Self.model(document, [fixed])
        _ = await fixedModel.perform(fixedModel.setBlockWidth(150))?.value
        _ = await fixedModel.perform(Self.model(document, [fixed]).setBlockHeight(90))?.value
        for side in ObjectPanelModel.InsetSide.allCases {
            _ = await fixedModel.perform(Self.model(document, [fixed]).setInset(side, Double(side.rawValue)))?.value
        }
        _ = await fixedModel.perform(Self.model(document, [fixed]).setDisplayBorder(true))?.value
        _ = await fixedModel.perform(Self.model(document, [fixed]).setDirection(.vertical))?.value
        let block = document.state.props(fixed).text.block
        #expect(block.width == 150 && block.height == 90 && block.displayBorder && block.direction == .vertical)
        #expect(block.inset.left == 1 && block.inset.right == 2 && block.inset.top == 3 && block.inset.bottom == 4)
        #expect(fixedModel.setBlockWidth(0) == nil && fixedModel.setBlockHeight(-1) == nil && fixedModel.setInset(.top, .nan) == nil)
        #expect(ObjectPanelModel.InsetSide.allCases.map(\.title) == ["Left", "Right", "Top", "Bottom"])
        // Not every object a text block: no section, no edits.
        let rect = await document.addRectangles([Rect(x: 300, y: 300, width: 5, height: 5)])[0]
        let mixed = ObjectPanelModel(document: document, selection: Selection([SelectionID(fixed), rect]))
        #expect(mixed.textBlock == nil && mixed.toggleAutoWidth() == nil && mixed.toggleAutoHeight() == nil && mixed.setDisplayBorder(true) == nil)
        #expect(ObjectPanelModel.TextBlockSection.shown(0) == 1 && ObjectPanelModel.TextBlockSection.shown(-3) == 1)
    }

    @Test func autoWidthAndHeightButtonsAreMultiSelectionAware() async throws {
        let document = DocumentHandle.memory(title: "Auto")
        let fixed = try #require(await document.addText("Body copy", frame: .area(Rect(x: 20, y: 20, width: 120, height: 60))))
        let auto = try #require(await document.addText("Label", at: Point(x: 20, y: 200)))
        // Mixed: both become auto-expanding.
        _ = await Self.model(document, [fixed, auto]).perform(Self.model(document, [fixed, auto]).toggleAutoWidth())?.value
        #expect(Self.model(document, [fixed, auto]).textBlock?.autoWidth == .on)
        #expect(document.undoTitle == "Undo Auto Width")
        // All auto: each is fixed at the width it is laid out at.
        let laidOut = try #require(document.textLayout(for: auto)?.sizes.first)
        _ = await Self.model(document, [fixed, auto]).perform(Self.model(document, [fixed, auto]).toggleAutoWidth())?.value
        #expect(Self.model(document, [fixed, auto]).textBlock?.autoWidth == .off)
        #expect(abs(document.state.props(auto).text.block.width - laidOut.width) < 0.001)
        #expect(document.undoTitle == "Undo Fixed Width")
        _ = await Self.model(document, [auto]).perform(Self.model(document, [auto]).toggleAutoHeight())?.value
        #expect(Self.model(document, [auto]).textBlock?.autoHeight == .off, "a label is auto height; the toggle fixes it")
        _ = await Self.model(document, [auto]).perform(Self.model(document, [auto]).toggleAutoHeight())?.value
        #expect(Self.model(document, [auto]).textBlock?.autoHeight == .on)
    }

    @Test func remoteChangesUpdateTheFieldsWithoutStealingTheDraft() async throws {
        let document = DocumentHandle.memory(title: "Remote")
        let block = try #require(await document.addText("Text", frame: .area(Rect(x: 0, y: 0, width: 100, height: 40))))
        let editor = FieldEditor(format: .measure(.points), value: Self.model(document, [block]).textBlock?.insetTop)
        editor.edit("7")
        _ = await document.receiveRemote(SetTextBlock(node: block, block: .with { $0.inset.top = 3 }, fields: [[5, 3]]))
        let remote = try #require(Self.model(document, [block]).textBlock)
        #expect(remote.insetTop == 3, "the section reads the remote value")
        editor.bind(selection: remote.insetTop)
        #expect(editor.text == "7" && editor.remoteChanged, "the draft stays; the field is tinted")
        editor.cancel()
        #expect(editor.text == "3")
    }

    @Test func insetLeftAndInsetRightFromTwoReplicasBothSurvive() async throws {
        let document = DocumentHandle.memory(title: "Merge")
        let block = try #require(await document.addText("Text", frame: .area(Rect(x: 0, y: 0, width: 100, height: 40))))
        _ = await Self.model(document, [block]).perform(Self.model(document, [block]).setInset(.left, 5))?.value
        _ = await document.receiveRemote(SetTextBlock(node: block, block: .with { $0.inset.right = 9 }, fields: [[5, 2]]))
        let inset = document.state.props(block).text.block.inset
        #expect(inset.left == 5 && inset.right == 9)
    }

    @Test func theSectionViewsBindingsWriteThroughTheModel() async throws {
        let document = DocumentHandle.memory(title: "Views")
        let block = try #require(await document.addText("Text", frame: .area(Rect(x: 0, y: 0, width: 100, height: 40))))
        let model = Self.model(document, [block])
        let section = try #require(model.textBlock)
        TextBlockSectionView.width(model)(80)
        await document.settle()
        TextBlockSectionView.height(Self.model(document, [block]))(30)
        await document.settle()
        TextBlockSectionView.inset(Self.model(document, [block]), .bottom)(2)
        await document.settle()
        TextBlockSectionView.displayBorder(section, Self.model(document, [block])).wrappedValue = true
        await document.settle()
        TextBlockSectionView.direction(section, Self.model(document, [block])).wrappedValue = "Vertical"
        await document.settle()
        TextBlockSectionView.direction(section, Self.model(document, [block])).wrappedValue = TextBlockSectionView.mixed
        TextBlockSectionView.autoWidth(Self.model(document, [block]))()
        await document.settle()
        TextBlockSectionView.autoHeight(Self.model(document, [block]))()
        await document.settle()
        let props = document.state.props(block).text.block
        #expect(props.width == 80 && props.height == 30 && props.inset.bottom == 2 && props.displayBorder && props.direction == .vertical)
        #expect(props.autoWidth && props.autoHeight)
        let after = try #require(Self.model(document, [block]).textBlock)
        #expect(TextBlockSectionView.direction(after, model).wrappedValue == "Vertical")
        #expect(!TextBlockSectionView.displayBorder(section, model).wrappedValue, "the binding reads the section it was built from")
        for side in ObjectPanelModel.InsetSide.allCases { _ = TextBlockSectionView.inset(after, side) }
        _ = TextBlockSectionView(section: after, model: Self.model(document, [block])).body
        _ = TextBlockSectionView(section: section, model: model).body
    }

    // MARK: Text on a path

    static func attached(_ document: DocumentHandle, alignment: Wiretuner_Doc_V1_Alignment = .left) async throws -> (text: OpID, path: OpID) {
        let text = try #require(await document.addText("On the path", at: Point(x: 10, y: 10)))
        let path = try #require(await document.addPath([Point(x: 0, y: 100), Point(x: 200, y: 100)]))
        _ = await document.perform(AttachTextToPath(text: text, path: path.opID)).value
        if alignment != .left {
            _ = await document.perform(SetParagraph(node: text, from: .start, to: .end, props: .with { $0.alignment = alignment }, fields: [[1]])).value
        }
        await document.settle()
        return (text, path.opID)
    }

    @Test func eachTextOnPathControlWritesItsRegister() async throws {
        let document = DocumentHandle.memory(title: "Path text")
        let (text, path) = try await Self.attached(document)
        let item = try #require(TextOnPath(text, in: document.state))
        #expect(item.path == path && abs(item.length - 200) < 1e-6)
        let section = try #require(Self.model(document, [text]).textOnPath)
        #expect(section.orientation == .rotate && section.showPath == .off && section.top == .baseline && section.bottom == .baseline)
        #expect(section.offsetStart == 0 && section.offsetEnd == 0)
        #expect(InspectorRegistry.standard.views(for: Self.model(document, [text])).map(\.id).contains("textOnPath"))
        TextOnPathSectionView.orientation(section, Self.model(document, [text])).wrappedValue = "Skew vertical"
        await document.settle()
        TextOnPathSectionView.showPath(section, Self.model(document, [text])).wrappedValue = true
        await document.settle()
        TextOnPathSectionView.alignment(section, Self.model(document, [text]), top: true).wrappedValue = "Ascent"
        await document.settle()
        TextOnPathSectionView.alignment(section, Self.model(document, [text]), top: false).wrappedValue = "Descent"
        await document.settle()
        TextOnPathSectionView.offset(Self.model(document, [text]), start: true)(12)
        await document.settle()
        TextOnPathSectionView.offset(Self.model(document, [text]), start: false)(8)
        await document.settle()
        TextOnPathSectionView.orientation(section, Self.model(document, [text])).wrappedValue = TextOnPathSectionView.mixed
        let props = document.state.props(text).text.onPath
        #expect(props.orientation == .skewVertical && props.showPath && props.top == .ascent && props.bottom == .descent)
        #expect(props.offsetStart == 12 && props.offsetEnd == 8)
        #expect(document.undoTitle == "Undo Right Offset")
        let after = try #require(Self.model(document, [text]).textOnPath)
        #expect(TextOnPathSectionView.orientation(after, Self.model(document, [text])).wrappedValue == "Skew vertical")
        #expect(TextOnPathSectionView.alignment(after, Self.model(document, [text]), top: true).wrappedValue == "Ascent")
        #expect(TextOnPathSectionView.title(Optional<Wiretuner_Doc_V1_PathAlignment>.none, in: TextOnPathSectionView.alignments) == "Mixed")
        #expect(ObjectPanelModel.TextOnPathSection.orientation(.unspecified) == .rotate && ObjectPanelModel.TextOnPathSection.alignment(.unspecified) == .none)
        _ = TextOnPathSectionView(section: after, model: Self.model(document, [text])).body
        // Ordinary blocks, and on_path without a live path child, have no section.
        let plain = try #require(await document.addText("Plain", at: Point(x: 300, y: 300)))
        #expect(Self.model(document, [plain]).textOnPath == nil && Self.model(document, [text, plain]).textOnPath == nil)
        #expect(Self.model(document, [plain]).setShowPath(true) == nil && Self.model(document, [text]).setPathOffset(.infinity, start: true) == nil)
        _ = await document.perform(DeleteNodes([path])).value
        #expect(TextOnPath(text, in: document.state) == nil, "a deleted path leaves an ordinary block")
        var probe = ChangeBuilder.probe
        #expect(throws: TextEditError.self) { try SetTextOnPath(node: path, values: .init(), fields: [3], label: "x").execute(&probe, state: document.state) }
        #expect(throws: TextEditError.self) { try SetTextOnPath(node: text, values: .init(), fields: [], label: "x").execute(&probe, state: document.state) }
    }

    @Test func theTriangleDragsAlongThePath() async throws {
        let document = DocumentHandle.memory(title: "Handle")
        let (text, _) = try await Self.attached(document)
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([SelectionID(text)]))
        let handle = TextPathHandle()
        #expect(handle.items(context).count == 1)
        // The path lives in the text's own space: its start in pasteboard space.
        let x0 = handle.items(context)[0].point(atLength: 0).x
        func offset(_ x: Double) -> Double { x - x0 }
        let tip = TextPathHandle.position(handle.items(context)[0], viewport: context.viewport)
        #expect(!handle.press(CanvasEvent(pasteboardPoint: Point(x: 500, y: 500), viewPoint: Point(x: 500, y: 500)), context: context))
        // Without Option: one change on release, the left offset where the pointer projects.
        #expect(handle.press(CanvasEvent(pasteboardPoint: context.viewport.toPasteboard(tip), viewPoint: tip), context: context))
        handle.drag(TestEvents.point(60, 130), context: context)
        #expect(handle.draggedLength.map { abs($0 - offset(60)) < 0.01 } == true)
        #expect(document.state.props(text).text.onPath.offsetStart == 0, "only the triangle moves while dragging")
        let ctx = DrawingToolTests.bitmap()
        handle.draw(in: ctx, viewport: context.viewport, context: context)
        handle.release(TestEvents.point(70, 90), context: context)
        await document.settle()
        #expect(abs(document.state.props(text).text.onPath.offsetStart - offset(70)) < 0.01)
        #expect(document.undoTitle == "Undo Move Text on Path")
        // With Option: the text moves on every drag event, one undo step for the drag.
        let now = try #require(handle.items(context).first)
        let at = TextPathHandle.position(now, viewport: context.viewport)
        #expect(handle.press(CanvasEvent(pasteboardPoint: context.viewport.toPasteboard(at), viewPoint: at, modifiers: .option), context: context))
        handle.drag(TestEvents.point(100, 100, .option), context: context)
        await document.settle()
        #expect(abs(document.state.props(text).text.onPath.offsetStart - offset(100)) < 0.01, "the text follows the drag")
        handle.drag(TestEvents.point(120, 100, .option), context: context)
        handle.release(TestEvents.point(130, 100, .option), context: context)
        await document.settle()
        try await Task.sleep(for: .milliseconds(20))
        await document.settle()
        #expect(abs(document.state.props(text).text.onPath.offsetStart - offset(130)) < 0.01)
        _ = await document.undo().value
        await document.settle()
        #expect(abs(document.state.props(text).text.onPath.offsetStart - offset(70)) < 0.01, "the Option drag undoes as one step")
        // Esc during a live drag takes back what it wrote.
        let again = TextPathHandle.position(try #require(handle.items(context).first), viewport: context.viewport)
        #expect(handle.press(CanvasEvent(pasteboardPoint: context.viewport.toPasteboard(again), viewPoint: again, modifiers: .option), context: context))
        handle.drag(TestEvents.point(150, 100, .option), context: context)
        await document.settle()
        handle.cancel(context: context)
        try await Task.sleep(for: .milliseconds(20))
        await document.settle()
        #expect(abs(document.state.props(text).text.onPath.offsetStart - offset(70)) < 0.01)
        handle.cancel(context: context)
        handle.drag(TestEvents.point(1, 1), context: context)
        handle.release(TestEvents.point(1, 1), context: context)
    }

    @Test func centredAndRightAlignedTextMoveTheirOffsets() async throws {
        let document = DocumentHandle.memory(title: "Aligned")
        let (right, _) = try await Self.attached(document, alignment: .right)
        let item = try #require(TextOnPath(right, in: document.state))
        #expect(abs(item.handleLength() - 200) < 1e-6)
        #expect(item.offsets(draggedTo: 150) == (start: 0, end: 50))
        let (centred, _) = try await Self.attached(document, alignment: .center)
        let middle = try #require(TextOnPath(centred, in: document.state))
        #expect(abs(middle.handleLength() - 100) < 1e-6)
        let moved = middle.offsets(draggedTo: 130)
        #expect(abs(moved.start - 30) < 1e-6 && abs(moved.end + 30) < 1e-6)
        #expect(middle.point(atLength: 500) == middle.point(atLength: 200), "clamped to the path")
        #expect(abs(middle.arcLength(nearest: middle.point(atLength: 50)) - 50) < 1e-6)
    }

    @Test func concurrentHandleDragsConvergeToTheLaterOffset() async throws {
        let document = DocumentHandle.memory(title: "Merge path text")
        let (text, _) = try await Self.attached(document)
        _ = await document.perform(SetTextOnPath(node: text, values: .with { $0.offsetStart = 20 }, fields: [6, 7], label: "Move Text on Path")).value
        // The remote drag is later (a greater OpId): it wins.
        _ = await document.receiveRemote(SetTextOnPath(node: text, values: .with { $0.offsetStart = 45 }, fields: [6, 7], label: "Move Text on Path"), replica: 0xFFFF)
        #expect(document.state.props(text).text.onPath.offsetStart == 45)
    }
}

extension ChangeBuilder {
    /// A builder to run a command's `execute` against for its refusals.
    static var probe: ChangeBuilder { ChangeBuilder(replica: 1, startCounter: 1) }
}
