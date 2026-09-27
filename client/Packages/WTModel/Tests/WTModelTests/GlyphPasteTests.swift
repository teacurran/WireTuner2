import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// FONT-004's paste into a glyph canvas (typeface-documents.adoc): the objects arrive one unit
/// per point, and a text block arrives as paths.
@Suite @MainActor struct GlyphPasteTests {
    @Test func textArrivesAsPathsAndTheOtherObjectsAsCopied() throws {
        var source = Replica(1)
        let rect = try #require(try source.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10),
                                                               transform: .translation(x: 5, y: 5)))).createdObjects[0]
        let text = try TextFixture.block(&source, "Ab", at: Point(x: 40, y: 40))
        let group = try #require(try source.perform(GroupObjects([rect]))).createdObjects[0]
        let payload = ClipboardPayload(copying: [group, text], from: source.state)
        let (scratch, roots) = try GlyphPaste.scratch(payload)
        #expect(roots.count == 2)
        let texts = GlyphPaste.textNodes(roots, in: scratch)
        #expect(texts.count == 1)
        let engine = DocumentFontIndex(state: scratch).layoutEngine
        var conversions: [OpID: TextConversion] = [:]
        for node in texts { conversions[node] = try TextToPaths.conversion(node, in: scratch, engine: engine) }
        let outlined = GlyphPaste.outlined(payload, scratch: scratch, roots: roots, conversions: conversions)
        #expect(outlined.nodes.count == 2 && outlined.colors == payload.colors && outlined.bounds == payload.bounds)
        let converted = outlined.nodes[1]
        guard case .group(let props)? = converted.props.kind else { Issue.record("a group"); return }
        #expect(props.common.name == "Ab" && converted.children.count >= 2)
        #expect(converted.children.allSatisfy { if case .path? = $0.props.kind { true } else { false } })
        #expect(!outlined.nodes.flatMap(\.flattened).contains { if case .text? = $0.props.kind { true } else { false } })
        // Pasted: one unit per point, no text.
        var glyph = Replica(2)
        let change = try #require(try glyph.perform(Paste(outlined)))
        let pasted = change.createdRoots
        #expect(pasted.count == 2 && glyph.state.nodeKind(pasted[1]) == .group)
        #expect(Objects.bounds(of: pasted[0], in: glyph.state) == Objects.bounds(of: group, in: source.state))
        // No conversion leaves the payload as it was.
        #expect(GlyphPaste.outlined(payload, scratch: scratch, roots: roots, conversions: [:]) == payload)
    }

    @Test func aBlockWithItsOwnFillAndAnInlineGraphicArrivesWhole() throws {
        var source = Replica(1)
        let node = try TextFixture.block(&source, "ab", at: Point(x: 10, y: 10))
        try source.perform(AddTextBlockAppearance.fill(node))
        let rect = try #require(try source.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)))).createdObjects[0]
        try source.perform(PasteInlineGraphic(node: node, at: TextFixture.at(source, node, 1), payload: ClipboardPayload(copying: [rect], from: source.state)))
        let payload = ClipboardPayload(copying: [node], from: source.state)
        let (scratch, roots) = try GlyphPaste.scratch(payload)
        let text = try #require(GlyphPaste.textNodes(roots, in: scratch).first)
        let conversion = try TextToPaths.conversion(text, in: scratch, engine: DocumentFontIndex(state: scratch).layoutEngine)
        #expect(conversion.block != nil && !conversion.graphics.isEmpty)
        let outlined = GlyphPaste.outlined(payload, scratch: scratch, roots: roots, conversions: [text: conversion])
        let group = outlined.nodes[0]
        // The block's rectangle at the bottom, the glyphs, then the inline graphic moved in.
        #expect(group.children.first?.props.path.appearance.fills.count == 1)
        guard case .rect? = group.children.last?.props.kind else { Issue.record("the graphic last"); return }
        var glyph = Replica(2)
        let change = try #require(try glyph.perform(Paste(outlined)))
        #expect(glyph.state.nodeKind(change.createdRoots[0]) == .group)
    }

    @Test func theGlyphGridDefaultsToTenUnitsFromTheOrigin() throws {
        var a = Replica(1)
        #expect(PageList(a.state).glyphGrid == GridSpec(size: 10, origin: .zero))
        var settings = Wiretuner_Doc_V1_NodeProps()
        settings.settings.grid.size = 25
        try a.perform(OpsCommand("Grid", ops: [Ops.set(WellKnown.settings, [SettingsFields.gridSize], values: settings)]))
        #expect(PageList(a.state).glyphGrid.size == 25 && PageList(a.state).settings.gridIsSet)
    }
}
