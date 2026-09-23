// A QR code encoder (DATA-018; ISO/IEC 18004): versions 1-40, byte mode (UTF-8), the four
// error correction levels, all eight masks with the standard penalty rules.  Pure Swift and
// deterministic, so every Mac draws the same modules for the same value; Core Image's
// `CIQRCodeGenerator` is used only to cross-check in tests.

import Foundation

/// `QrErrorCorrection`.
public enum QRErrorCorrection: Int, Hashable, Sendable, CaseIterable {
    case low
    case medium
    case quartile
    case high

    /// The two format bits (ISO 18004 Table 12): L 01, M 00, Q 11, H 10.
    var formatBits: Int {
        switch self {
        case .low: return 1
        case .medium: return 0
        case .quartile: return 3
        case .high: return 2
        }
    }
}

/// A QR symbol: `size` × `size` modules, true dark, row-major from the top-left.
public struct QRCode: Hashable, Sendable {
    public let version: Int
    public let errorCorrection: QRErrorCorrection
    public let mask: Int
    public let size: Int
    public private(set) var modules: [Bool]

    /// Why a value cannot be encoded.
    public enum EncodingError: Error, Equatable {
        /// More bytes than version 40 holds at this level.
        case tooLong(bytes: Int, capacity: Int)
    }

