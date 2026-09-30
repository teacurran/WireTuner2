import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Styles panel's text operations (TYPE-035): new styles per *Build text styles based on*,
/// Redefine, every Style Behavior control, the dropped style and the commands.
@Suite(.serialized) @MainActor struct TextStyleOperationTests {
    /// A window with Normal Text and a three-paragraph block whose paragraphs differ in size.
    static func world() async throws -> (TypeWorld, OpID) {
        let world = TypeWorld()
        _ = await world.document.perform(CreateNormalTextStyle()).value
        let node = try await world.block("Big\nSmall\nSmaller")
        let text = try #require(world.state.textNode(node))
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: text.anchor(at: 4), value: .with { $0.size = 30 })).value
        _ = await world.document.perform(ApplyMark(node: node, from: text.anchor(at: 4), to: .end, value: .with { $0.size = 10 })).value
        return (world, node)
    }

    static func model(_ world: TypeWorld, _ node: OpID) -> ObjectPanelModel {
        ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)]), textSession: world.window.objectEditing.textSession)
    }

    @Test func newStylesFollowBuildTextStylesBasedOn() async throws {
        let (world, node) = try await Self.world()
        defer { world.close() }
        let model = Self.model(world, node)
        #expect(model.styleAttributes(firstParagraph: true).character.size == 30)
        #expect(!model.styleAttributes(firstParagraph: false).character.hasSize, "shared attributes leave the size unset")
        _ = await TextStyleOperations.newStyle(.paragraph, model: model, firstParagraph: true)?.value
        let made = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        #expect(made.attrs.character.size == 30)
        _ = await TextStyleOperations.newStyle(.character, model: Self.model(world, node), firstParagraph: false)?.value
        let character = try #require(world.state.textStyles.styles(.character).first)
        #expect(!character.attrs.hasParagraph || character.attrs.paragraph == Wiretuner_Doc_V1_ParagraphSettings())
        // With nothing selected, a child of the style chosen.
        let empty = ObjectPanelModel(document: world.document, selection: Selection())
        _ = await TextStyleOperations.newStyle(.paragraph, model: empty, firstParagraph: true, parent: made.id)?.value
        #expect(world.state.textStyles.styles(.paragraph).contains { $0.parent == made.id })
        #expect(TextStyleOperations.newStyle(.paragraph, model: empty, firstParagraph: true) == nil)
        // Redefine from the selection.
        _ = await TextStyleOperations.redefine(made.id, model: Self.model(world, node), firstParagraph: false)?.value
        #expect(world.state.textStyles.style(made.id)?.attrs.character.size == 30, "a setting the paragraphs do not share is left as it was")
        _ = await TextStyleOperations.redefine(character.id, model: Self.model(world, node), firstParagraph: true)?.value
        #expect(world.state.textStyles.style(character.id)?.attrs.character.size == 30)
        #expect(TextStyleOperations.redefine(made.id, model: empty, firstParagraph: true) == nil)
        #expect(TextStyleOperations.currentStyle(empty) == world.state.textStyles.normalText)
        // The preference.
        let preferences = world.setup.environment.preferences
        #expect(TextStyleOperations.firstParagraph(preferences))
        _ = preferences.set("shared", for: PreferenceCatalog.Text.styleBasedOn)
        #expect(!TextStyleOperations.firstParagraph(preferences))
    }

    @Test func theStyleBehaviorRulerSetsTabsAndIndents() async throws {
        let (world, node) = try await Self.world()
        defer { world.close() }
        _ = await TextStyleOperations.newStyle(.paragraph, model: Self.model(world, node), firstParagraph: true)?.value
        let style = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        let behavior = TextStyleBehaviorModel(style: style, in: world.state)
        let ruler = StyleTabRuler(model: behavior)
        #expect(ruler.width == StyleTabRuler.length && ruler.scale == 1 && ruler.stops.isEmpty && !behavior.tabsChanged)
        // The ruler view's well drops a left stop; the source takes the edit, so nothing is performed.
        let view = StyleTabRulerView.makeRuler(behavior)
        view.begin(at: NSPoint(x: -TextRulerView.wellWidth + 3, y: 10))
        #expect(view.end(at: NSPoint(x: 50.004, y: 10)) == nil)
        #expect(behavior.tabs.map(\.position) == [50] && behavior.tabsChanged)
        #expect(ruler.place(.right, at: 400) == nil && behavior.tabs.count == 1, "past the ruler's end: nothing")
        _ = ruler.place(.center, at: 20)
        #expect(ruler.stops.map(\.stop.kind) == [.center, .left])
        _ = ruler.dragStop(from: 50, to: 80, offRuler: false, duplicate: false)
        _ = ruler.dragStop(from: 80, to: 120, offRuler: false, duplicate: true)
        _ = ruler.dragStop(from: 20, to: 0, offRuler: true, duplicate: false)
        _ = ruler.dragStop(from: 80, to: 0, offRuler: true, duplicate: true)
        _ = ruler.dragStop(from: 77, to: 0, offRuler: true, duplicate: false)
        #expect(behavior.tabs.map(\.position) == [80, 120])
        #expect(ruler.defaultTicks.first == 144)
        // Indents.
        _ = ruler.dragIndent(.left, by: 10)
        #expect(ruler.leftIndent == 10 && ruler.firstLine == 0)
        _ = ruler.dragIndent(.firstLine, by: 5)
        _ = ruler.dragIndent(.both, by: 5)
        _ = ruler.dragIndent(.right, by: -20)
        _ = ruler.dragIndent(.right, by: 0)
        #expect(ruler.leftIndent == 15 && ruler.firstLine == 10 && ruler.rightIndent == StyleTabRuler.length - 20)
        // btn:[OK]: the indents and the tab stops in one change.
        let command = try #require(behavior.command as? CompositeCommand)
        #expect(command.label == "Edit style \(style.name)")
        _ = await world.window.objectEditing.perform(command).value
        var attrs = try #require(world.state.textStyles.style(style.id)?.attrs)
        #expect(attrs.paragraph.tabsSet && attrs.paragraph.tabs.map(\.position).sorted() == [80, 120])
        #expect(attrs.paragraph.leftIndent == 15 && attrs.paragraph.firstLineIndent == -5 && attrs.paragraph.rightIndent == 20)
        // Tabs alone; then *No selection* unsets tabs and indents.
        let tabsOnly = TextStyleBehaviorModel(style: try #require(world.state.textStyles.style(style.id)), in: world.state)
        #expect(!tabsOnly.tabsChanged && tabsOnly.command == nil)
        _ = StyleTabRuler(model: tabsOnly).place(.decimal, at: 200)
        #expect(tabsOnly.command is SetTextStyleTabs)
        tabsOnly.clearTabsAndIndents()
        _ = await world.window.objectEditing.perform(try #require(tabsOnly.command)).value
        attrs = try #require(world.state.textStyles.style(style.id)?.attrs)
        #expect(!attrs.paragraph.tabsSet && attrs.paragraph.tabs.isEmpty && !attrs.paragraph.hasLeftIndent && !attrs.paragraph.hasRightIndent)
        PanelRendering.host(TextStyleBehaviorSheet(model: tabsOnly, commit: { _ in }, cancel: {}))
        // A character style has no tabs.
        _ = await TextStyleOperations.newStyle(.character, model: Self.model(world, node), firstParagraph: true)?.value
        let character = TextStyleBehaviorModel(style: try #require(world.state.textStyles.styles(.character).first), in: world.state)
        character.tabs = [.with { $0.position = 10 }]
        #expect(!character.tabsChanged)
    }

    @Test func everyStyleBehaviorControlSetsOrClearsItsField() async throws {
        let (world, node) = try await Self.world()
        defer { world.close() }
        _ = await TextStyleOperations.newStyle(.paragraph, model: Self.model(world, node), firstParagraph: true)?.value
        let style = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        let behavior = TextStyleBehaviorModel(style: style, in: world.state)
        #expect(behavior.command == nil && !behavior.isCharacter)
        behavior.family.wrappedValue = "Courier"
        behavior.face.wrappedValue = "Bold"
        behavior.size.wrappedValue = "14"
        behavior.leading.wrappedValue = "Auto"
        behavior.rangeKerning.wrappedValue = "5"
        behavior.baselineShift.wrappedValue = "2"
        behavior.horizontalScale.wrappedValue = "90"
        behavior.effect.wrappedValue = "Underline"
        behavior.alignment.wrappedValue = .center
        behavior.paragraphNumber(\.spaceAbove, has: \.hasSpaceAbove) { $0.clearSpaceAbove() }.wrappedValue = "6"
        behavior.keepLines.wrappedValue = "2"
        behavior.hangPunctuation.wrappedValue = "On"
        behavior.keepWithNext.wrappedValue = "Off"
        behavior.affectsColor.wrappedValue = true
        behavior.next.wrappedValue = style.id.description
        #expect(behavior.family.wrappedValue == "Courier" && behavior.leading.wrappedValue == "Auto" && behavior.effect.wrappedValue == "Underline")
        #expect(behavior.hangPunctuation.wrappedValue == "On" && behavior.keepWithNext.wrappedValue == "Off" && behavior.next.wrappedValue == style.id.description)
        #expect(behavior.size.wrappedValue == "14" && behavior.keepLines.wrappedValue == "2")
        let command = try #require(behavior.command)
        _ = await world.window.objectEditing.perform(command).value
        var attrs = try #require(world.state.textStyles.style(style.id)?.attrs)
        #expect(attrs.character.fontFamily == "Courier" && attrs.character.fontStyle == "Bold" && attrs.character.size == 14)
        #expect(attrs.character.leading.mode == .percent && attrs.character.rangeKerning == 5 && attrs.character.baselineShift == 2 && attrs.character.horizontalScale == 90)
        #expect(TextEffectKind(attrs.character.effect) == .underline && attrs.paragraph.alignment == .center && attrs.paragraph.spaceAbove == 6)
        #expect(attrs.paragraph.keepLines == 2 && attrs.paragraph.hangPunctuation && attrs.paragraph.hasKeepWithNext && !attrs.paragraph.keepWithNext)
        #expect(attrs.affectsColor && attrs.hasNext)
        // No selection clears each field.
        let clear = TextStyleBehaviorModel(style: try #require(world.state.textStyles.style(style.id)), in: world.state)
        for binding in [clear.family, clear.face, clear.leading, clear.effect, clear.hangPunctuation, clear.keepWithNext, clear.next] {
            binding.wrappedValue = TextStyleBehaviorModel.noSelection
        }
        for binding in [clear.size, clear.rangeKerning, clear.baselineShift, clear.horizontalScale, clear.keepLines] { binding.wrappedValue = "" }
        clear.alignment.wrappedValue = .unspecified
        clear.paragraphNumber(\.spaceAbove, has: \.hasSpaceAbove) { $0.clearSpaceAbove() }.wrappedValue = ""
        clear.leading.wrappedValue = "Solid"
        clear.effect.wrappedValue = "No effect"
        #expect(clear.effect.wrappedValue == "No effect" && clear.leading.wrappedValue == "Solid")
        clear.size.wrappedValue = "abc"
        _ = await world.window.objectEditing.perform(try #require(clear.command)).value
        attrs = try #require(world.state.textStyles.style(style.id)?.attrs)
        #expect(!attrs.character.hasFontFamily && !attrs.character.hasSize && !attrs.paragraph.hasAlignment && !attrs.paragraph.hasSpaceAbove && !attrs.hasNext)
        #expect(attrs.character.hasEffect && attrs.character.leading.mode == .extra)
        // Global settings.
        let global = TextStyleBehaviorModel(style: try #require(world.state.textStyles.style(style.id)), in: world.state)
        global.apply(.noSettings)
        #expect(global.attrs == Wiretuner_Doc_V1_TextStyleAttrs())
        global.apply(.original)
        #expect(global.attrs == global.original)
        global.apply(.defaults)
        #expect(!global.attrs.hasNext)
        global.affectsColor.wrappedValue = false
        let binding = TextStyleBehaviorSheet.global(global)
        #expect(binding.wrappedValue == "Global settings")
        binding.wrappedValue = TextStyleBehaviorModel.Global.original.rawValue
        binding.wrappedValue = "nothing"
        // The sheets render and commit.
        var committed: (any WTModel.Command)??
        PanelRendering.host(TextStyleBehaviorSheet(model: global, commit: { committed = .some($0) }, cancel: {}))
        TextStyleBehaviorSheet.committing(global) { committed = .some($0) }()
        #expect(committed != nil)
        var redefined: OpID?
        PanelRendering.host(RedefineTextStyleSheet(styles: world.state.textStyles.styles(.paragraph), selected: style.id, commit: { redefined = $0 }, cancel: {}))
        RedefineTextStyleSheet.committing(style.id) { redefined = $0 }()
        RedefineTextStyleSheet.committing(nil) { _ in Issue.record("nothing chosen") }()
        #expect(redefined == style.id)
        // A character style's sheet leaves paragraph fields alone.
        _ = await TextStyleOperations.newStyle(.character, model: Self.model(world, node), firstParagraph: true)?.value
        let character = try #require(world.state.textStyles.styles(.character).first)
        let characterModel = TextStyleBehaviorModel(style: character, in: world.state)
        characterModel.alignment.wrappedValue = .right
        characterModel.apply(.defaults)
        #expect(characterModel.isCharacter && characterModel.changedFields.allSatisfy { $0.first != 3 })
        PanelRendering.host(TextStyleBehaviorSheet(model: characterModel, commit: { _ in }, cancel: {}))
    }

    @Test func aDroppedStyleChangesTheParagraphOrTheBlockAndTheCommandsRun() async throws {
        let (world, node) = try await Self.world()
        defer { world.close() }
        _ = await TextStyleOperations.newStyle(.paragraph, model: Self.model(world, node), firstParagraph: true)?.value
        let style = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        let bounds = try #require(world.document.object(for: SelectionID(node))?.bounds)
        let top = Point(x: bounds.minX + 5, y: bounds.minY + 5)
        _ = await TextStyleOperations.drop(style.id, at: top, on: world.window, wholeBlock: false)?.value
        let styles = world.state.textStyles
        var paragraphs = try #require(world.state.textNode(node)).paragraphs
        #expect(styles.paragraphStyle(paragraphs[0].props).style == style.id && styles.paragraphStyle(paragraphs[2].props).style != style.id)
        _ = await TextStyleOperations.drop(style.id, at: top, on: world.window, wholeBlock: true)?.value
        paragraphs = try #require(world.state.textNode(node)).paragraphs
        #expect(paragraphs.allSatisfy { world.state.textStyles.paragraphStyle($0.props).style == style.id })
        #expect(TextStyleOperations.drop(style.id, at: Point(x: -900, y: -900), on: world.window, wholeBlock: true) == nil)
        _ = await TextStyleOperations.newStyle(.character, model: Self.model(world, node), firstParagraph: true)?.value
        let character = try #require(world.state.textStyles.styles(.character).first)
        _ = await TextStyleOperations.drop(character.id, at: top, on: world.window, wholeBlock: true)?.value
        // The commands.
        let preferences = world.setup.environment.preferences
        let commands = TextStyleOperations.commands(window: { [weak window = world.window] in window }, preferences: preferences)
        #expect(commands.map(\.title) == ["New Paragraph Style", "New Character Style", "Redefine Style…", "Style Behavior…"])
        #expect(commands.allSatisfy { $0.validation().isEnabled } && commands[2].contexts.contains(.style))
        for command in commands {
            if case .perform(let run) = command.action { run() }
            await world.document.settle()
            if let sheet = world.window.window?.attachedSheet { world.window.window?.endSheet(sheet) }
        }
        world.window.selection.model.clear()
        let none = TextStyleOperations.commands(window: { [weak window = world.window] in window }, preferences: preferences)
        #expect(!none[0].validation().isEnabled)
        #expect(TextStyleOperations.presentBehavior(OpID(counter: 999, replica: 9), on: world.window) == nil)
    }

    @Test func twoReplicasRenamingOneStyleConverge() async throws {
        let (world, node) = try await Self.world()
        defer { world.close() }
        _ = await TextStyleOperations.newStyle(.paragraph, model: Self.model(world, node), firstParagraph: true)?.value
        let style = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        _ = await world.document.perform(RenameTextStyle(style.id, to: "Local")).value
        await world.document.receiveRemote(RenameTextStyle(style.id, to: "Remote"))
        #expect(["Local", "Remote"].contains(world.state.textStyles.style(style.id)?.name ?? ""))
    }
}
