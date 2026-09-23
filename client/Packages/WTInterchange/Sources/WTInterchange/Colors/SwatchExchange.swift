// Adobe Swatch Exchange (`.ase`; spot-process.adoc, "Client"): `ASEF`, version 1.0, a block
// count, then blocks -- group start (0xC001, a name), group end (0xC002) and colour entry (0x0001:
// a UTF-16BE name, a four-character model, big-endian float components and a type: 0 global,
// 1 spot, 2 normal).  RGB reads as sRGB (the format has no space tag), LAB as CIELAB D50 with L
// stored 0...1, CMYK as CMYK and Gray as CMYK black.  Writing, Display P3 and OKLab colours are
// gamut-mapped into sRGB and reported; tints are written as the colour they show.

import Foundation
import WTRender

enum SwatchExchange {
    static let groupStart: UInt16 = 0xC001
    static let groupEnd: UInt16 = 0xC002
    static let colorEntry: UInt16 = 0x0001

    static func read(_ data: Data, name: String) throws -> ColorLibrary {
        var reader = ColorFileReader(data, format: .ase)
        guard Array(try reader.take(4)) == Array("ASEF".utf8) else {
            throw reader.fail("it does not start with ASEF")
        }
        _ = try reader.uint32()  // version 1.0
        let count = try reader.uint32()
        var group = ""
        var names: [String] = []
        var colors: [(color: Color, spot: Bool, group: String)] = []
        for _ in 0..<count {
            guard reader.remaining > 0 else { break }
            let type = try reader.uint16()
            let length = Int(try reader.uint32())
            var block = ColorFileReader(Data(try reader.take(length)), format: .ase)
            switch type {
            case groupStart:
                group = try block.utf16(Int(try block.uint16()))
            case groupEnd:
                group = ""
            case colorEntry:
                let colorName = try block.utf16(Int(try block.uint16()))
                let model = String(decoding: try block.take(4), as: UTF8.self)
                let color: Color
                switch model {
                case "CMYK":
                    color = Color(cyan: try block.float32(), magenta: try block.float32(), yellow: try block.float32(), black: try block.float32())
                case "RGB ":
                    color = Color(red: try block.float32(), green: try block.float32(), blue: try block.float32())
                case "LAB ":
                    color = Color(labL: try block.float32() * 100, a: try block.float32(), b: try block.float32())
                case "Gray":
                    color = Color(cyan: 0, magenta: 0, yellow: 0, black: 1 - (try block.float32()))
                default:
                    throw reader.fail("colour model \"\(model)\" is not CMYK, RGB, LAB or Gray")
                }
                let kind = block.remaining >= 2 ? try block.uint16() : 2
                names.append(colorName)
                colors.append((color, kind == 1, group))
            default:
                continue
            }
        }
        var library = ColorLibrary()
        library.name = name
        let keys = ColorLibraryFiles.uniqueKeys(names)
        library.colors = colors.indices.map { index in
            ColorLibraryFiles.entry(key: keys[index], name: names[index], color: colors[index].color, spot: colors[index].spot, group: colors[index].group)
        }
        return library
    }

    static func write(_ library: ColorLibrary) -> ColorLibraryExport {
        var blocks: [(type: UInt16, body: Data)] = []
        var mapped: [String] = []
        var tints: [String] = []
        var groups: [String] = []
        for entry in library.colors where !groups.contains(entry.group) {
            groups.append(entry.group)
        }
        for group in groups {
            if !group.isEmpty {
                var body = Data()
                body.appendBigEndian(UInt16(group.utf16.count + 1))
                body.appendUTF16BigEndian(group)
                blocks.append((groupStart, body))
            }
            for entry in library.colors where entry.group == group {
                if entry.tintPercent > 0 {
                    tints.append(entry.name)
                }
                var color = ColorLibraryFiles.shown(entry)
                if color.space == .displayP3 || color.space == .oklab {
                    color = WTColor.Gamut.map(color, into: .sRGB)
                    mapped.append(entry.name)
                }
                let c = color.components
                var body = Data()
                body.appendBigEndian(UInt16(entry.name.utf16.count + 1))
                body.appendUTF16BigEndian(entry.name)
                switch color.space {
                case .cmyk:
                    body.append(Data("CMYK".utf8))
                    [c.x, c.y, c.z, c.w].forEach { body.appendFloat32BigEndian($0) }
                case .lab:
                    body.append(Data("LAB ".utf8))
                    [c.x / 100, c.y, c.z].forEach { body.appendFloat32BigEndian($0) }
                default:
                    body.append(Data("RGB ".utf8))
                    [c.x, c.y, c.z].forEach { body.appendFloat32BigEndian($0) }
                }
                body.appendBigEndian(UInt16(entry.spot ? 1 : 0))
                blocks.append((colorEntry, body))
            }
            if !group.isEmpty {
                blocks.append((groupEnd, Data()))
            }
        }
        var data = Data("ASEF".utf8)
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt32(blocks.count))
        for block in blocks {
            data.appendBigEndian(block.type)
            data.appendBigEndian(UInt32(block.body.count))
            data.append(block.body)
        }
        return ColorLibraryExport(data: data, notes: ColorLibraryFiles.notes(mapped: mapped, tints: tints, format: "Adobe Swatch Exchange"))
    }
}
