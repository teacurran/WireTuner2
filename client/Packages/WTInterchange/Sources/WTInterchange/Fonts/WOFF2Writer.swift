// FONT-027: WOFF2 (W3C "WOFF File Format 2.0") in Swift (font-export.adoc, "WOFF2"): the sfnt's
// tables with the null transform -- flag 3 for glyf and loca, 0 for every other table -- in one
// Brotli stream from Apple's Compression framework.  The glyf/loca transform that makes
// `woff2_compress` output about 15% smaller is not applied (a noted follow-up).  `WOFF2Reader`
// decodes files with null transforms (this writer's) back to the sfnt, for tests and import.

import Compression
import Foundation

/// Writes WOFF2 files.
public enum WOFF2Writer {
    /// The 63 tags WOFF2 names by index.
    static let knownTags = [
        "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
        "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
        "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
        "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
    ]

    /// The tables of an sfnt, in directory order.
    static func tables(of sfnt: Data) throws -> (flavor: Int, tables: [(tag: String, data: [UInt8])]) {
        let reader = FontReader(sfnt, context: "sfnt")
        let flavor = try reader.u32(0)
        let count = try reader.u16(4)
        var tables: [(String, [UInt8])] = []
        for index in 0..<count {
            let entry = 12 + index * 16
            tables.append((try reader.tag(entry), try reader.slice(try reader.u32(entry + 8), try reader.u32(entry + 12))))
        }
        return (flavor, tables)
    }

    /// `value` as a UIntBase128: big-endian groups of seven bits, the high bit on all but the
    /// last byte.
    static func base128(_ value: Int) -> [UInt8] {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            groups.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return groups
    }

    /// `bytes` compressed with Brotli.
    static func brotli(_ bytes: [UInt8]) throws -> [UInt8] {
        var capacity = bytes.count + bytes.count / 2 + 1_024
        while capacity < 1 << 30 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = compression_encode_buffer(&output, capacity, bytes, bytes.count, nil, COMPRESSION_BROTLI)
            if written > 0 { return Array(output.prefix(written)) }
            capacity *= 2
        }
        throw FontReadError.malformed("brotli")
    }

    /// The WOFF2 file of the sfnt `data` (an OTF or TTF).
    public static func woff2(_ data: Data) throws -> Data {
        let (flavor, tables) = try tables(of: data)
        let ordered = tables.sorted { $0.tag < $1.tag }
        var directory = FontWriter()
        var stream: [UInt8] = []
        var sfntSize = 12 + ordered.count * 16
        for (tag, bytes) in ordered {
            let known = knownTags.firstIndex(of: tag)
            let transform = tag == "glyf" || tag == "loca" ? 3 : 0
            directory.u8((known ?? 63) | transform << 6)
            if known == nil { directory.tag(tag) }
            directory.append(base128(bytes.count))
            stream += bytes
            sfntSize += (bytes.count + 3) / 4 * 4
        }
        let compressed = try brotli(stream)
        var w = FontWriter()
        w.tag("wOF2")
        w.u32(flavor)
        let lengthOffset = w.count
        w.u32(0)
        w.u16(ordered.count)
        w.u16(0)
        w.u32(sfntSize)
        w.u32(compressed.count)
        w.u16(1); w.u16(0)          // version of the font data: 1.0
        for _ in 0..<5 { w.u32(0) } // no metadata, no private data
        w.append(directory)
        w.append(compressed)
        w.pad(to: 4)
        w.set32(w.count, at: lengthOffset)
        return Data(w.bytes)
    }
}

/// Reads WOFF2 files whose tables all use the null transform.
public enum WOFF2Reader {
    /// The sfnt a WOFF2 file holds.
    public static func sfnt(_ data: Data) throws -> Data {
        let reader = FontReader(data, context: "WOFF2")
        guard try reader.tag(0) == "wOF2" else { throw FontReadError.malformed("WOFF2 signature") }
        let flavor = try reader.u32(4)
        let count = try reader.u16(12)
        let compressedLength = try reader.u32(20)
        var position = 48
        var entries: [(tag: String, length: Int)] = []
        func base128() throws -> Int {
            var value = 0
            for _ in 0..<5 {
                let byte = try reader.u8(position)
                position += 1
                value = value << 7 | (byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw FontReadError.malformed("UIntBase128")
        }
        for _ in 0..<count {
            let flags = try reader.u8(position)
            position += 1
            let index = flags & 0x3F
            let tag: String
            if index == 63 {
                tag = try reader.tag(position)
                position += 4
            } else {
                tag = WOFF2Writer.knownTags[index]
            }
            let transform = flags >> 6
            let nullTransform = tag == "glyf" || tag == "loca" ? transform == 3 : transform == 0
            guard nullTransform else { throw FontReadError.unsupported("WOFF2 table transform") }
            entries.append((tag, try base128()))
        }
        let compressed = try reader.slice(position, compressedLength)
        let total = entries.reduce(0) { $0 + $1.length }
        var output = [UInt8](repeating: 0, count: max(total, 1))
        let written = compression_decode_buffer(&output, output.count, compressed, compressed.count, nil, COMPRESSION_BROTLI)
        guard written == total else { throw FontReadError.malformed("WOFF2 data") }
        var tables: [String: [UInt8]] = [:]
        var offset = 0
        for entry in entries {
            tables[entry.tag] = Array(output[offset..<(offset + entry.length)])
            offset += entry.length
        }
        return FontTables.assemble(tables, signature: flavor)
    }
}
