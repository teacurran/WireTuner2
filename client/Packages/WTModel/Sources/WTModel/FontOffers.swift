import CoreText
import Foundation
import WTProto
import WTText

/// One variation axis a font offers (type-specifications.adoc, "Variable font axes"): its tag, the
/// name the font gives it, and its range.
public struct FontAxisOffer: Hashable, Sendable {
    public let tag: String
    public let name: String
    public let minimum: Double
    public let defaultValue: Double
    public let maximum: Double

    public init(tag: String, name: String, minimum: Double, defaultValue: Double, maximum: Double) {
        self.tag = tag
        self.name = name
        self.minimum = minimum
        self.defaultValue = defaultValue
        self.maximum = maximum
    }

    /// `value` inside the range.
    public func clamped(_ value: Double) -> Double { min(max(value, minimum), maximum) }
}

/// A named instance of a variable family: its style name and axis values.
public struct FontInstanceOffer: Hashable, Sendable {
    public let style: String
    public let axes: [String: Double]

    public init(style: String, axes: [String: Double]) {
        self.style = style
        self.axes = axes
    }
}

/// What the Character section's *Axes* and *Features* groups offer for a face (type-specifications,
/// "Client", TYPE-046): the resolved font's axes (`CTFontCopyVariationAxes`), the family's named
/// instances (its faces' `kCTFontVariationAttribute`), the features of the documented table that
/// the font provides -- read as WTText reads them, by asking the layout which it drops -- and the
/// stylistic sets' names from the font's AAT selectors (Core Text names them from the `name`
/// table).
public enum FontOffers {
    /// The documented features, in the Features group's order.
    public static let featureTags: [String] = ["liga", "dlig", "smcp", "c2sc", "onum", "lnum", "tnum", "pnum", "frac", "swsh", "calt"]
        + (1...20).map { String(format: "ss%02d", $0) }

    /// The feature names the group shows (a stylistic set's own name takes over when the font has one).
    public static let featureTitles: [String: String] = [
        "liga": "Ligatures", "dlig": "Discretionary ligatures", "smcp": "Small caps", "c2sc": "All small caps",
        "onum": "Old-style figures", "lnum": "Lining figures", "tnum": "Tabular figures", "pnum": "Proportional figures",
        "frac": "Fractions", "swsh": "Swashes", "calt": "Contextual alternates",
    ]

    public static func title(_ tag: String, names: [String: String] = [:]) -> String {
        if let name = names[tag] { return name }
        if let title = featureTitles[tag] { return title }
        if tag.hasPrefix("ss"), let number = Int(tag.dropFirst(2)) { return "Stylistic set \(number)" }
        return tag
    }

    /// The face `family` `style` names, when it is installed or activated.
    public static func font(family: String, style: String?, size: Double = 12) -> CTFont? {
        FontManager.shared.font(for: FaceName(family: family, style: style), size: size)
    }

    /// A tag as its four characters.
    static func tag(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }

    /// A Core Foundation array of dictionaries, empty when absent.
    static func dictionaries(_ value: Any?) -> [[CFString: Any]] {
        value as? [[CFString: Any]] ?? []
    }

    /// A number entry of a Core Text dictionary.
    static func number(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
    }

    /// The font's axes, in the font's order.
    public static func axes(of font: CTFont) -> [FontAxisOffer] {
        dictionaries(CTFontCopyVariationAxes(font)).compactMap { axis in
            guard let identifier = number(axis, kCTFontVariationAxisIdentifierKey), let low = number(axis, kCTFontVariationAxisMinimumValueKey),
                  let high = number(axis, kCTFontVariationAxisMaximumValueKey), let standard = number(axis, kCTFontVariationAxisDefaultValueKey) else { return nil }
            let tag = tag(UInt32(identifier))
            return FontAxisOffer(tag: tag, name: (axis[kCTFontVariationAxisNameKey] as? String) ?? tag, minimum: min(low, high), defaultValue: standard, maximum: max(low, high))
        }
    }

