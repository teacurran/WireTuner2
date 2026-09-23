import Foundation

/// A string prepared for fuzzy matching: case- and diacritic-folded UTF-16 units and which of
/// them begin a word (after a space or punctuation, or an upper-case letter after a lower-case
/// one).
struct FuzzyCandidate: Sendable {
    let units: [UInt16]
    let wordStarts: [Bool]
    /// Which letters and digits occur: a query needing one the candidate lacks is rejected
    /// without scanning.
    let mask: UInt64

    init(_ string: String) {
        let original = Array(string.utf16)
        let isASCII = original.allSatisfy { $0 < 128 }
        let folded = isASCII ? original.map(Self.lowercasedASCII) : Array(Self.fold(string).utf16)
        units = folded
        mask = Self.mask(of: folded)
        let source = isASCII ? original : folded
        wordStarts = source.indices.map { index in
            guard index > 0 else { return true }
            let previous = source[index - 1], current = source[index]
            return !Self.isAlphanumeric(previous) || (Self.isUpper(current) && Self.isLower(previous))
        }
    }

    /// Bit 0-25 for a-z, 26-35 for 0-9, 63 for anything else but a space.
    static func mask(of units: [UInt16]) -> UInt64 {
        var mask: UInt64 = 0
        for unit in units {
            switch unit {
            case 97...122: mask |= 1 << UInt64(unit - 97)
            case 48...57: mask |= 1 << UInt64(unit - 48 + 26)
            case 32: break
            default: mask |= 1 << 63
            }
        }
        return mask
    }

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func lowercasedASCII(_ unit: UInt16) -> UInt16 {
        isUpper(unit) ? unit + 32 : unit
    }

    static func isUpper(_ unit: UInt16) -> Bool { (65...90).contains(unit) }
    static func isLower(_ unit: UInt16) -> Bool { (97...122).contains(unit) }

    static func isAlphanumeric(_ unit: UInt16) -> Bool {
        isUpper(unit) || isLower(unit) || (48...57).contains(unit) || unit >= 128
    }
}

/// Sublime-style subsequence matching (customizing.adoc, "Command palette"): every query
/// character must appear in order; the score rewards word starts and consecutive runs and
/// penalises longer candidates.  Spaces in the query are ignored, so `rot cw` matches *Rotate
/// Clockwise*.  Runs synchronously per keystroke over a few thousand items.
enum FuzzyMatcher {
    static let matchScore = 1.0
    static let wordStartBonus = 8.0
    static let consecutiveBonus = 5.0
    static let lengthPenalty = 0.05
    /// A match found only in the subtitle counts this much of a title match.
    static let subtitleWeight = 0.5

    /// The folded query without spaces.
    static func prepare(_ query: String) -> [UInt16] {
        FuzzyCandidate(query).units.filter { $0 != 32 }
    }

    /// The best score of `query` against `candidate`; nil when it is not a subsequence.
    static func score(_ query: [UInt16], _ candidate: FuzzyCandidate) -> Double? {
        let m = query.count, n = candidate.units.count
        guard m > 0 else { return 0 }
        let needed = FuzzyCandidate.mask(of: query)
        guard m <= n, candidate.mask & needed == needed else { return nil }
        // Raw pointers and `while` loops: this runs for every candidate item per keystroke, and
        // debug builds do not inline array or range iteration.
        return query.withUnsafeBufferPointer { query in
            candidate.units.withUnsafeBufferPointer { text in
                guard isSubsequence(query.baseAddress!, m, of: text.baseAddress!, n) else { return nil }
                return candidate.wordStarts.withUnsafeBufferPointer { wordStarts in
                    withUnsafeTemporaryAllocation(of: Double.self, capacity: 2 * n) { rows in
                        dynamicProgram(query: query.baseAddress!, m, text: text.baseAddress!, n, wordStarts: wordStarts.baseAddress!, rows: rows.baseAddress!)
                    }
                }
            }
        }
    }

    private static func isSubsequence(_ query: UnsafePointer<UInt16>, _ m: Int, of text: UnsafePointer<UInt16>, _ n: Int) -> Bool {
        var i = 0, j = 0
        while i < m, j < n {
            if text[j] == query[i] { i += 1 }
            j += 1
        }
        return i == m
    }

    /// best[j]: the best score of the query prefix so far with its last character at j; two
    /// rows, swapped per query character.
    private static func dynamicProgram(
        query: UnsafePointer<UInt16>, _ m: Int, text: UnsafePointer<UInt16>, _ n: Int, wordStarts: UnsafePointer<Bool>,
        rows: UnsafeMutablePointer<Double>
    ) -> Double? {
        var previous = rows, current = rows + n
        var i = 0
        while i < m {
            var bestBefore = -Double.infinity
            let character = query[i]
            var j = 0
            while j < n {
                if i > 0, j >= 2, previous[j - 2] > bestBefore { bestBefore = previous[j - 2] }
                if text[j] != character {
                    current[j] = -.infinity
                } else {
                    let gain = wordStarts[j] ? matchScore + wordStartBonus : matchScore
                    if i == 0 {
                        current[j] = gain
                    } else {
                        let adjacent = j >= 1 ? previous[j - 1] + consecutiveBonus : -.infinity
                        current[j] = (adjacent > bestBefore ? adjacent : bestBefore) + gain
                    }
                }
                j += 1
            }
            swap(&previous, &current)
            i += 1
        }
        var best = -Double.infinity
        var j = 0
        while j < n {
            if previous[j] > best { best = previous[j] }
            j += 1
        }
        return best.isFinite ? best - lengthPenalty * Double(n) : nil
    }

    /// Title first, then title and subtitle together at `subtitleWeight`.
    static func score(_ query: [UInt16], title: FuzzyCandidate, combined: @autoclosure () -> FuzzyCandidate) -> Double? {
        if let score = score(query, title) { return score }
        return score(query, combined()).map { $0 * subtitleWeight }
    }
}
