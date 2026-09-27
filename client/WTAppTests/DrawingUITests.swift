import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Calligraphic Pen (DRAW-019), the Eraser (DRAW-029), the Chart tool and Chart sheet
/// (DRAW-033) and their installer.
@Suite(.serialized) @MainActor struct DrawingUITests {
    typealias Fixture = DrawingToolTests.Fixture

    // MARK: Calligraphic Pen (DRAW-019)

    @Test func theNibAngleSetsTheWidth() throws {
        // Along a 45° nib: the minimum; across it: the full width.
        #expect(CalligraphicOutline.width(base: 10, direction: Vector(dx: 1, dy: -1), nibAngle: 45) == CalligraphicOutline.minimumWidth)
        #expect(abs(CalligraphicOutline.width(base: 10, direction: Vector(dx: 1, dy: 1), nibAngle: 45) - 10) < 1e-9)
        #expect(CalligraphicOutline.width(base: 10, direction: .zero, nibAngle: 45) == 10)
        // A straight stroke along the nib and one across it, within 0.1 pt.
        for (angle, expected) in [(0.0, CalligraphicOutline.minimumWidth), (90.0, 10.0)] {
            var settings = CalligraphicSettings()
            settings.fixedWidth = 10
            settings.angle = angle
            let captured = settings
            let f = Fixture(CalligraphicPen { captured })
            f.tool.mouseDown(TestEvents.point(0, 50))
            for x in stride(from: 5.0, through: 200, by: 5) { f.tool.mouseDragged(TestEvents.point(x, 50)) }
            let outline = try #require(f.tool.outline())
            let widths = PathEditingToolTests.halfWidths(outline, from: 20, to: 180).map { $0 * 2 }
            #expect(!widths.isEmpty && widths.allSatisfy { abs($0 - expected) < 0.1 }, "angle \(angle): \(widths.prefix(3))")
            f.tool.cancel()
        }
        #expect(CalligraphicOutline.outline(centerline: [], samples: []) == nil)
        #expect(CalligraphicOutline.outline(centerline: [VectorPoint(anchor: .zero), VectorPoint(anchor: .zero)], samples: []) == nil)
    }

