import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// COLOR-006's scene hook: colours resolve through the document's swatches while a scene is
/// built, a swatch change repaints exactly the objects using it; the new-document template; and
/// COLOR-011's `ApplyColor`.
@Suite struct ColorSceneTests {
    static func fillColor(_ scene: DocumentScene, _ node: OpID) -> Color? {
        guard case .path(let item)? = scene.object(node)?.item, case .fill(let paint)? = item.appearance.items.first else { return nil }
        return paint.paint.color
    }

    @Test func aSwatchRecolourShowsLiveAndRepaintsOnlyItsUsers() throws {
        var a = Replica(0xA)
        let grape = try ColorFixture.add(&a, Color(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let tint = try ColorFixture.tint(&a, of: grape, 50)
        let resolver = ColorResolver(a.state)
        let direct = try ColorFixture.shape(&a, fill: resolver.reference(to: grape))
        let unnamedTint = try ColorFixture.shape(&a, fill: resolver.tint(of: grape, percent: 25))
        let viaTint = try ColorFixture.shape(&a, fill: resolver.reference(to: tint))
        let plain = try ColorFixture.shape(&a, fill: ColorResolver.inline(Color(red: 0, green: 1, blue: 0)))
        let grouped = try ColorFixture.shape(&a, fill: resolver.reference(to: grape))
        try a.perform(GroupObjects([grouped, plain]))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let green = Color(red: 0, green: 0.6, blue: 0)
        let change = try #require(try a.perform(RedefineSwatch(grape, to: green, autoRename: false)))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .remote)
        #expect(Self.fillColor(scene, direct) == green, "the reference shows the swatch as it is now, not its cache")
        #expect(Self.fillColor(scene, viaTint) == green.tinted(0.5))
        #expect(Self.fillColor(scene, unnamedTint) == green.tinted(0.25))
        let touched = summary.touchedNodes
        #expect(touched.contains(NodeID(direct)) && touched.contains(NodeID(unnamedTint)) && touched.contains(NodeID(viaTint)))
        #expect(touched.contains(NodeID(grouped)) && !touched.contains(NodeID(plain)), "only the swatch's users repaint")
        #expect(builder.swatchIndex?.dependents(of: grape).isEmpty == false)
        // Removing the swatch: its users keep the colour (the cache refreshed by the removal).
        let removal = try #require(try a.perform(RemoveSwatches([grape])))
        let (removed, removedSummary) = builder.apply(removal, state: a.state, origin: .local)
        #expect(Self.fillColor(removed, direct) == green)
        #expect(removedSummary.touchedNodes.contains(NodeID(direct)))
    }

    @Test func aBuilderThatNeverRebuiltReadsTheIndexOnItsFirstChange() throws {
        var a = Replica(0xB)
        let grape = try ColorFixture.add(&a, Color(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let user = try ColorFixture.shape(&a, fill: ColorResolver(a.state).reference(to: grape))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        #expect(builder.swatchIndex == nil)
        let change = try #require(try a.perform(RenameSwatch(grape, to: "Plum")))
        let (_, summary) = builder.apply(change, state: a.state, origin: .remote)
        #expect(summary.touchedNodes.contains(NodeID(user)))
        #expect(builder.swatchIndex != nil)
        let (_, reloaded) = builder.reload(a.state)
        #expect(reloaded.touchedNodes.contains(NodeID(user)))
    }

    @Test func outputListsResolveSwatchesToo() throws {
        var a = Replica(0xC)
        let grape = try ColorFixture.add(&a, Color(red: 0.5, green: 0, blue: 0.5), name: "Grape", spot: true)
        let user = try ColorFixture.shape(&a, fill: ColorResolver(a.state).reference(to: grape))
        try a.perform(RedefineSwatch(grape, to: Color(red: 1, green: 0, blue: 0), autoRename: false))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let output = builder.outputDisplayList(a.state)
        guard case .path(let item)? = output.items.first, case .fill(let paint)? = item.appearance.items.first else {
            Issue.record("no fill")
            return
        }
        #expect(paint.paint.color?.spot?.name == "Grape" && paint.paint.color?.red == 1)
        #expect(Self.fillColor(builder.scene, user)?.red == 1)
    }

    // MARK: The template

    @Test func aNewDocumentStartsWithTheDefaultsAndNoUndoStep() throws {
        let core = DocumentTemplate.core(replica: 0xD, now: Replica.now)
        let list = SwatchList(core.state)
        #expect(list.swatches.map(\.name) == ["White", "Black", "Registration"])
        #expect(core.undoStack.undo.isEmpty, "the template is not something to undo")
        #expect(DocumentTemplate().label == "Default colors" && !DocumentTemplate().recordsUndo && AddSwatch(.black).recordsUndo)
        var again = core
        #expect(try again.perform(DocumentTemplate(), recording: DocumentCore.Recording(limit: 10, now: Replica.now)) == nil, "defaults present: nothing")
    }

    // MARK: ApplyColor

    /// A shape with a Basic fill under a Gradient fill, and a Basic stroke.
    static func twoFills(_ replica: inout Replica) throws -> OpID {
        let node = try ColorFixture.shape(&replica, fill: ColorResolver.inline(.white), stroke: ColorResolver.inline(.black))
        var gradient = Wiretuner_Doc_V1_Fill()
        gradient.settings.kind = .gradient
        try replica.perform(AddAppearance.fill([node], gradient))
        return node
    }

    @Test func applyColorWritesTheTopmostBasicRowOfEachObject() throws {
        var a = Replica(0xE)
        let grape = try ColorFixture.add(&a, Color(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let first = try ColorFixture.shape(&a, fill: ColorResolver.inline(.white), stroke: ColorResolver.inline(.black))
        let second = try ColorFixture.shape(&a, fill: ColorResolver.inline(.white))
        let group = try ColorFixture.shape(&a, fill: ColorResolver.inline(.white))
        let member = try ColorFixture.shape(&a, fill: ColorResolver.inline(.white))
        let grouping = try #require(try a.perform(GroupObjects([group, member])))
        let groupID = ColorFixture.created(grouping)[0]
        let ref = ColorResolver(a.state).reference(to: grape)
        let command = ApplyColor([first, second, groupID], target: .fill, color: ref, name: "Grape")
        #expect(command.label == "Apply \"Grape\" to 3 objects")
        #expect(ApplyColor([first], target: .fill, color: ColorResolver.none).label == "Apply None")
        #expect(ApplyColor([first], target: .stroke, color: ref).label == "Apply color")
        #expect(ApplyColor.rows([first, first], target: .both, in: a.state).count == 2, "a node is written once")
        try a.perform(command)
        for node in [first, second, group, member] {
            #expect(AppearanceEditing.entries(node, in: a.state).first { $0.row.list == .fills }?.fill.settings.basic.color == ref)
        }
        #expect(AppearanceEditing.entries(first, in: a.state).first { $0.row.list == .strokes }?.stroke.settings.basic.color == ColorResolver.inline(.black))
        try a.perform(ApplyColor([first], target: .both, color: ColorResolver.none))
        #expect(AppearanceEditing.entries(first, in: a.state).allSatisfy { AttributeFields.color($0) == ColorResolver.none })
        // The topmost Basic fill, past a gradient; the stroke target leaves the fills alone.
        let layered = try Self.twoFills(&a)
        try a.perform(ApplyColor([layered], target: .stroke, color: ref))
        let entries = AppearanceEditing.entries(layered, in: a.state)
        #expect(entries.first { $0.row.list == .strokes }?.stroke.settings.basic.color == ref)
        try a.perform(ApplyColor([layered], target: .fill, color: ref))
        #expect(AppearanceEditing.entries(layered, in: a.state).first { $0.kind == .fill(.basic) }?.fill.settings.basic.color == ref)
        // Nothing to colour: no change.
        let bare = try a.perform(CreateShape(.ellipse, size: Size(width: 1, height: 1), appearance: Wiretuner_Doc_V1_AppearanceProps()))!.createdObjects[0]
        #expect(try a.perform(ApplyColor([bare], target: .fill, color: ref)) == nil)
        #expect(ColorTarget.allCases.map(\.title) == ["Fill", "Stroke", "Both"] && ColorTarget.both.lists == [.fills, .strokes])
    }
}
