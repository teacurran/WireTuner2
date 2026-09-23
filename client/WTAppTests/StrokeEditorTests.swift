import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-006 (Basic stroke editor) and ATTR-015 (Calligraphic, Custom and Pattern stroke editors).
@Suite @MainActor struct StrokeEditorTests {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)

    static func presets() -> StrokePresetStore {
        StrokePresetStore(directory: TestEnvironment.temporaryDirectory())
    }

    /// The stroke editor of the fixture's stroke row (stack index 1).
    static func model(_ fixture: AttributeFixture, beep: @escaping @MainActor () -> Void = {}, presets: StrokePresetStore = presets(),
                      ids: [SelectionID]? = nil) -> StrokeEditorModel {
        StrokeEditorModel(context: fixture.context(1, ids: ids, beep: beep), presets: presets, widthPresets: ["0.5", "1", "x", "-2", "1", "99999"],
                          pasteboard: fixture.pasteboard)
    }

    static func perform(_ command: (any WTModel.Command)?, _ fixture: AttributeFixture) async {
        _ = await fixture.document.perform(command!).value
    }

    static func basic(_ fixture: AttributeFixture) -> Wiretuner_Doc_V1_BasicStroke {
        fixture.stack()[1].stroke.settings.basic
    }

    @Test func everyBasicControlWritesTheModel() async throws {
        let fixture = await AttributeFixture.make()
        var beeps = 0
        var model = Self.model(fixture) { beeps += 1 }
        #expect(model.kind == .basic && model.basicWidth == 1 && model.cap == .butt && model.join == .miter && model.miterLimit == 4)
        #expect(model.widthChoices == [0, 0.5, 1], "Hairline first, unreadable and out-of-range presets dropped")

        await Self.perform(model.setBasicColor(Self.red), fixture)
        #expect(Self.basic(fixture).color == Self.red && fixture.document.undoTitle == "Undo Change stroke color")
        await Self.perform(model.setBasicWidth(2), fixture)
        #expect(Self.basic(fixture).width == 2)
        // Typing: units, Hairline, the maximum clamps with a beep, garbage beeps.
        #expect(model.width(from: "Hairline", current: 2) == 0)
        #expect(model.width(from: "1in", current: 2) == 72)
        #expect(model.width(from: "20000", current: 2) == StrokeEditorModel.maximumWidth && beeps == 1)
        #expect(model.width(from: "abc", current: nil) == nil && beeps == 2)
        #expect(model.width(from: "-3", current: 2) == nil && beeps == 3)
        await Self.perform(model.setBasicWidth(99_999), fixture)
        #expect(Self.basic(fixture).width == StrokeEditorModel.maximumWidth && beeps == 4)
        await Self.perform(model.setCap(.round), fixture)
        await Self.perform(model.setJoin(.bevel), fixture)
        await Self.perform(model.setMiterLimit(90), fixture)
        await Self.perform(model.setBasicOverprint(true), fixture)
        let basic = Self.basic(fixture)
        #expect(basic.cap == .round && basic.join == .bevel && basic.miterLimit == 57 && basic.overprint)
        await Self.perform(model.setMiterLimit(0), fixture)
        model = Self.model(fixture)
        #expect(model.miterLimit == 1 && model.basicOverprint == true && model.basicColor == Self.red && model.cap == .round && model.join == .bevel)

        // The width field commits typed text.
        WidthField.commit("3 pt", model: model, value: model.basicWidth) { model.setBasicWidth($0) }
        await fixture.document.settle()
        #expect(Self.basic(fixture).width == 3)
        WidthField.commit("oops", model: model, value: 3) { model.setBasicWidth($0) }
        await fixture.document.settle()
        #expect(Self.basic(fixture).width == 3)
    }

    @Test func dashesAreCopiedAndTheEditorSavesCustomOnes() async throws {
        let fixture = await AttributeFixture.make()
        let presets = Self.presets()
        var model = Self.model(fixture, presets: presets)
        #expect(model.dashChoice == nil && model.dashChoices.count == DashPreset.builtIns.count)
        let long = try #require(model.dashChoices.first { $0.name == "Long" })
        await Self.perform(model.setDash(long), fixture)
        #expect(Self.basic(fixture).dash.lengths == [8, 4] && Self.basic(fixture).dash.name == "Long")
        model = Self.model(fixture, presets: presets)
        #expect(model.dashChoice == long)
        await Self.perform(model.setDash(nil), fixture)
        #expect(Self.basic(fixture).dash.lengths.isEmpty)

        // The Dash Editor: pairs up to the first empty one; OK saves on this Mac and applies.
        var editor = DashEditorModel(lengths: [5, 2, 1])
        #expect(editor.on == ["5", "1", "", ""] && editor.off == ["2", "", "", ""])
        #expect(editor.lengths == [5, 2, 1, 0])
        editor.off[1] = "x"
        #expect(editor.lengths == nil && editor.choice == nil)
        editor = DashEditorModel()
        #expect(editor.lengths == nil, "no lengths at all")
        editor.on[0] = "6"
        editor.off[0] = "3"
        let choice = try #require(editor.choice)
        #expect(choice.name == "6-3" && DashEditorModel.length("-1") == nil)
        await Self.perform(model.applyEditedDash(choice), fixture)
        #expect(Self.basic(fixture).dash.lengths == [6, 3] && presets.dashes == [choice])
        presets.add(choice)
        #expect(presets.dashes.count == 1, "saved once")
        // A dash used in the document but not saved still lists; a reloaded store reads the file.
        #expect(StrokePresetStore(directory: presets.directory).dashes == [choice])
        presets.removeDash(at: 0)
        presets.removeDash(at: 5)
        #expect(presets.dashes.isEmpty)
        model = Self.model(fixture, presets: presets)
        #expect(model.dashChoices.contains(choice), "the document's own dash is offered")
        var unnamed = choice.pattern
        unnamed.name = ""
        _ = await fixture.document.perform(EditAttribute.stroke(model.pairs, "Change dash", [AttributeFields.Basic.dash]) { $0.basic.dash = unnamed }).value
        #expect(StrokeEditorModel.documentDashes(fixture.document.state).map(\.name) == ["6-3"])

        // The pop-up's actions: plain applies, Option opens the editor on that dash.
        var opened: DashEditorModel?
        StrokeEditorView.chooseDash(long, option: true, model: model) { opened = $0 }
        #expect(opened == DashEditorModel(lengths: [8, 4]))
        StrokeEditorView.chooseDash(long, option: false, model: model) { opened = $0 }
        await fixture.document.settle()
        #expect(Self.basic(fixture).dash.lengths == [8, 4])
        #expect(!StrokeEditorView.optionHeld)
        var applied: DashChoice?
        DashEditorSheet.ok(editor) { applied = $0 }()
        #expect(applied == choice)
        var sheet: DashEditorModel? = editor
        let binding = StrokeEditorView.dashBinding(Binding(get: { sheet }, set: { sheet = $0 }))
        #expect(binding.wrappedValue?.model == editor && binding.wrappedValue?.id == 0)
        binding.wrappedValue = nil
        #expect(sheet == nil && binding.wrappedValue == nil)
    }

    @Test func arrowheadsAreCopiedIntoTheStroke() async throws {
        let fixture = await AttributeFixture.make()
        let presets = Self.presets()
        var model = Self.model(fixture, presets: presets)
        #expect(StrokeEditorModel.title(model.startArrowhead) == "None" && StrokeEditorModel.title(nil) == "None")
        let choices = model.arrowheadChoices
        #expect(choices.map(\.name) == Arrowhead.builtIns.map(\.name))
        await Self.perform(model.setArrowhead(choices[0], end: true), fixture)
        await Self.perform(model.setArrowhead(choices[2], end: false), fixture)
        #expect(Self.basic(fixture).endArrowhead == choices[0] && Self.basic(fixture).startArrowhead == choices[2])
        model = Self.model(fixture, presets: presets)
        #expect(StrokeEditorModel.title(model.endArrowhead) == "Triangle")
        await Self.perform(model.setArrowhead(nil, end: true), fixture)
        #expect(Self.basic(fixture).endArrowhead.contours.isEmpty)
        // A custom head saved on this Mac, and one found only in the document.
        var custom = choices[3]
        custom.name = ""
        custom.contours[0].points.removeLast()
        presets.add(custom)
        presets.add(custom)
        #expect(presets.arrowheads.count == 1 && StrokePresetStore(directory: presets.directory).arrowheads == [custom])
        #expect(StrokeEditorModel.title(custom) == "Custom")
        #expect(Self.model(fixture, presets: presets).arrowheadChoices.count == choices.count + 1)
        presets.removeArrowhead(at: 0)
        presets.removeArrowhead(at: 3)
        await Self.perform(model.setArrowhead(custom, end: false), fixture)
        #expect(Self.model(fixture, presets: presets).arrowheadChoices.last == custom)
        #expect(StrokeEditorModel.documentArrowheads(fixture.document.state) == [custom])
    }

    @Test func mergedWidthAndDashShowInTheEditor() async throws {
        let fixture = await AttributeFixture.make()
        let model = Self.model(fixture)
        // Replica A (this document) edits the width while replica B edits the dash of the same stroke.
        let remote = EditAttribute.stroke(model.pairs, "Change dash", [AttributeFields.Basic.dash]) { $0.basic.dash = DashChoice(name: "Medium", lengths: [4, 2]).pattern }
        var other = DocumentCore(state: fixture.document.state, replica: 0xBEEF)
        let outcome = try other.perform(remote, recording: DocumentCore.Recording(limit: 10, now: Date()))
        await Self.perform(model.setBasicWidth(5), fixture)
        _ = await fixture.document.receive(try #require(outcome?.change)).value
        let merged = Self.model(fixture)
        #expect(merged.basicWidth == 5 && merged.dash?.lengths == [4, 2])
    }

    @Test func kindSwitchingKeepsEachKindsSettings() async throws {
        let fixture = await AttributeFixture.make()
        var model = Self.model(fixture)
        await Self.perform(model.setBasicWidth(3), fixture)
        for (kind, _) in StrokeEditorModel.kinds {
            await Self.perform(Self.model(fixture).setKind(kind), fixture)
            #expect(Self.model(fixture).kind == kind)
            AttributeFixture.render(StrokeEditorView(model: Self.model(fixture)))
        }
        model = Self.model(fixture)
        await Self.perform(model.setPatternWidth(9), fixture)
        await Self.perform(model.setKind(.basic), fixture)
        #expect(Self.basic(fixture).width == 3)
        await Self.perform(Self.model(fixture).setKind(.pattern), fixture)
        #expect(Self.model(fixture).patternWidth == 9, "the Pattern settings came back")
    }

    @Test func calligraphicNibFieldsAndThePasteboard() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.calligraphic), fixture)
        var model = Self.model(fixture)
        #expect(model.nibWidth == 4 && model.nibHeight == 1 && model.nibAngle == 45 && model.nib.isEmpty)
        #expect(model.nibPreview.width > 0, "the ellipse")
        await Self.perform(model.setNib(width: 12, height: 3), fixture)
        await Self.perform(model.setNib(angle: 30), fixture)
        await Self.perform(model.setCalligraphicColor(Self.red), fixture)
        model = Self.model(fixture)
        #expect(model.nibWidth == 12 && model.nibHeight == 3 && model.nibAngle == 30 && model.calligraphicColor == Self.red)
        #expect(fixture.document.undoTitle == "Undo Change stroke color")

        // Paste In refuses an empty pasteboard and anything but one closed path, with a message.
        #expect(StrokeEditorView.paste(model) == PasteInError.empty.message)
        let open = await fixture.document.addPath([Point(x: 0, y: 0), Point(x: 5, y: 5)])!
        fixture.pasteboard.write(ClipboardPayload(copying: [open.opID], from: fixture.document.state).encoded())
        #expect(StrokeEditorView.paste(model) == PasteInError.notOneClosedPath.message)
        let triangle = await fixture.document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 5, y: 8)], closed: true)!
        fixture.pasteboard.write(ClipboardPayload(copying: [triangle.opID], from: fixture.document.state).encoded())
        #expect(StrokeEditorView.paste(model) == nil)
        await fixture.document.settle()
        model = Self.model(fixture)
        #expect(model.nib.count == 1 && model.nib[0].points.count == 3 && fixture.document.undoTitle == "Undo Paste In")
        // Copy Out puts the nib on the pasteboard at its size.
        model.copyNib()
        let payload = try #require(fixture.pasteboard.read().flatMap(ClipboardPayload.init(decoding:)))
        #expect(payload.nodes.count == 1)
        #expect(model.nibPreview.width > 0)
        var nowhere = model
        nowhere.pasteboard = nil
        if case .failure(let error) = nowhere.pasteNib() { #expect(error == .empty) } else { Issue.record("no pasteboard") }
        AttributeFixture.render(StrokeEditorView(model: model))
    }

    @Test func customAndPatternAndBrushControls() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.custom), fixture)
        var model = Self.model(fixture)
        await Self.perform(model.setCustomPattern(.neon), fixture)
        await Self.perform(model.setCustomColor(Self.red), fixture)
        await Self.perform(model.setCustom(width: 8), fixture)
        await Self.perform(model.setCustom(length: 12), fixture)
        await Self.perform(model.setCustom(spacing: -2), fixture)
        model = Self.model(fixture)
        #expect(model.customPattern == .neon && model.customColor == Self.red && model.customWidth == 8 && model.customLength == 12
                && model.customSpacing == 0)
        #expect(model.preview != nil)

        await Self.perform(model.setKind(.pattern), fixture)
        model = Self.model(fixture)
        await Self.perform(model.setPatternColor(Self.red), fixture)
        await Self.perform(model.setBitmap([0xFF]), fixture)
        model = Self.model(fixture)
        #expect(model.patternColor == Self.red && model.bitmap == [0xFF, 0, 0, 0, 0, 0, 0, 0])
        #expect(StrokeEditorModel.renderColor(nil) == .black && StrokeEditorModel.renderColor(Self.red) == RenderColor(red: 1, green: 0, blue: 0))

        await Self.perform(model.setKind(.brush), fixture)
        model = Self.model(fixture)
        await Self.perform(model.setBrushWidth(1000), fixture)
        await Self.perform(model.setBrushColor(Self.red), fixture)
        model = Self.model(fixture)
        #expect(model.brushWidth == 400 && model.brushColor == Self.red)
        AttributeFixture.render(StrokeEditorView(model: model))
    }

    @Test func mixedStrokesReadMixed() async throws {
        let fixture = await AttributeFixture.make(2)
        let first = Self.model(fixture, ids: [fixture.ids[0]])
        await Self.perform(first.setKind(.custom), fixture)
        let both = Self.model(fixture)
        #expect(both.kind == nil && both.customPattern == nil)
        AttributeFixture.render(StrokeEditorView(model: both))
        #expect(AttributeColorControl.caption(nil) == "Mixed" && AttributeColorControl.caption(ColorBridge.none) == "None"
                && AttributeColorControl.caption(Self.red).isEmpty)
    }

    @Test func presetSheetsAndStoreFiles() async throws {
        var removed: [Int] = []
        ManagePresetsSheet.delete(2) { removed.append($0) }()
        #expect(removed == [2])
        AttributeFixture.render(ManagePresetsSheet(title: "Manage Dashes", names: [], remove: { _ in }, done: {}))
        AttributeFixture.render(ManagePresetsSheet(title: "Manage Dashes", names: ["6-3"], remove: { _ in }, done: {}))
        AttributeFixture.render(DashEditorSheet(model: DashEditorModel(lengths: [4, 2]), apply: { _ in }, cancel: {}))
        #expect(StrokePresetStore.defaultDirectory.path.hasSuffix("WireTuner/Presets"))
        #expect(StrokePresetStore.shared.directory == StrokePresetStore.defaultDirectory)
        #expect(DashChoice.name(for: [1.5, 2]) == "1.5-2")
    }

    @Test func theControlsActionsWriteThroughTheModel() async throws {
        let fixture = await AttributeFixture.make()
        let model = Self.model(fixture)
        model.context.committing(model.setCap)(.square)
        await fixture.document.settle()
        #expect(Self.basic(fixture).cap == .square)
        StrokeEditorView.arrowheadAction(model.arrowheadChoices[1], end: true, model: model)()
        await fixture.document.settle()
        #expect(Self.basic(fixture).endArrowhead.name == "Open")
        var opened: DashEditorModel?
        StrokeEditorView.dashAction(nil, model: model, option: { true }) { opened = $0 }()
        #expect(opened == DashEditorModel())
        StrokeEditorView.dashAction(model.dashChoices[0], model: model, option: { false }) { opened = $0 }()
        await fixture.document.settle()
        #expect(Self.basic(fixture).dash.name == "Dotted")
        _ = StrokeEditorView.dashAction(nil, model: model) { _ in }
        StrokeEditorView.unavailable()
        WidthField.preset(8, model: model, command: model.setBasicWidth)()
        await fixture.document.settle()
        #expect(Self.basic(fixture).width == 8)
        WidthField.committing(model: model, value: 8, command: model.setBasicWidth)("Hairline")
        await fixture.document.settle()
        #expect(Self.basic(fixture).width == 0)
        for command in [model.setNibWidth(3), model.setNibHeight(2), model.setNibAngle(10), model.setCustomWidth(4), model.setCustomLength(5),
                        model.setCustomSpacing(6)] {
            _ = await fixture.document.perform(command).value
        }
        let settings = fixture.stack()[1].stroke.settings
        #expect(settings.calligraphic.width == 3 && settings.calligraphic.height == 2 && settings.calligraphic.angle == 10)
        #expect(settings.custom.width == 4 && settings.custom.length == 5 && settings.custom.spacing == 6)
    }

    @Test func mixedBasicStrokesRender() async throws {
        let fixture = await AttributeFixture.make(2)
        let first = Self.model(fixture, ids: [fixture.ids[0]])
        await Self.perform(first.setDash(DashChoice(name: "Long", lengths: [8, 4])), fixture)
        let both = Self.model(fixture)
        #expect(both.dash == nil && both.dashChoice == nil)
        AttributeFixture.render(StrokeEditorView(model: both))
        AttributeFixture.render(StrokeEditorView(model: Self.model(fixture, ids: [fixture.ids[1]])))
        var picked: Wiretuner_Doc_V1_ColorRef?
        AttributeColorControl.none { picked = $0 }()
        #expect(picked == ColorBridge.none)
        var slid: Double?
        AttributeSlider.clamping(0...10) { slid = $0 }(30)
        #expect(slid == 10)
        let context = AttributeEditorContext(document: fixture.document, item: both.context.item, entries: both.context.entries)
        context.beep()
    }

    @Test func thePresetSheetsActOnTheStore() async throws {
        let fixture = await AttributeFixture.make()
        let presets = Self.presets()
        let model = Self.model(fixture, presets: presets)
        presets.add(DashChoice(name: "6-3", lengths: [6, 3]))
        presets.add(model.arrowheadChoices[0])
        var closed = 0
        let dashes = StrokeEditorView.presetsSheet(arrowheads: false, model: model) { closed += 1 }
        #expect(dashes.names == ["6-3"])
        dashes.remove(0)
        let heads = StrokeEditorView.presetsSheet(arrowheads: true, model: model) { closed += 1 }
        #expect(heads.names == ["Triangle"])
        heads.remove(0)
        heads.done()
        #expect(presets.dashes.isEmpty && presets.arrowheads.isEmpty && closed == 1)
        let sheet = StrokeEditorView.dashSheet(DashEditorModel(lengths: [2, 2]), model: model) { closed += 1 }
        sheet.apply(DashChoice(name: "2-2", lengths: [2, 2]))
        sheet.cancel()
        await fixture.document.settle()
        #expect(closed == 3 && Self.basic(fixture).dash.lengths == [2, 2])
    }
}
