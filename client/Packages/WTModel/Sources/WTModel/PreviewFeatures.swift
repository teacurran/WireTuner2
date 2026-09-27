import CoreText
import Foundation
import WTInterchange

/// The Metrics window's *Features* pop-up (kerning-metrics.adoc, "Client"; opentype-features.adoc,
/// "Previewing substitutions"; FONT-020): the features a preview of the font can turn on or off --
/// the automatic ones the generator writes for it, then the tags of the user's feature file once
/// the file checks clean -- and the Core Text font that shapes with the chosen ones.  When the file
/// does not check clean the pop-up carries a warning and lists only the automatic features.
public struct PreviewFeatures: Hashable, Sendable {
    public struct Item: Hashable, Sendable, Identifiable {
        public var tag: String
        /// Written by the generator (kern, mark, mkmk, liga) rather than the user's file.
        public var isAutomatic: Bool
        /// Whether the preview applies it until someone says otherwise: the automatic features and
        /// the ones text engines apply by default; anything else (`smcp`, `swsh`, `ss01`…) is off.
        public var isOnByDefault: Bool

        public var id: String { tag }

        public init(tag: String, isAutomatic: Bool, isOnByDefault: Bool) {
            self.tag = tag
            self.isAutomatic = isAutomatic
            self.isOnByDefault = isOnByDefault
        }
    }

    /// The features text engines apply without being asked (the OpenType registry's defaults).
    public static let onByDefault: Set<String> = ["ccmp", "locl", "rlig", "liga", "clig", "calt", "kern", "mark", "mkmk", "curs", "rclt"]

    /// Shown in the pop-up when the user's feature file does not check clean.
    public static let uncheckedWarning = "The feature file has errors; only the automatic features can be previewed."

    public var items: [Item]
    /// Set when the user's file does not check clean (its features are then left out).
    public var warning: String?

    public init(items: [Item] = [], warning: String? = nil) {
        self.items = items
        self.warning = warning
    }

    /// The pop-up for `source`: the generated tags in the order kern, mark, mkmk, liga, then the
    /// user's tags in file order (a user tag that is also generated is listed once, as automatic).
    public static func of(_ source: FontSource) -> PreviewFeatures {
        let generated = FeatureGenerator.generatedTags(source)
        var items = ["kern", "mark", "mkmk", "liga"].filter(generated.contains).map { Item(tag: $0, isAutomatic: true, isOnByDefault: true) }
        guard !source.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return PreviewFeatures(items: items) }
        let report = FeatureChecker.check(source.features, glyphs: source.glyphs.map(\.name), generated: generated)
        guard report.isClean else { return PreviewFeatures(items: items, warning: uncheckedWarning) }
        var seen = Set(items.map(\.tag))
        for tag in report.featureTags where seen.insert(tag).inserted {
            items.append(Item(tag: tag, isAutomatic: false, isOnByDefault: onByDefault.contains(tag)))
        }
        return PreviewFeatures(items: items)
    }

    /// The tags on when nobody has chosen.
    public var defaultEnabled: Set<String> { Set(items.filter(\.isOnByDefault).map(\.tag)) }

    /// Core Text feature settings turning every listed feature on or off as `enabled` says.
    public func settings(enabled: Set<String>) -> [[String: Any]] {
        items.map { item in
            [kCTFontOpenTypeFeatureTag as String: item.tag, kCTFontOpenTypeFeatureValue as String: enabled.contains(item.tag) ? 1 : 0]
        }
    }

    /// `font` shaping with the listed features on or off as `enabled` says.
    public func font(_ font: CTFont, enabled: Set<String>) -> CTFont {
        let attributes = [kCTFontFeatureSettingsAttribute as String: settings(enabled: enabled)] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }
}
