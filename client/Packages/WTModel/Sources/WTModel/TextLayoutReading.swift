import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTText

/// A text node as WTText lays it out (creating-text, "Layout"; TXT-001): its merged characters,
/// winning marks and paragraph registers as a `TextContent`, and its block as a `TextContainer`.
/// What is read: every character mark WTText has an attribute for except `effect`, `stroke` and
/// `inline_graphic` (their drawing inputs are the text-effects tasks'), character styles only
/// through their own marks (style resolution is TYPE-034), the paragraph registers WTText uses
/// but `rule` (a stroke of the ATTR epic), and the block's size, auto sizing, inset, columns,
/// rows, adjustments and direction.  Text on a path and linked flows (TYPE-007) are laid out as
/// ordinary blocks; the block's own fill and stroke are not drawn yet.
public enum TextLayoutReading {
    /// The content of `text`, colours resolved through `colors`.
    public static func content(_ text: TextNode, colors: ColorResolver? = nil) -> TextContent {
        let all = Array(text.string.unicodeScalars)
        // The engine's runs cover every live character, in order.
        let runs = text.runs.map { WTText.TextRun(string(all[$0.range]), attributes: attributes($0.values, colors: colors)) }
        return TextContent(runs: runs, paragraphs: text.paragraphs.map { paragraphStyle($0.props) },
                           charIDs: text.chars.map { CharID(counter: $0.counter, replica: $0.replica) })
    }

    /// The block container of `text` (`TextProps.block` and the node's transform).
    public static func container(_ text: TextNode) -> TextContainer {
        let stored = text.props.block
        var block = TextBlock(width: stored.width, height: stored.height, autoWidth: stored.autoWidth, autoHeight: stored.autoHeight,
                              transform: PathEditing.transform(text.props.common.transform), displayBorder: stored.displayBorder)
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

    /// Lays `text` out with `engine` (the document's `DocumentFontIndex.layoutEngine`).
    @MainActor
    public static func layout(_ text: TextNode, engine: TextLayoutEngine, colors: ColorResolver? = nil) -> TextLayout {
        engine.layout(content(text, colors: colors), in: [container(text)])
    }

    /// The display item drawing text node `node` of `state`: a group of the laid-out block's items
    /// (glyph runs in pasteboard space through the node's own transform; the scene applies the
    /// enclosing groups' and layer's).  Nil when it is not a text node or draws nothing.
    @MainActor
    public static func item(_ node: OpID, in state: EngineState, engine: TextLayoutEngine) -> DisplayItem? {
        guard let text = TextNode(node, in: state) else { return nil }
        let items = layout(text, engine: engine, colors: ColorResolver.current ?? ColorResolver(state)).displayItems(forContainer: 0)
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
            case .fill(let ref)?: result.fill = colors?.color(ref) ?? inlineColor(ref) ?? result.fill
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