    @Test func bracketsChangeAVariableNibAndNotAFixedOne() async throws {
        var variable = CalligraphicSettings()
        variable.variable = true
        variable.removeOverlap = true
        variable.dotted = true
        let nib = variable
        let f = Fixture(CalligraphicPen { nib })
        #expect(f.host.messages.last == CalligraphicPen.statusMessage)
        f.tool.mouseDown(TestEvents.point(0, 50))
        f.tool.mouseDragged(TestEvents.point(20, 60))
        #expect(f.tool.keyDown(TestEvents.key("]", keyCode: 30)))
        f.tool.mouseDragged(TestEvents.point(40, 70))
        #expect(f.tool.bases.last == f.tool.bases.first! + 1, "the bracket widens from the next sample")
        f.tool.mouseDragged(TestEvents.point(60, 50, .option))
        f.tool.mouseDragged(TestEvents.point(80, 55, [.option, .shift]))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(TestEvents.point(100, 50))
        await f.tool.cleanup?.value
        await f.document.settle()
        #expect(f.created?.path?.contours.first?.closed == true)
        // Pressure drives a variable nib.
        f.tool.mouseDown(PathEditingToolTests.tablet(0, 100, pressure: 1))
        #expect(f.tool.bases == [variable.max])
        f.tool.cancel()
        let fixed = Fixture(CalligraphicPen { CalligraphicSettings() })
        fixed.tool.mouseDown(TestEvents.point(0, 50))
        #expect(!fixed.tool.keyDown(TestEvents.key("]", keyCode: 30)), "a fixed nib ignores the keys")
        #expect(fixed.tool.bases == [CalligraphicSettings().fixedWidth])
        fixed.tool.mouseUp(TestEvents.point(0, 50))
        fixed.tool.pointerMoved(TestEvents.point(0, 0))
        fixed.tool.flagsChanged(TestEvents.point(0, 0))
        fixed.tool.mouseDragged(TestEvents.point(1, 1))
        fixed.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: fixed.host.viewport)
        #expect(!fixed.tool.hasSomethingToCancel && fixed.tool.command() == nil)
        fixed.tool.deactivate()
        #expect(fixed.tool.outline() == nil)
    }

    // MARK: Eraser (DRAW-029)

    @Test func erasingThroughTheMiddleOfAnOpenPathLeavesTwoPieces() async throws {
        let document = DocumentHandle.memory(title: "Erase")
        let path = try #require(await document.addPath([Point(x: 0, y: 50), Point(x: 200, y: 50)]))
        let f = Fixture(EraserTool { EraserSettings(min: 10, max: 10) }, document: document)
        f.selection.model.set(Selection([path]))
        f.tool.mouseDown(TestEvents.point(100, 0))
        f.tool.mouseDragged(TestEvents.point(100, 50))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(TestEvents.point(100, 100))
        await document.settle()
        let paths = document.state.store.nodes.filter { document.state.nodeKind($0) == .path && document.state.isLive($0) }
        #expect(paths.count == 2 && document.undoTitle == "Undo Erase")
        let ends = paths.compactMap { document.object(for: SelectionID($0))?.path?.contours.first?.drawn.map { Objects.pasteboardTransform(of: $0.id, in: document.state).apply($0.anchor).x } }
        let inner = ends.flatMap { $0 }.filter { $0 > 50 && $0 < 150 }.sorted()
        #expect(inner.count == 2 && abs(inner[0] - 95) < 0.1 && abs(inner[1] - 105) < 0.1, "\(ends)")
        #expect(f.tool.command() == nil && !f.tool.hasSomethingToCancel)
    }

    @Test func bracketsChangeTheEraserMidDragAndPressureOverridesThem() async throws {
        let document = DocumentHandle.memory(title: "Erase")
        let first = try #require(await document.addPath([Point(x: 0, y: 50), Point(x: 400, y: 50)]))
        let second = try #require(await document.addPath([Point(x: 0, y: 150), Point(x: 400, y: 150)]))
        let f = Fixture(EraserTool { EraserSettings(min: 2, max: 20) }, document: document)
        f.selection.model.set(Selection([first, second]))
        f.tool.mouseDown(TestEvents.point(0, 0))
        let before = f.tool.samples.last!.width
        #expect(f.tool.keyDown(TestEvents.key("]", keyCode: 30)) && !f.tool.keyDown(TestEvents.key("x", keyCode: 7)))
        f.tool.mouseDragged(TestEvents.point(10, 10))
        #expect(f.tool.samples.last!.width == before + 1)
        f.tool.mouseDragged(PathEditingToolTests.tablet(20, 20, pressure: 1))
        #expect(f.tool.samples.last!.width == 20, "a pen in contact overrides the keys")
        #expect(f.tool.keyDown(TestEvents.key("[", keyCode: 33)) && f.tool.width.keyWidth == before + 1, "ignored while the pen is down")
        f.tool.mouseDragged(PathEditingToolTests.tablet(100, 200, pressure: 1))
        f.tool.mouseUp(PathEditingToolTests.tablet(100, 220, pressure: 1))
        await document.settle()
        #expect(document.undoTitle == "Undo Erase")
        // Nothing crossed, nothing written; the strip's edges of a single sample are the point.
        f.tool.mouseDown(TestEvents.point(500, 500))
        f.tool.mouseUp(TestEvents.point(510, 510))
        #expect(EraserStrip.edges([VariableStrokeOutline.Sample(point: .zero, width: 2)]).left == [.zero])
        #expect(EraserStrip.erase([VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 1, y: 0))], closed: false, samples: []) == nil)
        #expect(EraserStrip.halfWidth(near: .zero, samples: []) == 0)
        let coincident = EraserStrip.edges([VariableStrokeOutline.Sample(point: .zero, width: 2), VariableStrokeOutline.Sample(point: .zero, width: 2),
                                            VariableStrokeOutline.Sample(point: Point(x: 1, y: 0), width: 2)])
        #expect(coincident.left.count == 3)
        f.tool.pointerMoved(TestEvents.point(0, 0))
        f.tool.flagsChanged(TestEvents.point(0, 0))
        f.tool.mouseDragged(TestEvents.point(0, 0))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.deactivate()
        #expect(f.tool.command() == nil)
        let preferences = PreferenceStore(defaults: TestDefaults().defaults)
        #expect(EraserSettings(preferences: preferences).max == 12 && CalligraphicSettings(preferences: preferences).angle == 45)
    }

    // MARK: Chart tool and sheet (DRAW-033)

    @Test func theChartToolDragsAChartAndOpensTheSheet() async throws {
        let document = DocumentHandle.memory(title: "Chart")
        var opened: [OpID] = []
        let f = Fixture(ChartTool { opened.append($0) }, document: document)
        #expect(f.host.messages.last == ChartTool.statusMessage)
        f.tool.mouseDown(TestEvents.point(10, 10))
        f.tool.mouseDragged(TestEvents.point(110, 60, .shift))
        #expect(f.tool.rect == Rect(x: 10, y: 10, width: 100, height: 100))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(TestEvents.point(110, 60))
        await f.tool.creation?.value
        let chart = try #require(opened.first)
        #expect(document.state.nodeKind(chart) == .chart && document.state.props(chart).chart.size.width == 100)
        // Too small a drag makes nothing.
        f.tool.mouseDown(TestEvents.point(0, 0))
        f.tool.mouseUp(TestEvents.point(1, 1))
        f.tool.mouseDragged(TestEvents.point(2, 2))
        f.tool.flagsChanged(TestEvents.point(0, 0))
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)) && f.tool.rect == nil && !f.tool.hasSomethingToCancel)
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.deactivate()
    }

    @Test func theSheetEntersImportsTransposesAndChangesTheType() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try #require(await world.document.perform(CreateChart(size: Size(width: 200, height: 120))).value?.createdObjects.first)
        let model = ChartSheetModel(chart: chart, document: world.document, sink: world.window.objectEditing)
        #expect(model.isLive && model.grid == [["", ""]] && model.entry == "")
        // Enter a small table: labels across the top, one category.
        let cells: [(Int, Int, String)] = [(0, 1, "Q1"), (0, 2, "Q2"), (1, 0, "North"), (1, 1, "12"), (1, 2, "15")]
        for (row, column, text) in cells {
            model.active = ChartSheetModel.Position(row: row, column: column)
            model.entry = text
            await model.commit().value
        }
        #expect(model.model.grid == [["", "Q1", "Q2"], ["North", "12", "15"]])
        #expect(model.active == ChartSheetModel.Position(row: 2, column: 2) && world.document.undoTitle == "Undo Edit Chart Data")
        // The sheet's Undo reverts the last entry.
        await model.undo()?.value
        #expect(model.text(at: ChartSheetModel.Position(row: 1, column: 2)) == "")
        #expect(model.undo() != nil)
        // A remote cell arrives without disturbing the draft.
        model.active = ChartSheetModel.Position(row: 1, column: 1)
        model.entry = "draft"
        let current = model.model
        await world.document.receiveRemote(SetChartCell(chart, row: current.rows[0], column: current.columns[1], text: "Spring"))
        #expect(model.model.grid[0][1] == "Spring" && model.entry == "draft")
        // Import: tab-delimited text laid from the active cell, one change.
        model.active = ChartSheetModel.Position(row: 2, column: 0)
        await model.importText("South\t7\t9\nEast\t3\t4\n").value
        #expect(model.model.grid.count == 4 && model.model.grid[3] == ["East", "3", "4"] && world.document.undoTitle == "Undo Import Chart Data")
        let file = TestEnvironment.temporaryDirectory().appendingPathExtension("txt")
        try "West\t1\t2".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        model.active = ChartSheetModel.Position(row: 4, column: 0)
        await model.importFile(file)?.value
        #expect(model.model.grid.last == ["West", "1", "2"])
        #expect(model.importFile(URL(fileURLWithPath: "/nonexistent/chart.txt")) == nil && model.message != nil)
        // Transpose and Switch XY write their flags only.
        _ = await model.transpose().value
        #expect(model.model.props.transposed && world.document.undoTitle == "Undo Transpose")
        _ = await model.switchXY().value
        #expect(model.model.props.switchXy)
        // Copy, cut and paste cells.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uid-chart-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        model.pasteboard = pasteboard
        model.select(ChartSheetModel.Position(row: 3, column: 1))
        model.select(ChartSheetModel.Position(row: 3, column: 2), extending: true)
        #expect(model.copy() == "3\t4")
        await model.cut().value
        #expect(model.model.grid[3] == ["East", "", ""])
        model.select(ChartSheetModel.Position(row: 3, column: 1))
        await model.paste()?.value
        #expect(model.model.grid[3] == ["East", "3", "4"])
        pasteboard.clearContents()
        #expect(model.paste() == nil)
        model.move(rows: -10, columns: 1)
        #expect(model.active == ChartSheetModel.Position(row: 0, column: 2))
        model.resize(column: 1, to: 1000)
        #expect(model.width(of: 1) == 400 && model.width(of: 0) == ChartSheetModel.defaultColumnWidth)
        // The Type tab: drafts until Apply; only changed registers are written.
        model.type = .pie
        model.options.dataNumbers = true
        model.xAxis.suffix = "%"
        model.yAxis.manual = true
        model.decimalPrecision = 1
        model.thousandsSeparator = true
        #expect(!model.axesEnabled && !model.isScatter)
        let pending = model.pending
        #expect(pending.type == .pie && pending.options?.dataNumbers == true && pending.decimalPrecision == 1)
        await model.apply().value
        let props = model.model.props
        #expect(props.type == .pie && props.options.dataNumbers && props.xAxis.suffix == "%" && props.yAxis.manual && props.decimalPrecision == 1 && props.thousandsSeparator)
        #expect(model.pending == SetChartFields.Values())
        await model.apply().value
        model.type = .scatter
        model.cancel()
        #expect(model.type == .pie)
        // Apply with an entry draft commits it.
        model.active = ChartSheetModel.Position(row: 0, column: 0)
        model.entry = "Region"
        await model.apply().value
        await model.last?.value
        #expect(model.text(at: ChartSheetModel.Position(row: 0, column: 0)) == "Region")
        #expect(ChartSheetModel.types.map { ChartSheetModel.renderType($0.type) } == ChartType.allCases)
        #expect(ChartSheetModel.Tab.type.title == "Type" && ChartSheetModel.Tab.data.id == "data")
    }

    @Test func twoReplicasTypingInOneCellConverge() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try #require(await world.document.perform(CreateChart(size: Size(width: 100, height: 100))).value?.createdObjects.first)
        let model = ChartSheetModel(chart: chart, document: world.document, sink: world.window.objectEditing)
        model.entry = "1"
        await model.commit().value
        let current = model.model
        _ = await world.window.objectEditing.perform(SetChartCell(chart, row: current.rows[0], column: current.columns[0], text: "2")).value
        await world.document.receiveRemote(SetChartCell(chart, row: current.rows[0], column: current.columns[0], text: "3"))
        #expect(["2", "3"].contains(model.text(at: ChartSheetModel.Position(row: 0, column: 0))))
    }

    @Test func theSheetViewsAndTheFeatures() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try #require(await world.document.perform(CreateChart(size: Size(width: 100, height: 100))).value?.createdObjects.first)
        let model = ChartSheetModel(chart: chart, document: world.document, sink: world.window.objectEditing, tab: .type)
        var closed = 0
        PanelRendering.host(ChartSheetView(model: model) { closed += 1 })
        model.tab = .data
        PanelRendering.host(ChartSheetView(model: model) { closed += 1 })
        var axis = Wiretuner_Doc_V1_AxisOptions()
        axis.manual = true
        PanelRendering.host(ChartAxisSheet(axis: Binding(get: { axis }, set: { axis = $0 }), title: "X Axis") {})
        ChartSheetView.selecting(ChartSheetModel.Position(row: 1, column: 1), model)()
        ChartSheetView.moving(1, 0, model)()
        #expect(model.active == ChartSheetModel.Position(row: 2, column: 1))
        model.entry = "5"
        ChartSheetView.committing(model)()
        await model.last?.value
        ChartSheetView.importing(model) { nil }()
        let board = NSPasteboard(name: NSPasteboard.Name("uid-chart-actions-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.pasteboard = board
        for action in ChartSheetView.Action.allCases {
            ChartSheetView.action(action, model)()
            await model.last?.value
            await world.document.settle()
        }
        ChartSheetView.finishing(model) { closed += 1 }()
        ChartSheetView.cancelling(model) { closed += 1 }()
        #expect(closed == 2)
        let type = ChartSheetView.typeBinding(model)
        type.wrappedValue = .line
        #expect(model.type == .line)
        let x = ChartSheetView.axisBinding(.x, model), y = ChartSheetView.axisBinding(.y, model)
        x.wrappedValue = .with { $0.prefix = "$" }
        y.wrappedValue = .with { $0.suffix = "%" }
        #expect(model.xAxis.prefix == "$" && model.yAxis.suffix == "%" && x.wrappedValue.prefix == "$" && y.wrappedValue.suffix == "%")
        var choice: ChartSheetView.AxisChoice?
        ChartSheetView.opening(.y, Binding(get: { choice }, set: { choice = $0 }))()
        #expect(choice?.id == "y")
        // The features: the selected chart, the menu items, the sheet, the tool's double-click.
        world.window.selection.model.clear()
        let commands = ChartFeatures.commands { [weak window = world.window] in window }
        #expect(commands.map(\.title) == ["Edit Data…", "Chart Type…"] && !commands[0].validation().isEnabled)
        world.window.selection.model.set(Selection([SelectionID(chart)]))
        #expect(ChartFeatures.selectedChart(in: world.window) == chart && commands[1].validation().isEnabled && ChartFeatures.selectedChart(in: nil) == nil)
        for command in commands {
            if case .perform(let run) = command.action { run() }
            if let sheet = world.window.window?.attachedSheet { world.window.window?.endSheet(sheet) }
        }
        var previous: [ToolID] = []
        let options = ChartFeatures.toolOptions(window: { [weak window = world.window] in window }) { previous.append($0.id) }
        let descriptor = ChartFeatures.descriptor { [weak window = world.window] in window }
        options(descriptor)
        if let sheet = world.window.window?.attachedSheet { world.window.window?.endSheet(sheet) }
        options(ToolCatalog.all[0])
        #expect(previous == [ToolCatalog.all[0].id])
        let tool = try #require(descriptor.make() as? ChartTool)
        tool.openSheet(chart)
        if let sheet = world.window.window?.attachedSheet { world.window.window?.endSheet(sheet) }
        let delivered = DrawingToolDelivery.descriptors(store: world.setup.environment.preferences) { [weak window = world.window] in window }
        #expect(delivered.map(\.id) == [CalligraphicPen.id, EraserTool.id, ChartTool.id])
        for item in delivered.prefix(2) {
            #expect(item.options?() != nil)
            _ = item.make()
        }
    }
}
