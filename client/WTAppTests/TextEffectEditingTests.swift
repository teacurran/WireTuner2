import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// TYPE-037: the Effect pop-up, menu:Text[Effect], the option sheets and the Type Style items.
@Suite(.serialized) @MainActor struct TextEffectEditingTests {
    static func model(_ document: DocumentHandle, _ nodes: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: document, selection: Selection(nodes.map { SelectionID($0) }))
    }

    /// The effect mark values of a block's runs.
    static func effects(_ document: DocumentHandle, _ node: OpID) -> [Wiretuner_Doc_V1_TextEffect] {
        document.state.textNode(node)?.runs.map { TextEffectKind.effect(of: $0.values) } ?? []
    }

    @Test func thePopUpAppliesAnEffectWithItsDefaultsAsOneMark() async throws {
        let document = DocumentHandle.memory(title: "Effects")
        let text = try #require(await document.addText("Shadowed words"))
        let section = try #require(Self.model(document, [text]).textEffect)
        #expect(section.kind == TextEffectKind.none && section.effect == Wiretuner_Doc_V1_TextEffect())
        #expect(InspectorRegistry.standard.views(for: Self.model(document, [text])).map(\.id).contains("textEffect"))
        let change = try #require(await Self.model(document, [text]).setTextEffect(.shadow)?.value)
        #expect(change.label == "Text Effect")
        let marks = change.ops.filter { if case .textMark? = $0.op { true } else { false } }
        #expect(marks.count == 1, "one effect mark with the options whole")
        #expect(Self.effects(document, text) == [TextEffectKind.shadow.defaultEffect])
        #expect(Self.model(document, [text]).textEffect?.kind == .shadow)
        // Every kind round-trips through its stored form.
        for kind in TextEffectKind.allCases {
            #expect(TextEffectKind(kind.defaultEffect) == kind)
            #expect((kind.sheet == nil) == (kind == .none))
        }
        #expect(TextEffectKind.effects.count == 6 && TextEffectKind.allCases.map(\.title).contains("Zoom"))
        // None removes it.
        _ = await Self.model(document, [text]).setTextEffect(TextEffectKind.none)?.value
        #expect(Self.model(document, [text]).textEffect?.kind == TextEffectKind.none)
        // Blocks with different effects read as mixed.
        let other = try #require(await document.addText("Underlined", at: Point(x: 50, y: 120)))
        _ = await Self.model(document, [other]).setTextEffect(.underline)?.value
        let mixed = try #require(Self.model(document, [text, other]).textEffect)
        #expect(mixed.kind == nil && mixed.effect == nil)
        #expect(TextEffectSectionView.editor(mixed) == nil)
        let rect = await document.addRectangles([Rect(x: 300, y: 300, width: 5, height: 5)])[0]
        #expect(ObjectPanelModel(document: document, selection: Selection([SelectionID(text), rect])).textEffect == nil)
    }

    @Test func eachSheetWritesOneEffectMarkWithTheOptionsWhole() async throws {
        let document = DocumentHandle.memory(title: "Sheets")
        let text = try #require(await document.addText("Styled"))
        for kind in TextEffectKind.effects {
            _ = await Self.model(document, [text]).setTextEffect(kind)?.value
            let section = try #require(Self.model(document, [text]).textEffect)
            var sheet = try #require(TextEffectSectionView.editor(section))
            #expect(sheet.kind == kind && sheet.effect == kind.defaultEffect)
            switch kind.sheet {
            case .line?:
                sheet.line.position = 4
                sheet.line.width = 1.5
                sheet.line.overprint = true
                sheet.line.dash = try #require(TextEffectSheetModel.dash("3 1"))
                sheet.line.color = Appearances.inline(red: 1, green: 0, blue: 0)
            case .inline?:
                sheet.inline.count = 3
                sheet.inline.strokeWidth = 2
                sheet.inline.backgroundWidth = 0.5
            case .shadow?:
                sheet.shadow.offsetX = 25
                sheet.shadow.offsetY = -5
                sheet.shadow.tint = 80
            case .zoom?:
                sheet.zoom.zoomTo = 30
                sheet.zoom.offsetX = 5
                sheet.zoom.offsetY = 6
            case nil:
                Issue.record("every effect has a sheet")
            }
            let before = document.state.textNode(text)?.runs.count
            TextEffectSectionView.commit(sheet, Self.model(document, [text]))
            await document.settle()
            #expect(Self.effects(document, text) == [sheet.effect], "\(kind): the sheet's effect, whole")
            #expect(document.state.textNode(text)?.runs.count == before)
            #expect(TextEffectKind(sheet.effect) == kind)
        }
        // A line sheet keeps which line it edits.
        var strike = TextEffectSheetModel(kind: .strikethrough, current: nil)
        strike.line.width = 2
        #expect(TextEffectKind(strike.effect) == .strikethrough && strike.line.width == 2)
        var highlight = TextEffectSheetModel(kind: .highlight, current: TextEffectKind.zoom.defaultEffect)
        #expect(highlight.effect == TextEffectKind.highlight.defaultEffect, "another kind's effect is not a starting point")
        highlight.line.position = 1
        #expect(TextEffectKind(highlight.effect) == .highlight)
        #expect(TextEffectSheetModel(kind: .zoom, current: nil).line == Wiretuner_Doc_V1_TextLineEffect())
        #expect(TextEffectSheetModel.dash("1, 2 3") == .with { $0.lengths = [1, 2, 3] })
        #expect(TextEffectSheetModel.dash("x") == nil && TextEffectSheetModel.dash("-1") == nil && TextEffectSheetModel.dash(String(repeating: "1 ", count: 9)) == nil)
        #expect(TextEffectSheetModel.dashText(.with { $0.lengths = [3, 1.5] }) == "3 1.5")
        #expect(TextEffectSheetModel(kind: .zoom, current: nil).id == "zoom")
    }

    @Test func theSheetViewsAndTheirBindings() async throws {
        let document = DocumentHandle.memory(title: "Views")
        let text = try #require(await document.addText("Styled"))
        for kind in TextEffectKind.allCases {
            var committed: TextEffectSheetModel?
            var cancelled = false
            let view = TextEffectSheetView(model: TextEffectSheetModel(kind: kind, current: nil), commit: { committed = $0 }, cancel: { cancelled = true })
            _ = view.body
            view.commit(view.model)
            view.cancel()
            #expect(committed?.kind == kind && cancelled)
        }
        var line = Wiretuner_Doc_V1_TextLineEffect()
        let lineBinding = Binding(get: { line }, set: { line = $0 })
        TextEffectSheetView.dash(lineBinding)("2 2")
        TextEffectSheetView.dash(lineBinding)("nope")
        #expect(line.dash.lengths == [2, 2])
        var inline = Wiretuner_Doc_V1_TextInlineEffect()
        let count = TextEffectSheetView.count(Binding(get: { inline }, set: { inline = $0 }))
        count.wrappedValue = 500
        #expect(inline.count == 100 && count.wrappedValue == 100)
        count.wrappedValue = 0
        #expect(inline.count == 1)
        var shadow = Wiretuner_Doc_V1_TextShadowEffect()
        let tint = TextEffectSheetView.tint(Binding(get: { shadow }, set: { shadow = $0 }))
        tint.wrappedValue = 140
        #expect(shadow.tint == 100 && tint.wrappedValue == 100)
        // Colour wells: inline colours read and write; other references show black.
        var ref = Appearances.inline(red: 0, green: 0, blue: 1)
        let well = EffectColor.binding(Binding(get: { ref }, set: { ref = $0 }))
        well.wrappedValue = SwiftUI.Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        #expect(abs(ref.inline.rgb.r - 1) < 0.01 && ref.inline.rgb.b < 0.01)
        _ = EffectColor.color(Appearances.inline(red: 0.2, green: 0.4, blue: 0.6))
        _ = EffectColor.color(.with { $0.swatch = .init() })
        _ = EffectColor.color(.with { $0.tint = .init() })
        #expect(EffectColor.color(Wiretuner_Doc_V1_ColorRef()) == .black)
        // The pop-up: an effect applies it; Edit… opens the sheet of the text's effect.
        let model = Self.model(document, [text])
        var opened: TextEffectSheetModel?
        let editing = Binding(get: { opened }, set: { opened = $0 })
        let none = try #require(model.textEffect)
        TextEffectSectionView.choice(none, model, editing: editing).wrappedValue = TextEffectSectionView.edit
        #expect(opened == nil, "None has nothing to edit")
        TextEffectSectionView.choice(none, model, editing: editing).wrappedValue = "Inline"
        await document.settle()
        let inlined = try #require(Self.model(document, [text]).textEffect)
        #expect(TextEffectSectionView.choice(inlined, model, editing: editing).wrappedValue == "Inline")
        TextEffectSectionView.choice(inlined, Self.model(document, [text]), editing: editing).wrappedValue = TextEffectSectionView.edit
        #expect(opened?.kind == .inline)
        TextEffectSectionView.choice(inlined, Self.model(document, [text]), editing: editing).wrappedValue = "Nonsense"
        // The open sheet's buttons: OK writes the effect and closes, Cancel closes.
        var sheet = try #require(opened)
        sheet.inline.count = 4
        TextEffectSectionView.sheet(sheet, model: Self.model(document, [text]), editing: editing).ok()
        await document.settle()
        #expect(opened == nil && Self.effects(document, text).first?.inline.count == 4)
        opened = sheet
        TextEffectSectionView.sheet(sheet, model: Self.model(document, [text]), editing: editing).cancel()
        #expect(opened == nil)
        let view = TextEffectSectionView(section: inlined, model: Self.model(document, [text]))
        _ = view.body
        _ = view.sheet(sheet).body
        TextEffectSheetView.number("N", Binding(get: { 1.0 }, set: { _ in }), identifier: "n").commit(2)
        #expect(EffectColor.decode(Data([0xFF, 0xFF, 0xFF])) == Wiretuner_Doc_V1_Color())
        // Mixed effects read as mixed in the pop-up.
        let other = try #require(await document.addText("Other", at: Point(x: 50, y: 150)))
        let mixed = try #require(Self.model(document, [text, other]).textEffect)
        #expect(TextEffectSectionView.choice(mixed, model, editing: editing).wrappedValue == TextEffectSectionView.mixed)
        PanelRendering.host(TextEffectSectionView(section: mixed, model: Self.model(document, [text, other])))
        PanelRendering.host(TextEffectSheetView(model: sheet, commit: { _ in }, cancel: {}))
    }

    @Test func theTextMenuItemsApplyOrOpenTheSheet() async throws {
        let document = DocumentHandle.memory(title: "Menu")
        let text = try #require(await document.addText("Menu text"))
        #expect(TextFeatures.choose(.shadow, model: nil) == nil)
        #expect(TextFeatures.choose(.shadow, model: Self.model(document, [text])) == .applied)
        await document.settle()
        guard case .sheet(let sheet)? = TextFeatures.choose(.shadow, model: Self.model(document, [text])) else {
            Issue.record("the effect it already has opens its sheet")
            return
        }
        #expect(sheet.kind == .shadow)
        #expect(TextFeatures.choose(.shadow, model: Self.model(document, [text]), applyDefaults: true) == .applied, "Type Style applies the defaults")
        #expect(TextFeatures.choose(TextEffectKind.none, model: Self.model(document, [text])) == .applied)
        let commands = TextFeatures.commands(window: { nil })
        #expect(commands.count == 9 && commands.map(\.id).contains(TextFeatures.ID.underline))
        #expect(commands.allSatisfy { $0.validation() == .disabled(TextFeatures.noText) })
        let registry = CommandRegistry()
        TextFeatures.install(into: registry) { nil }
        #expect(registry.command(TextFeatures.ID.effect(.zoom))?.title == "Zoom")
        for command in commands { if case .perform(let run) = command.action { run() } }
    }

    @Test func theMenuItemsInAWindow() async throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: DocumentHandle.memory(title: "Window"), environment: environment.document)
        defer { controller.close() }
        controller.showWindow(nil)
        let document = controller.documentHandle
        let text = try #require(await document.addText("In a window"))
        controller.selection.model.set(Selection([SelectionID(text)]))
        let commands = TextFeatures.commands { [weak controller] in controller }
        let underline = try #require(commands.first { $0.id == TextFeatures.ID.underline })
        #expect(underline.validation() == .enabled)
        if case .perform(let run) = underline.action { run() }
        await document.settle()
        #expect(TextEffectEditingTests.model(document, [text]).textEffect?.kind == .underline)
        // Text ▸ Effect ▸ Underline on underlined text opens its sheet on the window.
        let item = try #require(commands.first { $0.id == TextFeatures.ID.effect(.underline) })
        if case .perform(let run) = item.action { run() }
        let sheet = try #require(controller.window?.attachedSheet)
        #expect(sheet.identifier?.rawValue == "text-effect.underline")
        controller.window?.endSheet(sheet)
        let presented = try #require(TextFeatures.present(TextEffectSheetModel(kind: .zoom, current: nil), on: controller))
        controller.window?.endSheet(presented)
        var closed = false
        TextFeatures.finish(on: controller) { closed = true }(TextEffectSheetModel(kind: .zoom, current: nil))
        await document.settle()
        #expect(closed && TextEffectEditingTests.model(document, [text]).textEffect?.kind == .zoom)
    }

    @Test func twoReplicasEditingShadowOffsetsEndWithOneWholeShadow() async throws {
        let document = DocumentHandle.memory(title: "Merge")
        let text = try #require(await document.addText("Word"))
        _ = await Self.model(document, [text]).setTextEffect(.shadow)?.value
        var mine = TextEffectKind.shadow.defaultEffect
        mine.shadow.offsetX = 30
        var theirs = TextEffectKind.shadow.defaultEffect
        theirs.shadow.offsetY = -40
        theirs.shadow.tint = 20
        _ = await Self.model(document, [text]).setTextEffect(mine)?.value
        _ = await document.receiveRemote(ApplyMark(node: text, from: .start, to: .end, value: .with { $0.effect = theirs }), replica: 0xFFFF)
        let merged = Self.effects(document, text)
        #expect(merged == [theirs], "the later whole effect wins; no mix of offsets")
    }
}
