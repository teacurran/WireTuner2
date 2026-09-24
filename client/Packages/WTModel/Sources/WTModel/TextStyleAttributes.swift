import WTCRDT
import WTProto

// The arithmetic of text style attributes (TYPE-034; type/text-styles.adoc, "Data model"): the
// optional "no selection" fields of `CharacterSettings` and `ParagraphSettings`, overlaying one
// set on another along a style chain, and the mark values and paragraph registers a set stands
// for.

/// Reading and combining `TextStyleAttrs`.
public enum TextStyleAttributes {
    /// The OpenType features `FeatureSettings` offers, with their fields.
    nonisolated(unsafe) static let features: [(tag: String, value: WritableKeyPath<Wiretuner_Doc_V1_FeatureSettings, Wiretuner_Doc_V1_FeatureState>,
                           has: KeyPath<Wiretuner_Doc_V1_FeatureSettings, Bool>)] = [
        ("liga", \.liga, \.hasLiga), ("dlig", \.dlig, \.hasDlig), ("smcp", \.smcp, \.hasSmcp), ("c2sc", \.c2Sc, \.hasC2Sc),
        ("onum", \.onum, \.hasOnum), ("lnum", \.lnum, \.hasLnum), ("tnum", \.tnum, \.hasTnum), ("pnum", \.pnum, \.hasPnum),
        ("frac", \.frac, \.hasFrac), ("swsh", \.swsh, \.hasSwsh), ("calt", \.calt, \.hasCalt),
        ("ss01", \.ss01, \.hasSs01), ("ss02", \.ss02, \.hasSs02), ("ss03", \.ss03, \.hasSs03), ("ss04", \.ss04, \.hasSs04),
        ("ss05", \.ss05, \.hasSs05), ("ss06", \.ss06, \.hasSs06), ("ss07", \.ss07, \.hasSs07), ("ss08", \.ss08, \.hasSs08),
        ("ss09", \.ss09, \.hasSs09), ("ss10", \.ss10, \.hasSs10), ("ss11", \.ss11, \.hasSs11), ("ss12", \.ss12, \.hasSs12),
        ("ss13", \.ss13, \.hasSs13), ("ss14", \.ss14, \.hasSs14), ("ss15", \.ss15, \.hasSs15), ("ss16", \.ss16, \.hasSs16),
        ("ss17", \.ss17, \.hasSs17), ("ss18", \.ss18, \.hasSs18), ("ss19", \.ss19, \.hasSs19), ("ss20", \.ss20, \.hasSs20),
    ]

    // MARK: Overlay

    /// `top` over `base`: every field `top` sets replaces `base`'s; ATOMIC fields (leading, fill,
    /// effect, axes, spacing ranges, tabs) are replaced whole.  A fill counts only from a set whose
    /// *Style affects text color* is on; the result's `affects_color` says whether it holds one.
    public static func overlay(_ base: Wiretuner_Doc_V1_TextStyleAttrs, _ top: Wiretuner_Doc_V1_TextStyleAttrs) -> Wiretuner_Doc_V1_TextStyleAttrs {
        var result = base
        if top.hasNext { result.next = top.next }
        if top.hasCharacter {
            result.character = overlay(base.character, top.character, color: top.affectsColor)
            if top.affectsColor && top.character.hasFill { result.affectsColor = true }
        }
        if top.hasParagraph { result.paragraph = overlay(base.paragraph, top.paragraph) }
        return result
    }

    static func overlay(_ base: Wiretuner_Doc_V1_CharacterSettings, _ top: Wiretuner_Doc_V1_CharacterSettings, color: Bool) -> Wiretuner_Doc_V1_CharacterSettings {
        var r = base
        if top.hasFontFamily { r.fontFamily = top.fontFamily }
        if top.hasFontStyle { r.fontStyle = top.fontStyle }
        if top.hasSize { r.size = top.size }
        if top.hasLeading { r.leading = top.leading }
        if top.hasRangeKerning { r.rangeKerning = top.rangeKerning }
        if top.hasBaselineShift { r.baselineShift = top.baselineShift }
        if top.hasHorizontalScale { r.horizontalScale = top.horizontalScale }
        if color && top.hasFill { r.fill = top.fill }
        if top.hasStroke { r.stroke = top.stroke }
        if top.hasEffect { r.effect = top.effect }
        if top.hasCase { r.case = top.case }
        if top.hasLanguage { r.language = top.language }
        if top.hasOverprint { r.overprint = top.overprint }
        if top.hasAxes { r.axes = top.axes }
        for feature in features where top.features[keyPath: feature.has] {
            r.features[keyPath: feature.value] = top.features[keyPath: feature.value]
        }
        return r
    }

