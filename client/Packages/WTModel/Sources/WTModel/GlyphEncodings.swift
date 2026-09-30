import Foundation

// FONT-010's encoding placeholders (glyph-grid.adoc, "Ordering and encodings"): menu:View[Encoding] chooses which
// empty slots the grid shows as faint placeholders -- ASCII, Latin-1, Mac Roman or Unicode blocks, several at
// once.  A slot is empty when no live glyph keeps its codepoint after the collision rule (a collided codepoint is
// present: the keeper has it).

/// A set of characters the grid can show the missing slots of.
public enum GlyphEncoding: String, Hashable, Sendable, CaseIterable, Identifiable {
    case ascii, latin1, macRoman
    case latinExtendedA, latinExtendedB, greek, cyrillic, hebrew, arabic, generalPunctuation, currencySymbols, letterlikeSymbols
    case arrows, mathematicalOperators, boxDrawing, geometricShapes

    public var id: String { rawValue }

    /// The three code pages first, then the Unicode blocks.
    public static let codePages: [GlyphEncoding] = [.ascii, .latin1, .macRoman]
    public static let blocks: [GlyphEncoding] = allCases.filter { !codePages.contains($0) }

    public var title: String {
        switch self {
        case .ascii: "ASCII"
        case .latin1: "Latin-1"
        case .macRoman: "Mac Roman"
        case .latinExtendedA: "Latin Extended-A"
        case .latinExtendedB: "Latin Extended-B"
        case .greek: "Greek"
        case .cyrillic: "Cyrillic"
        case .hebrew: "Hebrew"
        case .arabic: "Arabic"
        case .generalPunctuation: "General Punctuation"
        case .currencySymbols: "Currency Symbols"
        case .letterlikeSymbols: "Letterlike Symbols"
        case .arrows: "Arrows"
        case .mathematicalOperators: "Mathematical Operators"
        case .boxDrawing: "Box Drawing"
        case .geometricShapes: "Geometric Shapes"
        }
    }

    /// The Unicode blocks' ranges.
    static let blockRanges: [GlyphEncoding: ClosedRange<UInt32>] = [
        .latinExtendedA: 0x100...0x17F, .latinExtendedB: 0x180...0x24F, .greek: 0x370...0x3FF, .cyrillic: 0x400...0x4FF,
        .hebrew: 0x590...0x5FF, .arabic: 0x600...0x6FF, .generalPunctuation: 0x2000...0x206F, .currencySymbols: 0x20A0...0x20CF,
        .letterlikeSymbols: 0x2100...0x214F, .arrows: 0x2190...0x21FF, .mathematicalOperators: 0x2200...0x22FF,
        .boxDrawing: 0x2500...0x257F, .geometricShapes: 0x25A0...0x25FF,
    ]

    /// The printable characters of the encoding, ascending: assigned scalars that are not controls, format
    /// characters, private use or line and paragraph separators.
    public var codepoints: [UInt32] {
        switch self {
        case .macRoman: Self.macRomanCodepoints
        case .ascii: (UInt32(0x20)...0x7E).filter(Self.isPrintable)
        case .latin1: (Array(UInt32(0x20)...0x7E) + Array(UInt32(0xA0)...0xFF)).filter(Self.isPrintable)
        // Every block has its range.
        default: Self.blockRanges[self]!.filter(Self.isPrintable)
        }
    }

    static func isPrintable(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        switch scalar.properties.generalCategory {
        case .unassigned, .control, .format, .surrogate, .privateUse, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }

    /// Mac Roman's 0x20...0xFF as Unicode (the Apple logo, U+F8FF, is private use and left out).
    static let macRomanCodepoints: [UInt32] = {
        let bytes = (UInt8(0x20)...UInt8(0xFF)).filter { $0 != 0x7F }
        // Every byte is a Mac Roman character.
        let decoded = String(data: Data(bytes), encoding: .macOSRoman)!
        return Array(Set(decoded.unicodeScalars.map(\.value).filter(isPrintable))).sorted()
    }()

    /// The empty slots of `encodings` in `index`, ascending and without repeats.
    public static func placeholders(_ encodings: Set<GlyphEncoding>, in index: GlyphIndex) -> [UInt32] {
        guard !encodings.isEmpty else { return [] }
        let wanted = Set(encodings.flatMap(\.codepoints))
        return wanted.filter { index.glyph(for: $0) == nil }.sorted()
    }
}
