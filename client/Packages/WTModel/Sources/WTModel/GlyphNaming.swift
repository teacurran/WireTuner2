import Foundation

// FONT-008: glyph naming (glyph-grid.adoc, "Client": `WTModel.GlyphNaming`): the bundled AGLFN
// table, the `uniXXXX` / `uXXXXX` rules, ligature decomposition (`f_i`), suffix parsing
// (`a.alt`, `a.sc`) and Unicode character names (from ICU through Foundation), following the
// Adobe Glyph List Specification's mapping of a glyph name to a character sequence.

/// Glyph names and the characters they stand for.
public enum GlyphNaming {
    /// Longest glyph name (the PostScript and `post` table limit, GlyphProps validation).
    public static let maximumLength = 63

    static let scalarByName: [String: UInt32] = Dictionary(uniqueKeysWithValues: aglfn.map { ($0.name, $0.scalar) })
    static let nameByScalar: [UInt32: String] = Dictionary(uniqueKeysWithValues: aglfn.map { ($0.scalar, $0.name) })

    /// Whether `name` may name a glyph: 1 to 63 characters from `A-Z a-z 0-9 . _`, not starting
    /// with a digit (`.notdef` is valid).
    public static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= maximumLength else { return false }
        return !(first.value >= 0x30 && first.value <= 0x39) && name.unicodeScalars.allSatisfy(isNameCharacter)
    }

    static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "." || scalar == "_"
    }

    /// The name a new glyph for `scalar` gets: the AGLFN name, else `uniXXXX` in the BMP and
    /// `uXXXXX` above it.
    public static func name(for scalar: UInt32) -> String {
        if let name = nameByScalar[scalar] { return name }
        return scalar <= 0xFFFF ? String(format: "uni%04X", scalar) : String(format: "u%X", scalar)
    }

    /// The ligature name for a character sequence: the parts' names joined by `_` (`f_f_i`).
    public static func ligatureName(for scalars: [UInt32]) -> String {
        scalars.map(name(for:)).joined(separator: "_")
    }

    /// The name split at its first period after the first character: (`a`, `alt`) for `a.alt`;
    /// `.notdef` has no suffix.
    public static func split(_ name: String) -> (base: String, suffix: String?) {
        guard name.count > 1, let dot = name.dropFirst().firstIndex(of: ".") else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// The component names of a ligature name (the base split at underscores): `["f", "i"]` for
    /// `f_i.alt`; one part for an ordinary name.
    public static func ligatureParts(_ name: String) -> [String] {
        split(name).base.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
    }

    /// The characters `name` stands for by the AGL rules: the suffix dropped, each ligature part
    /// mapped through AGLFN, `uniXXXX…` (one or more groups of four upper-case hex digits in the
    /// BMP, no surrogates) or `uXXXX` to `uXXXXXX`.  Empty when any part maps to nothing.
    public static func scalars(of name: String) -> [UInt32] {
        var result: [UInt32] = []
        for part in ligatureParts(name) {
            guard let scalars = partScalars(part) else { return [] }
            result += scalars
        }
        return result
    }

    /// The single character `name` encodes by default, when it stands for exactly one.
    public static func codepoint(of name: String) -> UInt32? {
        let scalars = scalars(of: name)
        return scalars.count == 1 && split(name).suffix == nil ? scalars[0] : nil
    }

    static func partScalars(_ part: String) -> [UInt32]? {
        if let scalar = scalarByName[part] { return [scalar] }
        if part.hasPrefix("uni"), part.count > 3, (part.count - 3) % 4 == 0 {
            let digits = Array(part.dropFirst(3))
            var scalars: [UInt32] = []
            for start in stride(from: 0, to: digits.count, by: 4) {
                guard let value = hex(digits[start..<(start + 4)]), !(0xD800...0xDFFF).contains(value) else { return nil }
                scalars.append(value)
            }
            return scalars
        }
        if part.hasPrefix("u"), (5...7).contains(part.count) {
            guard let value = hex(part.dropFirst()), value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return nil }
            return [value]
        }
        return nil
    }

    /// Upper-case hexadecimal digits as a value (the AGL rules do not accept lower case).
    static func hex<S: Sequence>(_ digits: S) -> UInt32? where S.Element == Character {
        let text = String(digits)
        guard text.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        return UInt32(text, radix: 16)
    }

    /// The Unicode name of `scalar` ("LATIN SMALL LETTER E WITH ACUTE"), from ICU.
    public static func characterName(_ scalar: UInt32) -> String? {
        Unicode.Scalar(scalar)?.properties.name
    }

    /// `base`, or `base.1`, `base.2`, … -- the first not in `taken` (Paste as new, imports).
    public static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 1
        while taken.contains("\(base).\(counter)") {
            counter += 1
        }
        return "\(base).\(counter)"
    }

    /// The name a glyph for the typed text gets: one character's name, or the ligature name of
    /// several (the Add Glyph sheet's *Character* field).
    public static func name(forText text: String) -> String? {
        let scalars = text.unicodeScalars.map(\.value)
        guard !scalars.isEmpty else { return nil }
        return scalars.count == 1 ? name(for: scalars[0]) : ligatureName(for: scalars)
    }
}
