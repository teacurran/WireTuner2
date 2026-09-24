import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTText

/// A text node as WTText lays it out (creating-text, "Layout"; TXT-001): its merged characters,
/// winning marks and paragraph registers as a `TextContent`, and its block as a `TextContainer`.
/// What is read: every character mark WTText has an attribute for -- the glyph `stroke` and the
/// `effect` too (TYPE-029), and, with a `TextReadingContext`, `inline_graphic` (TYPE-038) --, the
/// paragraph registers WTText uses, the paragraph rule with its own stroke, and the block's size,
/// auto sizing, inset, columns, rows, adjustments, direction and its own fill and stroke
/// (`block_appearance`, TYPE-029).  With a context, text styles resolve (TYPE-034: defaults,
/// paragraph style, the paragraph's registers, character style, marks) and small capitals take
/// the document's *Small caps size* (TYPE-015).  Text on a path and linked flows (TYPE-007) are
/// laid out as ordinary blocks.
public enum TextLayoutReading {
    /// The content of `text`, colours resolved through `colors`; with `context`, styles resolved,
    /// small capitals sized and inline graphics drawn (a node referred to twice is drawn at the
    /// first U+FFFC only; one that is missing draws an empty box).
    public static func content(_ text: TextNode, colors: ColorResolver? = nil, context: TextReadingContext? = nil) -> TextContent {
        let all = Array(text.string.unicodeScalars)
        let paragraphs = text.paragraphs
        let styles = context?.styles
        var runs: [WTText.TextRun] = []
        var drawn: Set<OpID> = []
        // The engine's runs cover every live character, in order; with styles each is cut at the
        // paragraph ends, since each paragraph resolves its own style.
        for run in text.runs {
            let pieces = styles == nil ? [(run.range, paragraphs[0])] : paragraphs.compactMap { paragraph -> (Range<Int>, TextParagraph)? in
                let piece = run.range.clamped(to: paragraph.range)
                return piece.isEmpty ? nil : (piece, paragraph)
            }
            for (range, paragraph) in pieces {
                let values = styles?.characterValues(run.values, paragraph: paragraph.props) ?? run.values
                var attributes = attributes(values, colors: colors)
                if let context {
                    attributes.smallCapsSize = context.smallCapsSize
                    for case .inlineGraphic(let ref)? in values.map(\.value) {
                        let child = OpID(ref.id)
                        if drawn.insert(child).inserted { attributes.inlineGraphic = context.graphics[child] ?? InlineGraphic(bounds: .zero, items: nil) }
                    }
                }
                runs.append(WTText.TextRun(string(all[range]), attributes: attributes))
            }
        }
        let props = styles.map { styles in paragraphs.map { styles.paragraph($0.props) } } ?? paragraphs.map(\.props)
        return TextContent(runs: runs, paragraphs: props.map { paragraphStyle($0) },
                           charIDs: text.chars.map { CharID(counter: $0.counter, replica: $0.replica) })
    }

    /// The block container of `text` (`TextProps.block` and the node's transform), with the block's
    /// own fills and strokes `appearance` (`TextBlockAppearance.appearance`).
    public static func container(_ text: TextNode, appearance: Appearance = Appearance()) -> TextContainer {
        let stored = text.props.block
        var block = TextBlock(width: stored.width, height: stored.height, autoWidth: stored.autoWidth, autoHeight: stored.autoHeight,
                              transform: PathEditing.transform(text.props.common.transform), appearance: appearance,
                              displayBorder: stored.displayBorder)
        block.inset = Inset(left: stored.inset.left, right: stored.inset.right, top: stored.inset.top, bottom: stored.inset.bottom)
        let columns = stored.columns
        block.columns = ColumnsRows(columns: max(1, Int(columns.columns)), columnHeight: columns.columnHeight, columnSpacing: columns.columnSpacing,
                                    rows: max(1, Int(columns.rows)), rowWidth: columns.rowWidth, rowSpacing: columns.rowSpacing,
                                    flow: columns.flow == .across ? .across : .down,
                                    columnRules: extent(columns.columnRules), rowRules: extent(columns.rowRules))
        let adjust = stored.adjust
        block.adjust = AdjustColumns(balance: adjust.balance, modifyLeading: adjust.modifyLeading,
                                     thresholdPercent: adjust.thresholdPercent == 0 ? 50 : adjust.thresholdPercent,
                                     copyfitMinPercent: adjust.copyfitMinPercent == 0 ? 100 : adjust.copyfitMinPercent,
                                     copyfitMaxPercent: adjust.copyfitMaxPercent == 0 ? 100 : adjust.copyfitMaxPercent)
        block.direction = stored.direction == .vertical ? .vertical : .horizontal
        return .block(block)
    }