    public func isDark(x: Int, y: Int) -> Bool {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return false }
        return modules[y * size + x]
    }

    // MARK: Encoding

    /// `text` as UTF-8 in byte mode, in the smallest version that holds it at `level`, with
    /// the mask of lowest penalty (or `mask`, 0...7, when given).
    public static func encode(_ text: String, level: QRErrorCorrection = .medium, mask: Int? = nil) throws -> QRCode {
        try encode(bytes: Array(text.utf8), level: level, mask: mask)
    }

    public static func encode(bytes: [UInt8], level: QRErrorCorrection = .medium, mask: Int? = nil) throws -> QRCode {
        guard let version = (1...40).first(where: { dataCapacityBits($0, level) >= 4 + countBits($0) + 8 * bytes.count && bytes.count < 1 << countBits($0) }) else {
            throw EncodingError.tooLong(bytes: bytes.count, capacity: byteCapacity(version: 40, level: level))
        }
        let data = dataCodewords(bytes, version: version, level: level)
        let all = interleaved(data, version: version, level: level)
        var code = QRCode(version: version, errorCorrection: level, mask: 0, size: version * 4 + 17, modules: [])
        var function = [Bool](repeating: false, count: code.size * code.size)
        code.modules = [Bool](repeating: false, count: code.size * code.size)
        code.drawFunctionPatterns(&function)
        code.drawCodewords(all, function: function)
        if let mask {
            return code.masked(min(max(mask, 0), 7), function: function)
        }
        let candidates = (0..<8).map { code.masked($0, function: function) }
        let penalties = candidates.map(\.penalty)
        return candidates[penalties.indices.min { penalties[$0] < penalties[$1] }!]
    }

    /// The most bytes `version` holds at `level` in byte mode.
    public static func byteCapacity(version: Int, level: QRErrorCorrection) -> Int {
        (dataCapacityBits(version, level) - 4 - countBits(version)) / 8
    }

    static func countBits(_ version: Int) -> Int { version < 10 ? 8 : 16 }

    /// Bits of data (without error correction) `version` holds at `level`.
    static func dataCapacityBits(_ version: Int, _ level: QRErrorCorrection) -> Int {
        (rawDataModules(version) / 8 - QRTables.ecCodewordsPerBlock[level.rawValue][version] * QRTables.blocks[level.rawValue][version]) * 8
    }

    /// Modules available for codewords (data, error correction and remainder bits).
    static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 {
                result -= 36
            }
        }
        return result
    }

    /// Mode, count, bytes, terminator and padding: the data codewords.
    static func dataCodewords(_ bytes: [UInt8], version: Int, level: QRErrorCorrection) -> [UInt8] {
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                bits.append((value >> shift) & 1 == 1)
            }
        }
        append(0b0100, 4)
        append(bytes.count, countBits(version))
        for byte in bytes {
            append(Int(byte), 8)
        }
        let capacity = dataCapacityBits(version, level)
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var result: [UInt8] = stride(from: 0, to: bits.count, by: 8).map { start in
            (0..<8).reduce(UInt8(0)) { $0 << 1 | (bits[start + $1] ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while result.count < capacity / 8 {
            result.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }
        return result
    }

    /// The data split into blocks, each followed by its Reed-Solomon codewords, interleaved.
    static func interleaved(_ data: [UInt8], version: Int, level: QRErrorCorrection) -> [UInt8] {
        let blockCount = QRTables.blocks[level.rawValue][version]
        let ecLength = QRTables.ecCodewordsPerBlock[level.rawValue][version]
        let raw = rawDataModules(version) / 8
        let shortBlocks = blockCount - raw % blockCount
        let shortLength = raw / blockCount
        let generator = ReedSolomon.generator(degree: ecLength)
        var blocks: [[UInt8]] = []
        var offset = 0
        for index in 0..<blockCount {
            let length = shortLength - ecLength + (index < shortBlocks ? 0 : 1)
            let block = Array(data[offset..<(offset + length)])
            offset += length
            blocks.append(block + ReedSolomon.remainder(block, generator: generator))
        }
        var result: [UInt8] = []
        for column in 0...shortLength {
            for (index, block) in blocks.enumerated() {
                // Short blocks have no data codeword at the last data position.
                if column == shortLength - ecLength && index < shortBlocks {
                    continue
                }
                let position = column > shortLength - ecLength && index < shortBlocks ? column - 1 : column
                if position < block.count {
                    result.append(block[position])
                }
            }
        }
        return result
    }

    // MARK: Modules

    private mutating func set(_ x: Int, _ y: Int, _ dark: Bool, _ function: inout [Bool]) {
        modules[y * size + x] = dark
        function[y * size + x] = true
    }

    /// Finders, separators, timing, alignment, format and version areas.
    mutating func drawFunctionPatterns(_ function: inout [Bool]) {
        for i in 0..<size {
            set(6, i, i % 2 == 0, &function)
            set(i, 6, i % 2 == 0, &function)
        }
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard (0..<size).contains(x), (0..<size).contains(y) else { continue }
                    let distance = max(abs(dx), abs(dy))
                    set(x, y, distance != 2 && distance != 4, &function)
                }
            }
        }
        let positions = QRTables.alignmentPositions(version)
        let count = positions.count
        for (i, cx) in positions.enumerated() {
            for (j, cy) in positions.enumerated() {
                // Not over the finders.
                if (i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0) {
                    continue
                }
                for dy in -2...2 {
                    for dx in -2...2 {
                        set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1, &function)
                    }
                }
            }
        }
        // Reserve the format areas (written for real once the mask is known).
        drawFormatBits(mask: 0, &function)
        if version >= 7 {
            var remainder = version
            for _ in 0..<12 {
                remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25)
            }
            let bits = version << 12 | remainder
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                set(a, b, dark, &function)
                set(b, a, dark, &function)
            }
        }
    }

    /// The 15 format bits for `mask`, both copies, and the dark module.
    mutating func drawFormatBits(mask: Int, _ function: inout [Bool]) {
        let data = errorCorrection.formatBits << 3 | mask
        var remainder = data
        for _ in 0..<10 {
            remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
        }
        let bits = (data << 10 | remainder) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
        for i in 0...5 {
            set(8, i, bit(i), &function)
        }
        set(8, 7, bit(6), &function)
        set(8, 8, bit(7), &function)
        set(7, 8, bit(8), &function)
        for i in 9..<15 {
            set(14 - i, 8, bit(i), &function)
        }
        for i in 0..<8 {
            set(size - 1 - i, 8, bit(i), &function)
        }
        for i in 8..<15 {
            set(8, size - 15 + i, bit(i), &function)
        }
        set(8, size - 8, true, &function)
    }

    /// The codewords in the zigzag order: column pairs from the right, alternately upward and
    /// downward, skipping the vertical timing column and function modules.
    mutating func drawCodewords(_ codewords: [UInt8], function: [Bool]) {
        var index = 0
        let total = codewords.count * 8
        var right = size - 1
        while right >= 1 {
            if right == 6 {
                right = 5
            }
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vertical : vertical
                    guard !function[y * size + x] else { continue }
                    if index < total {
                        modules[y * size + x] = (codewords[index >> 3] >> (7 - UInt8(index & 7))) & 1 == 1
                        index += 1
                    }
                }
            }
            right -= 2
        }
    }

    /// The symbol with `mask` applied to the non-function modules and its format bits written.
    func masked(_ mask: Int, function: [Bool]) -> QRCode {
        var result = QRCode(version: version, errorCorrection: errorCorrection, mask: mask, size: size, modules: modules)
        for y in 0..<size {
            for x in 0..<size where !function[y * size + x] {
                if QRCode.maskCondition(mask, x: x, y: y) {
                    result.modules[y * size + x].toggle()
                }
            }
        }
        var scratch = function
        result.drawFormatBits(mask: mask, &scratch)
        return result
    }

    static func maskCondition(_ mask: Int, x: Int, y: Int) -> Bool {
        switch mask {
        case 0: return (x + y) % 2 == 0
        case 1: return y % 2 == 0
        case 2: return x % 3 == 0
        case 3: return (x + y) % 3 == 0
        case 4: return (x / 3 + y / 2) % 2 == 0
        case 5: return x * y % 2 + x * y % 3 == 0
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }

    // MARK: Penalty

    /// ISO 18004's four penalty rules: runs of five or more (3 + excess), 2 × 2 blocks (3
    /// each), finder-like 1:1:3:1:1 patterns with four light modules on either side (40 each),
    /// and the dark proportion's distance from 50% (10 per 5%).
    var penalty: Int {
        var result = 0
        for line in 0..<size {
            for horizontal in [true, false] {
                var runColor = false, runLength = 0
                var sequence: [Bool] = []
                sequence.reserveCapacity(size)
                for i in 0..<size {
                    let dark = horizontal ? modules[line * size + i] : modules[i * size + line]
                    sequence.append(dark)
                    if i > 0 && dark == runColor {
                        runLength += 1
                    } else {
                        if runLength >= 5 { result += 3 + runLength - 5 }
                        runColor = dark
                        runLength = 1
                    }
                }
                if runLength >= 5 { result += 3 + runLength - 5 }
                result += 40 * QRCode.finderLikePatterns(in: sequence)
            }
        }
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let dark = modules[y * size + x]
                if dark == modules[y * size + x + 1] && dark == modules[(y + 1) * size + x] && dark == modules[(y + 1) * size + x + 1] {
                    result += 3
                }
            }
        }
        let dark = modules.filter { $0 }.count
        let total = size * size
        let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        result += max(k, 0) * 10
        return result
    }

    /// Occurrences of dark-light-dark×3-light-dark with four light modules before or after
    /// (the area outside the symbol counts as light).
    static func finderLikePatterns(in line: [Bool]) -> Int {
        let core: [Bool] = [true, false, true, true, true, false, true]
        func light(_ i: Int) -> Bool { i < 0 || i >= line.count || !line[i] }
        var count = 0
        guard line.count >= core.count else { return 0 }
        for start in 0...(line.count - core.count) where (0..<core.count).allSatisfy({ line[start + $0] == core[$0] }) {
            let before = (1...4).allSatisfy { light(start - $0) }
            let after = (0..<4).allSatisfy { light(start + core.count + $0) }
            if before || after {
                count += 1
            }
        }
        return count
    }
}

