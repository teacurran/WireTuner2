import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// TYPE-022: the *Font* attribute of the Find & Replace panel's two tabs; TYPE-037's *Text
/// effect* attribute of the Select tab.
@Suite(.serialized) @MainActor struct TypeFindReplaceTests {
    /// Three blocks: Helvetica 12, Courier 18, and one half Helvetica half Courier Bold.
    static func fixture() async throws -> (document: DocumentHandle, plain: OpID, courier: OpID, mixed: OpID) {
        let document = DocumentHandle.memory(title: "Fonts")
        let plain = try #require(await document.addText("Plain Helvetica", at: Point(x: 20, y: 20)))
        let courier = try #require(await document.addText("All Courier", at: Point(x: 20, y: 80)))
        _ = await document.perform(ApplyMark(node: courier, from: .start, to: .end, value: .with { $0.fontFamily = "Courier" })).value
        _ = await document.perform(ApplyMark(node: courier, from: .start, to: .end, value: .with { $0.size = 18 })).value
        let mixed = try #require(await document.addText("HalfHalf", at: Point(x: 20, y: 140)))
        let text = try #require(document.state.textNode(mixed))
        _ = await document.perform(ApplyMark(node: mixed, from: text.anchor(at: 4), to: .end, value: .with { $0.fontFamily = "Courier" })).value
        _ = await document.perform(ApplyMark(node: mixed, from: text.anchor(at: 4), to: .end, value: .with { $0.fontStyle = "Bold" })).value
        await document.settle()
        return (document, plain, courier, mixed)
    }

    static func families(_ document: DocumentHandle, _ node: OpID) -> [String] {
        document.state.textNode(node)?.runs.map { ObjectPanelModel.family($0.values) } ?? []
    }

    @Test func criteriaMatchFamilyFaceAndSizeRanges() {
        let helvetica12: [Wiretuner_Doc_V1_TextMarkValue] = []
        let courierBold18: [Wiretuner_Doc_V1_TextMarkValue] = [.with { $0.fontFamily = "Courier" }, .with { $0.fontStyle = "Bold" }, .with { $0.size = 18 }]
        #expect(FontCriteria().matches(helvetica12) && FontCriteria().matches(courierBold18))
        #expect(FontCriteria(family: "Courier").matches(courierBold18) && !FontCriteria(family: "Courier").matches(helvetica12))
        #expect(FontCriteria(style: "Bold").matches(courierBold18) && !FontCriteria(style: "Bold").matches(helvetica12))
        #expect(FontCriteria(minSize: 12).matches(helvetica12) && !FontCriteria(minSize: 12).matches(courierBold18), "only Min: one exact size")
        #expect(FontCriteria(minSize: 10, maxSize: 20).matches(courierBold18) && !FontCriteria(minSize: 13, maxSize: 20).matches(helvetica12))
        #expect(FontCriteria(maxSize: 12).matches(helvetica12) && !FontCriteria(maxSize: 12).matches(courierBold18))
        #expect(FontCriteria(family: "Courier", style: "Bold", minSize: 10, maxSize: 20).summary == "Courier Bold 10–20 pt")
        #expect(FontCriteria(minSize: 9).summary == "any font 9 pt" && FontCriteria(maxSize: 30).summary == "any font up to 30 pt")
        #expect(FontReplacement(family: "Inter", style: "Medium", size: 14).summary == "Inter Medium 14 pt")
        #expect(FontReplacement().isEmpty && FontReplacement(size: 0).isEmpty && !FontReplacement(size: 9).isEmpty)
        #expect(FontReplacement(family: "", size: 20_000).values.isEmpty)
        #expect(EffectCriteria.any.matches([.with { $0.effect = TextEffectKind.zoom.defaultEffect }]) && !EffectCriteria.any.matches([]))
        #expect(EffectCriteria.kind(.zoom).matches([.with { $0.effect = TextEffectKind.zoom.defaultEffect }]))
        #expect(!EffectCriteria.kind(.shadow).matches([.with { $0.effect = TextEffectKind.zoom.defaultEffect }]))
        #expect(SearchScope.allCases.map(\.title) == ["Selection", "Page", "Document"])
    }

