import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The text-style UI glue: the style pop-ups with the *+* marker and the style commands (TYPE-034/
/// 035), the colour rows (TYPE-029), menu:Text[Convert Case] with its Settings sheet (TYPE-015) and
/// menu:Text[Convert to Paths] (TYPE-044).
@Suite(.serialized) @MainActor struct TextStyleUITests {
    static func model(_ document: DocumentHandle, _ nodes: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: document, selection: Selection(nodes.map { SelectionID($0) }))
    }

    /// A document with Normal Text and a three-paragraph block, the middle one centred.
    static func block() async throws -> (DocumentHandle, OpID) {
        let document = DocumentHandle.memory(title: "Styles")
        _ = await document.perform(CreateNormalTextStyle()).value
        let text = try #require(await document.addText("One\nTwo\nThree"))
        let paragraph = try #require(document.state.textNode(text)?.paragraphs[1])
        let node = try #require(document.state.textNode(text))
        _ = await document.perform(SetParagraph(node: text, from: node.anchor(at: paragraph.range.lowerBound), to: node.anchor(at: paragraph.range.lowerBound),
                                                props: .with { $0.alignment = .center }, fields: [[1]], label: "Alignment")).value
        await document.settle()
        return (document, text)
    }

    @Test func theStylePopUpsApplyAndMarkOverrides() async throws {
        let (document, text) = try await Self.block()
        let section = try #require(Self.model(document, [text]).textStyle)
        let normal = try #require(document.state.textStyles.normalText)
        #expect(section.paragraphStyle == normal && section.characterStyle == .some(nil) && section.overridden, "the centred paragraph overrides")
        #expect(InspectorRegistry().views(for: Self.model(document, [text])).isEmpty)
        TextStyleFeatures.register(into: .standard)
        #expect(InspectorRegistry.standard.views(for: Self.model(document, [text])).map(\.id).contains("textStyle"))
        // Shared attributes of three paragraphs: the alignment they disagree on is unset.
        let shared = Self.model(document, [text]).sharedTextAttributes
        #expect(!shared.paragraph.hasAlignment && shared.paragraph.hasLeftIndent)
        _ = await Self.model(document, [text]).newTextStyle(.paragraph)?.value
        let created = try #require(document.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        #expect(created.parent == normal && document.undoTitle.hasPrefix("Undo"))
        _ = await Self.model(document, [text]).applyParagraphStyle(created.id)?.value
        #expect(Self.model(document, [text]).textStyle?.paragraphStyle == created.id)
        #expect(TextStyleSectionView.title(created, overridden: true, current: true) == "\(created.name) +")
        #expect(TextStyleSectionView.title(created, overridden: true, current: false) == created.name)
        // A character style, applied and removed.
        _ = await Self.model(document, [text]).newTextStyle(.character)?.value
        let character = try #require(document.state.textStyles.styles(.character).first)
        #expect(!character.attrs.hasParagraph || character.attrs.paragraph == Wiretuner_Doc_V1_ParagraphSettings())
        _ = await Self.model(document, [text]).applyCharacterStyle(character.id)?.value
        #expect(Self.model(document, [text]).textStyle?.characterStyle == .some(character.id))
        _ = await Self.model(document, [text]).applyCharacterStyle(nil)?.value
        #expect(Self.model(document, [text]).textStyle?.characterStyle == .some(nil))
        // Redefine from the selection, rename, remove.
        _ = await Self.model(document, [text]).setFontSize(30)?.value
        _ = await Self.model(document, [text]).redefineParagraphStyle()?.value
        #expect(document.state.textStyles.resolved(created.id)?.character.size == 30 && document.undoTitle == "Undo Edit style \(created.name)")
        _ = await Self.model(document, [text]).renameTextStyle(created.id, to: "  Body  ")?.value
        #expect(document.state.textStyles.style(created.id)?.name == "Body")
        #expect(Self.model(document, [text]).renameTextStyle(created.id, to: " ") == nil)
        // The views and their bindings.
        let current = try #require(Self.model(document, [text]).textStyle)
        PanelRendering.host(TextStyleSectionView(section: current, model: Self.model(document, [text])))
        let paragraphBinding = TextStyleSectionView.paragraphBinding(current, Self.model(document, [text]))
        #expect(paragraphBinding.wrappedValue == created.id.description)
        paragraphBinding.wrappedValue = normal.description
        paragraphBinding.wrappedValue = "unknown"
        let characterBinding = TextStyleSectionView.characterBinding(current, Self.model(document, [text]))
        #expect(characterBinding.wrappedValue == ObjectPanelModel.noneStyle)
        characterBinding.wrappedValue = character.id.description
        await document.settle()
        TextStyleSectionView.renamingAction(current, Self.model(document, [text]), name: "Copy")()
        await document.settle()
        _ = await Self.model(document, [text]).removeTextStyle(created.id)?.value
        #expect(document.state.textStyles.style(created.id).map { document.state.textStyles.isLive($0.id) } == false)
        // Mixed: two blocks in different styles.
        let other = try #require(await document.addText("Other", at: Point(x: 50, y: 200)))
        _ = await Self.model(document, [other]).newTextStyle(.paragraph)?.value
        let second = try #require(document.state.textStyles.styles(.paragraph).last { !$0.isNormalText })
        _ = await Self.model(document, [other]).applyParagraphStyle(second.id)?.value
        _ = await Self.model(document, [other]).applyCharacterStyle(character.id)?.value
        _ = await Self.model(document, [text]).applyCharacterStyle(nil)?.value
        let mixed = try #require(Self.model(document, [text, other]).textStyle)
        #expect(mixed.paragraphStyle == nil && mixed.characterStyle == nil)
        PanelRendering.host(TextStyleSectionView(section: mixed, model: Self.model(document, [text, other])))
        #expect(TextStyleSectionView.characterBinding(mixed, Self.model(document, [text])).wrappedValue == "")
        #expect(Self.model(document, []).textStyle == nil && Self.model(document, []).newTextStyle(.paragraph) == nil)
        #expect(Self.model(document, []).redefineParagraphStyle() == nil && Self.model(document, []).applyParagraphStyle(normal) == nil)
        #expect(Self.model(document, []).applyCharacterStyle(nil) == nil)
        #expect(SharedTextAttributes.fields(Wiretuner_Doc_V1_TextStyleAttrs()).isEmpty)
    }

    @Test func twoReplicasRenamingOneStyleConvergeOnTheWinner() async throws {
        let (document, text) = try await Self.block()
        _ = await Self.model(document, [text]).newTextStyle(.paragraph)?.value
        let style = try #require(document.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        _ = await Self.model(document, [text]).renameTextStyle(style.id, to: "Mine")?.value
        _ = await document.receiveRemote(RenameTextStyle(style.id, to: "Theirs"))
        #expect(document.state.textStyles.style(style.id)?.name == "Theirs", "the later write wins and the pop-up reads it")
        #expect(Self.model(document, [text]).textStyle?.paragraphStyles.contains { $0.name == "Theirs" } == true)
    }

    @Test func theColourRowsWriteGlyphAndBlockColours() async throws {
        let (document, text) = try await Self.block()
        let red = RenderColor(red: 1, green: 0, blue: 0)
        let section = try #require(Self.model(document, [text]).textColor)
        #expect(section.fill == .black && !section.fillNone && section.stroke == false && section.blockFill == nil)
        TextStyleFeatures.register(into: .standard)
        #expect(InspectorRegistry.standard.views(for: Self.model(document, [text])).map(\.id).contains("textColor"))
        _ = await Self.model(document, [text]).setTextFill(red)?.value
        #expect(Self.model(document, [text]).textColor?.fill == red)
        _ = await Self.model(document, [text]).setTextFill(nil)?.value
        #expect(Self.model(document, [text]).textColor?.fillNone == true)
        _ = await Self.model(document, [text]).setTextStroke(true)?.value
        #expect(Self.model(document, [text]).textColor?.stroke == true)
        _ = await Self.model(document, [text]).setTextStroke(false)?.value
        _ = await Self.model(document, [text]).setBlockRow(.fills, on: true)?.value
        _ = await Self.model(document, [text]).setBlockRow(.strokes, on: true)?.value
        let rows = try #require(Self.model(document, [text]).textColor)
        #expect(rows.blockFill != nil && rows.blockStroke != nil)
        #expect(Self.model(document, [text]).setBlockRow(.fills, on: true) == nil, "already there")
        PanelRendering.host(TextColorSectionView(section: rows, model: Self.model(document, [text])))
        TextColorSectionView.fillBinding(rows, Self.model(document, [text])).wrappedValue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        TextColorSectionView.strokeBinding(rows, Self.model(document, [text])).wrappedValue = true
        TextColorSectionView.blockBinding(.fills, rows.blockFill, Self.model(document, [text])).wrappedValue = false
        await document.settle()
        #expect(Self.model(document, [text]).textColor?.blockFill == nil)
        _ = await Self.model(document, [text]).setBlockRow(.strokes, on: false)?.value
        #expect(Self.model(document, [text]).textColor?.blockStroke == nil)
        #expect(Self.model(document, []).textColor == nil && Self.model(document, []).setTextFill(red) == nil && Self.model(document, []).setTextStroke(true) == nil)
        #expect(Self.model(document, []).setBlockRow(.fills, on: true) == nil)
    }

    @Test func convertCaseAndItsSettingsSheet() async throws {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Case")
        let window = DocumentWindowController(document: document, environment: environment.document)
        let text = try #require(await document.addText("the iphone"))
        window.selection.model.set(Selection([SelectionID(text)]))
        let commands = TextStyleFeatures.commands(window: { window })
        let upper = try #require(commands.first { $0.id == ContextMenuCatalog.ID.convertCase("upper") })
        #expect(upper.validation().isEnabled)
        if case .perform(let run) = upper.action { run() }
        await document.settle()
        #expect(document.string(text) == "THE IPHONE")
        _ = await TextStyleFeatures.convert(.title, model: TextFeatures.model(window))?.value
        #expect(document.string(text) == "The Iphone")
        #expect(TextStyleFeatures.convert(.title, model: nil) == nil)
        #expect(TextStyleFeatures.convert(.title, model: Self.model(document, [])) == nil)
        // The Settings sheet: an exception, OK writes it.
        let sheet = try #require(TextStyleFeatures.showCaseSettings(on: window))
        #expect(sheet.identifier?.rawValue == TextCaseSettingsModel.sheet)
        window.window?.endSheet(sheet)
        let model = TextCaseSettingsModel(TextCaseSettings(document.state))
        model.addRow()
        let row = try #require(model.rows.first)
        model.toggle(.title, in: row.id)
        model.toggle(.uppercase, in: row.id)
        TextCaseSettingsSheet.wordBinding(row.id, model).wrappedValue = " iPhone "
        TextCaseSettingsSheet.conversionBinding(.title, row.id, model).wrappedValue = true
        #expect(TextCaseSettingsSheet.wordBinding(row.id, model).wrappedValue == " iPhone ")
        #expect(TextCaseSettingsSheet.conversionBinding(.title, row.id, model).wrappedValue)
        model.addRow()
        model.smallCapsPercent = 300
        #expect(model.settings.smallCapsPercent == 100 && model.settings.exceptions.map(\.word) == ["iPhone"])
        var committed: TextCaseSettings?
        PanelRendering.host(TextCaseSettingsSheet(model: model, commit: { committed = $0 }, cancel: {}))
        _ = await document.perform(SetTextCaseSettings(model.settings)).value
        #expect(TextCaseSettings(document.state).exceptions.first?.word == "iPhone" && committed == nil)
        model.remove(row.id)
        model.toggle(.title, in: UUID())
        #expect(model.rows.count == 1)
        _ = await TextStyleFeatures.convert(.title, model: TextFeatures.model(window))?.value
        #expect(document.string(text) == "The iPhone")
        let settings = try #require(commands.first { $0.id == TextStyleFeatures.ID.caseSettings })
        #expect(settings.validation().isEnabled)
        if case .perform(let run) = settings.action { run() }
        window.window?.attachedSheet.map { window.window?.endSheet($0) }
        #expect(!TextStyleFeatures.commands(window: { nil })[5].validation().isEnabled)
        window.close()
    }

    @Test func convertToPathsReplacesTheBlockWithAGroupInOneChange() async throws {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Paths")
        let window = DocumentWindowController(document: document, environment: environment.document)
        let text = try #require(await document.addText("Hi"))
        let rect = await document.addRectangles([Rect(x: 0, y: 200, width: 10, height: 10)])[0]
        var alerts: [String] = []
        let commands = TextStyleFeatures.commands(window: { window }) { title, _ in alerts.append(title) }
        let convert = try #require(commands.first { $0.id == ContextMenuCatalog.ID.convertToPaths })
        window.selection.model.set(Selection([rect]))
        #expect(!convert.validation().isEnabled && TextStyleFeatures.convertToPaths(window, alert: { _, _ in }) == nil)
        window.selection.model.set(Selection([SelectionID(text)]))
        #expect(convert.validation().isEnabled)
        if case .perform(let run) = convert.action { run() }
        await document.settle()
        #expect(!document.state.isLive(text) && document.undoTitle == "Undo Convert text to paths")
        #expect(TextStyleFeatures.convertToPaths(nil, alert: { _, _ in }) == nil)
        #expect(!TextStyleFeatures.commands(window: { nil }).last!.validation().isEnabled)
        _ = alerts
        window.close()
    }

    @Test func sharedAttributesCaretsAndTheViewsActions() async throws {
        // Every character attribute two runs share is set; one they differ on is not.
        let red = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        let run: [Wiretuner_Doc_V1_TextMarkValue] = [
            .with { $0.fontFamily = "Helvetica" }, .with { $0.fontStyle = "Bold" }, .with { $0.size = 12 }, .with { $0.leading = .init() },
            .with { $0.rangeKerning = 5 }, .with { $0.baselineShift = 2 }, .with { $0.horizontalScale = 90 }, .with { $0.fill = red },
            .with { $0.stroke = TextColor.defaultStroke }, .with { $0.effect = TextEffectKind.shadow.defaultEffect }, .with { $0.case = .smallCaps },
            .with { $0.language = "en" },
        ]
        let attrs = SharedTextAttributes.attrs(runs: [run, run], paragraphs: [])
        #expect(attrs.affectsColor && attrs.character.hasLanguage && attrs.character.hasCase && !attrs.paragraph.hasAlignment)
        #expect(SharedTextAttributes.fields(attrs).count == 13)
        #expect(!SharedTextAttributes.attrs(runs: [run, [.with { $0.size = 9 }]], paragraphs: []).character.hasSize)
        // A caret in the Text tool: the paragraph commands take its paragraph, the others nothing.
        let (document, text) = try await Self.block()
        let session = TextEditingSession(document: document, sink: document, target: .node(text))
        session.select(anchor: 5, focus: 5)
        let model = ObjectPanelModel(document: document, selection: Selection([SelectionID(text)]), textSession: session)
        #expect(model.textTargets.count == 1 && model.targetParagraphs.map(\.index) == [1] && model.targetRuns.count == 1)
        #expect(model.applyCharacterStyle(nil) == nil && TextStyleFeatures.convert(.uppercase, model: model) == nil)
        session.select(anchor: 0, focus: 7)
        #expect(ObjectPanelModel(document: document, selection: Selection([SelectionID(text)]), textSession: session).targetParagraphs.map(\.index) == [0, 1])
        // The view's actions.
        let plain = Self.model(document, [text])
        let section = try #require(plain.textStyle)
        TextStyleSectionView.newStyle(.character, plain)()
        await document.settle()
        TextStyleSectionView.redefining(Self.model(document, [text]))()
        await document.settle()
        var shown = false
        TextStyleSectionView.showing(Binding(get: { shown }, set: { shown = $0 }))()
        #expect(shown)
        let character = try #require(document.state.textStyles.styles(.character).first)
        _ = await Self.model(document, [text]).applyCharacterStyle(character.id)?.value
        let styled = try #require(Self.model(document, [text]).textStyle)
        #expect(TextStyleSectionView.characterBinding(styled, Self.model(document, [text])).wrappedValue == character.id.description)
        _ = await Self.model(document, [text]).newTextStyle(.paragraph)?.value
        let extra = try #require(document.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        _ = await Self.model(document, [text]).applyParagraphStyle(extra.id)?.value
        TextStyleSectionView.removing(try #require(Self.model(document, [text]).textStyle), Self.model(document, [text]))()
        await document.settle()
        #expect(!document.state.textStyles.isLive(extra.id))
        _ = section
        // The colour rows: a mixed stroke reads as off, and None clears the fill.
        let other = try #require(await document.addText("Stroked", at: Point(x: 50, y: 300)))
        _ = await Self.model(document, [other]).setTextStroke(true)?.value
        let mixed = try #require(Self.model(document, [text, other]).textColor)
        #expect(mixed.stroke == nil && !TextColorSectionView.strokeBinding(mixed, Self.model(document, [text, other])).wrappedValue)
        TextColorSectionView.clearing(Self.model(document, [other]))()
        await document.settle()
        #expect(Self.model(document, [other]).textColor?.fillNone == true)
        // The settings sheet's rows and buttons.
        let settings = TextCaseSettingsModel(TextCaseSettings())
        settings.addRow()
        let row = try #require(settings.rows.first)
        #expect(TextCaseSettingsSheet.wordBinding(UUID(), settings).wrappedValue == "" && !TextCaseSettingsSheet.conversionBinding(.title, UUID(), settings).wrappedValue)
        TextCaseSettingsSheet.wordBinding(UUID(), settings).wrappedValue = "ignored"
        var committed: TextCaseSettings?
        TextCaseSettingsSheet.committing(settings) { committed = $0 }()
        #expect(committed?.exceptions.isEmpty == true)
        TextCaseSettingsSheet.removing(row.id, settings)()
        #expect(settings.rows.isEmpty)
    }

    @Test func aMissingFontIsNamedWhenTheTextIsConverted() async throws {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Missing")
        let window = DocumentWindowController(document: document, environment: environment.document)
        let text = try #require(await document.addText("Gone"))
        _ = await document.perform(ApplyMark(node: text, from: .start, to: .end, value: .with { $0.fontFamily = "NoSuchFontFamilyAnywhere" })).value
        await document.settle()
        window.selection.model.set(Selection([SelectionID(text)]))
        var alerts: [String] = []
        _ = await TextStyleFeatures.convertToPaths(window) { title, _ in alerts.append(title) }?.value
        #expect(alerts == ["Some fonts were missing"])
        window.close()
    }
}
