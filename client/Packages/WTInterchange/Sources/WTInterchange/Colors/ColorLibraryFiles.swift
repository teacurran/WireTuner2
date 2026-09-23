// Colour library files (COLOR-013; spot-process.adoc, "Color libraries" and "Client";
// exporting-colors.adoc): the `.wtcolors` text-protobuf library, Adobe Swatch Exchange (`.ase`),
// Photoshop swatches (`.aco`) and Photoshop colour tables (`.act`), read into and written from
// `colorlib.proto`'s `ColorLibrary`.  Every reader keeps each colour in the space its file says;
// a writer whose format cannot say a space (`.ase` and `.aco` have no Display P3 or OKLab)
// gamut-maps the colour into sRGB with COLOR-024's `WTColor.Gamut.map` and reports it.

import Foundation
import SwiftProtobuf
import WTProto
import WTRender

public typealias ColorLibrary = Wiretuner_Lib_V1_ColorLibrary
public typealias LibraryColor = Wiretuner_Lib_V1_LibraryColor

/// The library file formats.
public enum ColorLibraryFormat: String, CaseIterable, Hashable, Sendable {
    /// {product}'s own library: `ColorLibrary` as text protobuf, every colour in its own space.
    case wtcolors
    /// Adobe Swatch Exchange.
    case ase
    /// Photoshop swatches.
    case aco
    /// Photoshop colour table (sRGB only, read only).
    case act

    public var fileExtension: String { rawValue }

    /// The format of a file extension (case-insensitive).
    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    /// Whether {product} writes the format (the colour table is import only).
    public var isWritable: Bool { self != .act }
}

/// Why a library file could not be read or written.
public enum ColorLibraryError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The extension names no library format.
    case unknownFormat(String)
    /// The bytes are not a file of the format.
    case malformed(format: ColorLibraryFormat, reason: String)
    /// The format is read only.
    case notWritable(ColorLibraryFormat)
    /// A file could not be read or written.
    case io(String)

    public var description: String {
        switch self {
        case .unknownFormat(let name):
            return "\(name) is not a color library WireTuner reads (.wtcolors, .ase, .aco or .act)."
        case .malformed(let format, let reason):
            return "The .\(format.rawValue) file cannot be read: \(reason)."
        case .notWritable(let format):
            return ".\(format.rawValue) files can be imported but not written."
        case .io(let message):
            return message
        }
    }
}

/// A library written to a format, and what the format could not carry.
public struct ColorLibraryExport: Sendable {
    public var data: Data
    /// Lines for the export summary: colours gamut-mapped into sRGB, spots written as process,
    /// tints written as plain colours.
    public var notes: [String]
}

public enum ColorLibraryFiles {
    /// `data` read as `format`; `name` names a library whose format carries no name (the file's
    /// base name).
    public static func read(_ data: Data, format: ColorLibraryFormat, name: String) throws -> ColorLibrary {
        switch format {
        case .wtcolors:
            do {
                return try ColorLibrary(textFormatString: String(decoding: data, as: UTF8.self))
            } catch {
                throw ColorLibraryError.malformed(format: .wtcolors, reason: "it is not a WireTuner color library")
            }
        case .ase:
            return try SwatchExchange.read(data, name: name)
        case .aco:
            return try PhotoshopSwatches.read(data, name: name)
        case .act:
            return try PhotoshopColorTable.read(data, name: name)
        }
    }

