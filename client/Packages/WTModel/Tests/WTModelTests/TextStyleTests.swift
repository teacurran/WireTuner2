import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTText

/// TYPE-034 text style nodes and resolution (text-styles.adoc).
@Suite struct TextStyleTests {
    static func attrs(_ build: (inout Wiretuner_Doc_V1_TextStyleAttrs) -> Void) -> Wiretuner_Doc_V1_TextStyleAttrs {
        var attrs = Wiretuner_Doc_V1_TextStyleAttrs()
        build(&attrs)
        return attrs
    }

    /// Creates a style on `replica`; returns its node.
    @discardableResult
    static func style(_ replica: inout Replica, _ kind: TextStyleKind = .paragraph, name: String = "",
                      basedOn: OpID? = nil, _ build: (inout Wiretuner_Doc_V1_TextStyleAttrs) -> Void = { _ in }) throws -> OpID {
        let change = try replica.perform(CreateTextStyle(kind, name: name, attrs: attrs(build), basedOn: basedOn))!
        return OpID(counter: change.startCounter, replica: change.replica)
    }

    static func size(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> Double? {
        values.compactMap { if case .size(let size)? = $0.value { size } else { nil } }.last
    }

    static func family(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> String? {
        values.compactMap { if case .fontFamily(let family)? = $0.value { family } else { nil } }.last
    }

    /// The character values of live offset `offset` as the layout resolves them.
    static func resolved(_ replica: Replica, _ node: OpID, _ offset: Int) -> [Wiretuner_Doc_V1_TextMarkValue] {
        let text = TextFixture.text(replica, node)
        let paragraph = text.paragraphs[text.paragraphIndex(at: offset)]
        return replica.state.textStyles.characterValues(text.values(at: offset), paragraph: paragraph.props)
    }

    // MARK: Styles and resolution

    @Test func createNamesAndChainsResolveRootToLeaf() throws {
        var a = Replica(1)
        let body = try Self.style(&a, name: "Body") { $0.character.size = 11; $0.character.fontFamily = "Helvetica"; $0.paragraph.leftIndent = 10 }
        let quote = try Self.style(&a, basedOn: body) { $0.character.size = 9; $0.paragraph.alignment = .center }
        let resolver = a.state.textStyles
        #expect(resolver.style(quote)?.name == "Style-1")
        #expect(resolver.style(quote)?.parent == body)
        #expect(resolver.chain(of: quote) == [quote, body])
        let resolved = try #require(resolver.resolved(quote))
        #expect(resolved.character.size == 9 && resolved.character.fontFamily == "Helvetica")
        #expect(resolved.paragraph.leftIndent == 10 && resolved.paragraph.alignment == .center)
        #expect(resolver.styles(.paragraph).map(\.name) == ["Body", "Style-1"])
        #expect(resolver.styles(.character).isEmpty)
        #expect(resolver.children(of: body) == [quote])
        #expect(CreateTextStyle.nextName(in: resolver) == "Style-2")
        // A character style keeps no paragraph settings; a parent of the other kind is refused.
        let emphasis = try Self.style(&a, .character, name: "Emphasis") { $0.character.fontStyle = "Italic"; $0.paragraph.leftIndent = 4 }
        #expect(!a.state.textStyles.style(emphasis)!.attrs.hasParagraph)
        #expect(throws: TextStyleError.notStyle(body)) { try a.perform(CreateTextStyle(.character, basedOn: body)) }
        #expect(throws: TextStyleError.invalidValue("name")) { try a.perform(CreateTextStyle(.paragraph, name: String(repeating: "x", count: 300))) }
        #expect(a.state.textStyles.style(OpID(counter: 99, replica: 9)) == nil)
    }

    @Test func cyclesAreCutAtTheSmallestNodeAndDanglingParentsAreRoots() throws {
        var a = Replica(1)
        let one = try Self.style(&a, name: "One") { $0.character.size = 1 }
        let two = try Self.style(&a, name: "Two", basedOn: one) { $0.character.size = 2 }
        let three = try Self.style(&a, name: "Three", basedOn: two) { $0.character.fontFamily = "Three" }
        // one -> three closes the loop one <- two <- three <- one.
        try a.perform(EditTextStyle(one, attrs: .init(), fields: [[2, 3]]))
        var parent = Wiretuner_Doc_V1_StyleProps()
        parent.basedOn.id = three.proto
        try a.perform(TestSet(node: one, path: TextStyleFields.basedOn, values: TextStyleFields.values { $0 = parent }))
        let resolver = a.state.textStyles
        // `one` is the smallest id: its based_on reads as unset.
        #expect(resolver.chain(of: three) == [three, two, one])
        #expect(resolver.chain(of: one) == [one])
        #expect(resolver.chain(of: two) == [two, one])
        #expect(resolver.resolved(three)?.character.size == 2)
        // A deleted parent reads as unset.
        try a.perform(RemoveTextStyle(one))
        #expect(a.state.textStyles.chain(of: two) == [two])
    }

    @Test func normalTextIsCreatedOnceAndGovernsUnstyledParagraphs() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "plain")
        let steps = a.core.undoStack.undo.count
        try a.perform(CreateNormalTextStyle())
        #expect(try a.perform(CreateNormalTextStyle()) == nil)
        let normal = try #require(a.state.textStyles.normalText)
        #expect(a.state.textStyles.style(normal)?.name == "Normal Text")
        #expect(a.state.textStyles.style(normal)?.isNormalText == true)
        #expect(a.core.undoStack.undo.count == steps)
        try a.perform(EditTextStyle(normal, attrs: Self.attrs { $0.character.size = 30 }, fields: [[2, 3]], name: "Normal Text"))
        #expect(Self.size(Self.resolved(a, node, 0)) == 30)
        #expect(throws: TextStyleError.normalText) { try a.perform(RemoveTextStyle(normal)) }
        // A deleted Normal Text still reads as live.
        try a.perform(TestSet(node: normal, delete: true))
        #expect(a.state.textStyles.isLive(normal))
    }

