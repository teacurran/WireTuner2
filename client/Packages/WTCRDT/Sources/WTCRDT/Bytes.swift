import CryptoKit

/// Big-endian fixed-width writers for the canonical encodings, and hex.
enum Bytes {
    static func u32(_ value: UInt32, into out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    static func u64(_ value: UInt64, into out: inout [UInt8]) {
        u32(UInt32(truncatingIfNeeded: value >> 32), into: &out)
        u32(UInt32(truncatingIfNeeded: value), into: &out)
    }

    static func id(_ id: OpID, into out: inout [UInt8]) {
        u64(id.counter, into: &out)
        u64(id.replica, into: &out)
    }

    static func block(_ block: [UInt8], into out: inout [UInt8]) {
        u32(UInt32(block.count), into: &out)
        out.append(contentsOf: block)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