    @Test func replacingAFamilyIsOneChangeTouchingOnlyMatchingRuns() async throws {
        let (document, plain, courier, mixed) = try await Self.fixture()
        let search = TypeAttributeSearch(document: document, selection: .empty)
        let (command, blocks) = try #require(search.replaceFont(FontCriteria(family: "Courier"), with: FontReplacement(family: "Menlo"), in: .document))
        #expect(blocks == 2)
        let change = try #require(await document.perform(command).value)
        #expect(change.label == "Replace font Courier → Menlo (2 blocks)")
        #expect(change.ops.allSatisfy { if case .textMark? = $0.op { true } else { false } }, "only marks")
        #expect(change.ops.count == 2, "one mark per matched run")
        #expect(Self.families(document, plain) == ["Helvetica"])
        #expect(Self.families(document, courier) == ["Menlo"])
        #expect(Self.families(document, mixed) == ["Helvetica", "Menlo"])
        #expect(document.undoTitle == "Undo Replace font Courier → Menlo (2 blocks)")
        // Nothing matching, or nothing to change: no change.
        #expect(search.replaceFont(FontCriteria(family: "Futura"), with: FontReplacement(family: "Menlo"), in: .document) == nil)
        #expect(search.replaceFont(FontCriteria(), with: FontReplacement(), in: .document) == nil)
        // Size and face together, in the selection only.
        let selected = TypeAttributeSearch(document: document, selection: Selection([SelectionID(plain)]))
        let (resize, count) = try #require(selected.replaceFont(FontCriteria(minSize: 12), with: FontReplacement(style: "Italic", size: 24), in: .selection))
        #expect(count == 1)
        _ = await document.perform(resize).value
        let values = document.state.textNode(plain)?.runs.first?.values ?? []
        #expect(ObjectPanelModel.size(values) == 24 && ObjectPanelModel.style(values) == "Italic")
        #expect(ObjectPanelModel.size(document.state.textNode(courier)?.runs.first?.values ?? []) == 18)
    }

    @Test func findSelectsMatchingBlocksAddingOrRemoving() async throws {
        let (document, plain, courier, mixed) = try await Self.fixture()
        let search = TypeAttributeSearch(document: document, selection: .empty)
        #expect(search.find(in: .document) { FontCriteria(family: "Courier").matches($0) } == [courier, mixed])
        #expect(search.find(in: .document) { FontCriteria(style: "Bold").matches($0) } == [mixed])
        // Page scope: blocks whose box meets the current page (the fixture's are on the pasteboard).
        let page = try #require(document.currentPage)
        let onPage = try #require(await document.addText("On the page", at: Point(x: page.minX + 30, y: page.minY + 30)))
        #expect(search.find(in: .page) { FontCriteria(family: "Helvetica").matches($0) } == [onPage])
        #expect(search.bounds(of: plain) != nil && search.bounds(of: OpID(counter: 999, replica: 9)) == nil)
        let empty = try #require(await document.perform(CreateTextBlock(.point(Point(x: 300, y: 300)))).value?.createdObjects.first)
        await document.settle()
        #expect(search.runs(of: empty) { _ in true } == [0..<0] && search.runs(of: empty) { _ in false }.isEmpty)
        #expect(search.runs(of: OpID(counter: 999, replica: 9)) { _ in true }.isEmpty)
        let current = Selection([SelectionID(plain), SelectionID(courier)])
        #expect(TypeAttributeSearch.selection(after: [mixed], current: current, scope: .document, adjust: false).ids == [SelectionID(mixed)])
        #expect(TypeAttributeSearch.selection(after: [mixed, plain], current: current, scope: .page, adjust: true).ids == [SelectionID(plain), SelectionID(courier), SelectionID(mixed)])
        #expect(TypeAttributeSearch.selection(after: [courier], current: current, scope: .selection, adjust: true).ids == [SelectionID(plain)])
        // Locked blocks are not found.
        _ = await document.perform(SetLocked([courier], locked: true)).value
        await document.settle()
        #expect(TypeAttributeSearch(document: document, selection: .empty).blocks(in: .document).contains(courier) == false)
    }

