// COLOR-013: colour library files.  `.wtcolors` round-trips byte for byte with every space; `.ase`
// files laid out as Illustrator and Photoshop write them (built here byte by byte, independently
// of the writer) read with spot/process, groups and spaces; `.aco` and `.act` read; the writers
// gamut-map what their formats cannot say and report it; the bundled libraries and My Libraries.

import Foundation
import Testing
@testable import WTInterchange
import WTProto
import WTRender

@Suite struct ColorLibraryTests {
    // MARK: Fixtures

    /// An `.ase` file as Adobe applications write it: blocks of (type, body).
    static func ase(_ blocks: [(UInt16, Data)]) -> Data {
        var data = Data("ASEF".utf8) + Data([0, 1, 0, 0])
        data.appendBigEndian(UInt32(blocks.count))
        for (type, body) in blocks {
            data.appendBigEndian(type)
            data.appendBigEndian(UInt32(body.count))
            data.append(body)
        }
        return data
    }

    static func utf16Name(_ name: String) -> Data {
        var data = Data()
        data.appendBigEndian(UInt16(name.utf16.count + 1))
        for unit in name.utf16 { data.appendBigEndian(unit) }
        data.appendBigEndian(UInt16(0))
        return data
    }

    static func aseColor(_ name: String, model: String, _ values: [Float], type: UInt16) -> (UInt16, Data) {
        var body = utf16Name(name) + Data(model.utf8)
        for value in values { body.appendBigEndian(value.bitPattern) }
        body.appendBigEndian(type)
        return (0x0001, body)
    }

    /// Illustrator: a group holding a spot CMYK colour, a global process RGB and a LAB spot.
    static var illustratorASE: Data {
        ase([
            (0xC001, utf16Name("Brand")),
            aseColor("PANTONE 300 C", model: "CMYK", [1, 0.44, 0, 0], type: 1),
            aseColor("Sky", model: "RGB ", [0.4, 0.8, 1], type: 0),
            (0xC002, Data()),
            aseColor("Measured", model: "LAB ", [0.5, 20, -30], type: 1),
        ])
    }

    /// Photoshop: ungrouped normal colours, a grey and a repeated name.
    static var photoshopASE: Data {
        ase([
            aseColor("Red", model: "RGB ", [1, 0, 0], type: 2),
            aseColor("Mid grey", model: "Gray", [0.25], type: 2),
            aseColor("Red", model: "RGB ", [0.5, 0, 0], type: 2),
        ])
    }

    static func library(_ colors: [LibraryColor], name: String = "Mixed") -> ColorLibrary {
        var library = ColorLibrary()
        library.name = name
        library.notes = "made in a test"
        library.rows = 2
        library.columns = 3
        library.colors = colors
        return library
    }

    static var mixed: ColorLibrary {
        var tint = ColorLibraryFiles.entry(key: "Grape 50%", color: Color(red: 0.5, green: 0, blue: 1))
        tint.tintOf = "Grape"
        tint.tintPercent = 50
        return library([
            ColorLibraryFiles.entry(key: "Grape", color: Color(red: 0.5, green: 0, blue: 1), group: "Fruit"),
            tint,
            ColorLibraryFiles.entry(key: "P3 red", color: Color(displayP3Red: 1, green: 0, blue: 0)),
            ColorLibraryFiles.entry(key: "OK teal", color: Color(oklabL: 0.7, a: -0.1, b: -0.05)),
            ColorLibraryFiles.entry(key: "Lab", color: Color(labL: 60, a: 10, b: 20)),
            ColorLibraryFiles.entry(key: "Ink", color: Color(cyan: 0.1, magenta: 0.8, yellow: 0.9, black: 0), spot: true),
        ])
    }

    // MARK: .wtcolors

