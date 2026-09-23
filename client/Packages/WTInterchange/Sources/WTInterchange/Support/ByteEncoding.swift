// Byte-level encoders the own writers share: ASCII85 and hex for PostScript data, PackBits
// run-length coding (PostScript's RunLengthDecode, PSD's RLE channels), CRC-32 (PNG chunks) and
// big- and little-endian integer appends.

import Foundation

enum ASCII85 {
    /// `data` as ASCII85 (PostScript's ASCII85Decode), in lines of at most `lineLength`
    /// characters, terminated by `~>`.  A line that would start with `%` starts with a space
    /// instead (white space is ignored by the filter), so no data line reads as a DSC comment.
    static func encode(_ data: Data, lineLength: Int = 64) -> String {
        var characters: [UInt8] = []
        characters.reserveCapacity(data.count * 5 / 4 + 8)
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let count = min(4, bytes.count - index)
            var word: UInt32 = 0
            for offset in 0..<4 {
                word = word << 8 | UInt32(offset < count ? bytes[index + offset] : 0)
            }
            if word == 0 && count == 4 {
                characters.append(UInt8(ascii: "z"))
            } else {
                var digits = [UInt8](repeating: 0, count: 5)
                var value = word
                for position in stride(from: 4, through: 0, by: -1) {
                    digits[position] = UInt8(value % 85) + 33
                    value /= 85
                }
                characters += digits[0...count]
            }
            index += 4
        }
        var result = ""
        var start = 0
        while start < characters.count {
            let end = min(start + lineLength, characters.count)
            if characters[start] == UInt8(ascii: "%") {
                result += " "
            }
            result += String(decoding: characters[start..<end], as: UTF8.self)
            result += "\n"
            start = end
        }
        return result + "~>"
    }
}

enum HexLines {
    /// `data` as upper-case hex digits in lines of `bytesPerLine` bytes.
    static func encode(_ data: Data, bytesPerLine: Int = 32) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var lines: [String] = []
        var line: [UInt8] = []
        line.reserveCapacity(bytesPerLine * 2)
        for byte in data {
            line.append(digits[Int(byte >> 4)])
            line.append(digits[Int(byte & 0x0F)])
            if line.count == bytesPerLine * 2 {
                lines.append(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
            }
        }
        if !line.isEmpty {
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines.joined(separator: "\n")
    }
}

enum PackBits {
    /// `bytes` run-length coded: a length byte n followed by n + 1 literal bytes (0...127), or
    /// 257 − n copies of the next byte (129...255).  128 is never written (PostScript's EOD).
    static func encode<Bytes: Collection>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count + input.count / 128 + 1)
        var index = 0
        while index < input.count {
            var run = 1
            while index + run < input.count && run < 128 && input[index + run] == input[index] {
                run += 1
            }
            if run >= 2 {
                output.append(UInt8(257 - run))
                output.append(input[index])
                index += run
                continue
            }
            var literal = 1
            while index + literal < input.count && literal < 128 {
                // A literal stops before a run of at least two.
                if index + literal + 1 < input.count && input[index + literal] == input[index + literal + 1] {
                    break
                }
                literal += 1
            }
            output.append(UInt8(literal - 1))
            output += input[index..<(index + literal)]
            index += literal
        }
        return output
    }

    /// The inverse of `encode` (used by tests and the PSD reader checks); stops at 128.
    static func decode(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let header = Int(bytes[index])
            index += 1
            if header < 128 {
                let end = min(index + header + 1, bytes.count)
                output += bytes[index..<end]
                index = end
            } else if header > 128, index < bytes.count {
                output += [UInt8](repeating: bytes[index], count: 257 - header)
                index += 1
            } else {
                break
            }
        }
        return output
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    /// The CRC-32 (ISO 3309, as PNG uses it) of `bytes`.
    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Integer appends for binary formats.
extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendBigEndian(_ value: UInt64) {
        appendBigEndian(UInt32(value >> 32))
        appendBigEndian(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