    @Test func thePanelStateChangesAndFinds() async throws {
        let (document, _, courier, mixed) = try await Self.fixture()
        let selection = ActiveSelection(model: SelectionModel(), document: document)
        let state = FindReplaceState()
        #expect(state.change(nil) == nil && state.find(nil).isEmpty)
        state.from = FontCriteria(family: "Courier")
        state.to = FontReplacement(size: 30)
        let change = try #require(await state.change(selection)?.value)
        #expect(change.label.hasPrefix("Replace font Courier → 30 pt") && state.result == "2 blocks changed")
        state.from = FontCriteria(family: "Futura")
        #expect(state.change(selection) == nil && state.result == "No blocks changed")
        state.select(.select)
        state.from = FontCriteria(family: "Courier")
        #expect(state.find(selection) == [courier, mixed] && state.result == "2 blocks found")
        #expect(selection.model?.ids == [SelectionID(courier), SelectionID(mixed)])
        state.attribute = .textEffect
        _ = await document.perform(ApplyMark(node: mixed, from: .start, to: .end, value: .with { $0.effect = TextEffectKind.zoom.defaultEffect })).value
        state.effect = .kind(.zoom)
        #expect(state.find(selection) == [mixed] && state.result == "1 block found")
        state.select(.replace)
        #expect(state.attribute == .font, "the Replace tab has no text effect attribute")
        #expect(FindReplaceState.Attribute.available(in: .replace) == [.font] && FindReplaceState.Tab.select.title == "Select")
        let single = ActiveSelection(model: SelectionModel(Selection([SelectionID(courier)])), document: document)
        state.to = FontReplacement(size: 11)
        state.from = FontCriteria()
        state.scope = .selection
        _ = await state.change(single)?.value
        #expect(state.result == "1 block changed")
    }

    @Test func thePanelBodyAndItsBindings() async throws {
        let (document, _, _, _) = try await Self.fixture()
        let selection = ActiveSelection(model: SelectionModel(), document: document)
        let state = FindReplaceState()
        for tab in FindReplaceState.Tab.allCases {
            state.select(tab)
            for attribute in FindReplaceState.Attribute.available(in: tab) {
                state.attribute = attribute
                _ = FindReplacePanelBody(selection: selection, state: state).body
            }
        }
        _ = FindReplacePanel.descriptor(selection: selection, state: state).makeView()
        var family: String? = nil
        let binding = FindReplacePanelBody.optional(Binding(get: { family }, set: { family = $0 }), none: FindReplacePanelBody.anyFont)
        #expect(binding.wrappedValue == FindReplacePanelBody.anyFont)
        binding.wrappedValue = "Courier"
        #expect(family == "Courier" && binding.wrappedValue == "Courier")
        binding.wrappedValue = FindReplacePanelBody.anyFont
        #expect(family == nil)
        var size: Double? = nil
        let field = FindReplacePanelBody.size(Binding(get: { size }, set: { size = $0 }))
        field.wrappedValue = "14"
        #expect(size == 14 && field.wrappedValue == "14")
        field.wrappedValue = "nope"
        #expect(size == 14, "refused text keeps the value")
        field.wrappedValue = " "
        #expect(size == nil)
        let effect = FindReplacePanelBody.effect(state)
        effect.wrappedValue = "Shadow"
        #expect(state.effect == .kind(.shadow) && effect.wrappedValue == "Shadow")
        effect.wrappedValue = "Any effect"
        #expect(state.effect == .any)
        #expect(!FindReplacePanelBody.families.isEmpty && !FindReplacePanelBody.styles(of: "Helvetica").isEmpty)
    }

    @Test func concurrentTypingInsideAMatchedRunPicksUpTheReplacement() async throws {
        let (document, _, courier, _) = try await Self.fixture()
        let (command, _) = try #require(TypeAttributeSearch(document: document, selection: .empty)
            .replaceFont(FontCriteria(family: "Courier"), with: FontReplacement(family: "Menlo"), in: .document))
        // A collaborator types inside the run before the replacement arrives.
        let text = try #require(document.state.textNode(courier))
        _ = await document.receiveRemote(InsertText(node: courier, text: "xyz", at: text.anchor(at: 3)))
        _ = await document.perform(command).value
        await document.settle()
        let node = try #require(document.state.textNode(courier))
        #expect(node.string == "Allxyz Courier")
        #expect(Self.families(document, courier) == ["Menlo"], "the typed characters are inside the replaced run")
    }
}
