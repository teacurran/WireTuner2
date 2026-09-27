import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Paragraph section (TYPE-026), the text ruler (TYPE-023), colour drops on text (TYPE-030)
/// and the Flow Around Selection sheet (TYPE-039).
@Suite(.serialized) @MainActor struct TypeLayoutUITests {
    static func model(_ world: TypeWorld, _ nodes: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: world.document, selection: Selection(nodes.map { SelectionID($0) }), textSession: world.window.objectEditing.textSession)
    }

    // MARK: Paragraph section (TYPE-026)

    @Test func eachParagraphControlWritesOnlyItsRegister() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("One\nTwo")
        let section = try #require(Self.model(world, [node]).paragraph)
        #expect(section.spaceAbove == 0 && section.hyphenate == .off && section.ruleMode == Wiretuner_Doc_V1_RuleMode.none)
        let fields: [([UInt32], String)] = [
            (ObjectPanelModel.ParagraphField.spaceAbove, "Space Above"), (ObjectPanelModel.ParagraphField.spaceBelow, "Space Below"),
            (ObjectPanelModel.ParagraphField.leftIndent, "Left Indent"), (ObjectPanelModel.ParagraphField.rightIndent, "Right Indent"),
            (ObjectPanelModel.ParagraphField.firstLineIndent, "First Line Indent"),
        ]
        for (index, (field, label)) in fields.enumerated() {
            _ = await Self.model(world, [node]).setParagraphValue(field, Double(index + 2), label: label)?.value
            #expect(world.document.undoTitle == "Undo \(label)")
        }
        let props = try #require(world.state.textNode(node)?.paragraphs.map(\.props))
        #expect(props.allSatisfy { $0.spaceAbove == 2 && $0.spaceBelow == 3 && $0.leftIndent == 4 && $0.rightIndent == 5 && $0.firstLineIndent == 6 })
        #expect(props.allSatisfy { $0.alignment == .unspecified }, "nothing else written")
        #expect(Self.model(world, [node]).setParagraphValue([99], 1, label: "x") == nil)
        #expect(Self.model(world, [node]).setParagraphValue(ObjectPanelModel.ParagraphField.spaceAbove, .nan, label: "x") == nil)
        _ = await Self.model(world, [node]).setHyphenate(true)?.value
        _ = await Self.model(world, [node]).setHyphenation(.with { $0.language = "de"; $0.consecutive = 2; $0.skipCapitalized = true })?.value
        _ = await Self.model(world, [node]).setHangPunctuation(true)?.value
        _ = await Self.model(world, [node]).setRuleMode(.centered)?.value
        _ = await Self.model(world, [node]).setRule(.with { $0.widthPercent = 50; $0.basis = .column; $0.position = 4; $0.above = true; $0.stroke.width = 2 },
                                                    overridesStroke: true)?.value
        _ = await Self.model(world, [node]).setAlignmentSettings(raggedWidth: 150, flushZone: -5)?.value
        let after = try #require(world.state.textNode(node)?.paragraphs[0].props)
        #expect(after.hyphenation.enabled && after.hyphenation.language == "de" && after.hyphenation.consecutive == 2 && after.hyphenation.skipCapitalized)
        #expect(after.hangPunctuation && after.rule.mode == .centered && after.rule.widthPercent == 50 && after.rule.basis == .column && after.rule.above)
        #expect(after.rule.stroke.width == 2 && after.raggedWidth == 100 && after.flushZone == 0)
        _ = await Self.model(world, [node]).setParagraphValue(ObjectPanelModel.ParagraphField.raggedWidth, 80, label: "Ragged")?.value
        _ = await Self.model(world, [node]).setParagraphValue(ObjectPanelModel.ParagraphField.flushZone, 30, label: "Flush")?.value
        _ = await Self.model(world, [node]).setRule(.with { $0.widthPercent = 70 }, overridesStroke: false)?.value
        // The Text tool's paragraph only; mixed values show as mixed.
        await world.edit(node, select: 5..<5)
        _ = await Self.model(world, [node]).setParagraphValue(ObjectPanelModel.ParagraphField.spaceAbove, 12, label: "Space Above")?.value
        await world.settle()
        world.window.objectEditing.textSession = nil
        let mixed = try #require(Self.model(world, [node]).paragraph)
        #expect(mixed.spaceAbove == nil && mixed.spaceBelow == 3)
        _ = await Self.model(world, [node]).inhibitHyphens(true)?.value
        #expect(try #require(world.state.textNode(node)).values(at: 0).contains { $0.noHyphen })
        // Nothing selected: no section.
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).paragraph == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).setParagraph(.init(), fields: [[7]], label: "x") == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).paragraphProps.isEmpty)
    }

    @Test func alignmentAndSpaceAboveFromTwoReplicasBothApply() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Merged")
        await world.document.receiveRemote(SetParagraph(node: node, from: .start, to: .end, props: .with { $0.alignment = .center }, fields: [[1]]))
        _ = await Self.model(world, [node]).setParagraphValue(ObjectPanelModel.ParagraphField.spaceAbove, 8, label: "Space Above")?.value
        let props = try #require(world.state.textNode(node)?.paragraphs[0].props)
        #expect(props.alignment == .center && props.spaceAbove == 8)
    }

    @Test func theParagraphSectionAndItsSheetsRender() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Rendered")
        let model = Self.model(world, [node])
        let section = try #require(model.paragraph)
        TypeSections.register(into: .standard)
        #expect(InspectorRegistry.standard.views(for: model).map(\.id).contains("textParagraph"))
        PanelRendering.host(ParagraphSectionView(section: section, model: model))
        ParagraphSectionView.commit(ObjectPanelModel.ParagraphField.spaceBelow, "Space Below", model)(9)
        let hyphenate = ParagraphSectionView.toggle(section.hyphenate) { model.setHyphenate($0) }
        #expect(!hyphenate.wrappedValue)
        hyphenate.wrappedValue = true
        let rule = ParagraphSectionView.rule(section, model)
        #expect(rule.wrappedValue == "None")
        rule.wrappedValue = "Paragraph"
        rule.wrappedValue = "Unknown"
        await world.settle()
        let mixedSection = ObjectPanelModel.ParagraphSection(nodes: [node], editing: false, spaceAbove: nil, spaceBelow: nil, leftIndent: nil, rightIndent: nil,
                                                              firstLineIndent: nil, hyphenate: .mixed, hangPunctuation: .mixed, ruleMode: nil, first: .init())
        #expect(ParagraphSectionView.rule(mixedSection, model).wrappedValue == ParagraphSectionView.mixed)
        PanelRendering.host(ParagraphSectionView(section: mixedSection, model: model))
        var sheet: ParagraphSectionView.Sheet?
        let binding = Binding(get: { sheet }, set: { sheet = $0 })
        ParagraphSectionView.opening(.rule, binding)()
        #expect(sheet?.id == "rule")
        var closed = 0
        for value in [ParagraphSectionView.Sheet.hyphenation, .rule, .alignment] {
            PanelRendering.host(ParagraphSectionView.sheetView(value, section: section, model: model) { closed += 1 })
        }
        // The sheets' actions.
        var hyphenation: Wiretuner_Doc_V1_Hyphenation?
        var inhibited: Bool?
        let hyphenSheet = HyphenationSheet(hyphenation: .with { $0.consecutive = 3 }, editing: true, commit: { hyphenation = $0 },
                                           inhibit: { inhibited = $0 }, cancel: {})
        PanelRendering.host(hyphenSheet)
        HyphenationSheet.committing(.with { $0.language = "fr" }, { hyphenation = $0 })()
        #expect(hyphenation?.language == "fr")
        var value = Wiretuner_Doc_V1_Hyphenation()
        let consecutive = HyphenationSheet.consecutive(Binding(get: { value }, set: { value = $0 }))
        consecutive.wrappedValue = 4
        consecutive.wrappedValue = -1
        #expect(consecutive.wrappedValue == 0)
        let inhibit = HyphenationSheet.inhibiting { inhibited = $0 }
        inhibit.wrappedValue = true
        #expect(inhibited == true && !inhibit.wrappedValue && HyphenationSheet.languages.first?.code == "")
        var committedRule: (Wiretuner_Doc_V1_ParagraphRule, Bool)?
        PanelRendering.host(ParagraphRuleSheet(rule: .with { $0.stroke.width = 1 }, commit: { committedRule = ($0, $1) }, cancel: {}))
        PanelRendering.host(ParagraphRuleSheet(rule: .init(), commit: { committedRule = ($0, $1) }, cancel: {}))
        ParagraphRuleSheet.committing(.with { $0.widthPercent = 40 }, true) { committedRule = ($0, $1) }()
        #expect(committedRule?.0.widthPercent == 40 && committedRule?.1 == true)
        var ruleValue = Wiretuner_Doc_V1_ParagraphRule()
        let tint = ParagraphRuleSheet.strokeTint(Binding(get: { ruleValue }, set: { ruleValue = $0 }))
        #expect(tint.wrappedValue == 100)
        tint.wrappedValue = 40
        #expect(abs(tint.wrappedValue - 40) < 1e-9)
        var alignment: (Double, Double)?
        PanelRendering.host(AlignmentSheet(raggedWidth: 90, flushZone: 10, commit: { alignment = ($0, $1) }, cancel: {}))
        AlignmentSheet.committing(80, 20) { alignment = ($0, $1) }()
        #expect(alignment?.0 == 80 && alignment?.1 == 20)
    }

    // MARK: Text ruler (TYPE-023)

    @Test func theRulerPlacesMovesAndRemovesStopsAndMovesIndents() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try #require(await world.document.perform(CreateTextBlock(.area(Rect(x: 40, y: 40, width: 300, height: 100)), text: "Tabs\ttext")).value?.createdObjects.first)
        await world.document.settle()
        await world.edit(node, select: 0..<0)
        let session = try #require(world.session)
        var model = TextRulerModel(session: session, viewport: world.window.viewport)
        #expect(model.width == 300 && model.defaultTicks.first == 36 && model.defaultTicks.count == 8)
        // Each kind from the well.
        for (index, kind) in TextRulerModel.wellKinds.enumerated() {
            _ = await world.window.objectEditing.perform(try #require(model.place(kind, at: Double(index + 1) * 50))).value
        }
        await world.settle()
        model = TextRulerModel(session: session, viewport: world.window.viewport)
        #expect(model.stops.map(\.stop.kind) == TextRulerModel.wellKinds && model.stops.map(\.stop.position) == [50, 100, 150, 200, 250])
        #expect(model.defaultTicks == [252.0, 288.0], "no default ticks left of the last stop")
        #expect(model.place(.left, at: 400) == nil)
        // Move, duplicate and drag off.
        _ = await world.window.objectEditing.perform(try #require(model.dragStop(from: 50, to: 60, offRuler: false, duplicate: false))).value
        _ = await world.window.objectEditing.perform(try #require(model.dragStop(from: 60, to: 70, offRuler: false, duplicate: true))).value
        _ = await world.window.objectEditing.perform(try #require(model.dragStop(from: 250, to: 250, offRuler: true, duplicate: false))).value
        #expect(model.dragStop(from: 100, to: 100, offRuler: false, duplicate: false) == nil)
        #expect(model.dragStop(from: 100, to: 100, offRuler: true, duplicate: true) == nil)
        await world.settle()
        model = TextRulerModel(session: session, viewport: world.window.viewport)
        #expect(model.stops.map(\.stop.position) == [60, 70, 100, 150, 200])
        // Each indent marker.
        for (indent, delta) in [(TextRulerModel.Indent.left, 10.0), (.firstLine, 5), (.both, 4), (.right, -20)] {
            _ = await world.window.objectEditing.perform(try #require(model.dragIndent(indent, by: delta))).value
            await world.settle()
            model = TextRulerModel(session: session, viewport: world.window.viewport)
        }
        let props = try #require(world.state.textNode(node)?.paragraphs[0].props)
        #expect(props.leftIndent == 14 && props.firstLineIndent == -5 && props.rightIndent == 20)
        #expect(model.leftIndent == 14 && model.firstLine == 9 && model.rightIndent == 280)
        #expect(model.dragIndent(.left, by: 0) == nil && model.dragIndent(.left, by: .infinity) == nil)
        #expect(model.scale > 0 && abs(model.angle) < 1e-9 && model.position(model.scale * 10) == 10)
    }

    @Test func theRulerViewsGesturesAndTheTrackingLine() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try #require(await world.document.perform(CreateTextBlock(.area(Rect(x: 40, y: 40, width: 300, height: 100)), text: "Ruler")).value?.createdObjects.first)
        await world.document.settle()
        let rulers = TextRulers(window: world.window, defaults: world.setup.environment.preferences.defaults)
        rulers.update()
        #expect(rulers.view.isHidden, "no Text tool session")
        await world.edit(node, select: 0..<0)
        rulers.update()
        #expect(!rulers.view.isHidden && rulers.view.superview === world.window.canvas)
        let view = rulers.view
        let scale = try #require(view.model?.scale)
        // Drag a left stop from the well onto the ruler.
        let well = NSPoint(x: -TextRulerView.wellWidth + 2, y: 10)
        #expect(view.grab(at: well) == .well(.left))
        view.begin(at: well)
        view.drag(to: NSPoint(x: 80 * scale, y: 10))
        #expect(rulers.tracking == 80)
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rulers.drawTracking(in: context, viewport: world.window.viewport)
        _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
        #expect(view.end(at: NSPoint(x: 80 * scale, y: 10)) != nil && rulers.tracking == nil)
        await world.settle()
        rulers.update()
        #expect(view.model?.stops.map(\.stop.position) == [80])
        // Move it with a drag, then drag it off.
        #expect(view.grab(at: NSPoint(x: 80 * scale, y: 12)) == .stop(80))
        view.begin(at: NSPoint(x: 80 * scale, y: 12))
        view.drag(to: NSPoint(x: 90 * scale, y: 12))
        _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
        view.end(at: NSPoint(x: 90 * scale, y: 12))
        await world.settle()
        rulers.update()
        #expect(view.model?.stops.map(\.stop.position) == [90])
        view.begin(at: NSPoint(x: 90 * scale, y: 12))
        view.end(at: NSPoint(x: 90 * scale, y: 60))
        await world.settle()
        rulers.update()
        #expect(view.model?.stops.isEmpty == true)
        // The indent markers.
        #expect(view.grab(at: NSPoint(x: 0, y: 2)) == .indent(.both))
        #expect(view.grab(at: NSPoint(x: 0, y: 6)) == .indent(.left))
        #expect(view.grab(at: NSPoint(x: 0, y: 15)) == .indent(.firstLine))
        #expect(view.grab(at: NSPoint(x: 300 * scale, y: 6)) == .indent(.right))
        #expect(view.grab(at: NSPoint(x: 150 * scale, y: 6)) == nil)
        #expect(view.grab(at: NSPoint(x: -TextRulerView.wellWidth - 20, y: 6)) == nil)
        view.begin(at: NSPoint(x: 0, y: 6))
        view.end(at: NSPoint(x: 12 * scale, y: 6))
        await world.settle()
        #expect(abs((world.state.textNode(node)?.paragraphs[0].props.leftIndent ?? 0) - 12) < 1e-9)
        // A press on nothing does nothing.
        view.begin(at: NSPoint(x: 150 * scale, y: 6))
        view.drag(to: NSPoint(x: 160 * scale, y: 6))
        #expect(view.end(at: NSPoint(x: 160 * scale, y: 6)) == nil)
        for kind in TextRulerModel.wellKinds + [.unspecified] { #expect(!TextRulerView.stopGlyph(kind, at: .zero).isEmpty) }
        // Hidden by menu:View[Text Rulers]; the command toggles it.
        let command = TypeWindowParts.textRulersCommand(defaults: world.setup.environment.preferences.defaults) { [weak window = world.window] in window }
        #expect(command.validation().isChecked)
        if case .perform(let run) = command.action { run() }
        #expect(!rulers.isShown)
        rulers.update()
        #expect(rulers.view.isHidden)
        rulers.isShown = true
        rulers.tracksLine = { false }
        rulers.drawTracking(in: context, viewport: world.window.viewport)
        let empty = TextRulerView()
        empty.place(in: world.window.canvas)
        #expect(empty.grab(at: .zero) == nil && empty.end(at: .zero) == nil)
        _ = empty.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 10, height: 10)).map { empty.cacheDisplay(in: NSRect(x: 0, y: 0, width: 10, height: 10), to: $0) }
    }

    @Test func theWindowPartsAttachOnce() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let preferences = world.setup.environment.preferences
        let parts = TypeWindowParts.attach(world.window, preferences: preferences)
        #expect(TypeWindowParts.attach(world.window, preferences: preferences) === parts && TypeWindowParts.parts(of: world.window) === parts)
        #expect(!world.window.canvas.overlayExtras.isEmpty && world.window.canvas.textColorDrop != nil)
        world.window.canvas.drawOverlay(in: try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)))
        #expect(world.window.canvas.textColorDrop?(NSPasteboard(name: NSPasteboard.Name("uid-empty-\(UUID().uuidString)")), .zero) == false)
        TypeWindowParts.detach(world.window)
        #expect(TypeWindowParts.parts(of: world.window) == nil)
    }

    @Test func aClosedWindowsPartsAreNeverHandedToAnotherWindow() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let preferences = world.setup.environment.preferences
        let other = TypeWorld()
        let stale = TypeWindowParts.attach(other.window, preferences: preferences)
        // Closing the window detaches its parts.
        other.close()
        #expect(TypeWindowParts.parts(of: other.window) == nil)
        // An entry left by a deallocated window whose address this window now has: never reused.
        TypeWindowParts.entries[ObjectIdentifier(world.window)] = TypeWindowParts.Entry(window: nil, parts: stale)
        #expect(TypeWindowParts.parts(of: world.window) == nil)
        let fresh = TypeWindowParts.attach(world.window, preferences: preferences)
        #expect(fresh !== stale && TypeWindowParts.parts(of: world.window) === fresh)
        world.close()
        #expect(TypeWindowParts.parts(of: world.window) == nil)
    }

    @Test func aClosedWindowsCanvasDrawsNoneOfItsParts() async throws {
        var extras: [@MainActor (CGContext, Viewport) -> Void] = []
        var viewport: Viewport?
        weak var closed: DocumentWindowController?
        do {
            let other = TypeWorld()
            TypeWindowParts.attach(other.window, preferences: other.setup.environment.preferences)
            extras = other.window.canvas.overlayExtras
            viewport = other.window.viewport
            closed = other.window
            other.close()
        }
        await Task.yield()
        // Whether or not the controller is gone yet, its parts (which hold it unowned) are not touched.
        let context = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for extra in extras { extra(context, try #require(viewport)) }
        if let closed { #expect(TypeWindowParts.parts(of: closed) == nil) }
    }

    // MARK: Colour drops (TYPE-030)

    @Test func aColorDroppedOnTextGoesToTheCharactersTheBorderOrTheInterior() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try #require(await world.document.perform(CreateTextBlock(.area(Rect(x: 40, y: 40, width: 200, height: 80)), text: "Colored words")).value?.createdObjects.first)
        await world.document.settle()
        let red = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        let blue = ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1))
        let state = world.state
        // The block: a fill and a stroke added, then recoloured.
        _ = await world.window.objectEditing.perform(try #require(TextColorDrop.command(.interior(node), color: red, in: state))).value
        _ = await world.window.objectEditing.perform(try #require(TextColorDrop.command(.border(node), color: red, in: world.state))).value
        #expect(TextBlockAppearance.rows(node, in: world.state).count == 2)
        _ = await world.window.objectEditing.perform(try #require(TextColorDrop.command(.border(node), color: blue, in: world.state))).value
        #expect(TextBlockAppearance.rows(node, in: world.state).count == 2, "the existing stroke recoloured")
        // The characters.
        _ = await world.window.objectEditing.perform(try #require(TextColorDrop.command(.characters(node: node, range: 0..<7), color: blue, in: world.state))).value
        let text = try #require(world.state.textNode(node))
        #expect(text.values(at: 0).contains { $0.fill == blue } && !text.values(at: 8).contains { $0.fill == blue })
        #expect(TextColorDrop.command(.characters(node: node, range: 0..<99), color: blue, in: world.state) == nil)
        // Hit testing: the Text tool's selection takes the drop.
        let drop = TextColorDrop(window: world.window)
        let point = world.window.viewport.toView(Point(x: 60, y: 50))
        #expect(drop.target(at: world.window.viewport.toView(Point(x: 900, y: 900))) == nil)
        let plain = drop.target(at: point)
        #expect(plain == .interior(node) || plain == .border(node))
        await world.edit(node, select: 0..<4)
        #expect(drop.target(at: point) == .characters(node: node, range: 0..<4))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uid-color-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(drop.drop(pasteboard, at: point) == nil, "no colour")
        ColorDrag.write(ColorRefPasteboard(ref: red, color: RenderColor(red: 1, green: 0, blue: 0)), to: pasteboard)
        _ = await drop.drop(pasteboard, at: point)?.value
        #expect(try #require(world.state.textNode(node)).values(at: 1).contains { $0.fill == red })
        // A drop over a rectangle is not text's.
        _ = await world.document.addRectangles([Rect(x: 400, y: 400, width: 50, height: 50)])
        #expect(drop.target(at: world.window.viewport.toView(Point(x: 425, y: 425))) == nil)
    }

    @Test func twoReplicasDroppingOnOneWordConvergeToTheLater() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("word")
        let red = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        let blue = ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1))
        _ = await world.window.objectEditing.perform(try #require(TextColorDrop.command(.characters(node: node, range: 0..<4), color: red, in: world.state))).value
        await world.document.receiveRemote(try #require(TextColorDrop.command(.characters(node: node, range: 0..<4), color: blue, in: world.state)))
        #expect(try #require(world.state.textNode(node)).values(at: 2).contains { $0.fill == blue })
    }

    // MARK: Flow Around Selection (TYPE-039)

    @Test func theWrapSheetWritesTheObjectsTextWrap() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let body = try await world.block("body")
        let ids = await world.document.addRectangles([Rect(x: 60, y: 50, width: 20, height: 20)])
        let square = ids[0].opID
        world.window.selection.model.clear()
        #expect(TextWrapFeatures.targets(in: world.window) == .failure(.nothing) && TextWrapFeatures.targets(in: nil) == .failure(.nothing))
        let commands = TextWrapFeatures.commands { [weak window = world.window] in window }
        #expect(!commands[0].validation().isEnabled && commands[0].title == "Flow Around Selection…")
        world.window.selection.model.set(Selection(ids))
        #expect(commands[0].validation().isEnabled && TextWrapFeatures.targets(in: world.window) == .success([square]))
        #expect(TextWrapFeatures.current([square], in: world.state) == (false, 0))
        let sheet = try #require(TextWrapFeatures.present(on: world.window))
        world.window.window?.endSheet(sheet)
        if case .perform(let run) = commands[0].action { run() }
        if let open = world.window.window?.attachedSheet { world.window.window?.endSheet(open) }
        await TextWrapFeatures.apply(SetTextWrap([square], enabled: true, standoff: 4), editing: world.window.objectEditing, document: world.document).value
        #expect(TextWrapFeatures.current([square], in: world.state) == (true, 4))
        #expect(TextWrapping.wrappingObjects(for: body, in: world.state) == [square])
        // Groups are refused with a message.
        let group = try #require(await world.document.perform(GroupObjects([square])).value?.createdObjects.first)
        world.window.selection.model.set(Selection([SelectionID(group)]))
        var alerts: [String] = []
        #expect(TextWrapFeatures.present(on: world.window) { title, _ in alerts.append(title) } == nil)
        #expect(alerts == ["Text cannot wrap around this object"])
        world.window.selection.model.clear()
        #expect(TextWrapFeatures.present(on: world.window) { _, _ in Issue.record("no alert") } == nil)
        // The sheet.
        var committed: (Bool, Double)?
        PanelRendering.host(TextWrapSheet(enabled: true, standoff: 3, commit: { committed = ($0, $1) }, cancel: {}))
        TextWrapSheet.committing(true, 5) { committed = ($0, $1) }()
        #expect(committed?.0 == true && committed?.1 == 5)
        TextWrapSheet.removing { committed = ($0, $1) }()
        #expect(committed?.0 == false)
    }
}
