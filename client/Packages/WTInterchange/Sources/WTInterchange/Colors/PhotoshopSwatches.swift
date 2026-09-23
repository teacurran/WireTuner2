// Photoshop swatches (`.aco`) and colour tables (`.act`).
//
// `.aco`: a version 1 section (a count, then per colour a space id and four 16-bit values) and,
// in files from Photoshop 6 on, a version 2 section repeating the colours with a UTF-16BE name
// each.  Spaces: 0 RGB (0...65535), 1 HSB, 2 CMYK (65535 is no ink), 7 Lab (L 0...10000, a and b
// signed hundredths), 8 Grayscale (0...10000 of black), 9 wide CMYK (0...10000 of ink).  The
// format has no spot colours, tints, Display P3 or OKLab: written, spots become process and the
// wide colours are gamut-mapped into sRGB, reported.
//
// `.act`: 256 sRGB triples, optionally followed by the number of colours used and a
// transparency index (0xFFFF for none).

import Foundation
import WTRender

enum PhotoshopSwatches {
    static func read(_ data: Data, name: String) throws -> ColorLibrary {
        var reader = ColorFileReader(data, format: .aco)
        var colors: [Color] = []
        var names: [String] = []
        while reader.remaining >= 4 {
            let version = try reader.uint16()
            let count = Int(try reader.uint16())
            guard version == 1 || version == 2 else {
                throw reader.fail("section version \(version) is not 1 or 2")
            }
            var section: [Color] = []
            var sectionNames: [String] = []
            for _ in 0..<count {
                let space = try reader.uint16()
                let values = [try reader.uint16(), try reader.uint16(), try reader.uint16(), try reader.uint16()]
                section.append(try color(space: space, values, reader: reader))
                if version == 2 {
                    _ = try reader.uint16()
                    sectionNames.append(try reader.utf16(Int(try reader.uint16())))
                }
            }
            // A version 2 section repeats version 1's colours with names: it replaces them.
            colors = section
            names = version == 2 ? sectionNames : section.indices.map { "Color \($0 + 1)" }
        }
        var library = ColorLibrary()
        library.name = name
        let keys = ColorLibraryFiles.uniqueKeys(names)
        library.colors = colors.indices.map { ColorLibraryFiles.entry(key: keys[$0], name: names[$0], color: colors[$0]) }
        return library
    }

    static func color(space: UInt16, _ v: [UInt16], reader: ColorFileReader) throws -> Color {
        func unit(_ value: UInt16) -> Double { Double(value) / 65535 }
        switch space {
        case 0:
            return Color(red: unit(v[0]), green: unit(v[1]), blue: unit(v[2]))
        case 1:
            let (r, g, b) = Quantizer.hsb(hue: unit(v[0]), saturation: unit(v[1]), brightness: unit(v[2]))
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case 2:
            return Color(cyan: 1 - unit(v[0]), magenta: 1 - unit(v[1]), yellow: 1 - unit(v[2]), black: 1 - unit(v[3]))
        case 7:
            return Color(labL: Double(v[0]) / 100, a: Double(Int16(bitPattern: v[1])) / 100, b: Double(Int16(bitPattern: v[2])) / 100)
        case 8:
            return Color(cyan: 0, magenta: 0, yellow: 0, black: min(Double(v[0]) / 10000, 1))
        case 9:
            return Color(cyan: Double(v[0]) / 10000, magenta: Double(v[1]) / 10000, yellow: Double(v[2]) / 10000, black: Double(v[3]) / 10000)
        default:
            throw reader.fail("color space \(space) is not RGB, HSB, CMYK, Lab or Grayscale")
        }
    }

    static func write(_ library: ColorLibrary) -> ColorLibraryExport {
        var mapped: [String] = []
        var spots: [String] = []
        var tints: [String] = []
        var records: [(space: UInt16, values: [UInt16])] = []
        func word(_ value: Double) -> UInt16 { UInt16((min(max(value, 0), 1) * 65535).rounded()) }
        for entry in library.colors {
            if entry.spot { spots.append(entry.name) }
            if entry.tintPercent > 0 { tints.append(entry.name) }
            var color = ColorLibraryFiles.shown(entry)
            if color.space == .displayP3 || color.space == .oklab {
                color = WTColor.Gamut.map(color, into: .sRGB)
                mapped.append(entry.name)
            }
            let c = color.components
            switch color.space {
            case .cmyk:
                records.append((2, [word(1 - c.x), word(1 - c.y), word(1 - c.z), word(1 - c.w)]))
            case .lab:
                let l = UInt16((min(max(c.x, 0), 100) * 100).rounded())
                let a = Int16((min(max(c.y, -128), 127) * 100).rounded()), b = Int16((min(max(c.z, -128), 127) * 100).rounded())
                records.append((7, [l, UInt16(bitPattern: a), UInt16(bitPattern: b), 0]))
            default:
                records.append((0, [word(c.x), word(c.y), word(c.z), 0]))
            }
        }
        var data = Data()
        for version: UInt16 in [1, 2] {
            data.appendBigEndian(version)
            data.appendBigEndian(UInt16(records.count))
            for (index, record) in records.enumerated() {
                data.appendBigEndian(record.space)
                record.values.forEach { data.appendBigEndian($0) }
                if version == 2 {
                    let name = library.colors[index].name
                    data.appendBigEndian(UInt16(0))
                    data.appendBigEndian(UInt16(name.utf16.count + 1))
                    data.appendUTF16BigEndian(name)
                }
            }
        }
        return ColorLibraryExport(data: data, notes: ColorLibraryFiles.notes(mapped: mapped, spots: spots, tints: tints, format: "Photoshop swatches"))
    }
}

enum PhotoshopColorTable {
    /// The colours of a table: the first `count` (all 256 without the trailer), less the
    /// transparent index; named by their 8-bit values, keyed by position.
    static func read(_ data: Data, name: String) throws -> ColorLibrary {
        var reader = ColorFileReader(data, format: .act)
        guard reader.remaining >= 768 else {
            throw reader.fail("a color table holds 768 bytes of RGB")
        }
        let triples = Array(try reader.take(768))
        var count = 256
        var transparent: Int?
        if reader.remaining >= 4 {
            count = min(Int(try reader.uint16()), 256)
            let index = Int(try reader.uint16())
            transparent = index < 256 ? index : nil
        }
        var library = ColorLibrary()
        library.name = name
        for index in 0..<count where index != transparent {
            let (r, g, b) = (triples[index * 3], triples[index * 3 + 1], triples[index * 3 + 2])
            library.colors.append(ColorLibraryFiles.entry(key: String(index + 1), name: "\(r)r \(g)g \(b)b", color: Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)))
        }
        return library
    }
}
