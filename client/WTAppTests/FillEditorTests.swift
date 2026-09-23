import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-017: the fill editors, and ATTR-013: the shared pattern editor.
@Suite @MainActor struct FillEditorTests {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)

    static func model(_ fixture: AttributeFixture, ids: [SelectionID]? = nil) -> FillEditorModel {
        FillEditorModel(context: fixture.context(0, ids: ids), pasteboard: fixture.pasteboard)
    }

    static func perform(_ command: (any WTModel.Command)?, _ fixture: AttributeFixture) async {
        _ = await fixture.document.perform(command!).value
    }

    static func settings(_ fixture: AttributeFixture) -> Wiretuner_Doc_V1_FillSettings {
        fixture.stack()[0].fill.settings
    }

    @Test func basicAndKindSwitching() async throws {
        let fixture = await AttributeFixture.make()
        var model = Self.model(fixture)
        #expect(model.kind == .basic && model.basicOverprint == false)
        await Self.perform(model.setBasicColor(Self.red), fixture)
        await Self.perform(model.setBasicOverprint(true), fixture)
        #expect(Self.settings(fixture).basic.color == Self.red && Self.settings(fixture).basic.overprint)
        #expect(model.setKind(.gradient) == nil && FillEditorView.choose(.gradient, model: model) != nil)
        for (kind, _) in FillEditorModel.kinds where kind != .gradient {
            #expect(FillEditorView.choose(kind, model: Self.model(fixture)) == nil)
            await fixture.document.settle()
            #expect(Self.model(fixture).kind == kind)
            AttributeFixture.render(FillEditorView(model: Self.model(fixture)))
        }
        await Self.perform(Self.model(fixture).setKind(.basic), fixture)
        model = Self.model(fixture)
        #expect(model.basicColor == Self.red, "Basic comes back with its colour")
        // A gradient written elsewhere shows its note.
        _ = await fixture.document.perform(EditAttribute.fill(model.pairs, "Gradient", [AttributeFields.kind]) { $0.kind = .gradient }).value
        AttributeFixture.render(FillEditorView(model: Self.model(fixture)))
        #expect(Self.model(fixture).preview != nil)
    }

    @Test func everyCustomPatternShowsItsOwnOptions() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.custom), fixture)
        for (pattern, _) in AttributeNames.customFillPatterns {
            await Self.perform(Self.model(fixture).setCustomPattern(pattern), fixture)
            let model = Self.model(fixture)
            #expect(model.customPattern == pattern)
            for option in CustomFillOption.options(pattern) {
                if option.isColor {
                    await Self.perform(model.setCustomColor(option, Self.red), fixture)
                    #expect(Self.model(fixture).customColor(option) == Self.red)
                } else {
                    await Self.perform(model.setCustomNumber(option, 1_000_000), fixture)
                    #expect(Self.model(fixture).customNumber(option) == option.range.upperBound, "\(option) clamps")
                    #expect(!option.title.isEmpty)
                }
            }
            AttributeFixture.render(FillEditorView(model: Self.model(fixture)))
        }
        #expect(CustomFillOption.options(.blackWhiteNoise).isEmpty && CustomFillOption.options(.hatch).contains(.angle2))
        #expect(CustomFillOption.options(.bricks).map(\.title) == ["Color", "Mortar", "Width", "Height", "Angle"])
        #expect(CustomFillOption.options(.tigerTeeth).map(\.title) == ["Color", "Background", "Count", "Angle"])
        #expect(Self.model(fixture).customNumber(.color) == 0)
        #expect(Self.settings(fixture).custom.color2 == Self.red)
        let colorOption = Self.model(fixture).setCustomNumber(.color, 3)
        await Self.perform(colorOption, fixture)
        await Self.perform(Self.model(fixture).setCustomOverprint(true), fixture)
        #expect(Self.model(fixture).customOverprint == true && CustomFillOption.radius.title == "Radius" && CustomFillOption.gray.title == "Gray")
        #expect(CustomFillOption.whiteness.title == "Whiteness" && CustomFillOption.sideLength.title == "Side length")
    }

    @Test func lensOptionsAndTheTypeResetRule() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.lens), fixture)
        var model = Self.model(fixture)
        #expect(model.lensType == .transparency && model.lensAmount == 50 && model.magnification == 2)
        await Self.perform(model.setLensColor(Self.red), fixture)
        await Self.perform(model.setLensAmount(140), fixture)
        await Self.perform(model.setMagnification(0), fixture)
        await Self.perform(model.setCenterpointShown(true), fixture)
        await Self.perform(model.setObjectsOnly(true), fixture)
        await Self.perform(model.setSnapshot(true), fixture)
        model = Self.model(fixture)
        #expect(model.lensColor == Self.red && model.lensAmount == 100 && model.magnification == 1)
        #expect(model.centerpointShown == true && model.objectsOnly == true && model.snapshot == true)
        await Self.perform(model.setSnapshot(false), fixture)
        #expect(Self.model(fixture).snapshot == false)
        for (type, _) in AttributeNames.lensTypes {
            await Self.perform(Self.model(fixture).setCenterpointShown(true), fixture)
            await Self.perform(Self.model(fixture).setLensType(type), fixture)
            let lens = Self.model(fixture)
            #expect(lens.lensType == type && lens.centerpointShown == false, "choosing a lens clears its options")
            AttributeFixture.render(FillEditorView(model: lens))
        }
        #expect(FillEditorModel.showsColor(.monochrome) && !FillEditorModel.showsColor(.invert))
        #expect(FillEditorModel.showsAmount(.darken) && !FillEditorModel.showsAmount(.magnify))
        #expect(FillEditorModel.showsMagnification(.magnify) && !FillEditorModel.showsMagnification(nil))
        // A slider drag is one undo step.
        let context = Self.model(fixture).context
        context.dragging(true)
        await Self.perform(Self.model(fixture).setLensAmount(10), fixture)
        await Self.perform(Self.model(fixture).setLensAmount(20), fixture)
        context.dragging(false)
        _ = await fixture.document.undo().value
        #expect(Self.model(fixture).lensAmount == 100)
        #expect(AttributeSlider.binding(nil, range: 1...20) { _ in }.wrappedValue == 1)
        var slid: Double?
        AttributeSlider.binding(50, range: 0...100) { slid = $0 }.wrappedValue = 30
        #expect(slid == 30 && AttributeSlider.binding(500, range: 0...100) { _ in }.wrappedValue == 100)
    }

    @Test func patternAndTexturedFills() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.pattern), fixture)
        var model = Self.model(fixture)
        #expect(model.bitmap == SetAttributeKind.defaultBitmap)
        await Self.perform(model.setPatternColor(Self.red), fixture)
        await Self.perform(model.setBitmap(PatternEditorState.inverted(model.bitmap)), fixture)
        await Self.perform(model.setPatternOverprint(true), fixture)
        model = Self.model(fixture)
        #expect(model.patternColor == Self.red && model.bitmap == SetAttributeKind.defaultBitmap.map { ~$0 } && model.patternOverprint == true)

        await Self.perform(model.setKind(.textured), fixture)
        model = Self.model(fixture)
        await Self.perform(model.setTexture(.marble), fixture)
        await Self.perform(model.setTexturedColor(Self.red), fixture)
        await Self.perform(model.setTexturedOverprint(true), fixture)
        model = Self.model(fixture)
        #expect(model.texture == .marble && model.texturedColor == Self.red && model.texturedOverprint == true)
    }

    @Test func tiledFillPasteInCopyOutAndTransform() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.tiled), fixture)
        var model = Self.model(fixture)
        #expect(!model.hasTile && !model.copyTile() && model.scaleX == 100 && model.scaleY == 100)
        #expect(FillEditorView.paste(model) == PasteInError.empty.message)
        // A lens-filled object is refused with the message.
        let lensed = await fixture.document.addRectangles([Rect(x: 50, y: 50, width: 5, height: 5)])[0]
        let lensRow = AppearanceEditing.stack(lensed.opID, in: fixture.document.state)[0]
        _ = await fixture.document.perform(SetAttributeKind([(node: lensed.opID, row: lensRow)], fill: .lens)).value
        fixture.pasteboard.write(ClipboardPayload(copying: [lensed.opID], from: fixture.document.state).encoded())
        #expect(FillEditorView.paste(model) == PasteInError.excluded.message)
        // Artwork pastes in, draws, and copies back out.
        let art = await fixture.document.addPath([Point(x: 0, y: 0), Point(x: 6, y: 0), Point(x: 3, y: 5)], closed: true, filled: true)!
        fixture.pasteboard.write(ClipboardPayload(copying: [art.opID], from: fixture.document.state).encoded())
        #expect(FillEditorView.paste(model) == nil)
        await fixture.document.settle()
        model = Self.model(fixture)
        #expect(model.hasTile && fixture.document.undoTitle == "Undo Paste In" && model.preview != nil)
        fixture.pasteboard.write([])
        #expect(model.copyTile())
        #expect(fixture.pasteboard.read().flatMap(ClipboardPayload.init(decoding:))?.nodes.count == 1)

        await Self.perform(model.setTileAngle(30), fixture)
        await Self.perform(model.setTileScale(x: 50), fixture)
        await Self.perform(model.setTileScale(y: -5), fixture)
        await Self.perform(model.setTileOffset(x: 4), fixture)
        await Self.perform(Self.model(fixture).setTileOffset(y: -2), fixture)
        await Self.perform(model.setTiledOverprint(true), fixture)
        model = Self.model(fixture)
        #expect(model.tileAngle == 30 && model.scaleX == 50 && model.scaleY == 1 && model.offsetX == 4 && model.offsetY == -2 && model.tiledOverprint == true)
        AttributeFixture.render(FillEditorView(model: model))
        var nowhere = model
        nowhere.pasteboard = nil
        if case .failure(let error) = nowhere.pasteTile() { #expect(error == .empty) } else { Issue.record("no pasteboard") }

        // The dial.
        #expect(AngleDial.normalized(-30) == 330 && AngleDial.normalized(400) == 40)
        var dialed: Double?
        let coordinator = AngleDial.Coordinator { dialed = $0 }
        let slider = NSSlider(value: 90, minValue: 0, maxValue: 360, target: nil, action: nil)
        coordinator.changed(slider)
        #expect(dialed == 90)
    }

    @Test func thePatternEditorTogglesDragsAndPicksPresets() async throws {
        let state = PatternEditorState()
        let document = PatternEditorState.cleared()
        #expect(state.shown(document) == document)
        // Click toggles one pixel; the picture is written at mouse-up.
        state.press(x: 0, y: 0, document: document)
        #expect(state.shown(document)[0] == 0x80)
        // Dragging paints the pressed value; a remote change meanwhile does not disturb the drag.
        state.drag(x: 1, y: 0)
        state.drag(x: 9, y: 0)
        let remote: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xFF]
        #expect(state.shown(remote)[0] == 0xC0 && state.shown(remote)[7] == 0, "the drag's picture shows while dragging")
        #expect(state.release() == [0xC0, 0, 0, 0, 0, 0, 0, 0])
        #expect(state.shown(remote) == remote, "after mouse-up the grid shows the document")
        #expect(state.release() == nil)
        state.drag(x: 0, y: 0)
        // Pressing a painted pixel erases.
        state.press(x: 0, y: 0, document: [0x80])
        state.drag(x: 0, y: 1)
        #expect(state.release() == Array(repeating: 0, count: 8))
        #expect(PatternEditorState.inverted([0x0F]) == [0xF0] + Array(repeating: 0xFF, count: 7))
        #expect(PatternEditorState.isPainted([0x01], x: 7, y: 0) && !PatternEditorState.isPainted([], x: 0, y: 3))

        // The palette: 64 presets from the bundle, eight at a time.
        #expect(PatternPresets.all.count == PatternPresets.count)
        #expect(state.page(PatternPresets.all).map(\.index) == Array(0..<8))
        state.paletteOffset = 100
        #expect(state.page(PatternPresets.all).first?.index == 56)
        let offset = PatternEditorView.offset(state, count: 64)
        offset.wrappedValue = 9.4
        #expect(state.paletteOffset == 9 && offset.wrappedValue == 9)
        #expect(PatternPresets.bitmap("00") == nil && PatternPresets.bitmap("GG00000000000000") == nil)
        #expect(PatternPresets.load(nil) == [PatternBitmap.checker.rows])
        let file = TestEnvironment.temporaryDirectory().appendingPathExtension("json")
        try JSONEncoder().encode(["zz"]).write(to: file)
        #expect(PatternPresets.load(file) == [PatternBitmap.checker.rows])
        #expect(PatternEditorView.preview(PatternBitmap.checker.rows, color: .black) != nil)
        AttributeFixture.render(PatternEditorView(bitmap: document, color: .black, state: state) { _ in })
    }

    @Test func theGridViewHitTestsPixelsAndWritesAtMouseUp() async throws {
        let view = PatternGridView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        #expect(view.pixel(at: NSPoint(x: 15, y: 75))! == (1, 7) && view.pixel(at: NSPoint(x: 90, y: 5)) == nil)
        #expect(view.isFlipped && view.acceptsFirstResponder)
        #expect(PatternGridView(frame: .zero).pixel(at: .zero) == nil)
        let state = PatternEditorState()
        var written: [[UInt8]] = []
        PatternGrid.wire(view, state: state, document: PatternEditorState.cleared()) { written.append($0) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 5, 5))
        view.mouseDragged(with: event(.leftMouseDragged, 15, 5))
        view.mouseDragged(with: event(.leftMouseDragged, 500, 5))
        view.mouseDown(with: event(.leftMouseDown, 500, 500))
        #expect(view.rows[0] == 0xC0 && written.isEmpty)
        view.mouseUp(with: event(.leftMouseUp, 15, 5))
        #expect(written == [[0xC0, 0, 0, 0, 0, 0, 0, 0]])
        view.mouseUp(with: event(.leftMouseUp, 15, 5))
        #expect(written.count == 1, "no drag, nothing written")
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(rep.colorAt(x: 5, y: 5) != nil)
        window.contentView = nil
        let grid = PatternGrid(rows: [0xFF], state: state, document: [0xFF]) { _ in }
        AttributeFixture.render(grid.frame(width: 64, height: 64))
    }

    @Test func colorsBridgeBetweenAppKitAndTheDocument() async {
        let srgb = ColorBridge.ref(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        #expect(srgb.inline.space == .srgb && abs(srgb.inline.rgb.g - 0.5) < 1e-6)
        let p3 = ColorBridge.ref(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 1])!)
        #expect(p3.inline.space == .displayP3 && p3.inline.rgb.r == 1)
        #expect(ColorBridge.ref(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)).inline.rgb.b == 1)
        #expect(ColorBridge.isNone(ColorBridge.none) && !ColorBridge.isNone(srgb) && ColorBridge.cgColor(ColorBridge.none) == nil)
        #expect(ColorBridge.cgColor(srgb) != nil)
        #expect(ColorWellModel(ref: nil, state: EngineState()).chip == .mixed)
        #expect(ColorWellModel(ref: srgb, state: EngineState()).valueText == "#FF8000")
        var toggled: Bool?
        let toggle = AttributeToggle.binding(nil) { toggled = $0 }
        #expect(!toggle.wrappedValue)
        toggle.wrappedValue = true
        #expect(toggled == true)
        var chosen: Int?
        let picker = AttributePicker<Int>.binding(nil, fallback: 3) { chosen = $0 }
        #expect(picker.wrappedValue == 3)
        picker.wrappedValue = 4
        #expect(chosen == 4)
        AttributeFixture.render(AttributePicker<Int>(title: "Empty", value: nil, choices: [], identifier: "empty") { _ in })
        AttributeFixture.render(AttributeToggle(title: "Mixed", value: nil, identifier: "mixed") { _ in })
        AttributeFixture.render(AttributePreviewImage(image: nil, identifier: "none"))
        let fixture = await AttributeFixture.make()
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .blur
        _ = await fixture.document.perform(AddAppearance.effect([fixture.ids[0].opID], effect)).value
        #expect(AttributePreview.image(fixture.stack().last!) == nil)
    }

    @Test func theControlsActionsWriteThroughTheModel() async throws {
        let fixture = await AttributeFixture.make()
        await Self.perform(Self.model(fixture).setKind(.tiled), fixture)
        var model = Self.model(fixture)
        for command in [model.setTileScaleX(40), model.setTileScaleY(60), model.setTileOffsetX(3)] {
            _ = await fixture.document.perform(command).value
        }
        _ = await fixture.document.perform(Self.model(fixture).setTileOffsetY(7)).value
        model = Self.model(fixture)
        #expect(model.scaleX == 40 && model.scaleY == 60 && model.offsetX == 3 && model.offsetY == 7)
        model.copyOut()
        await Self.perform(model.setKind(.custom), fixture)
        await Self.perform(Self.model(fixture).setCustomPattern(.bricks), fixture)
        model = Self.model(fixture)
        await Self.perform(model.colorSetter(.mortar)(Self.red), fixture)
        await Self.perform(model.numberSetter(.height)(9), fixture)
        #expect(Self.model(fixture).customColor(.mortar) == Self.red && Self.model(fixture).customNumber(.height) == 9)
    }

    @Test func mixedAndUnsetFillsRead() async throws {
        let fixture = await AttributeFixture.make(2)
        await Self.perform(Self.model(fixture, ids: [fixture.ids[0]]).setKind(.tiled), fixture)
        let mixed = Self.model(fixture)
        #expect(mixed.kind == nil)
        AttributeFixture.render(FillEditorView(model: mixed))
        // Both custom with different patterns: the form lists no options.
        await Self.perform(Self.model(fixture, ids: [fixture.ids[1]]).setKind(.custom), fixture)
        await Self.perform(Self.model(fixture, ids: [fixture.ids[0]]).setKind(.custom), fixture)
        await Self.perform(Self.model(fixture, ids: [fixture.ids[0]]).setCustomPattern(.hatch), fixture)
        #expect(Self.model(fixture).customPattern == nil)
        AttributeFixture.render(FillEditorView(model: Self.model(fixture)))
        // Unset registers read their defaults.
        let one = Self.model(fixture, ids: [fixture.ids[0]])
        _ = await fixture.document.perform(EditAttribute.fill(one.pairs, "Clear", [AttributeFields.Lens.type, AttributeFields.Tiled.scaleX, AttributeFields.Tiled.scaleY]) { _ in }).value
        let cleared = Self.model(fixture, ids: [fixture.ids[0]])
        #expect(cleared.lensType == .transparency && cleared.scaleX == 100 && cleared.scaleY == 100)
        await Self.perform(cleared.setKind(.tiled), fixture)
        AttributeFixture.render(FillEditorView(model: Self.model(fixture, ids: [fixture.ids[0]])))
    }
}
