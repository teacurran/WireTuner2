// A Code 128 encoder (DATA-018; ISO/IEC 15417): code sets A, B and C with the shortest
// symbol found by dynamic programming over set changes and single-character shifts, the
// modulo-103 check character and the stop pattern.  ASCII (0-127) only.

import Foundation

public struct Code128: Hashable, Sendable {
    /// The symbol values, start and check characters included, stop excluded.
    public let values: [Int]

    /// Why a value cannot be encoded.
    public enum EncodingError: Error, Equatable {
        case empty
        /// A character outside ASCII, at this offset.
        case notASCII(offset: Int)
    }

    public static let startA = 103
    public static let startB = 104
    public static let startC = 105
    public static let stop = 106
    static let codeA = 101, codeB = 100, codeC = 99, shift = 98

    /// Bar and space widths of each symbol value, in modules (ISO 15417 Table 1); the stop
    /// pattern has seven elements.
    public static let patterns: [[Int]] = [
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
        "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
        "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
        "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
        "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
        "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
        "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
        "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
        "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
        "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
        "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
    ].map { $0.map { Int(String($0))! } }

    private enum CodeSet: Int, CaseIterable {
        case a, b, c

        var start: Int { [Code128.startA, Code128.startB, Code128.startC][rawValue] }
        var switchCode: Int { [Code128.codeA, Code128.codeB, Code128.codeC][rawValue] }
    }

    public init(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else {
            throw EncodingError.empty
        }
        if let bad = bytes.firstIndex(where: { $0 > 127 }) {
            throw EncodingError.notASCII(offset: bad)
        }
        values = Code128.withCheck(Code128.shortest(bytes))
    }

    /// A value in set A (control characters and upper case) or nil.
    private static func valueA(_ byte: UInt8) -> Int? {
        byte < 32 ? Int(byte) + 64 : byte < 96 ? Int(byte) - 32 : nil
    }

    /// A value in set B (printable characters and lower case) or nil.
    private static func valueB(_ byte: UInt8) -> Int? {
        byte >= 32 && byte < 128 ? Int(byte) - 32 : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    /// The fewest symbol values (start first) that encode `bytes`: a shortest path over
    /// (position, code set) where a character costs one value in a set that has it, two digits
    /// cost one value in C, a change of set one value, and a single character of the other of
    /// A and B a shift plus the character.  Ties prefer B, then A, then C, and changes late.
    static func shortest(_ bytes: [UInt8]) -> [Int] {
        let n = bytes.count
        let sets = CodeSet.allCases
        // cost[i][s]: fewest values encoding bytes[i...] when in set s at position i.
        var cost = [[Int]](repeating: [Int](repeating: Int.max / 2, count: 3), count: n + 1)
        var choice = [[[Int]]](repeating: [[Int]](repeating: [], count: 3), count: n + 1)
        var nextSet = [[CodeSet]](repeating: [.a, .b, .c], count: n + 1)
        var advance = [[Int]](repeating: [0, 0, 0], count: n + 1)
        cost[n] = [0, 0, 0]
        for i in stride(from: n - 1, through: 0, by: -1) {
            // First the cost of encoding in place, then of switching (which leads to encoding).
            var inPlace = [Int](repeating: Int.max / 2, count: 3)
            var inPlaceValues = [[Int]](repeating: [], count: 3)
            var inPlaceAdvance = [0, 0, 0]
            for set in sets {
                var best = Int.max / 2
                var values: [Int] = []
                var step = 0
                switch set {
                case .a, .b:
                    let own = set == .a ? valueA(bytes[i]) : valueB(bytes[i])
                    let other = set == .a ? valueB(bytes[i]) : valueA(bytes[i])
                    if let own, cost[i + 1][set.rawValue] + 1 < best {
                        best = cost[i + 1][set.rawValue] + 1
                        values = [own]
                        step = 1
                    }
                    if let other, cost[i + 1][set.rawValue] + 2 < best {
                        best = cost[i + 1][set.rawValue] + 2
                        values = [shift, other]
                        step = 1
                    }
                case .c:
                    if i + 1 < n, isDigit(bytes[i]), isDigit(bytes[i + 1]) {
                        best = cost[i + 2][CodeSet.c.rawValue] + 1
                        values = [Int(bytes[i] - 48) * 10 + Int(bytes[i + 1] - 48)]
                        step = 2
                    }
                }
                inPlace[set.rawValue] = best
                inPlaceValues[set.rawValue] = values
                inPlaceAdvance[set.rawValue] = step
            }
            for set in sets {
                var best = inPlace[set.rawValue]
                var values = inPlaceValues[set.rawValue]
                var target = set
                var step = inPlaceAdvance[set.rawValue]
                for other in [CodeSet.b, .a, .c] where other != set && inPlace[other.rawValue] + 1 < best {
                    best = inPlace[other.rawValue] + 1
                    values = [other.switchCode] + inPlaceValues[other.rawValue]
                    target = other
                    step = inPlaceAdvance[other.rawValue]
                }
                cost[i][set.rawValue] = best
                choice[i][set.rawValue] = values
                nextSet[i][set.rawValue] = target
                advance[i][set.rawValue] = step
            }
        }
        let start = [CodeSet.b, .a, .c].min { cost[0][$0.rawValue] < cost[0][$1.rawValue] }!
        var result = [start.start]
        var position = 0
        var set = start
        while position < n {
            result += choice[position][set.rawValue]
            let next = nextSet[position][set.rawValue]
            position += advance[position][set.rawValue]
            set = next
        }
        return result
    }

    /// `values` followed by the check character: the start value plus each value times its
    /// position, modulo 103.
    static func withCheck(_ values: [Int]) -> [Int] {
        let sum = values.enumerated().reduce(0) { $0 + ($1.offset == 0 ? $1.element : $1.element * $1.offset) }
        return values + [sum % 103]
    }

    /// The bars as (start, width) runs in modules from the first bar (the stop included),
    /// without the quiet zone.
    public var bars: [(start: Int, width: Int)] {
        var result: [(Int, Int)] = []
        var x = 0
        for value in values + [Code128.stop] {
            for (index, width) in Code128.patterns[value].enumerated() {
                if index % 2 == 0 {
                    result.append((x, width))
                }
                x += width
            }
        }
        return result
    }

    /// The symbol's width in modules: 11 per value and 13 for the stop.
    public var moduleWidth: Int { values.count * 11 + 13 }

    public static func == (lhs: Code128, rhs: Code128) -> Bool { lhs.values == rhs.values }
    public func hash(into hasher: inout Hasher) { hasher.combine(values) }
}