    /// Lays `text` out with `engine` (the document's `DocumentFontIndex.layoutEngine`); with
    /// `state`, as the scene draws it (styles, inline graphics and the block's appearance).
    @MainActor
    public static func layout(_ text: TextNode, engine: TextLayoutEngine, colors: ColorResolver? = nil, state: EngineState? = nil) -> TextLayout {
        guard let state else { return engine.layout(content(text, colors: colors), in: [container(text)]) }
        return engine.layout(content(text, colors: colors, context: TextReadingContext(text.id, in: state)),
                             in: [container(text, appearance: TextBlockAppearance.appearance(text.id, in: state))])
    }

    /// The nodes the drawing of text node `node` reads besides itself (for the scene's dependency
    /// index): the text style nodes, the settings node (defaults, *Small caps size*) and its
    /// inline graphic children.
    public static func sources(_ node: OpID, in state: EngineState) -> [OpID] {
        let styles = state.store.children(TextStyleFields.collection).filter { state.store.kind($0) == TextStyleFields.kind }
        return styles + [WellKnown.settings] + state.store.children(node)
    }

    /// The display item drawing text node `node` of `state`: a group of the laid-out block's items
    /// (glyph runs in pasteboard space through the node's own transform; the scene applies the
    /// enclosing groups' and layer's).  Nil when it is not a text node or draws nothing.
    @MainActor
    public static func item(_ node: OpID, in state: EngineState, engine: TextLayoutEngine) -> DisplayItem? {
        guard let text = TextNode(node, in: state) else { return nil }
        let items = layout(text, engine: engine, colors: ColorResolver.current ?? ColorResolver(state), state: state).displayItems(forContainer: 0)
        return items.isEmpty ? nil : .group(GroupItem(children: items))
    }

    // MARK: Attributes

    /// The character attributes of the winning mark values of one run.
    public static func attributes(_ values: [Wiretuner_Doc_V1_TextMarkValue], colors: ColorResolver? = nil) -> TextAttributes {
        var result = TextAttributes()
        for value in values {
            switch value.value {
            case .fontFamily(let family)?: result.fontFamily = family
            case .fontStyle(let style)?: result.fontStyle = style
            case .size(let size)?: result.size = size
            case .leading(let leading)?: result.leading = Self.leading(leading)
            case .kerning(let kerning)?: result.kerning = kerning
            case .rangeKerning(let tracking)?: result.rangeKerning = tracking
            case .baselineShift(let shift)?: result.baselineShift = shift
            case .horizontalScale(let scale)?: result.horizontalScale = scale
            case .fill(let ref)?:
                if case .none? = ref.ref { result.fill = .clear } else { result.fill = colors?.color(ref) ?? inlineColor(ref) ?? result.fill }
            case .stroke(let stroke)?: result.stroke = stroke == Wiretuner_Doc_V1_BasicStroke() ? nil : Appearances.basic(stroke)
            case .effect(let effect)?: result.effect = Self.effect(effect)
            case .language(let language)?: result.language = language
            case .noBreak(let flag)?: result.noBreak = flag
            case .noHyphen(let flag)?: result.noHyphen = flag
            case .overprint(let flag)?: result.overprint = flag
            case .case(let style)?: result.smallCaps = style == .smallCaps
            case .axes(let variation)?:
                result.axes = Dictionary(variation.axes.map { ($0.tag, $0.value) }, uniquingKeysWith: { _, last in last })
            case .feature(let feature)?: result.features[feature.tag] = featureState(feature.state)
            default: break
            }
        }
        return result
    }