    static func overlay(_ base: Wiretuner_Doc_V1_ParagraphSettings, _ top: Wiretuner_Doc_V1_ParagraphSettings) -> Wiretuner_Doc_V1_ParagraphSettings {
        var r = base
        if top.hasAlignment { r.alignment = top.alignment }
        if top.hasRaggedWidth { r.raggedWidth = top.raggedWidth }
        if top.hasFlushZone { r.flushZone = top.flushZone }
        if top.hasLeftIndent { r.leftIndent = top.leftIndent }
        if top.hasRightIndent { r.rightIndent = top.rightIndent }
        if top.hasFirstLineIndent { r.firstLineIndent = top.firstLineIndent }
        if top.hasSpaceAbove { r.spaceAbove = top.spaceAbove }
        if top.hasSpaceBelow { r.spaceBelow = top.spaceBelow }
        if top.tabsSet {
            r.tabs = top.tabs
            r.tabsSet = true
        }
        if top.hasHyphenation { r.hyphenation = top.hyphenation }
        if top.hasRule { r.rule = top.rule }
        if top.hasHangPunctuation { r.hangPunctuation = top.hangPunctuation }
        if top.hasKeepLines { r.keepLines = top.keepLines }
        if top.hasKeepWithNext { r.keepWithNext = top.keepWithNext }
        if top.hasWordSpacing { r.wordSpacing = top.wordSpacing }
        if top.hasLetterSpacing { r.letterSpacing = top.letterSpacing }
        return r
    }

    // MARK: As marks and registers

    /// The mark values a style's character settings stand for, one per set field (one `feature`
    /// value per set feature); the fill only when `attrs.affects_color` holds one.
    public static func markValues(_ attrs: Wiretuner_Doc_V1_TextStyleAttrs) -> [Wiretuner_Doc_V1_TextMarkValue] {
        let c = attrs.character
        var values: [Wiretuner_Doc_V1_TextMarkValue] = []
        func add(_ build: (inout Wiretuner_Doc_V1_TextMarkValue) -> Void) {
            var value = Wiretuner_Doc_V1_TextMarkValue()
            build(&value)
            values.append(value)
        }
        if c.hasFontFamily { add { $0.fontFamily = c.fontFamily } }
        if c.hasFontStyle { add { $0.fontStyle = c.fontStyle } }
        if c.hasSize { add { $0.size = c.size } }
        if c.hasLeading { add { $0.leading = c.leading } }
        if c.hasRangeKerning { add { $0.rangeKerning = c.rangeKerning } }
        if c.hasBaselineShift { add { $0.baselineShift = c.baselineShift } }
        if c.hasHorizontalScale { add { $0.horizontalScale = c.horizontalScale } }
        if attrs.affectsColor && c.hasFill { add { $0.fill = c.fill } }
        if c.hasStroke { add { $0.stroke = c.stroke } }
        if c.hasEffect { add { $0.effect = c.effect } }
        if c.hasCase { add { $0.case = c.case } }
        if c.hasLanguage { add { $0.language = c.language } }
        if c.hasOverprint { add { $0.overprint = c.overprint } }
        if c.hasAxes { add { $0.axes = c.axes } }
        for feature in features where c.features[keyPath: feature.has] {
            add { $0.feature = .with { $0.tag = feature.tag; $0.state = c.features[keyPath: feature.value] } }
        }
        return values
    }