    @Test func resolutionOrderDefaultsParagraphStyleRegistersCharacterStyleMarks() throws {
        var a = Replica(1)
        // Document defaults: family "Default", size 8.
        var settings = Wiretuner_Doc_V1_SettingsProps()
        settings.defaults.text.character.fontFamily = "Default"
        settings.defaults.text.character.size = 8
        try a.perform(TestSet(node: WellKnown.settings, paths: [RegisterPath([2, 10, 3])], values: SettingsFields.values { $0 = settings }))
        let heading = try Self.style(&a, name: "Heading") {
            $0.character.size = 20
            $0.character.fill = Appearances.inline(red: 1, green: 0, blue: 0)
            $0.paragraph.spaceAbove = 12
            $0.paragraph.alignment = .center
        }
        let code = try Self.style(&a, .character, name: "Code") { $0.character.fontFamily = "Menlo"; $0.affectsColor = true
            $0.character.fill = Appearances.inline(red: 0, green: 0, blue: 1) }
        let node = try TextFixture.block(&a, "Title words\nbody")
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .start, style: heading))
        try a.perform(SetParagraph(node: node, from: .start, to: .start, props: .with { $0.alignment = .right }, fields: [[1]]))
        try a.perform(ApplyCharacterStyle(node: node, from: TextFixture.at(a, node, 6), to: TextFixture.at(a, node, 11), style: code))
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 8), to: TextFixture.at(a, node, 9), value: TextFixture.size(40)))
        let resolver = a.state.textStyles
        let text = TextFixture.text(a, node)
        // The paragraph: style's space above, own alignment over the style's centre.
        let first = resolver.paragraph(text.paragraphs[0].props)
        #expect(first.spaceAbove == 12 && first.alignment == .right)
        #expect(resolver.paragraph(text.paragraphs[1].props).spaceAbove == 0)
        // Characters: defaults < paragraph style < character style < marks.  Heading's fill does not
        // count (affects_color off); Code's does.
        let plain = Self.resolved(a, node, 0)
        #expect(Self.family(plain) == "Default" && Self.size(plain) == 20)
        #expect(!plain.contains { if case .fill? = $0.value { true } else { false } })
        let styled = Self.resolved(a, node, 7)
        #expect(Self.family(styled) == "Menlo" && Self.size(styled) == 20)
        #expect(styled.contains { if case .fill? = $0.value { true } else { false } })
        #expect(Self.size(Self.resolved(a, node, 8)) == 40)
        #expect(Self.family(Self.resolved(a, node, 13)) == "Default" && Self.size(Self.resolved(a, node, 13)) == 8)
        // The layout reads the resolution, run pieces cut at the paragraph end.
        let content = TextLayoutReading.content(text, context: TextReadingContext(node, in: a.state))
        #expect(content.runs.first?.attributes.fontFamily == "Default")
        #expect(content.runs.first?.attributes.size == 20)
        #expect(content.runs.last?.attributes.size == 8)
        #expect(content.paragraphs.first?.spaceAbove == 12)
        // Overrides: the alignment register and the size mark; the character style is no override.
        let overrides = resolver.overrides(in: text, paragraph: 0)
        #expect(overrides.paragraph == [1])
        #expect(overrides.character == ["3"])
        #expect(resolver.overrides(in: text, paragraph: 1).paragraph.isEmpty)
        #expect(resolver.overrides(in: text, paragraph: 5) == ([], []))
    }

    @Test func applyingAStyleAgainRemovesOverridesAndEditsShowThrough() throws {
        var a = Replica(1)
        let body = try Self.style(&a, name: "Body") {
            $0.character.size = 11
            $0.paragraph.leftIndent = 5
            $0.paragraph.tabsSet = true
            $0.paragraph.tabs = [.with { $0.position = 36 }]
            $0.character.features.liga = .off
        }
        let node = try TextFixture.block(&a, "one two")
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: body))
        try a.perform(ApplyMark(node: node, from: .start, to: TextFixture.at(a, node, 3), value: TextFixture.size(30)))
        try a.perform(SetParagraph(node: node, from: .start, to: .start, props: .with { $0.leftIndent = 50; $0.rightIndent = 7 }, fields: [[4], [5]]))
        var text = TextFixture.text(a, node)
        #expect(a.state.textStyles.overrides(in: text, paragraph: 0).paragraph == [4, 5])
        // Re-applying clears the governed ones (left indent, size) and keeps the right indent the style leaves alone.
        let change = try #require(try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .start, style: body)))
        #expect(change.label == "Apply style")
        text = TextFixture.text(a, node)
        #expect(text.paragraphs[0].props.leftIndent == 0 && text.paragraphs[0].props.rightIndent == 7)
        #expect(Self.size(Self.resolved(a, node, 0)) == 11)
        #expect(a.state.textStyles.overrides(in: text, paragraph: 0).paragraph == [5])
        #expect(a.state.textStyles.overrides(in: text, paragraph: 0).character.isEmpty)
        #expect(a.state.textStyles.paragraph(text.paragraphs[0].props).tabs.map(\.position) == [36])
        // Editing the style: every paragraph using it follows, with no ops to the text.
        let edit = try #require(try a.perform(EditTextStyle(body, attrs: Self.attrs { $0.character.size = 14 }, fields: [[2, 3]], name: "Body")))
        #expect(edit.label == "Edit style Body")
        #expect(edit.ops.allSatisfy { if case .set(let set)? = $0.op { OpID(set.node) == body } else { false } })
        #expect(Self.size(Self.resolved(a, node, 4)) == 14)
        #expect(throws: TextStyleError.invalidValue("fields")) { try a.perform(EditTextStyle(body, attrs: .init(), fields: [])) }
        #expect(EditTextStyle(body, attrs: .init(), fields: [[4]]).label == "Edit style")
        // Own tab stops are deleted when the style sets tabs.
        try a.perform(TestTab(node: node))
        #expect(!TextFixture.text(a, node).paragraphs[0].props.tabs.isEmpty)
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .start, style: body))
        #expect(TextFixture.text(a, node).paragraphs[0].props.tabs.isEmpty)
        // A character style on a paragraph, a paragraph style on characters: refused.
        let emphasis = try Self.style(&a, .character, name: "Em") { $0.character.fontStyle = "Italic" }
        #expect(throws: TextStyleError.notStyle(emphasis)) { try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: emphasis)) }
        #expect(throws: TextStyleError.notStyle(body)) { try a.perform(ApplyCharacterStyle(node: node, from: .start, to: .end, style: body)) }
        #expect(try a.perform(ApplyCharacterStyle(node: node, from: .start, to: .start, style: emphasis)) == nil)
    }

    @Test func otherKindsSelfParentsAndUnknownReferences() throws {
        var a = Replica(1)
        // A graphic style under 0:6 is not a text style.
        var graphic = Wiretuner_Doc_V1_NodeProps()
        graphic.style.kind = .graphic
        graphic.style.common.name = "Graphic"
        try a.perform(TestCreate(parent: TextStyleFields.collection, props: graphic))
        #expect(a.state.textStyles.styles(.paragraph).isEmpty)
        let emphasis = try Self.style(&a, .character, name: "Em")
        let body = try Self.style(&a, name: "Body")
        // Based on itself, or on a character style: read as roots.
        var parent = Wiretuner_Doc_V1_StyleProps()
        parent.basedOn.id = body.proto
        try a.perform(TestSet(node: body, path: TextStyleFields.basedOn, values: TextStyleFields.values { $0 = parent }))
        #expect(a.state.textStyles.chain(of: body) == [body])
        parent.basedOn.id = emphasis.proto
        try a.perform(TestSet(node: body, path: TextStyleFields.basedOn, values: TextStyleFields.values { $0 = parent }))
        #expect(a.state.textStyles.style(body)?.parent == nil)
        // A reference to an unknown style caches nothing.
        #expect(a.state.textStyles.ref(OpID(counter: 99, replica: 9)).cached.isEmpty)
        // Next naming a character style is ignored at a split.
        try a.perform(EditTextStyle(body, attrs: Self.attrs { $0.next = .with { $0.id = emphasis.proto } }, fields: [[1]]))
        let node = try TextFixture.block(&a, "one\ntwo")
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: body))
        try a.perform(SplitParagraph(node: node, at: TextFixture.at(a, node, 3), followsNextStyle: true))
        try a.perform(SplitParagraph(node: node, at: TextFixture.at(a, node, 5), followsNextStyle: true))
        let resolver = a.state.textStyles
        #expect(TextFixture.text(a, node).paragraphs.allSatisfy { resolver.paragraphStyle($0.props).style == body })
        // A style applied to an empty block writes its reference and no marks.
        let empty = try TextFixture.block(&a)
        let change = try #require(try a.perform(ApplyParagraphStyle(node: empty, from: .start, to: .end, style: body)))
        #expect(!change.ops.contains { if case .textMark? = $0.op { true } else { false } })
    }

    @Test func removingOneCharacterStyleKeepsAnothersMarks() throws {
        var a = Replica(1)
        let one = try Self.style(&a, .character, name: "One") { $0.character.size = 5 }
        let two = try Self.style(&a, .character, name: "Two") { $0.character.size = 7 }
        let base = try Self.style(&a, name: "Base") { $0.character.features.liga = .off }
        let child = try Self.style(&a, name: "Child", basedOn: base) { $0.paragraph.tabsSet = true; $0.paragraph.tabs = [.with { $0.position = 9 }] }
        let node = try TextFixture.block(&a, "aabb")
        try a.perform(ApplyCharacterStyle(node: node, from: .start, to: TextFixture.at(a, node, 2), style: one))
        try a.perform(ApplyCharacterStyle(node: node, from: TextFixture.at(a, node, 2), to: .end, style: two))
        try a.perform(RemoveTextStyle(one))
        #expect(Self.size(Self.resolved(a, node, 0)) == 5)
        #expect(Self.size(Self.resolved(a, node, 3)) == 7)
        // The child keeps its own tabs and takes the removed parent's feature.
        try a.perform(RemoveTextStyle(base))
        let resolved = try #require(a.state.textStyles.resolved(child))
        #expect(resolved.character.features.liga == .off && resolved.paragraph.tabs.map(\.position) == [9])
    }

    @Test func tabStopsOfAStyleAreElements() throws {
        var a = Replica(1)
        let body = try Self.style(&a, name: "Body")
        #expect(throws: TextStyleError.invalidValue("fields")) { try a.perform(EditTextStyle(body, attrs: .init(), fields: [[3, 9]])) }
        try a.perform(SetTextStyleTabs(body, tabs: [.with { $0.position = 20 }, .with { $0.position = 40; $0.kind = .right }]))
        var resolved = try #require(a.state.textStyles.resolved(body))
        #expect(resolved.paragraph.tabsSet && resolved.paragraph.tabs.map(\.position) == [20, 40])
        try a.perform(SetTextStyleTabs(body, tabs: [.with { $0.position = 30 }]))
        resolved = try #require(a.state.textStyles.resolved(body))
        #expect(resolved.paragraph.tabs.map(\.position) == [30])
        try a.perform(SetTextStyleTabs(body, tabs: nil))
        resolved = try #require(a.state.textStyles.resolved(body))
        #expect(!resolved.paragraph.tabsSet && resolved.paragraph.tabs.isEmpty)
        let em = try Self.style(&a, .character, name: "Em")
        #expect(throws: TextStyleError.notStyle(em)) { try a.perform(SetTextStyleTabs(em, tabs: [])) }
        #expect(throws: TextStyleError.invalidValue("fields")) { try a.perform(EditTextStyle(em, attrs: .init(), fields: [[3, 1]])) }
    }

    @Test func aWrongKindReferenceReadsAsItsCache() throws {
        var a = Replica(1)
        let emphasis = try Self.style(&a, .character, name: "Em") { $0.character.size = 33 }
        let node = try TextFixture.block(&a, "x")
        // A paragraph `style` register naming a character style, with a cache.
        var props = Wiretuner_Doc_V1_ParagraphProps()
        props.style.id = emphasis.proto
        props.style.cached = try Self.attrs { $0.character.size = 17 }.serializedData()
        try a.perform(SetParagraph(node: node, from: .start, to: .start, props: props, fields: [[17]]))
        let resolver = a.state.textStyles
        #expect(resolver.paragraphStyle(TextFixture.text(a, node).paragraphs[0].props).style == nil)
        #expect(Self.size(Self.resolved(a, node, 0)) == 17)
        // No cache: reads as no style.
        props.style.cached = Data()
        try a.perform(SetParagraph(node: node, from: .start, to: .start, props: props, fields: [[17]]))
        #expect(Self.size(Self.resolved(a, node, 0)) == nil)
    }

    @Test func removingAStyleLeavesEveryParagraphRenderingIdentically() throws {
        var a = Replica(1)
        let base = try Self.style(&a, name: "Base") { $0.character.fontFamily = "Georgia"; $0.paragraph.spaceBelow = 3 }
        let body = try Self.style(&a, name: "Body", basedOn: base) {
            $0.character.size = 13
            $0.character.features.ss02 = .on
            $0.paragraph.leftIndent = 9
            $0.paragraph.tabsSet = true
            $0.paragraph.tabs = [.with { $0.position = 72 }]
            $0.next = .with { $0.id = OpID(counter: 1, replica: 1).proto }
            $0.affectsColor = true
            $0.character.fill = Appearances.inline(red: 0, green: 1, blue: 0)
        }
        let child = try Self.style(&a, name: "Child", basedOn: body) { $0.character.fontStyle = "Bold" }
        let emphasis = try Self.style(&a, .character, name: "Em") { $0.character.size = 20 }
        let node = try TextFixture.block(&a, "styled text\nchild para")
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .start, style: body))
        try a.perform(ApplyParagraphStyle(node: node, from: .end, to: .end, style: child))
        try a.perform(ApplyCharacterStyle(node: node, from: TextFixture.at(a, node, 7), to: TextFixture.at(a, node, 11), style: emphasis))
        // The style changes after the text was styled: the caches are stale until the removal.
        try a.perform(EditTextStyle(body, attrs: Self.attrs { $0.character.size = 15 }, fields: [[2, 3]]))
        try a.perform(EditTextStyle(emphasis, attrs: Self.attrs { $0.character.size = 22 }, fields: [[2, 3]]))
        let before = TextLayoutReading.content(TextFixture.text(a, node), context: TextReadingContext(node, in: a.state))
        let change = try #require(try a.perform(RemoveTextStyle(body)))
        #expect(change.label == "Remove style")
        let after = TextLayoutReading.content(TextFixture.text(a, node), context: TextReadingContext(node, in: a.state))
        #expect(after == before)
        // The child now hangs off Base, with Body's settings folded in.
        let resolver = a.state.textStyles
        #expect(resolver.style(child)?.parent == base)
        #expect(resolver.style(child)?.attrs.character.size == 15)
        #expect(resolver.style(child)?.attrs.paragraph.tabs.map(\.position) == [72])
        #expect(!resolver.isLive(body))
        // Removing the character style too keeps the look through the mark's cache.
        try a.perform(RemoveTextStyle(emphasis))
        #expect(TextLayoutReading.content(TextFixture.text(a, node), context: TextReadingContext(node, in: a.state)) == before)
        // Undo restores the style and its links.
        a.undo()
        a.undo()
        #expect(a.state.textStyles.isLive(body))
        #expect(a.state.textStyles.style(child)?.parent == body)
        #expect(throws: TextStyleError.notStyle(OpID(counter: 99, replica: 9))) { try a.perform(RemoveTextStyle(OpID(counter: 99, replica: 9))) }
    }

    @Test func renameAndNextStyleAtSplit() throws {
        var a = Replica(1)
        let body = try Self.style(&a, name: "Body") { $0.paragraph.leftIndent = 4 }
        let heading = try Self.style(&a, name: "Heading") { $0.next = .with { $0.id = body.proto }; $0.paragraph.alignment = .center }
        let rename = try #require(try a.perform(RenameTextStyle(heading, to: "Title")))
        #expect(rename.label == "Rename style")
        #expect(a.state.textStyles.style(heading)?.name == "Title")
        #expect(throws: TextStyleError.invalidValue("name")) { try a.perform(RenameTextStyle(heading, to: "")) }
        let node = try TextFixture.block(&a, "Head")
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: heading))
        // Return in the middle keeps the style on both halves.
        try a.perform(SplitParagraph(node: node, at: TextFixture.at(a, node, 2), followsNextStyle: true))
        var resolver = a.state.textStyles
        var text = TextFixture.text(a, node)
        #expect(text.paragraphs.map { resolver.paragraphStyle($0.props).style } == [heading, heading])
        // Return at the end: the new paragraph takes Body.
        try a.perform(SplitParagraph(node: node, at: .end, followsNextStyle: true))
        resolver = a.state.textStyles
        text = TextFixture.text(a, node)
        #expect(text.paragraphs.map { resolver.paragraphStyle($0.props).style } == [heading, heading, body])
        // Without the flag, or with no next, nothing but the split.
        try a.perform(SplitParagraph(node: node, at: .end))
        try a.perform(SplitParagraph(node: node, at: .end, followsNextStyle: true))
        #expect(TextFixture.text(a, node).paragraphs.count == 5)
    }

    @Test func theResolverKeepsUnchangedChainsCached() throws {
        var a = Replica(1)
        let root = try Self.style(&a, name: "Root") { $0.character.size = 10 }
        _ = try Self.style(&a, name: "Leaf", basedOn: root) { $0.character.fontFamily = "A" }
        let other = try Self.style(&a, name: "Other") { $0.character.size = 12 }
        var resolver = TextStyleResolver(a.state)
        #expect(resolver.rebuilt == 3)
        try a.perform(EditTextStyle(other, attrs: Self.attrs { $0.character.size = 13 }, fields: [[2, 3]]))
        resolver.update(a.state)
        #expect(resolver.rebuilt == 1)
        try a.perform(EditTextStyle(root, attrs: Self.attrs { $0.character.size = 11 }, fields: [[2, 3]]))
        resolver.update(a.state)
        #expect(resolver.rebuilt == 2)
        #expect(TextStyleResolver().resolved(root) == nil)
    }

    @Test func editingAStyleUpdatesTenThousandParagraphsQuickly() throws {
        var a = Replica(1)
        let body = try Self.style(&a, name: "Body") { $0.character.size = 10; $0.paragraph.leftIndent = 3 }
        let count = PerfBudget.isMeasuring ? 10_000 : 1_000
        let node = try TextFixture.block(&a, Array(repeating: "p", count: count).joined(separator: "\n"))
        try a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: body))
        try a.perform(EditTextStyle(body, attrs: Self.attrs { $0.character.size = 12; $0.paragraph.leftIndent = 6 }, fields: [[2, 3], [3, 4]]))
        let text = TextFixture.text(a, node)
        let paragraphs = text.paragraphs
        let clock = ContinuousClock()
        var resolved: [Wiretuner_Doc_V1_ParagraphProps] = []
        let elapsed = clock.measure {
            let resolver = TextStyleResolver(a.state)
            resolved = paragraphs.map { resolver.paragraph($0.props) }
        }
        #expect(resolved.count == count)
        #expect(resolved.allSatisfy { $0.leftIndent == 6 })
        PerfBudget.expect(elapsed, within: .milliseconds(20), "resolve 10,000 paragraphs after a style edit")
    }

    // MARK: Merge

    @Test func applyStyleVersusConcurrentBoldConvergesWithTheLaterOpIdOnTheOverlap() throws {
        var pair = Pair()
        let heading = try Self.style(&pair.a, name: "Heading") { $0.character.fontStyle = "Light"; $0.character.size = 18 }
        let node = try TextFixture.block(&pair.a, "one two three")
        pair.sync()
        let bold = TextFixture.mark { $0.fontStyle = "Bold" }
        // B bolds "two" after enough edits that its OpId is the greater; A applies the style.
        for _ in 0..<40 {
            try pair.b.perform(SetTextBlock(node: node, block: .with { $0.width = 10 }, fields: [[3]]))
        }
        try pair.b.perform(ApplyMark(node: node, from: TextFixture.at(pair.b, node, 4), to: TextFixture.at(pair.b, node, 7), value: bold))
        try pair.a.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: heading))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        func style(_ offset: Int) -> String? {
            Self.resolved(pair.a, node, offset).compactMap { if case .fontStyle(let s)? = $0.value { s } else { nil } }.last
        }
        #expect(style(0) == "Light")
        #expect(style(5) == "Bold")
        #expect(Self.size(Self.resolved(pair.a, node, 5)) == 18)
        // The other order of OpIds: the style applied later wins the overlap.
        var other = Pair()
        let h2 = try Self.style(&other.b, name: "Heading") { $0.character.fontStyle = "Light" }
        let n2 = try TextFixture.block(&other.b, "one two")
        other.sync()
        try other.a.perform(ApplyMark(node: n2, from: .start, to: .end, value: bold))
        try other.b.perform(ApplyParagraphStyle(node: n2, from: .start, to: .end, style: h2))
        other.sync()
        #expect(other.a.state.stateHash == other.b.state.stateHash)
        #expect(Self.resolved(other.a, n2, 0).compactMap { if case .fontStyle(let s)? = $0.value { s } else { nil } }.last == "Light")
    }

    @Test func deleteStyleVersusApplyStyleConvergesWithTheCachedAppearance() throws {
        var pair = Pair()
        let heading = try Self.style(&pair.a, name: "Heading") { $0.character.size = 24; $0.paragraph.spaceAbove = 6 }
        let node = try TextFixture.block(&pair.a, "title")
        pair.sync()
        try pair.a.perform(RemoveTextStyle(heading))
        try pair.b.perform(ApplyParagraphStyle(node: node, from: .start, to: .end, style: heading))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            let text = TextFixture.text(replica, node)
            let resolver = replica.state.textStyles
            #expect(resolver.paragraphStyle(text.paragraphs[0].props).style == nil)
            #expect(resolver.paragraph(text.paragraphs[0].props).spaceAbove == 6)
            #expect(Self.size(Self.resolved(replica, node, 0)) == 24)
        }
    }

    @Test func twoReplicasEditDifferentSettingsOfOneStyle() throws {
        var pair = Pair()
        let body = try Self.style(&pair.a, name: "Body") { $0.character.size = 10 }
        pair.sync()
        try pair.a.perform(EditTextStyle(body, attrs: Self.attrs { $0.character.size = 12 }, fields: [[2, 3]]))
        try pair.b.perform(EditTextStyle(body, attrs: Self.attrs { $0.paragraph.alignment = .right }, fields: [[3, 1]]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let resolved = try #require(pair.a.state.textStyles.resolved(body))
        #expect(resolved.character.size == 12 && resolved.paragraph.alignment == .right)
    }

    // MARK: Attribute arithmetic

    @Test func everySettingOverlaysAndMapsToAMarkOrRegister() {
        let top = Self.attrs {
            let c = $0.character
            _ = c
            $0.character.fontFamily = "F"; $0.character.fontStyle = "S"; $0.character.size = 5
            $0.character.leading = .with { $0.mode = .fixed; $0.value = 14 }
            $0.character.rangeKerning = 3; $0.character.baselineShift = 2; $0.character.horizontalScale = 90
            $0.character.fill = Appearances.inline(red: 1, green: 1, blue: 0); $0.affectsColor = true
            $0.character.stroke = .with { $0.width = 2 }
            $0.character.effect = .with { $0.underline = .init() }
            $0.character.case = .smallCaps; $0.character.language = "fr"; $0.character.overprint = true
            $0.character.axes = .with { $0.axes = [.with { $0.tag = "wght"; $0.value = 700 }] }
            $0.character.features.calt = .off; $0.character.features.ss20 = .on
            $0.paragraph.alignment = .justified; $0.paragraph.raggedWidth = 80; $0.paragraph.flushZone = 70
            $0.paragraph.leftIndent = 1; $0.paragraph.rightIndent = 2; $0.paragraph.firstLineIndent = 3
            $0.paragraph.spaceAbove = 4; $0.paragraph.spaceBelow = 5
            $0.paragraph.tabsSet = true; $0.paragraph.tabs = [.with { $0.position = 9 }]
            $0.paragraph.hyphenation = .with { $0.enabled = true }; $0.paragraph.rule = .with { $0.mode = .centered }
            $0.paragraph.hangPunctuation = true; $0.paragraph.keepLines = 2; $0.paragraph.keepWithNext = true
            $0.paragraph.wordSpacing = .with { $0.opt = 100 }; $0.paragraph.letterSpacing = .with { $0.opt = 1 }
            $0.next = .with { $0.id = OpID(counter: 3, replica: 3).proto }
        }
        let merged = TextStyleAttributes.overlay(Self.attrs { $0.character.size = 99 }, top)
        #expect(merged == top)
        #expect(TextStyleAttributes.markValues(top).count == 16)
        #expect(Set(TextStyleAttributes.markValues(top).map(TextStyleAttributes.key)).count == 16)
        let paragraph = TextStyleAttributes.paragraph(top.paragraph)
        #expect(paragraph.fields == Array(1...16))
        #expect(TextStyleAttributes.setFields(paragraph.props) == Array(1...16))
        #expect(TextStyleAttributes.paragraph(paragraph.props, over: .init()) == paragraph.props)
        for field in UInt32(1)...16 {
            #expect(TextStyleAttributes.paragraphValue(paragraph.props, field) != Wiretuner_Doc_V1_ParagraphProps())
        }
        #expect(TextStyleAttributes.characterFields(top.character) == Array(1...15))
        #expect(TextStyleAttributes.paragraphSettingsFields(top.paragraph) == [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17])
        // A fill without "affects color" is left out.
        var noColor = top
        noColor.affectsColor = false
        #expect(TextStyleAttributes.markValues(noColor).count == 15)
        #expect(!TextStyleAttributes.overlay(.init(), noColor).character.hasFill)
        // Keys of every mark attribute.
        let keys = [
            TextFixture.mark { $0.kerning = 1 }, TextFixture.mark { $0.style = .init() }, TextFixture.mark { $0.noBreak = true },
            TextFixture.mark { $0.inlineGraphic = .init() }, TextFixture.mark { $0.noHyphen = true }, TextFixture.mark { $0.link = "x" },
            TextFixture.mark { $0.field = .init() }, TextFixture.mark { $0.mention = "m" }, Wiretuner_Doc_V1_TextMarkValue(),
        ].map(TextStyleAttributes.key)
        #expect(keys == ["5", "12", "15", "17", "19", "40", "41", "42", ""])
    }
}

/// A raw register write, for states the commands never produce (loops, deleted styles).
struct TestSet: Command {
    var node: OpID
    var paths: [RegisterPath] = []
    var values = Wiretuner_Doc_V1_NodeProps()
    var delete = false
    var label: String { "Test" }

    init(node: OpID, path: RegisterPath, values: Wiretuner_Doc_V1_NodeProps) {
        self.node = node
        paths = [path]
        self.values = values
    }

    init(node: OpID, paths: [RegisterPath], values: Wiretuner_Doc_V1_NodeProps) {
        self.node = node
        self.paths = paths
        self.values = values
    }

    init(node: OpID, delete: Bool) {
        self.node = node
        self.delete = delete
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(delete ? Ops.setDeleted(node) : Ops.set(node, paths, values: values))
    }
}

/// A raw `CreateNode`.
struct TestCreate: Command {
    var parent: OpID
    var props: Wiretuner_Doc_V1_NodeProps
    var label: String { "Create" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.create(parent: parent, position: try PathEditing.topPosition(in: parent, state: state), props: props))
    }
}

/// Adds one tab stop to the first paragraph's terminator (or the tail).
struct TestTab: Command {
    var node: OpID
    var label: String { "Tab" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = TextNode(node, in: state)!
        let paragraph = text.paragraphs[0]
        let base = paragraph.terminator.map(TextFields.paragraph) ?? TextFields.tailParagraph
        builder.append(Ops.elementInsert(node, base.child(9), positions: [[0x80]],
                                         values: TextEditing.paragraphValues(.with { $0.tabs = [.with { $0.position = 10 }] }, newline: paragraph.terminator != nil)))
    }
}
