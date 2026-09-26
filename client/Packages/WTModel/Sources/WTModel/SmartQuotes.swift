/// Smart quotes (editing-text.adoc, "Smart quotes"; TYPE-012): what a typed `'` or `"` becomes
/// under the *Smart quotes* preference.  Applied at keystroke time on the client; the document only
/// ever sees the resulting character, so nothing here writes.  The opening form follows the start
/// of the text, white space, an opening bracket, a dash or another opening quote; anything else --
/// a letter, a digit, punctuation that closes -- takes the closing form (so an apostrophe after a
/// letter is the closing single quote).
public struct SmartQuotes: Equatable, Sendable {
    /// The four characters of a set: opening and closing double, opening and closing single.
    public let openDouble: Character
    public let closeDouble: Character
    public let openSingle: Character
    public let closeSingle: Character

    public init(_ openDouble: Character, _ closeDouble: Character, _ openSingle: Character, _ closeSingle: Character) {
        self.openDouble = openDouble
        self.closeDouble = closeDouble
        self.openSingle = openSingle
        self.closeSingle = closeSingle
    }

    /// The six sets of the preference's pop-up, by preference value.
    public static let sets: [(id: String, quotes: SmartQuotes)] = [
        ("english", SmartQuotes("\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}")),
        ("german", SmartQuotes("\u{201E}", "\u{201C}", "\u{201A}", "\u{2018}")),
        ("guillemets", SmartQuotes("\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}")),
        ("guillemets_reversed", SmartQuotes("\u{00BB}", "\u{00AB}", "\u{203A}", "\u{2039}")),
        ("swedish", SmartQuotes("\u{201D}", "\u{201D}", "\u{2019}", "\u{2019}")),
        ("corner", SmartQuotes("\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}")),
    ]

    /// The set a preference value names (an unknown value reads as English).
    public static func set(_ id: String) -> SmartQuotes {
        sets.first { $0.id == id }?.quotes ?? sets[0].quotes
    }

    /// Characters after which a quote opens.
    static let openers: Set<Character> = ["(", "[", "{", "<", "\u{2014}", "\u{2013}", "-", "/", "\u{00A0}"]

    /// Whether a quote typed after `previous` (nil: the start of the text) opens.
    public func opens(after previous: Character?) -> Bool {
        guard let previous else { return true }
        if previous.isWhitespace || previous.isNewline || Self.openers.contains(previous) { return true }
        return [openDouble, openSingle].contains(previous) && previous != closeDouble && previous != closeSingle
    }

    /// What typing `typed` after `previous` inserts: a straight quote replaced by its curly form,
    /// anything else unchanged.
    public func replacement(for typed: String, after previous: Character?) -> String {
        switch typed {
        case "\"": return String(opens(after: previous) ? openDouble : closeDouble)
        case "'": return String(opens(after: previous) ? openSingle : closeSingle)
        default: return typed
        }
    }
}

/// The special characters of menu:Text[Special Characters] (editing-text.adoc, "Special
/// characters"; TYPE-012): what each inserts.
public enum SpecialCharacter: String, CaseIterable, Sendable {
    case endOfColumn, endOfLine, nonBreakingSpace, emSpace, enSpace, thinSpace, emDash, enDash, discretionaryHyphen

    /// The code point typed.
    public var character: Character {
        switch self {
        case .endOfColumn: "\u{000C}"
        case .endOfLine: "\u{2028}"
        case .nonBreakingSpace: "\u{00A0}"
        case .emSpace: "\u{2003}"
        case .enSpace: "\u{2002}"
        case .thinSpace: "\u{2009}"
        case .emDash: "\u{2014}"
        case .enDash: "\u{2013}"
        case .discretionaryHyphen: "\u{00AD}"
        }
    }

    public var title: String {
        switch self {
        case .endOfColumn: "End of Column"
        case .endOfLine: "End of Line"
        case .nonBreakingSpace: "Non-breaking Space"
        case .emSpace: "Em Space"
        case .enSpace: "En Space"
        case .thinSpace: "Thin Space"
        case .emDash: "Em Dash"
        case .enDash: "En Dash"
        case .discretionaryHyphen: "Discretionary Hyphen"
        }
    }

    /// The mark *Show invisibles* draws for a character that prints nothing (nil: it prints).
    public static func invisibleMark(for scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case " ": "\u{00B7}"
        case "\u{00A0}": "\u{00B0}"
        case "\u{2002}", "\u{2003}", "\u{2009}": "\u{00B7}"
        case "\t": "\u{2192}"
        case "\n": "\u{00B6}"
        case "\u{2028}": "\u{00AC}"
        case "\u{000C}": "\u{00A7}"
        case "\u{00AD}": "-"
        default: nil
        }
    }
}