    /// The `ParagraphProps` a style's paragraph settings stand for, and the fields they set
    /// (`ParagraphProps` numbers; 9 when the tabs are set).
    public static func paragraph(_ settings: Wiretuner_Doc_V1_ParagraphSettings) -> (props: Wiretuner_Doc_V1_ParagraphProps, fields: [UInt32]) {
        var props = Wiretuner_Doc_V1_ParagraphProps()
        var fields: [UInt32] = []
        if settings.hasAlignment { props.alignment = settings.alignment; fields.append(1) }
        if settings.hasRaggedWidth { props.raggedWidth = settings.raggedWidth; fields.append(2) }
        if settings.hasFlushZone { props.flushZone = settings.flushZone; fields.append(3) }
        if settings.hasLeftIndent { props.leftIndent = settings.leftIndent; fields.append(4) }
        if settings.hasRightIndent { props.rightIndent = settings.rightIndent; fields.append(5) }
        if settings.hasFirstLineIndent { props.firstLineIndent = settings.firstLineIndent; fields.append(6) }
        if settings.hasSpaceAbove { props.spaceAbove = settings.spaceAbove; fields.append(7) }
        if settings.hasSpaceBelow { props.spaceBelow = settings.spaceBelow; fields.append(8) }
        if settings.tabsSet { props.tabs = settings.tabs; fields.append(9) }
        if settings.hasHyphenation { props.hyphenation = settings.hyphenation; fields.append(10) }
        if settings.hasRule { props.rule = settings.rule; fields.append(11) }
        if settings.hasHangPunctuation { props.hangPunctuation = settings.hangPunctuation; fields.append(12) }
        if settings.hasKeepLines { props.keepLines = settings.keepLines; fields.append(13) }
        if settings.hasKeepWithNext { props.keepWithNext = settings.keepWithNext; fields.append(14) }
        if settings.hasWordSpacing { props.wordSpacing = settings.wordSpacing; fields.append(15) }
        if settings.hasLetterSpacing { props.letterSpacing = settings.letterSpacing; fields.append(16) }
        return (props, fields)
    }

    /// The fields of `own` (a paragraph's registers) that hold a value: a non-default register is
    /// set, a default one (never written, or cleared) is not; tab stops (9) when there are any.
    /// `style` (17) is not an attribute and is left out.
    public static func setFields(_ own: Wiretuner_Doc_V1_ParagraphProps) -> [UInt32] {
        var fields = TextEditing.presentFields(own).filter { $0 != 17 }
        if !own.tabs.isEmpty { fields.append(9) }
        return fields.sorted()
    }

    /// `own` over `base`: each field `own` sets (`setFields`) replaces `base`'s.
    public static func paragraph(_ own: Wiretuner_Doc_V1_ParagraphProps, over base: Wiretuner_Doc_V1_ParagraphProps) -> Wiretuner_Doc_V1_ParagraphProps {
        var r = base
        for field in setFields(own) {
            switch field {
            case 1: r.alignment = own.alignment
            case 2: r.raggedWidth = own.raggedWidth
            case 3: r.flushZone = own.flushZone
            case 4: r.leftIndent = own.leftIndent
            case 5: r.rightIndent = own.rightIndent
            case 6: r.firstLineIndent = own.firstLineIndent
            case 7: r.spaceAbove = own.spaceAbove
            case 8: r.spaceBelow = own.spaceBelow
            case 9: r.tabs = own.tabs
            case 10: r.hyphenation = own.hyphenation
            case 11: r.rule = own.rule
            case 12: r.hangPunctuation = own.hangPunctuation
            case 13: r.keepLines = own.keepLines
            case 14: r.keepWithNext = own.keepWithNext
            case 15: r.wordSpacing = own.wordSpacing
            default: r.letterSpacing = own.letterSpacing
            }
        }
        if own.hasStyle { r.style = own.style }
        return r
    }

