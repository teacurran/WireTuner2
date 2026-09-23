import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// The document's fonts (TXT-002 glue): the faces its text marks name, the report the Missing
/// Fonts sheet reads, the tables, and which text re-lays out when the fonts change.
@MainActor
@Suite struct DocumentFontIndexTests {
    static let missing = "WireTuner Missing Family"

    /// A document with a visible layer and helpers for text blocks and marks.
    struct Text {
        var replica = Replica(4)
        let layer: OpID

        init() throws {
            var props = Fixture.layer(name: "L")
            props.layer.visible = true
            props.layer.printing = true
            layer = try replica.perform(OpsCommand("Layer", ops: [Ops.create(parent: WellKnown.layers, position: [0x80], props: props)]))!.createdNodes[0]
        }

        /// A text block holding `string`; returns it and its character ids.
        mutating func block(_ string: String, parent: OpID? = nil) throws -> (node: OpID, chars: [OpID]) {
            let node = try replica.perform(OpsCommand("Text", ops: [Ops.create(parent: parent ?? layer, position: [0x80], props: Fixture.textBlock())]))!.createdNodes[0]
            let first = try replica.perform(OpsCommand("Type", ops: [Ops.textInsert(node, Fixture.text, string)]))!.opIDs[0]
            return (node, (0..<string.unicodeScalars.count).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) })
        }

        /// A mark over `chars[range]`.
        static func mark(_ node: OpID, _ chars: [OpID], _ range: ClosedRange<Int>, _ value: Wiretuner_Doc_V1_TextMarkValue) -> Wiretuner_Doc_V1_Op {
            var mark = Wiretuner_Doc_V1_TextMark()
            mark.node = node.proto
            mark.text = Fixture.text.proto
            mark.start.char = Ops.elementID(chars[range.lowerBound])
            mark.start.before = true
            mark.end.char = Ops.elementID(chars[range.upperBound])
            mark.end.before = false
            mark.value = value
            var op = Wiretuner_Doc_V1_Op()
            op.textMark = mark
            return op
        }

        static func family(_ name: String) -> Wiretuner_Doc_V1_TextMarkValue {
            var value = Wiretuner_Doc_V1_TextMarkValue()
            value.fontFamily = name
            return value
        }

        static func style(_ name: String) -> Wiretuner_Doc_V1_TextMarkValue {
            var value = Wiretuner_Doc_V1_TextMarkValue()
            value.fontStyle = name
            return value
        }

        static func characterStyle(_ node: OpID, cached: Wiretuner_Doc_V1_TextStyleAttrs? = nil) -> Wiretuner_Doc_V1_TextMarkValue {
            var value = Wiretuner_Doc_V1_TextMarkValue()
            value.style.id = node.proto
            if let cached { value.style.cached = (try? cached.serializedBytes()) ?? Data() }
            return value
        }

        /// Performs `ops` and returns the event the document would publish.
        mutating func event(_ ops: [Wiretuner_Doc_V1_Op]) throws -> DocumentEvent {
            let before = replica.state
            let change = try replica.perform(OpsCommand("Edit", ops: ops))!
            return DocumentEvent(change: change, origin: .remote, before: before, after: replica.state)
        }
    }

    static func styleNode(family: String?, style: String?, basedOn: OpID? = nil) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.kind = .character
        if let family { props.style.text.character.fontFamily = family }
        if let style { props.style.text.character.fontStyle = style }
        if let basedOn { props.style.basedOn.id = basedOn.proto }
        return props
    }

    @Test func facesAreWhatTheRunsMarksName() throws {
        var text = try Text()
        let (node, chars) = try text.block("Hello world")
        try text.replica.perform(OpsCommand("Marks", ops: [
            Text.mark(node, chars, 0...4, Text.family("Helvetica")),
            Text.mark(node, chars, 0...1, Text.style("Bold")),
            Text.mark(node, chars, 6...10, Text.family(Self.missing)),
            Text.mark(node, chars, 5...5, Text.style("Italic")),   // a style with no family: the default, unreported
        ]))
        #expect(DocumentFontIndex.faces(of: node, in: text.replica.state) == [
            FaceName(family: "Helvetica", style: "Bold"), FaceName(family: "Helvetica"), FaceName(family: Self.missing),
        ])
        let fonts = DocumentFontIndex(state: text.replica.state)
        #expect(fonts.faces[node]?.count == 3)
        #expect(DocumentFontIndex.namedFaces(in: text.replica.state) == fonts.allFaces)
        #expect(fonts.nodes(naming: FaceName(family: Self.missing)) == [node])
        #expect(fonts.layoutEngine.fonts === fonts.manager)
        let report = fonts.report()
        #expect(report.resolutions[FaceName(family: "Helvetica")]?.source == .installed)
        #expect(report.facesNeedingSheet == [FaceName(family: Self.missing)])
        #expect(fonts.report(for: [FaceName(family: "Helvetica")]).facesNeedingSheet.isEmpty)
    }

    @Test func characterStylesNameTheirFacesThroughBasedOnAndTheirCache() throws {
        var text = try Text()
        let styles = OpID.wellKnown(6)
        let parent = try text.replica.perform(OpsCommand("Style", ops: [Ops.create(parent: styles, position: [0x40], props: Self.styleNode(family: "Courier", style: "Bold"))]))!.createdNodes[0]
        let child = try text.replica.perform(OpsCommand("Style", ops: [Ops.create(parent: styles, position: [0x80], props: Self.styleNode(family: nil, style: "Oblique", basedOn: parent))]))!.createdNodes[0]
        let (node, chars) = try text.block("abcdef")
        var cached = Wiretuner_Doc_V1_TextStyleAttrs()
        cached.character.fontFamily = "Times"
        try text.replica.perform(OpsCommand("Marks", ops: [
            Text.mark(node, chars, 0...1, Text.characterStyle(child)),
            Text.mark(node, chars, 2...3, Text.characterStyle(OpID(counter: 999, replica: 9), cached: cached)),
            Text.mark(node, chars, 4...5, Text.characterStyle(parent)),
            Text.mark(node, chars, 5...5, Text.family("Helvetica")),   // a family mark wins over the style's
        ]))
        #expect(DocumentFontIndex.faces(of: node, in: text.replica.state) == [
            FaceName(family: "Courier", style: "Oblique"), FaceName(family: "Times"), FaceName(family: "Courier", style: "Bold"),
            FaceName(family: "Helvetica", style: "Bold"),
        ])
        // Changing a style re-reads every text node.
        let fonts = DocumentFontIndex(state: text.replica.state)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.text.character.fontFamily = "Menlo"
        fonts.apply(try text.event([Ops.set(parent, [RegisterPath([154, 7, 2, 1])], values: props)]))
        #expect(fonts.faces[node]?.contains(FaceName(family: "Menlo", style: "Oblique")) == true)
    }

    @Test func onlyDrawnTextCountsAndChangesKeepTheFacesCurrent() throws {
        var text = try Text()
        let (node, chars) = try text.block("abc")
        let fonts = DocumentFontIndex(state: text.replica.state)
        #expect(fonts.faces.isEmpty)
        // A mark (local or remote) names a face.
        fonts.apply(try text.event([Text.mark(node, chars, 0...2, Text.family(Self.missing))]))
        #expect(fonts.faces[node] == [FaceName(family: Self.missing)])
        #expect(fonts.resolutions[FaceName(family: Self.missing)]?.source == .defaultSubstitute)
        // Deleting it, or a group holding it, drops it; restoring brings it back.
        fonts.apply(try text.event([Ops.setDeleted(node)]))
        #expect(fonts.faces.isEmpty && fonts.resolutions.isEmpty)
        fonts.apply(try text.event([Ops.setDeleted(node, false)]))
        #expect(fonts.faces[node] != nil)
        var groupProps = Wiretuner_Doc_V1_NodeProps()
        groupProps.group = Wiretuner_Doc_V1_GroupProps()
        let group = try text.replica.perform(OpsCommand("Group", ops: [Ops.create(parent: text.layer, position: [0xC0], props: groupProps)]))!.createdNodes[0]
        fonts.apply(try text.event([Ops.move(node, parent: group, position: [0x80])]))
        #expect(fonts.faces[node] != nil)
        fonts.apply(try text.event([Ops.setDeleted(group)]))
        #expect(fonts.faces.isEmpty)
        #expect(DocumentFontIndex.faces(in: text.replica.state).isEmpty)
        // A deleted layer's objects are still shown, so their text still counts.
        fonts.apply(try text.event([Ops.setDeleted(group, false), Ops.setDeleted(text.layer)]))
        #expect(fonts.faces[node] != nil)
        // A new text block with marks in one change; a reload reads everything.
        let (other, otherChars) = try text.block("xy")
        let created = try text.event([Text.mark(other, otherChars, 0...1, Text.family("Helvetica"))])
        fonts.apply(created)
        #expect(fonts.faces[other] == [FaceName(family: "Helvetica")])
        fonts.apply(DocumentEvent(change: Wiretuner_Doc_V1_Change(), origin: .reload, before: text.replica.state, after: EngineState()))
        #expect(fonts.faces.isEmpty)
        #expect(!DocumentFontIndex.isDrawnText(text.layer, in: text.replica.state))
    }

    @Test func aSubstitutionOrActivationReLaysOutJustTheTextItChanges() throws {
        var text = try Text()
        let (missing, missingChars) = try text.block("abc")
        let (installed, installedChars) = try text.block("def")
        try text.replica.perform(OpsCommand("Marks", ops: [
            Text.mark(missing, missingChars, 0...2, Text.family(Self.missing)),
            Text.mark(installed, installedChars, 0...2, Text.family("Helvetica")),
        ]))
        let fonts = DocumentFontIndex(state: text.replica.state, manager: FontManager(substitutions: FontSubstitutionTable()))
        #expect(fonts.fontsChanged().isEmpty)
        // A per-document row for the missing family: only its text re-lays out.
        fonts.documentSubstitutions = [FontSubstitution(missing: FaceName(family: Self.missing), substitute: FaceName(family: "Courier"))]
        #expect(fonts.documentSubstitutions.count == 1)
        #expect(fonts.fontsChanged() == [missing])
        #expect(fonts.report().resolutions[FaceName(family: Self.missing)]?.source == .substitution)
        #expect(fonts.report().facesNeedingSheet.isEmpty)
        #expect(fonts.fontsChanged().isEmpty)
        // A change that moves the generation but no answer re-lays out nothing.
        fonts.teamLibraryFamilies = ["Some Team Family"]
        #expect(fonts.teamLibraryFamilies == ["Some Team Family"])
        #expect(fonts.fontsChanged().isEmpty)
        // The remembered table (the preference) takes over when the document's row goes.
        fonts.documentSubstitutions = []
        fonts.substitutions = FontSubstitutionTable(rows: [FontSubstitution(missing: FaceName(family: Self.missing), substitute: FaceName(family: "Times"))])
        #expect(fonts.substitutions.rows.count == 1)
        #expect(fonts.fontsChanged() == [missing])
        #expect(fonts.resolutions[FaceName(family: Self.missing)]?.face.family == "Times")
        // The builder rebuilds the nodes the caller passes and names them in its summary.
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(text.replica.state)
        let (_, summary) = builder.invalidate([missing], state: text.replica.state)
        #expect(summary.touchedNodes == [NodeID(missing)])
        #expect(summary.origin == .local)
    }
}
