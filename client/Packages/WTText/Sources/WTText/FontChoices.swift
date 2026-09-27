import Foundation

/// Type sizes as the Text menu and the Text toolbar offer them (type-specifications.adoc, "Font,
/// size and style"): the presets, *Smaller* and *Larger* in 1-point steps, and *Other…* with any
/// size from 1 to 10,000 points (outside that range a size reads as the default).
public enum TypeSizes {
    /// menu:Text[Size]'s presets, in points.
    public static let presets: [Double] = [9, 10, 12, 14, 18, 24, 36, 48, 72]
    /// The sizes a user may set.
    public static let range: ClosedRange<Double> = 1...10_000
    /// *Smaller* and *Larger* move by this many points.
    public static let step = 1.0

    /// `size` moved by `delta` points and kept inside `range`.
    public static func stepped(_ size: Double, by delta: Double) -> Double {
        min(max(size + delta, range.lowerBound), range.upperBound)
    }

    /// A typed size: a number with an optional `pt` ("12", "12.5 pt", "9pt"), inside `range`;
    /// nil for anything else.
    public static func parse(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("pt") { trimmed = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard let value = Double(trimmed), value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// "12", "12.5": a size without trailing zeros, for a field or a menu title.
    public static func format(_ size: Double) -> String {
        size.rounded() == size ? String(Int(size)) : String(format: "%g", size)
    }
}

/// One family in the Font menu or the Text toolbar's family list.
public struct FontFamilyChoice: Hashable, Sendable {
    public let family: String
    /// Some text of the document names it.
    public let inDocument: Bool
    /// Neither installed nor activated on this Mac: shown in brackets, drawn in a substitute.
    public let isMissing: Bool

    public init(family: String, inDocument: Bool, isMissing: Bool) {
        self.family = family
        self.inDocument = inDocument
        self.isMissing = isMissing
    }

    /// What a menu shows: the name, in brackets when the font is missing (font-substitution.adoc).
    public var title: String { isMissing ? "[\(family)]" : family }
}

/// The families the Font menu lists, in its three groups: the recently used ones, the document's
/// fonts missing on this Mac, then every family that can be laid out.
public struct FontFamilyList: Hashable, Sendable {
    public let recent: [FontFamilyChoice]
    public let missing: [FontFamilyChoice]
    public let all: [FontFamilyChoice]

    /// - Parameters:
    ///   - installed: every family that can be laid out (`FontManager.families()`).
    ///   - recents: the recently used families, most recent first.
    ///   - documentFamilies: the families the document's text names.
    ///   - isAvailable: whether a family can be laid out as itself.
    public init(installed: [String], recents: [String], documentFamilies: Set<String>, isAvailable: (String) -> Bool) {
        func choice(_ family: String) -> FontFamilyChoice {
            FontFamilyChoice(family: family, inDocument: documentFamilies.contains(family), isMissing: !isAvailable(family))
        }
        let installedSet = Set(installed)
        // A recent family that is gone and not in the document is left out.
        recent = recents.filter { installedSet.contains($0) || documentFamilies.contains($0) }.map(choice)
        missing = documentFamilies.filter { !isAvailable($0) }.sorted().map(choice)
        all = installed.map(choice)
    }

    /// Every family once, recent first, then missing, then the rest: a combo box's list.
    public var flattened: [FontFamilyChoice] {
        var seen: Set<String> = []
        return (recent + missing + all).filter { seen.insert($0.family).inserted }
    }
}

/// The recently used families (the Font menu's top group), most recent first.
public enum FontRecents {
    public static let limit = 10

    /// `list` with `family` moved to the front, without duplicates, at most `limit` long.
    public static func adding(_ family: String, to list: [String], limit: Int = FontRecents.limit) -> [String] {
        guard !family.isEmpty else { return list }
        return Array(([family] + list.filter { $0 != family }).prefix(limit))
    }
}

/// The type-to-filter rule of the family lists: case- and diacritic-insensitive, families that
/// start with the query before those that merely contain it; an empty query keeps everything.
public enum FontFilter {
    public static func filter(_ families: [String], matching query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return families }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let prefix = families.filter { $0.range(of: needle, options: options.union(.anchored)) != nil }
        let rest = families.filter { $0.range(of: needle, options: options) != nil && !prefix.contains($0) }
        return prefix + rest
    }
}