    @Test func wtcolorsRoundTripsByteForByteWithEverySpace() throws {
        let first = try ColorLibraryFiles.write(Self.mixed, format: .wtcolors)
        #expect(first.notes.isEmpty)
        let read = try ColorLibraryFiles.read(first.data, format: .wtcolors, name: "ignored")
        #expect(read == Self.mixed)
        #expect(read.colors[2].value.space == .displayP3 && read.colors[3].value.space == .oklab && read.colors[4].value.space == .lab)
        let again = try ColorLibraryFiles.write(read, format: .wtcolors)
        #expect(again.data == first.data)
        #expect(throws: ColorLibraryError.malformed(format: .wtcolors, reason: "it is not a WireTuner color library")) {
            try ColorLibraryFiles.read(Data("colors { bogus".utf8), format: .wtcolors, name: "x")
        }
    }

    // MARK: .ase

    @Test func illustratorSwatchExchangeReadsSpotsGroupsAndSpaces() throws {
        let library = try ColorLibraryFiles.read(Self.illustratorASE, format: .ase, name: "Brand book")
        #expect(library.name == "Brand book")
        #expect(library.colors.map(\.key) == ["PANTONE 300 C", "Sky", "Measured"])
        #expect(library.colors.map(\.spot) == [true, false, true])
        #expect(library.colors.map(\.group) == ["Brand", "Brand", ""])
        let pantone = ColorLibraryFiles.color(library.colors[0].value)
        #expect(pantone.space == .cmyk && abs(pantone.components.y - 0.44) < 1e-6)
        let sky = ColorLibraryFiles.color(library.colors[1].value)
        #expect(sky.space == .sRGB && library.colors[1].value.space == .srgb)
        let measured = ColorLibraryFiles.color(library.colors[2].value)
        #expect(measured.space == .lab && measured.components.x == 50 && measured.components.y == 20 && measured.components.z == -30)
    }

    @Test func photoshopSwatchExchangeReadsGreyAsBlackAndKeysRepeats() throws {
        let library = try ColorLibraryFiles.read(Self.photoshopASE, format: .ase, name: "Photoshop")
        #expect(library.colors.map(\.key) == ["Red", "Mid grey", "Red 2"])
        #expect(library.colors.map(\.name) == ["Red", "Mid grey", "Red"])
        #expect(library.colors.allSatisfy { !$0.spot })
        let grey = ColorLibraryFiles.color(library.colors[1].value)
        #expect(grey.space == .cmyk && grey.components.w == 0.75)
    }

    @Test func swatchExchangeRoundTripsAndMapsWideColors() throws {
        let export = try ColorLibraryFiles.write(Self.mixed, format: .ase)
        #expect(export.notes.contains { $0.contains("2 colors gamut-mapped into sRGB") && $0.contains("P3 red") && $0.contains("OK teal") })
        #expect(export.notes.contains { $0.contains("1 tint written as plain colors") })
        let read = try ColorLibraryFiles.read(export.data, format: .ase, name: "Mixed")
        #expect(read.colors.map(\.key) == ["Grape", "Grape 50%", "P3 red", "OK teal", "Lab", "Ink"])
        #expect(read.colors.map(\.group) == ["Fruit", "", "", "", "", ""])
        #expect(read.colors.map(\.spot) == [false, false, false, false, false, true])
        let p3 = ColorLibraryFiles.color(read.colors[2].value)
        let mapped = WTColor.Gamut.map(Color(displayP3Red: 1, green: 0, blue: 0), into: .sRGB)
        #expect(p3.space == .sRGB && abs(p3.components.x - mapped.components.x) < 1e-6 && abs(p3.components.y - mapped.components.y) < 1e-6)
        let tint = ColorLibraryFiles.color(read.colors[1].value)
        #expect(abs(tint.components.x - 0.75) < 1e-6 && abs(tint.components.y - 0.5) < 1e-6)
        let lab = ColorLibraryFiles.color(read.colors[4].value)
        #expect(lab.space == .lab && abs(lab.components.x - 60) < 1e-4)
        // Exported, imported and exported again: identical bytes.
        #expect(try ColorLibraryFiles.write(read, format: .ase).data == ColorLibraryFiles.write(read, format: .ase).data)
        let second = try ColorLibraryFiles.read(ColorLibraryFiles.write(read, format: .ase).data, format: .ase, name: "Mixed")
        #expect(try ColorLibraryFiles.write(second, format: .ase).data == ColorLibraryFiles.write(read, format: .ase).data)
    }

    @Test func malformedSwatchExchangeIsRefused() {
        #expect(throws: ColorLibraryError.self) { try ColorLibraryFiles.read(Data("GIF8".utf8), format: .ase, name: "x") }
        #expect(throws: ColorLibraryError.self) { try ColorLibraryFiles.read(Self.ase([Self.aseColor("x", model: "HSV ", [0, 0, 0], type: 0)]), format: .ase, name: "x") }
        let truncated = Self.illustratorASE.prefix(30)
        #expect(throws: ColorLibraryError.malformed(format: .ase, reason: "it ends early")) { try ColorLibraryFiles.read(Data(truncated), format: .ase, name: "x") }
        // A declared count past the blocks present stops at the end; unknown blocks are skipped.
        var extra = Self.ase([(0x0042, Data([1, 2])), Self.aseColor("Only", model: "RGB ", [0, 0, 0], type: 2)])
        extra.replaceSubrange(8..<12, with: Data([0, 0, 0, 9]))
        #expect((try? ColorLibraryFiles.read(extra, format: .ase, name: "x"))?.colors.map(\.key) == ["Only"])
    }

    // MARK: .aco and .act

    static func aco(_ records: [(UInt16, [UInt16], String)], version2: Bool) -> Data {
        var data = Data()
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(records.count))
        for record in records {
            data.appendBigEndian(record.0)
            record.1.forEach { data.appendBigEndian($0) }
        }
        if version2 {
            data.appendBigEndian(UInt16(2))
            data.appendBigEndian(UInt16(records.count))
            for record in records {
                data.appendBigEndian(record.0)
                record.1.forEach { data.appendBigEndian($0) }
                data.appendBigEndian(UInt16(0))
                data += utf16Name(record.2)
            }
        }
        return data
    }

    @Test func photoshopSwatchesReadEverySpace() throws {
        let records: [(UInt16, [UInt16], String)] = [
            (0, [65535, 0, 32768, 0], "Pinkish"),
            (1, [0, 65535, 65535, 0], "Hue red"),
            (2, [0, 65535, 65535, 32768], "Cyan ink"),
            (7, [5000, UInt16(bitPattern: -2000), 3000, 0], "Lab"),
            (8, [2500, 0, 0, 0], "Grey"),
            (9, [10000, 0, 5000, 0], "Wide"),
        ]
        let named = try ColorLibraryFiles.read(Self.aco(records, version2: true), format: .aco, name: "Swatches")
        #expect(named.colors.map(\.name) == ["Pinkish", "Hue red", "Cyan ink", "Lab", "Grey", "Wide"])
        let colors = named.colors.map { ColorLibraryFiles.color($0.value) }
        #expect(colors[0].space == .sRGB && colors[0].components.x == 1 && abs(colors[0].components.z - 0.5) < 0.001)
        #expect(colors[1].space == .sRGB && colors[1].components.x == 1 && colors[1].components.y == 0)
        #expect(colors[2].space == .cmyk && colors[2].components.x == 1 && colors[2].components.y == 0 && abs(colors[2].components.w - 0.5) < 0.001)
        #expect(colors[3].space == .lab && colors[3].components.x == 50 && colors[3].components.y == -20 && colors[3].components.z == 30)
        #expect(colors[4].components.w == 0.25)
        #expect(colors[5].components.x == 1 && colors[5].components.z == 0.5)
        let unnamed = try ColorLibraryFiles.read(Self.aco(Array(records.prefix(2)), version2: false), format: .aco, name: "Old")
        #expect(unnamed.colors.map(\.key) == ["Color 1", "Color 2"])
        #expect(throws: ColorLibraryError.self) { try ColorLibraryFiles.read(Self.aco([(3, [0, 0, 0, 0], "x")], version2: false), format: .aco, name: "x") }
        #expect(throws: ColorLibraryError.self) { try ColorLibraryFiles.read(Data([0, 5, 0, 0]), format: .aco, name: "x") }
    }

    @Test func photoshopSwatchesWriteAndReport() throws {
        let export = try ColorLibraryFiles.write(Self.mixed, format: .aco)
        #expect(export.notes.contains { $0.contains("1 spot color written as process") && $0.contains("Ink") })
        #expect(export.notes.contains { $0.contains("gamut-mapped") } && export.notes.contains { $0.contains("tint") })
        let read = try ColorLibraryFiles.read(export.data, format: .aco, name: "Mixed")
        #expect(read.colors.map(\.name) == Self.mixed.colors.map(\.name))
        let ink = ColorLibraryFiles.color(read.colors[5].value)
        #expect(ink.space == .cmyk && abs(ink.components.y - 0.8) < 0.0001)
        let lab = ColorLibraryFiles.color(read.colors[4].value)
        #expect(lab.space == .lab && lab.components.x == 60 && lab.components.y == 10)
    }

    @Test func colorTablesReadUsedColorsLessTransparency() throws {
        var table = Data((0..<256).flatMap { [UInt8($0), UInt8(255 - $0), 7] })
        let full = try ColorLibraryFiles.read(table, format: .act, name: "Table")
        #expect(full.colors.count == 256 && full.colors[1].name == "1r 254g 7b" && full.colors[1].key == "2")
        table.appendBigEndian(UInt16(4))
        table.appendBigEndian(UInt16(2))
        let short = try ColorLibraryFiles.read(table, format: .act, name: "Table")
        #expect(short.colors.map(\.key) == ["1", "2", "4"])
        #expect(ColorLibraryFiles.color(short.colors[0].value).space == .sRGB)
        #expect(throws: ColorLibraryError.self) { try ColorLibraryFiles.read(Data(count: 100), format: .act, name: "x") }
        #expect(throws: ColorLibraryError.notWritable(.act)) { try ColorLibraryFiles.write(short, format: .act) }
    }

    // MARK: Formats, colours and files

    @Test func formatsAndErrorsDescribeThemselves() throws {
        #expect(ColorLibraryFormat(fileExtension: "ASE") == .ase && ColorLibraryFormat(fileExtension: "png") == nil)
        #expect(ColorLibraryFormat.allCases.filter(\.isWritable) == [.wtcolors, .ase, .aco])
        #expect(ColorLibraryFormat.aco.fileExtension == "aco")
        for error in [ColorLibraryError.unknownFormat("a.png"), .malformed(format: .ase, reason: "r"), .notWritable(.act), .io("m")] {
            #expect(!error.description.isEmpty)
        }
        // A colour with no case reads as white CMYK; alpha is not stored.
        #expect(ColorLibraryFiles.color(Wiretuner_Doc_V1_Color()) == Color(cyan: 0, magenta: 0, yellow: 0, black: 0))
        #expect(ColorLibraryFiles.uniqueKeys(["", "", "A"]) == ["Color", "Color 2", "A"])
    }

    @Test func filesReadByExtensionAndMyLibrariesListsThem() throws {
        let directory = Corpus.directory().appendingPathComponent("libraries-\(UUID().uuidString)")
        let registry = ColorLibraryRegistry(directory: directory)
        #expect(registry.files().isEmpty)
        let source = Corpus.directory().appendingPathComponent("Brand \(UUID().uuidString.prefix(6)).ase")
        try Self.illustratorASE.write(to: source)
        let installed = try registry.install(source)
        let twice = try registry.install(source)
        #expect(installed.lastPathComponent != twice.lastPathComponent && twice.lastPathComponent.hasSuffix(" 2.ase"))
        let saved = try registry.save(Self.mixed)
        #expect(saved.lastPathComponent == "Mixed.wtcolors")
        var unnamed = Self.mixed
        unnamed.name = ""
        #expect(try registry.save(unnamed).lastPathComponent == "Colors.wtcolors")
        try Data("junk".utf8).write(to: directory.appendingPathComponent("Broken.aco"))
        try Data("not a library".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("team"), withIntermediateDirectories: true)
        let listed = registry.libraries()
        #expect(listed.libraries.count == 4 && listed.unreadable.map(\.lastPathComponent) == ["Broken.aco"])
        #expect(try ColorLibraryFiles.read(contentsOf: saved) == Self.mixed)
        #expect(throws: ColorLibraryError.unknownFormat("notes.txt")) { try ColorLibraryFiles.read(contentsOf: directory.appendingPathComponent("notes.txt")) }
        #expect(throws: ColorLibraryError.self) { try ColorLibraryFiles.read(contentsOf: directory.appendingPathComponent("missing.ase")) }
        #expect(throws: ColorLibraryError.self) { try registry.install(directory.appendingPathComponent("Broken.aco")) }
        // A directory that cannot be created (a file is in the way) is reported.
        let blocked = ColorLibraryRegistry(directory: directory.appendingPathComponent("notes.txt"))
        #expect(throws: ColorLibraryError.self) { try blocked.install(source) }
        #expect(throws: ColorLibraryError.self) { try blocked.save(Self.mixed) }
        #expect(ColorLibraryRegistry.defaultDirectory().path.hasSuffix("WireTuner/Colors"))
    }

    @Test func bundledLibrariesHoldTheirColors() throws {
        let all = BundledColorLibraries.all
        #expect(all.map(\.name) == ["Crayon", "Grays", "Web Safe", "Process"])
        #expect(all.map(\.colors.count) == [48, 21, 216, 1331])
        for library in all {
            #expect(Set(library.colors.map(\.key)).count == library.colors.count)
            let file = try ColorLibraryFiles.write(library, format: .wtcolors).data
            #expect(try ColorLibraryFiles.read(file, format: .wtcolors, name: "") == library)
        }
        #expect(ColorLibraryFiles.color(BundledColorLibraries.crayon.colors[0].value) == Color(red: 1, green: 0.8, blue: 0.4))
        #expect(ColorLibraryFiles.color(BundledColorLibraries.grays.colors[20].value) == Color(cyan: 0, magenta: 0, yellow: 0, black: 1))
        #expect(BundledColorLibraries.webSafe.colors[215].key == "#FFFFFF" && BundledColorLibraries.webSafe.colors[1].name == "0r 0g 51b #000033")
        #expect(BundledColorLibraries.process.colors[1].value.cmyk.y == 0.1)
    }
}
