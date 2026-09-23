import Foundation

/// A minimal TrueType font written in the tests (TXT-002): a family no Mac has installed, with
/// `.notdef` and square glyphs for "A" and "B" (B twice as wide), and a chosen `OS/2.fsType`, so
/// activation, lookup and embedding licences can be exercised without vendoring font files.
enum FontFixture {
    static func font(family: String, style: String = "Regular", weight: UInt16 = 400, fsType: UInt16 = 0, os2: Bool = true) -> Data {
        let postScript = (family + "-" + style).filter { !$0.isWhitespace }
        // Glyphs: .notdef (empty), A (a 500-unit square), B (a 1,000-unit wide rectangle).
        let advances: [UInt16] = [500, 600, 1100]
        let glyphs: [[UInt8]] = [[], square(width: 500), square(width: 1000)]
        var glyf: [UInt8] = []
        var loca: [UInt8] = []
        for glyph in glyphs {
            loca += u16(UInt16(glyf.count / 2))
            glyf += glyph
            if glyf.count % 2 == 1 { glyf.append(0) }
        }
        loca += u16(UInt16(glyf.count / 2))

        var head: [UInt8] = u32(0x0001_0000) + u32(0x0001_0000) + u32(0) + u32(0x5F0F_3CF5)
        head += u16(0x000B) + u16(1000) + [UInt8](repeating: 0, count: 16)
        head += i16(0) + i16(0) + i16(1000) + i16(700)
        head += u16(weight >= 700 ? 1 : 0) + u16(8) + i16(2) + i16(0) + i16(0)

        var hhea: [UInt8] = u32(0x0001_0000) + i16(800) + i16(-200) + i16(0) + u16(1100)
        hhea += i16(0) + i16(100) + i16(1000) + i16(1) + i16(0) + i16(0)
        hhea += [UInt8](repeating: 0, count: 8) + i16(0) + u16(UInt16(glyphs.count))

        var maxp: [UInt8] = u32(0x0001_0000) + u16(UInt16(glyphs.count)) + u16(4) + u16(1) + u16(0) + u16(0) + u16(2)
        maxp += [UInt8](repeating: 0, count: 16)

        var hmtx: [UInt8] = []
        for advance in advances {
            hmtx += u16(advance) + i16(0)
        }

        // cmap: format 4 mapping A (0x41) → 1 and B (0x42) → 2.
        var subtable: [UInt8] = u16(4) + u16(32) + u16(0) + u16(4) + u16(4) + u16(1) + u16(0)
        subtable += u16(0x42) + u16(0xFFFF) + u16(0) + u16(0x41) + u16(0xFFFF)
        subtable += u16(UInt16(bitPattern: Int16(1 - 0x41))) + u16(1) + u16(0) + u16(0)
        let cmap: [UInt8] = u16(0) + u16(1) + u16(3) + u16(1) + u32(12) + subtable

        let names: [(UInt16, String)] = [(1, family), (2, style), (3, postScript), (4, family + " " + style), (6, postScript), (16, family), (17, style)]
        var storage: [UInt8] = []
        var records: [UInt8] = []
        for (id, value) in names {
            let bytes = value.utf16.flatMap { u16($0) }
            records += u16(3) + u16(1) + u16(0x409) + u16(id) + u16(UInt16(bytes.count)) + u16(UInt16(storage.count))
            storage += bytes
        }
        let name: [UInt8] = u16(0) + u16(UInt16(names.count)) + u16(UInt16(6 + records.count)) + records + storage

        let os2Table = os2
        var os2: [UInt8] = u16(4) + i16(700) + u16(weight) + u16(5) + u16(fsType)
        os2 += [UInt8](repeating: 0, count: 22) + [UInt8](repeating: 0, count: 10)
        os2 += u32(1) + u32(0) + u32(0) + u32(0) + Array("NONE".utf8)
        os2 += u16(weight >= 700 ? 0x20 : 0x40) + u16(0x41) + u16(0x42)
        os2 += i16(800) + i16(-200) + i16(0) + u16(800) + u16(200) + u32(1) + u32(0)
        os2 += i16(500) + i16(700) + u16(0) + u16(0x20) + u16(1)

        let post: [UInt8] = u32(0x0003_0000) + [UInt8](repeating: 0, count: 28)

        return sfnt((os2Table ? [("OS/2", os2)] : []) + [("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea), ("hmtx", hmtx), ("loca", loca), ("maxp", maxp), ("name", name), ("post", post)])
    }

    /// A simple glyph: one clockwise rectangle `width` × 700 units.
    static func square(width: Int16) -> [UInt8] {
        var glyph: [UInt8] = i16(1) + i16(0) + i16(0) + i16(width) + i16(700) + u16(3) + u16(0)
        glyph += [UInt8](repeating: 0x01, count: 4)
        glyph += i16(0) + i16(0) + i16(width) + i16(0)
        glyph += i16(0) + i16(700) + i16(0) + i16(-700)
        return glyph
    }

    static func sfnt(_ tables: [(String, [UInt8])]) -> Data {
        let sorted = tables.sorted { $0.0 < $1.0 }
        var data: [UInt8] = u32(0x0001_0000) + u16(UInt16(sorted.count)) + u16(128) + u16(3) + u16(UInt16(sorted.count * 16 - 128))
        var offset = 12 + 16 * sorted.count
        var body: [UInt8] = []
        for (tag, table) in sorted {
            data += Array(tag.utf8) + u32(checksum(table)) + u32(UInt32(offset)) + u32(UInt32(table.count))
            let padded = table + [UInt8](repeating: 0, count: (4 - table.count % 4) % 4)
            body += padded
            offset += padded.count
        }
        return Data(data + body)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        let padded = bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
        var sum: UInt32 = 0
        for index in stride(from: 0, to: padded.count, by: 4) {
            sum &+= UInt32(padded[index]) << 24 | UInt32(padded[index + 1]) << 16 | UInt32(padded[index + 2]) << 8 | UInt32(padded[index + 3])
        }
        return sum
    }

    static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    static func i16(_ value: Int16) -> [UInt8] { u16(UInt16(bitPattern: value)) }
    static func u32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    /// A scratch directory for activated font files.
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WTTextFontTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
