import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// LIB-027: the Overrides section, and formatting, paragraph settings, placeholders, type nudges,
/// the Text Editor and remote carets on a text override.
@Suite(.serialized) @MainActor struct SymbolOverrideEditingTests {
    typealias Fixture = TextToolTests.Fixture

    /// Editing the instance's text block "Label" with the Text tool; returns the instance, the master.
    static func editing(_ fixture: Fixture) async throws -> (instance: OpID, master: OpID, session: TextEditingSession) {
        let (instance, master) = try await SymbolInstanceTextTests.instance(fixture)
        fixture.click(50.5, 56)
        return (instance, master, try #require(fixture.session))
    }

    static func panel(_ fixture: Fixture, _ instance: OpID) -> ObjectPanelModel {
        ObjectPanelModel(document: fixture.document, selection: Selection([SelectionID(instance)]), textSession: fixture.session)
    }

    static func text(_ fixture: Fixture, _ instance: OpID, _ master: OpID) throws -> TextNode {
        try #require(Symbols.textNode(master, in: instance, state: fixture.document.state))
    }

    @Test func thePanelsFormatTheSelectionInsideAnInstance() async throws {
        let fixture = Fixture()
        let (instance, master, session) = try await Self.editing(fixture)
        let panel = Self.panel(fixture, instance)
        #expect(panel.editingText === session)
        let section = try #require(panel.text)
        #expect(section.nodes == [instance] && section.editing)
        #expect(InspectorRegistry.standard.views(for: panel).map(\.id).contains("text") && panel.paragraph != nil && panel.spacing != nil)
        #expect(ObjectPanelModel(document: fixture.document, selection: Selection([SelectionID(instance)])).text == nil, "not editing: no text section")
        // Character formatting over a selection.
        session.select(anchor: 0, focus: 2)
        await fixture.settle()
        _ = await panel.setFontSize(30)?.value
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).runs.contains { $0.range == 0..<2 && $0.values.contains { $0.size == 30 } })
        #expect(fixture.document.string(master) == "Label" && fixture.document.undoTitle == "Undo Size")
        _ = await panel.formatText([TextFixtureValues.family("Georgia"), TextFixtureValues.size(20)], label: "Font")?.value
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).runs.contains { $0.range == 0..<2 && $0.values.contains { $0.fontFamily == "Georgia" } })
        _ = await panel.setTextFill(RenderColor(red: 1, green: 0, blue: 0))?.value
        _ = await panel.setTextStroke(true)?.value
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).runs.contains { run in run.range.contains(0) && run.values.contains { if case .stroke? = $0.value { true } else { false } } })
        _ = await panel.setTextStroke(false)?.value
        _ = await panel.setTextFill(nil)?.value
        await fixture.settle()
        #expect(panel.setBlockRow(.fills, on: true) == nil, "the block's own rows are the master's")
        #expect(panel.textColor?.blockFill == nil)
        // Paragraph settings: the last paragraph's go on the override.
        _ = await panel.setAlignment(.center)?.value
        _ = await panel.setParagraphValue(ObjectPanelModel.ParagraphField.spaceAbove, 5, label: "Space Above")?.value
        await fixture.settle()
        let tail = try #require(try Self.text(fixture, instance, master).paragraphs.last?.props)
        #expect(tail.alignment == .center && tail.spaceAbove == 5)
        #expect(Symbols.textNode(master, in: instance, state: fixture.document.state)?.paragraphs.last?.props.alignment == .center)
        #expect(TextNode(master, in: fixture.document.state)?.paragraphs.last?.props.alignment != .center, "the master is untouched")
        // At an insertion point the format waits for the next typed characters.
        session.select(anchor: 5, focus: 5)
        await fixture.settle()
        session.format(TextFixtureValues.size(9))
        await fixture.type("!")
        #expect(try Self.text(fixture, instance, master).runs.contains { $0.range == 5..<6 && $0.values.contains { $0.size == 9 } })
    }

    @Test func placeholdersAndNudgesInsideAnInstance() async throws {
        let fixture = Fixture()
        let (instance, master, session) = try await Self.editing(fixture)
        let field = try #require(await fixture.document.perform(AddFields([AddFields.Field("Name")])).value?.insertedElements(WellKnown.settings, DataFieldsPaths.fields).first)
        await fixture.settle()
        session.select(anchor: 5, focus: 5)
        session.insertField(field)
        await fixture.settle()
        var text = try Self.text(fixture, instance, master)
        #expect(text.string == "Label{{Name}}" && session.focusOffset == 13)
        #expect(DataPlaceholders.unitRange(7..<7, in: text) == 5..<13)
        #expect(fixture.document.undoTitle == "Undo Insert field")
        // Typing the braces converts what was typed.
        await fixture.type(" {{Name}}")
        text = try Self.text(fixture, instance, master)
        #expect(text.string == "Label{{Name}} {{Name}}" && DataPlaceholders.unitRange(16..<16, in: text) == 14..<22)
        // A field over a selection replaces it.
        session.select(anchor: 0, focus: 5)
        session.insertField(field)
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).string.hasPrefix("{{Name}}{{Name}}"))
        // Type nudges reach the override too.
        let nudger = TypeNudger(editing: fixture.editing)
        session.select(anchor: 0, focus: 3)
        await fixture.settle()
        #expect(nudger.nudge(TypeNudge(kind: .size, delta: 2)))
        _ = await nudger.flush()?.value
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).runs.contains { $0.range.lowerBound == 0 && $0.values.contains { $0.size == 14 } })
        session.select(anchor: 2, focus: 2)
        await fixture.settle()
        #expect(nudger.nudge(TypeNudge(kind: .kerning, delta: 10)))
        _ = await nudger.flush()?.value
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).runs.contains { $0.range == 1..<2 && $0.values.contains { $0.kerning == 10 } })
    }

    @Test func remoteCaretsFollowAnOverrideOnAnotherScreen() async throws {
        let fixture = Fixture()
        let (instance, master, session) = try await Self.editing(fixture)
        #expect(session.presenceCaret == nil, "before the first edit the text is the master's")
        await fixture.type("My ")
        session.select(anchor: 3, focus: 8)
        await fixture.settle()
        let caret = try #require(session.presenceCaret)
        let element = try #require(Symbols.liveOverrides(of: instance, in: fixture.document.state).values.first.flatMap { OpID(element: $0.id) })
        #expect(caret.node == instance && caret.text == SymbolFields.overrideText(element))
        #expect(fixture.carets.last??.node == instance)
        // Published, and drawn by another window over the same state at the instance's placement.
        let presence = LocalPresence()
        LocalPresencePublisher(presence: presence).caret(caret)
        let update = await presence.presence()
        #expect(update?.caret.text == SymbolFields.overrideText(element).proto)
        var priya = RemoteParticipant(id: "p", name: "Priya", colorIndex: 1)
        priya.caret = RemoteCaret(node: SelectionID(instance), position: caret.position, rangeEnd: caret.rangeEnd, text: caret.text)
        let overlay = PresenceOverlay(document: fixture.document, viewport: TextToolTests.viewport)
        let drawn = try #require(overlay.carets([priya]).first)
        #expect(drawn.rect.minX > 50 && drawn.rect.minX < 90 && drawn.name == "Priya")
        #expect(!overlay.textSelections([priya]).isEmpty)
        overlay.draw(in: TextToolTests.context(), participants: [priya], options: PresenceDisplayOptions(), clock: CursorLabelClock())
        // A field naming no override element of the instance draws the flag at the instance.
        priya.caret = RemoteCaret(node: SelectionID(instance), position: caret.position, text: SymbolFields.overrideText(OpID(counter: 99, replica: 9)))
        #expect(PresenceOverlay.caretText(try #require(priya.caret), in: fixture.document) == nil)
        #expect(overlay.caretGeometry(try #require(priya.caret)) == nil && overlay.carets([priya]).count == 1)
        #expect(Symbols.overrideMaster(ofTextField: TextFields.text, in: instance, state: fixture.document.state) == nil)
        #expect(Symbols.overrideMaster(ofTextField: caret.text, in: instance, state: fixture.document.state) == master)
    }

    @Test func theTextEditorEditsAnOverride() async throws {
        let fixture = Fixture()
        let (instance, master, _) = try await Self.editing(fixture)
        let world = GlueWorld()
        defer { world.close() }
        TextEditorFeatures.shared.showsWindows = false
        defer { TextEditorFeatures.shared.closeAll(of: fixture.document) }
        let target = TextEditingSession.Target.override(instance: instance, master: master)
        #expect(TextEditorFeatures.key(fixture.document, target).hasSuffix("#\(instance)/\(master)"))
        #expect(TextEditorFeatures.key(fixture.document, .pending(.point(.zero))) == "\(fixture.document.id)#")
        let model = TextEditorModel(document: fixture.document, target: target, sink: fixture.editing)
        #expect(model.node == instance && model.text?.string == "Label" && model.isLive)
        #expect(model.title == "Text Editor — \(fixture.document.state.displayName(of: instance)) › Text: Label")
        model.replace(NSRange(location: 5, length: 0), with: "!")
        await model.session.settle()
        await fixture.settle()
        #expect(try Self.text(fixture, instance, master).string == "Label!" && fixture.document.string(master) == "Label")
        #expect(model.attributedString().string == "Label!")
        // Collaborators' carets in the same override show; one in the master does not.
        let element = try #require(Symbols.liveOverrides(of: instance, in: fixture.document.state).values.first.flatMap { OpID(element: $0.id) })
        var priya = RemoteParticipant(id: "p", name: "Priya", colorIndex: 1)
        priya.caret = RemoteCaret(node: SelectionID(instance), position: .zero, text: SymbolFields.overrideText(element))
        var tom = RemoteParticipant(id: "t", name: "Tom", colorIndex: 2)
        tom.caret = RemoteCaret(node: SelectionID(instance), position: .zero)
        #expect(model.remoteMarks([priya, tom]).map(\.name) == ["Priya"])
        // The menu's target is the Text tool's override; the window opens for it once.
        world.window.objectEditing.textSession = fixture.session
        #expect(TextEditorFeatures.editTarget(in: world.window) == target && TextEditorFeatures.target(in: world.window) == nil)
        let controller = TextEditorFeatures.shared.show(target, in: world.window)
        #expect(TextEditorFeatures.shared.show(target, in: world.window) === controller)
        #expect(TextEditorFeatures.shared.controller(for: target, in: world.document) === controller)
        let command = try #require(TextEditorFeatures.shared.commands { world.window }.first)
        #expect(command.validation() == .enabled)
        if case .perform(let run) = command.action { run() }
        controller.close()
        world.window.objectEditing.textSession = nil
    }

    /// LIB-027's rest: the Text tool's kbd:[Option]-click on a block inside an instance opens the Text
    /// Editor on its override.
    @Test func optionClickOpensTheTextEditorOnTheOverride() async throws {
        let fixture = Fixture()
        let (instance, master) = try await SymbolInstanceTextTests.instance(fixture)
        var opened: [OpID] = []
        var blocks = 0
        let tool = TextTool()
        var context = ToolContext(document: fixture.document, host: fixture.host, selection: fixture.controller)
        context.openTextEditor = { _, _ in blocks += 1 }
        context.openOverrideEditor = { opened += [$0, $1] }
        tool.activate(in: context)
        let point = Point(x: 50.5, y: 56)
        tool.mouseDown(CanvasEvent(pasteboardPoint: point, viewPoint: point, modifiers: [.option]))
        #expect(opened == [instance, master] && blocks == 0 && tool.session == nil)
        // Away from the instance an Option-click still makes a block for the editor.
        let away = Point(x: 300, y: 250)
        tool.mouseDown(CanvasEvent(pasteboardPoint: away, viewPoint: away, modifiers: [.option]))
        #expect(blocks == 1 && opened.count == 2)
        tool.deactivate()
    }

    /// LIB-027's rest: the Object panel's paragraph and character styles apply to the override.
    @Test func textStylesApplyToTheOverride() async throws {
        let fixture = Fixture()
        let (instance, master, session) = try await Self.editing(fixture)
        _ = await fixture.document.perform(CreateTextStyle(.paragraph, name: "Heading", attrs: .with { $0.paragraph.alignment = .center })).value
        _ = await fixture.document.perform(CreateTextStyle(.character, name: "Loud", attrs: .with { $0.character.size = 30 })).value
        let styles = fixture.document.state.textStyles
        let heading = try #require(styles.styles(.paragraph).first { $0.name == "Heading" }).id
        let loud = try #require(styles.styles(.character).first { $0.name == "Loud" }).id
        session.select(anchor: 0, focus: 2)
        await fixture.settle()
        let panel = Self.panel(fixture, instance)
        #expect(panel.targetParagraphs.count == 1 && panel.targetRuns.count >= 1)
        _ = await panel.applyParagraphStyle(heading)?.value
        await fixture.settle()
        var text = try Self.text(fixture, instance, master)
        #expect(styles.paragraphStyle(text.paragraphs[0].props).style == heading && fixture.document.undoTitle == "Undo Apply style")
        #expect(Self.panel(fixture, instance).textStyle?.paragraphStyle == heading)
        #expect(TextNode(master, in: fixture.document.state).map { styles.paragraphStyle($0.paragraphs[0].props).style } != heading, "the master is untouched")
        _ = await panel.applyCharacterStyle(loud)?.value
        await fixture.settle()
        #expect(Self.panel(fixture, instance).textStyle?.characterStyle == .some(loud))
        _ = await panel.applyCharacterStyle(nil)?.value
        await fixture.settle()
        text = try Self.text(fixture, instance, master)
        #expect(Self.panel(fixture, instance).textStyle?.characterStyle == .some(nil))
        // At an insertion point the caret's run is read and a character style writes nothing.
        session.select(anchor: 1, focus: 1)
        await fixture.settle()
        #expect(Self.panel(fixture, instance).targetRuns.count == 1)
        #expect(Self.panel(fixture, instance).applyCharacterStyle(loud) == nil)
        _ = text
    }

    // MARK: The Overrides section

    /// A symbol of a rectangle, a text block and an image with two instances, and the section over
    /// both.
    @MainActor
    struct SectionWorld {
        let world = GlueWorld()
        var symbol = OpID.zero, first = OpID.zero, second = OpID.zero, rect = OpID.zero, text = OpID.zero, image = OpID.zero

        static func make() async throws -> SectionWorld {
            var w = SectionWorld()
            let document = w.world.document
            w.rect = try #require(await document.addRectangles([Rect(x: 100, y: 100, width: 40, height: 40)]).first?.opID)
            w.text = try #require(await document.perform(CreateTextBlock(.point(Point(x: 100, y: 160)), text: "Buy now")).value?.createdObjects.first)
            let layer = try #require(Objects.parent(of: w.rect, in: document.state))
            var props = Wiretuner_Doc_V1_NodeProps()
            props.image.pixels.blobSha256 = Data(repeating: 2, count: 32)
            w.image = try #require(await document.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0xF0], props: props)])).value?.createdNodes.first)
            let change = try #require(await document.perform(ConvertToSymbol([w.rect, w.text, w.image])).value)
            w.symbol = change.createdNodes[0]
            w.first = change.createdNodes[1]
            w.second = try #require(await document.perform(PlaceInstance(w.symbol, at: Point(x: 400, y: 200))).value?.createdObjects.first)
            await document.settle()
            return w
        }

        func model(_ instances: [OpID]) -> OverridesSectionModel {
            OverridesSectionModel(panel: ObjectPanelModel(document: world.document, selection: Selection(instances.map { SelectionID($0) })))
        }

        func row(_ master: OpID, _ property: Wiretuner_Doc_V1_OverrideProperty) -> OverrideRow? {
            Symbols.overrideRows(of: symbol, in: world.document.state).first { $0.master == master && $0.property == property }
        }
    }

    @Test func overrideEachKindFromThePanelThenResetOneAndAll() async throws {
        let w = try await SectionWorld.make()
        defer { w.world.close() }
        var model = w.model([w.first])
        #expect(model.symbol == w.symbol && model.explanation == nil && model.rows.count == 7 && !model.hasOverrides)
        let text = try #require(w.row(w.text, .text)), fill = try #require(w.row(w.rect, .fill)), stroke = try #require(w.row(w.rect, .stroke))
        let visible = try #require(w.row(w.rect, .hidden)), image = try #require(w.row(w.image, .image))
        #expect(OverridesSectionModel.title(text) == "Text: Buy now — Text" && OverridesSectionModel.title(visible) == "Rect — Visible")
        #expect(OverridesSectionModel.title(fill).hasSuffix("Fill") && OverridesSectionModel.title(stroke).hasSuffix("Stroke") && OverridesSectionModel.title(image).hasSuffix("Image"))
        #expect(model.value(text) == (.text("Buy now"), false) && OverridesSectionModel.text(model.value(text).value) == "Buy now")
        Render.view(OverridesSectionView(model: model))
        // Each kind.
        _ = await model.setText(text, "Sold out")?.value
        _ = await model.setColor(fill, CGColor(red: 1, green: 0, blue: 0, alpha: 1))?.value
        _ = await model.setColor(stroke, CGColor(red: 0, green: 1, blue: 0, alpha: 1))?.value
        _ = await model.setVisible(visible, false)?.value
        let stored = TestBox<[ImportedBlob]>([])
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("override-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 9, 9]).write(to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }
        model.chooseFile = { picture }
        model.storeBlob = { blob, _ in stored.value.append(blob) }
        _ = await model.chooseImage(image)?.value
        await w.world.document.settle()
        let state = w.world.document.state
        let live = Symbols.liveOverrides(of: w.first, in: state)
        #expect(Set(live.keys.map(\.property)) == [.text, .fill, .stroke, .hidden, .image])
        #expect(Symbols.textNode(w.text, in: w.first, state: state)?.string == "Sold out" && live[visible.key]?.hidden == true)
        #expect(stored.value.count == 1 && stored.value[0].uti == "public.png" && live[image.key]?.hasImage == true)
        #expect(model.value(text).overridden && model.value(fill).overridden && model.hasOverrides)
        #expect(model.value(visible) == (.visible(false), true) && model.color(model.value(fill).value).components?.first == 1)
        #expect(Symbols.liveOverrides(of: w.second, in: state).isEmpty, "the other instance is untouched")
        Render.view(OverridesSectionView(model: model))
        // Reset one, then all.
        _ = await model.reset(fill)?.value
        await w.world.document.settle()
        #expect(!model.value(fill).overridden && w.world.document.undoTitle == "Undo Reset override")
        _ = await model.resetAll()?.value
        await w.world.document.settle()
        #expect(!model.hasOverrides && w.world.document.undoTitle == "Undo Reset all overrides")
        // A file that cannot be read, or a refused store, writes nothing.
        model.chooseFile = { nil }
        #expect(model.chooseImage(image) == nil)
        model.chooseFile = { picture }
        model.storeBlob = { _, _ in throw CancellationError() }
        #expect(await model.chooseImage(image)?.value == nil)
        // The view's editors reach the model.
        OverridesSectionView.committing(text, model)("On sale")
        OverridesSectionView.color(stroke, model, value: nil).wrappedValue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        OverridesSectionView.visible(visible, model, value: .visible(true)).wrappedValue = false
        #expect(OverridesSectionView.visible(visible, model, value: nil).wrappedValue && !OverridesSectionView.visible(visible, model, value: .visible(false)).wrappedValue)
        OverridesSectionView.action { model.reset(visible) }()
        OverrideRowView.resetting(fill, model)()
        OverrideRowView.choosing(image, model)()
        #expect(OverridesSectionModel.text(.visible(true)) == nil)
        await w.world.document.settle()
        #expect(Symbols.textNode(w.text, in: w.first, state: w.world.document.state)?.string == "On sale")
        // The colour panel's stream is written once it settles (D-076).
        #expect(await eventually { Symbols.liveOverrides(of: w.first, in: w.world.document.state)[stroke.key] != nil })
        // A picture of an unknown type is stored as plain data.
        let odd = FileManager.default.temporaryDirectory.appendingPathComponent("override-\(UUID().uuidString).zzzq")
        try Data([1, 2, 3]).write(to: odd)
        defer { try? FileManager.default.removeItem(at: odd) }
        model.chooseFile = { odd }
        model.storeBlob = { blob, _ in stored.value.append(blob) }
        _ = await model.chooseImage(image)?.value
        #expect(stored.value.last?.uti == UTType.data.identifier)
        // Detach releases the instance.
        _ = await model.detach()?.value
        await w.world.document.settle()
        #expect(!w.world.document.state.isLive(w.first) && w.world.document.undoTitle == "Undo Detach instance")
    }

    @Test func severalInstancesShowMixedValuesAndDifferentSymbolsExplain() async throws {
        let w = try await SectionWorld.make()
        defer { w.world.close() }
        let fill = try #require(w.row(w.rect, .fill)), visible = try #require(w.row(w.rect, .hidden))
        _ = await w.world.document.perform(SetOverride([w.first], master: w.rect, value: .fill(SymbolFixtureColors.red), in: w.world.document.state)).value
        await w.world.document.settle()
        let both = w.model([w.first, w.second])
        #expect(both.value(fill).value == nil && both.value(fill).overridden, "mixed, and one overrides it")
        #expect(both.color(nil) == CGColor(gray: 0, alpha: 1))
        Render.view(OverridesSectionView(model: both))
        _ = await w.world.document.perform(SetOverride([w.first], master: w.rect, value: .hidden(true), in: w.world.document.state)).value
        await w.world.document.settle()
        #expect(both.value(visible).value == nil)
        Render.view(OverridesSectionView(model: both))
        _ = await both.setVisible(visible, false)?.value
        await w.world.document.settle()
        #expect([w.first, w.second].allSatisfy { Symbols.liveOverrides(of: $0, in: w.world.document.state)[visible.key]?.hidden == true })
        // Instances of another symbol: an explanation and no rows.
        let square = try #require(await w.world.document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)]).first?.opID)
        let other = try #require(await w.world.document.perform(CopyToSymbol([square])).value?.createdNodes.first)
        let third = try #require(await w.world.document.perform(PlaceInstance(other, at: Point(x: 600, y: 600))).value?.createdObjects.first)
        await w.world.document.settle()
        let mixed = w.model([w.first, third])
        #expect(mixed.symbol == nil && mixed.rows.isEmpty && mixed.explanation == OverridesSectionModel.differentSymbols)
        Render.view(OverridesSectionView(model: mixed))
        // A missing symbol, and a symbol with nothing to override.
        _ = await w.world.document.perform(RemoveSymbols([other], instances: .release, in: w.world.document.state)).value
        let layer = try #require(Objects.parent(of: w.first, in: w.world.document.state))
        let orphan = try #require(await w.world.document.perform(OpsCommand("Orphan", ops: [
            Ops.create(parent: layer, position: [0xF8],
                       props: .with { $0.instance.symbol.id = OpID(counter: 999, replica: 9).proto }),
        ])).value?.createdNodes.first)
        await w.world.document.settle()
        #expect(w.model([orphan]).explanation == OverridesSectionModel.missingSymbol)
        let empty = try #require(await w.world.document.perform(OpsCommand("Empty", ops: [
            Ops.create(parent: WellKnown.symbols, position: [0xF8], props: .with { $0.symbol.common.name = "Empty" }),
        ])).value?.createdNodes.first)
        let hollow = try #require(await w.world.document.perform(PlaceInstance(empty, at: .zero)).value?.createdObjects.first)
        await w.world.document.settle()
        #expect(w.model([hollow]).explanation == OverridesSectionModel.nothingToOverride)
        // The section shows for instances only.
        let section = OverridesSection.section { _, _ in }
        #expect(section.make(ObjectPanelModel(document: w.world.document, selection: Selection([SelectionID(w.first)]))) != nil)
        #expect(section.make(ObjectPanelModel(document: w.world.document, selection: Selection([]))) == nil)
        #expect(InspectorRegistry.standard.sections.contains { $0.id == "text" && $0.kinds?.contains(.instance) == true })
    }

    @Test func aRemoteResetWhileARowIsEditedKeepsTheRowAndTheTyping() async throws {
        let w = try await SectionWorld.make()
        defer { w.world.close() }
        let model = w.model([w.first])
        let text = try #require(w.row(w.text, .text))
        _ = await model.setText(text, "Sold out")?.value
        await w.world.document.settle()
        let rows = model.rows
        // Someone else resets it while this person is still typing in the field.
        _ = await w.world.document.receiveRemote(ResetOverrides([w.first], key: text.key))
        #expect(model.rows == rows && model.value(text) == (.text("Buy now"), false), "the row stays, showing the symbol's text")
        // The field's keystrokes still land when it commits.
        _ = await model.setText(text, "Sold out again")?.value
        await w.world.document.settle()
        #expect(Symbols.textNode(w.text, in: w.first, state: w.world.document.state)?.string == "Sold out again")
    }

    @Test func twoReplicasTypingIntoOneOverrideShowTheMergedTextInThePanel() async throws {
        let w = try await SectionWorld.make()
        defer { w.world.close() }
        let text = try #require(w.row(w.text, .text))
        _ = await w.world.document.perform(OverrideText(w.first, master: w.text, edit: .insert("!", at: 7))).value
        await w.world.document.settle()
        // Two people type into the same override at once.
        let state = w.world.document.state
        var mine = DocumentCore(state: state, replica: 0x51)
        var theirs = DocumentCore(state: state, replica: 0x52)
        let a = try #require(try mine.perform(OverrideText(w.first, master: w.text, edit: .insert("Now ", at: 0)), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let b = try #require(try theirs.perform(OverrideText(w.first, master: w.text, edit: .insert("!!", at: 8)), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        mine.receive(b, serverSeq: 0)
        theirs.receive(a, serverSeq: 0)
        #expect(mine.state.stateHash == theirs.state.stateHash)
        _ = await w.world.document.receive(a).value
        _ = await w.world.document.receive(b).value
        await w.world.document.settle()
        let merged = Symbols.textNode(w.text, in: w.first, state: w.world.document.state)?.string
        #expect(merged == "Now Buy now!!!" && merged == Symbols.textNode(w.text, in: w.first, state: mine.state)?.string)
        #expect(w.model([w.first]).value(text) == (.text("Now Buy now!!!"), true))
    }
}

/// Mark values for these tests.
enum TextFixtureValues {
    static func size(_ size: Double) -> Wiretuner_Doc_V1_TextMarkValue { .with { $0.size = size } }
    static func family(_ name: String) -> Wiretuner_Doc_V1_TextMarkValue { .with { $0.fontFamily = name } }
}

enum SymbolFixtureColors {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)
}