/// Reed-Solomon over GF(256) with the QR polynomial x⁸ + x⁴ + x³ + x² + 1.
enum ReedSolomon {
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var result = 0
        for bit in stride(from: 7, through: 0, by: -1) {
            result = (result << 1) ^ ((result >> 7) * 0x11D)
            result ^= ((Int(y) >> bit) & 1) * Int(x)
        }
        return UInt8(result)
    }

    /// The generator of degree `degree` (roots α⁰ ... α^(degree-1)), leading 1 omitted.
    static func generator(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree {
                    result[j] ^= result[j + 1]
                }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    /// The error correction codewords of `data`.
    static func remainder(_ data: [UInt8], generator: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: generator.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for index in result.indices {
                result[index] ^= multiply(generator[index], factor)
            }
        }
        return result
    }
}

/// ISO 18004 Table 9 (error correction codewords per block and block counts, by level then
/// version; index 0 unused) and the alignment pattern positions.
enum QRTables {
    static let ecCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    static let blocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    /// The alignment pattern centres of `version` along each axis (none for version 1).
    static func alignmentPositions(_ version: Int) -> [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let size = version * 4 + 17
        let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
        var result: [Int] = []
        var position = size - 7
        while result.count < count - 1 {
            result.insert(position, at: 0)
            position -= step
        }
        return [6] + result
    }
}
