import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTText

// Convert to Paths (TYPE-044; type/text-to-paths.adoc): each text block becomes a group in its
// place holding a path per glyph (composite for several contours, holes included), the effects
// that can be shapes, the block's own fill and stroke as a rectangle at the bottom, and its inline
// graphics moved in; the text (and the path it follows) is marked deleted.  Laying the text out
// needs the document's engine on the main actor, so `TextToPaths.conversion` captures what the
// converter sees and `ConvertTextToPaths` writes it as one change.

/// Why Convert to Paths refused.
public enum TextToPathsError: Error, Hashable, Sendable {
    /// Linked blocks must be unlinked first.
    case linked(OpID)
    /// Not a text node.
    case notText(OpID)
}

/// One text node as the converter saw it: its shapes in its parent's space, and what the change
/// needs besides.
public struct TextConversion: Sendable {
    public var node: OpID
    /// The group's name: the block's first words.
    public var name: String
    /// Glyphs and effects in the text's parent space, with each glyph's fill and stroke as stored.
    public var shapes: [ConvertedShape]
    /// The block's rectangle (its four corners, parent space) when it has a fill or stroke of its own.
    public var block: [Point]?
    /// Each inline graphic child with its new transform in the parent's space.
    public var graphics: [(node: OpID, transform: AffineTransform)]
    /// Fonts drawn with a substitute's outlines (the Missing Fonts warning); empty when none.
    public var substitutedFonts: [String]
}

/// A path the conversion writes: its outline and attribute stack.
public struct ConvertedShape: Sendable {
    public var path: DisplayPath
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
}

/// Capturing a conversion.
public enum TextToPaths {
    /// How many words name the group.
    static let nameWords = 3

    /// What converting text node `node` of `state` produces, laid out with `engine`.  Throws for a
    /// linked block or a node that is not text.
    @MainActor
    public static func conversion(_ node: OpID, in state: EngineState, engine: TextLayoutEngine) throws -> TextConversion {
        guard let text = TextNode(node, in: state) else { throw TextToPathsError.notText(node) }
        if isLinked(text, in: state) { throw TextToPathsError.linked(node) }
        let layout = TextLayoutReading.layout(text, engine: engine, colors: ColorResolver(state), state: state)
        let outlines = layout.outlines(forContainer: 0)
        let context = TextReadingContext(node, in: state)
        let styles = TextStyleResolver(state)
        let paragraphs = text.paragraphs
        func values(at offset: Int) -> [Wiretuner_Doc_V1_TextMarkValue] {
            styles.characterValues(text.values(at: offset), paragraph: paragraphs[text.paragraphIndex(at: offset)].props)
        }
        var shapes = outlines.under.map(shape)
        for glyph in outlines.glyphs {
            shapes.append(ConvertedShape(path: glyph.path, appearance: glyphAppearance(values(at: glyph.offset), overprint: glyph.overprint)))
        }
        shapes += outlines.over.map(shape)
        var block: [Point]?
        let stored = state.props(node).text.blockAppearance
        if !stored.fills.isEmpty || !stored.strokes.isEmpty, let size = layout.sizes.first {
            let frame = layout.containers[0].transform
            block = [Point(x: 0, y: 0), Point(x: size.width, y: 0), Point(x: size.width, y: size.height), Point(x: 0, y: size.height)].map(frame.apply)
        }
        var graphics: [(node: OpID, transform: AffineTransform)] = []
        var seen: Set<OpID> = []
        // A graphic named twice is drawn, and moved, at its first placeholder.
        for (offset, graphic) in InlineGraphics.placements(text) where context.graphics[graphic] != nil && seen.insert(graphic).inserted {
            guard let placed = outlines.inlines.first(where: { $0.offset == offset }) else { continue }
            let own = PathEditing.transform(NodeValues.common(state.props(graphic))?.transform ?? .init())
            graphics.append((graphic, own.concatenating(placed.transform)))
        }
        let substituted = layout.fontReport.substitutedFaces.keys.map(\.family) + layout.fontReport.missingFamilies
        return TextConversion(node: node, name: name(text.string), shapes: shapes, block: block, graphics: graphics,
                              substitutedFonts: Array(Set(substituted)).sorted())
    }

    /// Whether `text` is part of a linked flow.
    static func isLinked(_ text: TextNode, in state: EngineState) -> Bool {
        [text.props.nextLink, text.props.prevLink].contains { ref in
            let id = OpID(ref.id)
            return id != .zero && state.isLive(id)
        }
    }