    /// The value of paragraph field `field` in `props`, for comparing an override with the style.
    static func paragraphValue(_ props: Wiretuner_Doc_V1_ParagraphProps, _ field: UInt32) -> Wiretuner_Doc_V1_ParagraphProps {
        var only = Wiretuner_Doc_V1_ParagraphProps()
        switch field {
        case 1: only.alignment = props.alignment
        case 2: only.raggedWidth = props.raggedWidth
        case 3: only.flushZone = props.flushZone
        case 4: only.leftIndent = props.leftIndent
        case 5: only.rightIndent = props.rightIndent
        case 6: only.firstLineIndent = props.firstLineIndent
        case 7: only.spaceAbove = props.spaceAbove
        case 8: only.spaceBelow = props.spaceBelow
        case 9: only.tabs = props.tabs.map { stop in
            var copy = stop
            copy.clearID()
            return copy
        }
        case 10: only.hyphenation = props.hyphenation
        case 11: only.rule = props.rule
        case 12: only.hangPunctuation = props.hangPunctuation
        case 13: only.keepLines = props.keepLines
        case 14: only.keepWithNext = props.keepWithNext
        case 15: only.wordSpacing = props.wordSpacing
        default: only.letterSpacing = props.letterSpacing
        }
        return only
    }

    /// The fields of `settings` that are set, as `CharacterSettings` field numbers.
    static func characterFields(_ settings: Wiretuner_Doc_V1_CharacterSettings) -> [UInt32] {
        var fields: [UInt32] = []
        if settings.hasFontFamily { fields.append(1) }
        if settings.hasFontStyle { fields.append(2) }
        if settings.hasSize { fields.append(3) }
        if settings.hasLeading { fields.append(4) }
        if settings.hasRangeKerning { fields.append(5) }
        if settings.hasBaselineShift { fields.append(6) }
        if settings.hasHorizontalScale { fields.append(7) }
        if settings.hasFill { fields.append(8) }
        if settings.hasStroke { fields.append(9) }
        if settings.hasEffect { fields.append(10) }
        if settings.hasCase { fields.append(11) }
        if settings.hasLanguage { fields.append(12) }
        if settings.hasOverprint { fields.append(13) }
        if settings.hasAxes { fields.append(14) }
        if settings.hasFeatures { fields.append(15) }
        return fields
    }

    /// The fields of `settings` that are set, as `ParagraphSettings` field numbers (10 for tabs).
    static func paragraphSettingsFields(_ settings: Wiretuner_Doc_V1_ParagraphSettings) -> [UInt32] {
        var fields: [UInt32] = []
        if settings.hasAlignment { fields.append(1) }
        if settings.hasRaggedWidth { fields.append(2) }
        if settings.hasFlushZone { fields.append(3) }
        if settings.hasLeftIndent { fields.append(4) }
        if settings.hasRightIndent { fields.append(5) }
        if settings.hasFirstLineIndent { fields.append(6) }
        if settings.hasSpaceAbove { fields.append(7) }
        if settings.hasSpaceBelow { fields.append(8) }
        if settings.tabsSet { fields.append(10) }
        if settings.hasHyphenation { fields.append(11) }
        if settings.hasRule { fields.append(12) }
        if settings.hasHangPunctuation { fields.append(13) }
        if settings.hasKeepLines { fields.append(14) }
        if settings.hasKeepWithNext { fields.append(15) }
        if settings.hasWordSpacing { fields.append(16) }
        if settings.hasLetterSpacing { fields.append(17) }
        return fields
    }

    /// The attribute identity of a mark value: its `TextMarkValue` field number, and a `feature`'s
    /// tag.
    public static func key(_ value: Wiretuner_Doc_V1_TextMarkValue) -> String {
        switch value.value {
        case .feature(let feature)?: "21/\(feature.tag)"
        case .fontFamily?: "1"
        case .fontStyle?: "2"
        case .size?: "3"
        case .leading?: "4"
        case .kerning?: "5"
        case .rangeKerning?: "6"
        case .baselineShift?: "7"
        case .horizontalScale?: "8"
        case .fill?: "9"
        case .stroke?: "10"
        case .effect?: "11"
        case .style?: "12"
        case .language?: "14"
        case .noBreak?: "15"
        case .case?: "16"
        case .inlineGraphic?: "17"
        case .overprint?: "18"
        case .noHyphen?: "19"
        case .axes?: "20"
        case .link?: "40"
        case .field?: "41"
        case .mention?: "42"
        case nil: ""
        }
    }
}