    /// The library file at `url`, its format from the extension and its name from the base name.
    public static func read(contentsOf url: URL) throws -> ColorLibrary {
        guard let format = ColorLibraryFormat(fileExtension: url.pathExtension) else {
            throw ColorLibraryError.unknownFormat(url.lastPathComponent)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ColorLibraryError.io("\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
        return try read(data, format: format, name: url.deletingPathExtension().lastPathComponent)
    }

    /// `library` in `format`.
    public static func write(_ library: ColorLibrary, format: ColorLibraryFormat) throws -> ColorLibraryExport {
        switch format {
        case .wtcolors:
            return ColorLibraryExport(data: Data(library.textFormatString().utf8), notes: [])
        case .ase:
            return SwatchExchange.write(library)
        case .aco:
            return PhotoshopSwatches.write(library)
        case .act:
            throw ColorLibraryError.notWritable(.act)
        }
    }

    // MARK: Colours

    /// A stored colour as the display list's value, by the read-time rules (spot-process.adoc):
    /// no case reads as white CMYK, `rgb` tagged Lab or OKLab (or an unknown tag) as sRGB, `lab`
    /// tagged sRGB or Display P3 (or an unknown tag) as CIELAB.
    static func color(_ stored: Wiretuner_Doc_V1_Color) -> Color {
        switch stored.components {
        case .cmyk(let cmyk)?:
            return Color(cyan: cmyk.c, magenta: cmyk.m, yellow: cmyk.y, black: cmyk.k)
        case .rgb(let rgb)?:
            return stored.space == .displayP3 ? Color(displayP3Red: rgb.r, green: rgb.g, blue: rgb.b) : Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        case .lab(let lab)?:
            return stored.space == .oklab ? Color(oklabL: lab.l, a: lab.a, b: lab.b) : Color(labL: lab.l, a: lab.a, b: lab.b)
        case nil:
            return Color(cyan: 0, magenta: 0, yellow: 0, black: 0)
        }
    }

    /// The display list's colour as a stored `Color` (alpha is not stored).
    static func stored(_ color: Color) -> Wiretuner_Doc_V1_Color {
        var result = Wiretuner_Doc_V1_Color()
        let c = color.components
        switch color.space {
        case .cmyk:
            var cmyk = Wiretuner_Doc_V1_Cmyk()
            (cmyk.c, cmyk.m, cmyk.y, cmyk.k) = (c.x, c.y, c.z, c.w)
            result.cmyk = cmyk
        case .sRGB, .displayP3:
            var rgb = Wiretuner_Doc_V1_Rgb()
            (rgb.r, rgb.g, rgb.b) = (c.x, c.y, c.z)
            result.rgb = rgb
            result.space = color.space == .displayP3 ? .displayP3 : .srgb
        case .lab, .oklab:
            var lab = Wiretuner_Doc_V1_Lab()
            (lab.l, lab.a, lab.b) = (c.x, c.y, c.z)
            result.lab = lab
            result.space = color.space == .oklab ? .oklab : .lab
        }
        return result
    }

    /// The colour a library entry shows: a tint is its base's colour tinted.
    static func shown(_ entry: LibraryColor) -> Color {
        let base = color(entry.value)
        return entry.tintPercent > 0 ? base.tinted(entry.tintPercent / 100) : base
    }

    /// A library colour.
    static func entry(key: String, name: String? = nil, color: Color, spot: Bool = false, group: String = "") -> LibraryColor {
        var entry = LibraryColor()
        entry.key = key
        entry.name = name ?? key
        entry.value = stored(color)
        entry.spot = spot
        entry.group = group
        return entry
    }

    /// `names` made unique by suffixing repeats (" 2", " 3"…), as library keys must be.
    static func uniqueKeys(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { name in
            var key = name.isEmpty ? "Color" : name
            var counter = 2
            while seen.contains(key) {
                key = "\(name.isEmpty ? "Color" : name) \(counter)"
                counter += 1
            }
            seen.insert(key)
            return key
        }
    }

    /// The summary lines of an export to a format without wide spaces, spots or tints.
    static func notes(mapped: [String], spots: [String] = [], tints: [String] = [], format: String) -> [String] {
        var notes: [String] = []
        if !mapped.isEmpty {
            notes.append("\(mapped.count) color\(mapped.count == 1 ? "" : "s") gamut-mapped into sRGB (\(format) has no Display P3 or OKLab): \(mapped.joined(separator: ", "))")
        }
        if !spots.isEmpty {
            notes.append("\(spots.count) spot color\(spots.count == 1 ? "" : "s") written as process (\(format) has no spot colors): \(spots.joined(separator: ", "))")
        }
        if !tints.isEmpty {
            notes.append("\(tints.count) tint\(tints.count == 1 ? "" : "s") written as plain colors (\(format) has no tints): \(tints.joined(separator: ", "))")
        }
        return notes
    }
}

/// Big-endian reading over a byte array, failing with the format's error.
struct ColorFileReader {
    let bytes: [UInt8]
    let format: ColorLibraryFormat
    var position = 0

    init(_ data: Data, format: ColorLibraryFormat) {
        bytes = [UInt8](data)
        self.format = format
    }

    var remaining: Int { bytes.count - position }

    func fail(_ reason: String) -> ColorLibraryError {
        .malformed(format: format, reason: reason)
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else {
            throw fail("it ends early")
        }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func uint16() throws -> UInt16 {
        let slice = try take(2)
        return UInt16(slice[slice.startIndex]) << 8 | UInt16(slice[slice.startIndex + 1])
    }

    mutating func uint32() throws -> UInt32 {
        UInt32(try uint16()) << 16 | UInt32(try uint16())
    }

    mutating func float32() throws -> Double {
        Double(Float(bitPattern: try uint32()))
    }

    /// `units` UTF-16BE code units, a trailing NUL dropped.
    mutating func utf16(_ units: Int) throws -> String {
        var codes: [UInt16] = []
        for _ in 0..<units {
            codes.append(try uint16())
        }
        if codes.last == 0 {
            codes.removeLast()
        }
        return String(decoding: codes, as: UTF16.self)
    }
}

extension Data {
    /// `string` as UTF-16BE code units with a terminating NUL.
    mutating func appendUTF16BigEndian(_ string: String) {
        for unit in string.utf16 {
            appendBigEndian(unit)
        }
        appendBigEndian(UInt16(0))
    }

    mutating func appendFloat32BigEndian(_ value: Double) {
        appendBigEndian(Float(value).bitPattern)
    }
}