    /// The named instances of `family`: each face whose descriptor carries axis values.
    public static func instances(family: String) -> [FontInstanceOffer] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let faces = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor] ?? []
        var seen = Set<String>()
        return faces.compactMap { face -> FontInstanceOffer? in
            guard let style = CTFontDescriptorCopyAttribute(face, kCTFontStyleNameAttribute) as? String, !seen.contains(style) else { return nil }
            let font = CTFontCreateWithFontDescriptor(face, 12, nil)
            let offered = axes(of: font)
            guard !offered.isEmpty else { return nil }
            let values = CTFontDescriptorCopyAttribute(face, kCTFontVariationAttribute) as? [NSNumber: NSNumber] ?? [:]
            // An axis the face does not name stands at its default.
            var result = Dictionary(uniqueKeysWithValues: offered.map { ($0.tag, $0.defaultValue) })
            for (key, value) in values { result[tag(key.uint32Value)] = value.doubleValue }
            seen.insert(style)
            return FontInstanceOffer(style: style, axes: result)
        }
        .sorted { ($0.axes["wght"] ?? 0, $0.axes["wdth"] ?? 0, $0.style) < ($1.axes["wght"] ?? 0, $1.axes["wdth"] ?? 0, $1.style) }
    }

    /// The documented features the face offers, in the table's order: the layout is asked to
    /// apply all of them and reports those the font lacks.
    public static func features(family: String, style: String?, engine: TextLayoutEngine = TextLayoutEngine()) -> [String] {
        guard FontManager.shared.isAvailable(family) else { return [] }
        var attributes = TextAttributes()
        attributes.fontFamily = family
        if let style { attributes.fontStyle = style }
        for tag in featureTags { attributes.features[tag] = .on }
        let layout = engine.layout(TextContent("x", attributes: attributes), in: [.block(TextBlock(autoWidth: true, autoHeight: true))])
        let dropped = layout.fontReport.droppedFeatures.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return featureTags.filter { !dropped.contains($0) }
    }

    /// The stylistic sets' names the font gives (`ss03` → "Single-storey a").
    public static func stylisticSetNames(of font: CTFont) -> [String: String] {
        var names: [String: String] = [:]
        for feature in dictionaries(CTFontCopyFeatures(font)) where number(feature, kCTFontFeatureTypeIdentifierKey) == 35 {
            for selector in dictionaries(feature[kCTFontFeatureTypeSelectorsKey]) {
                let identifier = Int(number(selector, kCTFontFeatureSelectorIdentifierKey) ?? 0)
                guard identifier >= 2, identifier <= 40, identifier % 2 == 0, let name = selector[kCTFontFeatureSelectorNameKey] as? String else { continue }
                names[String(format: "ss%02d", identifier / 2)] = name
            }
        }
        return names
    }
}

/// A text style's feature settings by tag (text-styles.adoc: the tri-states are a STRUCT).
public extension Wiretuner_Doc_V1_FeatureSettings {
    /// The field number of `tag` under `FeatureSettings`; nil for a tag the style cannot hold.
    static func field(_ tag: String) -> UInt32? {
        TextStyleAttributes.features.firstIndex { $0.tag == tag }.map(TextStyleEditing.featureField)
    }

    /// The state set for `tag`, nil when it is *No selection*.
    func state(_ tag: String) -> Wiretuner_Doc_V1_FeatureState? {
        guard let entry = TextStyleAttributes.features.first(where: { $0.tag == tag }), self[keyPath: entry.has] else { return nil }
        return self[keyPath: entry.value]
    }

    /// Sets `tag` to `state`, or back to *No selection* with nil.
    mutating func set(_ tag: String, _ state: Wiretuner_Doc_V1_FeatureState?) {
        guard let entry = TextStyleAttributes.features.first(where: { $0.tag == tag }) else { return }
        if let state {
            self[keyPath: entry.value] = state
        } else {
            var copy = self
            copy[keyPath: entry.value] = .unspecified
            // A proto3 optional is cleared by rebuilding without it.
            var cleared = Wiretuner_Doc_V1_FeatureSettings()
            for other in TextStyleAttributes.features where other.tag != tag && copy[keyPath: other.has] {
                cleared[keyPath: other.value] = copy[keyPath: other.value]
            }
            self = cleared
        }
    }
}
