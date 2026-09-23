// The libraries {product} ships and the *My Libraries* registry (spot-process.adoc, "Color
// libraries" and "Client").  The four bundled libraries are built here from their definitions
// -- Crayon (the 48 crayon-box colours, sRGB), Grays (black in 5% steps, CMYK), Web Safe (the 216
// browser-safe colours, sRGB, keyed by hex) and Process (cyan, magenta and yellow in 10% steps,
// CMYK) -- so `BundledColorLibraries.all` is the data and the app writes them into its bundle
// with `ColorLibraryFiles.write(_:format: .wtcolors)` if it wants files.  *My Libraries* is the
// directory `~/Library/Application Support/WireTuner/Colors/`: every library file there (not the
// team cache below it) is listed, and importing a file copies it in.

import Foundation
import WTRender

public enum BundledColorLibraries {
    /// Crayon, Grays, Web Safe and Process, in the Options menu's order.
    public static var all: [ColorLibrary] { [crayon, grays, webSafe, process] }

    /// The crayon box: name and 8-bit sRGB value.
    static let crayons: [(String, UInt32)] = [
        ("Cantaloupe", 0xFFCC66), ("Honeydew", 0xCCFF66), ("Spindrift", 0x66FFCC), ("Sky", 0x66CCFF), ("Lavender", 0xCC66FF), ("Carnation", 0xFF6FCF),
        ("Licorice", 0x000000), ("Snow", 0xFFFFFF), ("Salmon", 0xFF6666), ("Banana", 0xFFFF66), ("Flora", 0x66FF66), ("Ice", 0x66FFFF),
        ("Orchid", 0x6666FF), ("Bubblegum", 0xFF66FF), ("Lead", 0x191919), ("Mercury", 0xE6E6E6), ("Tangerine", 0xFF8000), ("Lime", 0x80FF00),
        ("Sea Foam", 0x00FF80), ("Aqua", 0x0080FF), ("Grape", 0x8000FF), ("Strawberry", 0xFF0080), ("Tungsten", 0x333333), ("Silver", 0xCCCCCC),
        ("Maraschino", 0xFF0000), ("Lemon", 0xFFFF00), ("Spring", 0x00FF00), ("Turquoise", 0x00FFFF), ("Blueberry", 0x0000FF), ("Magenta", 0xFF00FF),
        ("Iron", 0x4C4C4C), ("Magnesium", 0xB3B3B3), ("Mocha", 0x804000), ("Fern", 0x408000), ("Moss", 0x008040), ("Ocean", 0x004080),
        ("Eggplant", 0x400080), ("Maroon", 0x800040), ("Steel", 0x666666), ("Aluminum", 0x999999), ("Cayenne", 0x800000), ("Asparagus", 0x808000),
        ("Clover", 0x008000), ("Teal", 0x008080), ("Midnight", 0x000080), ("Plum", 0x800080), ("Tin", 0x7F7F7F), ("Nickel", 0x808080),
    ]

    static func library(_ name: String, rows: UInt32, columns: UInt32, colors: [LibraryColor]) -> ColorLibrary {
        var library = ColorLibrary()
        library.name = name
        library.rows = rows
        library.columns = columns
        library.colors = colors
        return library
    }

    static func rgb(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    public static var crayon: ColorLibrary {
        library("Crayon", rows: 8, columns: 6, colors: crayons.map { ColorLibraryFiles.entry(key: $0.0, color: rgb($0.1)) })
    }

    public static var grays: ColorLibrary {
        library("Grays", rows: 3, columns: 7, colors: stride(from: 0, through: 100, by: 5).map { percent in
            ColorLibraryFiles.entry(key: "Gray \(percent)%", color: Color(cyan: 0, magenta: 0, yellow: 0, black: Double(percent) / 100))
        })
    }

    public static var webSafe: ColorLibrary {
        var colors: [LibraryColor] = []
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    let value = UInt32(r * 51) << 16 | UInt32(g * 51) << 8 | UInt32(b * 51)
                    let hex = String(format: "#%06X", value)
                    colors.append(ColorLibraryFiles.entry(key: hex, name: "\(r * 51)r \(g * 51)g \(b * 51)b \(hex)", color: rgb(value)))
                }
            }
        }
        return library("Web Safe", rows: 12, columns: 18, colors: colors)
    }

    public static var process: ColorLibrary {
        var colors: [LibraryColor] = []
        for c in 0...10 {
            for m in 0...10 {
                for y in 0...10 {
                    let name = "\(c * 10)c \(m * 10)m \(y * 10)y 0k"
                    colors.append(ColorLibraryFiles.entry(key: name, color: Color(cyan: Double(c) / 10, magenta: Double(m) / 10, yellow: Double(y) / 10, black: 0), group: "\(c * 10)% Cyan"))
                }
            }
        }
        return library("Process", rows: 11, columns: 11, colors: colors)
    }
}

/// *My Libraries*: the library files in one directory on this Mac.
public struct ColorLibraryRegistry: Sendable {
    public var directory: URL

    /// `~/Library/Application Support/WireTuner/Colors/`.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WireTuner", isDirectory: true).appendingPathComponent("Colors", isDirectory: true)
    }

    public init(directory: URL = ColorLibraryRegistry.defaultDirectory()) {
        self.directory = directory
    }

    /// The library files in the directory, by name (the team cache's subdirectory is not
    /// listed); empty when the directory does not exist.
    public func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { ColorLibraryFormat(fileExtension: $0.pathExtension) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every listed library read, with the files that could not be read.
    public func libraries() -> (libraries: [ColorLibrary], unreadable: [URL]) {
        var libraries: [ColorLibrary] = []
        var unreadable: [URL] = []
        for url in files() {
            if let library = try? ColorLibraryFiles.read(contentsOf: url) {
                libraries.append(library)
            } else {
                unreadable.append(url)
            }
        }
        return (libraries, unreadable)
    }

    /// Copies an imported library file into the directory (creating it), a repeated name
    /// suffixed, after checking it reads; returns the copy.
    @discardableResult
    public func install(_ url: URL) throws -> URL {
        _ = try ColorLibraryFiles.read(contentsOf: url)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = freeURL(url.deletingPathExtension().lastPathComponent, extension: url.pathExtension.lowercased())
            try manager.copyItem(at: url, to: target)
            return target
        } catch {
            throw ColorLibraryError.io("The library could not be added to My Libraries: \(error.localizedDescription)")
        }
    }

    /// Writes `library` into the directory as `.wtcolors` (the export sheet's *Save to My
    /// Libraries*); returns the file.
    @discardableResult
    public func save(_ library: ColorLibrary) throws -> URL {
        let manager = FileManager.default
        let name = library.name.isEmpty ? "Colors" : library.name.replacingOccurrences(of: "/", with: "-")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = freeURL(name, extension: ColorLibraryFormat.wtcolors.fileExtension)
            try ColorLibraryFiles.write(library, format: .wtcolors).data.write(to: target)
            return target
        } catch {
            throw ColorLibraryError.io("The library could not be saved to My Libraries: \(error.localizedDescription)")
        }
    }

    /// `name.extension` in the directory, suffixed " 2", " 3"… until no file has the name.
    func freeURL(_ name: String, extension fileExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