    /// The block's first words, at most `nameWords` of them.
    static func name(_ string: String) -> String {
        let words = string.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).prefix(nameWords)
        return words.joined(separator: " ")
    }

    /// A glyph's attribute stack: its fill (unless *None*) and its stroke, as the text stores them.
    static func glyphAppearance(_ values: [Wiretuner_Doc_V1_TextMarkValue], overprint: Bool) -> Wiretuner_Doc_V1_AppearanceProps {
        var fill = Wiretuner_Doc_V1_ColorRef()
        fill.inline = ColorValues.stored(.black)
        var stroke: Wiretuner_Doc_V1_BasicStroke?
        for value in values {
            switch value.value {
            case .fill(let ref)?: fill = ref
            case .stroke(let basic)?: stroke = basic
            default: break
            }
        }
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        if case .none? = fill.ref {} else {
            var element = Wiretuner_Doc_V1_Fill()
            element.settings.kind = .basic
            element.settings.basic.color = fill
            element.settings.basic.overprint = overprint
            appearance.fills = [element]
        }
        if let stroke {
            var element = Wiretuner_Doc_V1_Stroke()
            element.settings.kind = .basic
            element.settings.basic = stroke
            appearance.strokes = [element]
        }
        return appearance
    }

    /// An effect shape with its paint as plain colours.
    static func shape(_ shape: TextShape) -> ConvertedShape {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        if let fill = shape.fill, case .solid(let color) = fill.paint {
            var element = Wiretuner_Doc_V1_Fill()
            element.settings.kind = .basic
            element.settings.basic.color = ColorResolver.inline(color)
            element.settings.basic.overprint = fill.overprint
            appearance.fills = [element]
        }
        if let stroke = shape.stroke, case .solid(let color) = stroke.paint {
            var element = Wiretuner_Doc_V1_Stroke()
            element.settings.kind = .basic
            element.settings.basic.color = ColorResolver.inline(color)
            element.settings.basic.width = stroke.style.width
            element.settings.basic.cap = stroke.style.cap == .round ? .round : stroke.style.cap == .square ? .square : .butt
            element.settings.basic.join = stroke.style.join == .round ? .round : stroke.style.join == .bevel ? .bevel : .miter
            element.settings.basic.dash.lengths = stroke.style.dash
            element.settings.basic.overprint = stroke.overprint
            appearance.strokes = [element]
        }
        return ConvertedShape(path: shape.path, appearance: appearance)
    }

    /// The contours of a display path, for `CreatePath.appendContours`.
    static func contours(_ path: DisplayPath) -> [NewContour] {
        var props = Wiretuner_Doc_V1_PathProps()
        props.contours = InlineShapes.contours(path)
        return VectorPath(props).contours.map { NewContour(closed: $0.closed, points: $0.points) }
    }
}

/// menu:Text[Convert to Paths] (kbd:[Cmd+Shift+P]) over captured conversions: per block, a group
/// named after its first words at the block's place in the stacking order, a path per glyph and
/// effect shape (the block's rectangle at the bottom), its inline graphics moved into the group,
/// and `deleted = true` on the text -- and on the path text on a path follows.  One change,
/// "Convert text to paths"; a block deleted since it was captured is skipped (a concurrent
/// converter got there first).
public struct ConvertTextToPaths: Command {
    public var conversions: [TextConversion]
    public var label: String { "Convert text to paths" }

    public init(_ conversions: [TextConversion]) {
        self.conversions = conversions
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for conversion in conversions where state.isLive(conversion.node) {
            try convert(conversion, state: state, builder: &builder)
        }
    }

    private func convert(_ conversion: TextConversion, state: EngineState, builder: inout ChangeBuilder) throws {
        let node = conversion.node
        guard let text = TextNode(node, in: state) else { throw TextToPathsError.notText(node) }
        if TextToPaths.isLinked(text, in: state) { throw TextToPathsError.linked(node) }
        guard let parent = state.store.placement(node)?.parent else { throw TextToPathsError.notText(node) }
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.common.name = conversion.name
        // Marks the group as text a reader can no longer read (the accessibility check, IO-033).
        group.group.common.note = AccessibilityCheck.outlinedTextNote
        let groupID = builder.append(Ops.create(parent: parent, position: try Arranging.keys(next: node, above: true, count: 1, in: state)[0], props: group))
        var shapes = conversion.shapes
        if let corners = conversion.block {
            var outline = DisplayPath()
            outline.move(to: corners[0])
            for corner in corners.dropFirst() { outline.addLine(to: corner) }
            outline.close()
            var appearance = state.props(node).text.blockAppearance
            appearance.effects = []
            for index in appearance.fills.indices { appearance.fills[index].clearID() }
            for index in appearance.strokes.indices { appearance.strokes[index].clearID() }
            shapes.insert(ConvertedShape(path: outline, appearance: appearance), at: 0)
        }
        let keys = try PathEditing.keys(between: nil, and: nil, count: shapes.count + conversion.graphics.count)
        for (shape, key) in zip(shapes, keys) {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.path = Wiretuner_Doc_V1_PathProps()
            let path = builder.append(Ops.create(parent: groupID, position: key, props: props))
            try CreatePath.appendContours(TextToPaths.contours(shape.path), to: path, builder: &builder)
            for op in try PathEditing.appearanceInserts(path, kind: .path, appearancePath: PathFields.appearance, shape.appearance) {
                builder.append(op)
            }
        }
        for ((graphic, transform), key) in zip(conversion.graphics, keys.dropFirst(shapes.count)) {
            guard let kind = state.nodeKind(graphic) else { continue }
            builder.append(Ops.move(graphic, parent: groupID, position: key))
            builder.append(Ops.set(graphic, [RegisterPath([kind.rawValue, 1, 4])], values: NodeValues.with(kind: kind, transform: PathEditing.proto(transform))))
        }
        builder.append(Ops.setDeleted(node))
        if text.props.hasOnPath {
            for child in state.liveChildren(node) where state.nodeKind(child) == .path {
                builder.append(Ops.setDeleted(child))
            }
        }
    }
}