    /// The paragraph style of one paragraph's registers.  An unset (0) `ragged_width` reads as
    /// 100 (paragraphs.adoc, read-time normalizations); unset spacing ranges are the defaults.
    public static func paragraphStyle(_ props: Wiretuner_Doc_V1_ParagraphProps) -> ParagraphStyle {
        var style = ParagraphStyle()
        switch props.alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .justified: style.alignment = .justified
        default: style.alignment = .left
        }
        style.raggedWidth = props.raggedWidth == 0 ? 100 : min(max(props.raggedWidth, 0), 100)
        style.flushZone = min(max(props.flushZone, 0), 100)
        style.leftIndent = props.leftIndent
        style.rightIndent = props.rightIndent
        style.firstLineIndent = props.firstLineIndent
        style.spaceAbove = props.spaceAbove
        style.spaceBelow = props.spaceBelow
        style.tabs = props.tabs.map { stop in
            WTText.TabStop(tabKind(stop.kind), at: stop.position, leader: stop.leader)
        }
        let hyphenation = props.hyphenation
        style.hyphenation = Hyphenation(enabled: hyphenation.enabled, language: hyphenation.language.isEmpty ? nil : hyphenation.language,
                                        consecutive: Int(hyphenation.consecutive), skipCapitalized: hyphenation.skipCapitalized)
        style.rule = rule(props.rule)
        style.hangPunctuation = props.hangPunctuation
        style.keepLines = Int(props.keepLines)
        style.keepWithNext = props.keepWithNext
        if props.hasWordSpacing {
            style.wordSpacing = SpacingRange(min: props.wordSpacing.min, optimum: props.wordSpacing.opt, max: props.wordSpacing.max)
        }
        if props.hasLetterSpacing {
            style.letterSpacing = SpacingRange(min: props.letterSpacing.min, optimum: props.letterSpacing.opt, max: props.letterSpacing.max)
        }
        return style
    }

    /// A paragraph rule: its mode, width (0 reads as 100%), basis, position and its own stroke (none
    /// uses the block's).
    static func rule(_ rule: Wiretuner_Doc_V1_ParagraphRule) -> WTText.ParagraphRule {
        let mode: WTText.ParagraphRule.Mode = switch rule.mode {
        case .centered: .centered
        case .paragraph: .paragraph
        default: .none
        }
        return WTText.ParagraphRule(mode: mode, widthPercent: rule.widthPercent == 0 ? 100 : rule.widthPercent,
                                    basis: rule.basis == .column ? .column : .lastLine, position: rule.position, above: rule.above,
                                    stroke: rule.hasStroke ? Appearances.basic(rule.stroke) : nil)
    }

    /// A text effect with its options; nil for an effect of no kind (a cleared mark).
    static func effect(_ effect: Wiretuner_Doc_V1_TextEffect) -> WTText.TextEffect? {
        func color(_ ref: Wiretuner_Doc_V1_ColorRef, _ fallback: Color) -> Color {
            ref.ref == nil ? fallback : Appearances.color(ref) ?? .clear
        }
        func line(_ line: Wiretuner_Doc_V1_TextLineEffect) -> WTText.TextLineEffect {
            WTText.TextLineEffect(position: line.position, width: line.width, dash: Appearances.dash(line.dash), color: color(line.color, .black),
                                  overprint: line.overprint)
        }
        switch effect.effect {
        case .highlight(let value)?: return .highlight(line(value))
        case .underline(let value)?: return .underline(line(value))
        case .strikethrough(let value)?: return .strikethrough(line(value))
        case .inline(let value)?:
            return .inline(WTText.TextInlineEffect(count: Int(value.count), strokeWidth: value.strokeWidth, strokeColor: color(value.strokeColor, .black),
                                                   backgroundWidth: value.backgroundWidth, backgroundColor: color(value.backgroundColor, .white)))
        case .shadow(let value)?:
            return .shadow(WTText.TextShadowEffect(offsetX: value.offsetX, offsetY: value.offsetY, color: color(value.color, .black), tint: value.tint))
        case .zoom(let value)?:
            return .zoom(WTText.TextZoomEffect(zoomTo: value.zoomTo, offsetX: value.offsetX, offsetY: value.offsetY, from: color(value.from, .black),
                                               to: color(value.to, .white)))
        case nil: return nil
        }
    }

    static func leading(_ value: Wiretuner_Doc_V1_Leading) -> WTText.Leading {
        switch value.mode {
        case .fixed: WTText.Leading(mode: .fixed, value: value.value)
        case .percent: WTText.Leading(mode: .percent, value: value.value)
        default: WTText.Leading(mode: .extra, value: value.value)
        }
    }

    static func featureState(_ state: Wiretuner_Doc_V1_FeatureState) -> WTText.FeatureState {
        switch state {
        case .on: .on
        case .off: .off
        default: .default
        }
    }

    static func tabKind(_ kind: Wiretuner_Doc_V1_TabKind) -> WTText.TabStop.Kind {
        switch kind {
        case .right: .right
        case .center: .center
        case .decimal: .decimal
        case .wrapping: .wrapping
        default: .left
        }
    }

    static func extent(_ extent: Wiretuner_Doc_V1_RuleExtent) -> WTText.RuleExtent {
        switch extent {
        case .inset: .inset
        case .full: .full
        default: .none
        }
    }

    /// An inline colour without a resolver (swatch references need one).
    static func inlineColor(_ ref: Wiretuner_Doc_V1_ColorRef) -> Color? {
        if case .inline(let stored)? = ref.ref { return ColorValues.color(stored) }
        return nil
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
