import Foundation
import Testing
import WTInterchange
@testable import WTModel

/// FONT-026 (Done when): the generated OTF and TTF pass fontbakery's universal profile with no
/// FAIL or ERROR, but for the three design checks left out below.  fontbakery is a Python tool outside the build: the test runs it
/// when `WT_FONTBAKERY` names its executable (`python3 -m venv fb && fb/bin/pip install
/// fontbakery`), and is skipped otherwise.  `WT_FONTBAKERY_OUT=<folder>` keeps the fonts and the
/// JSON reports.
@Suite struct FontBakeryTests {
    static let executable = ProcessInfo.processInfo.environment["WT_FONTBAKERY"].flatMap { $0.isEmpty ? nil : $0 }

    /// The universal profile's checks left out, each about the test font's design rather than
    /// the compiled tables: lowercase counterparts of every capital (`case_mapping`), the usual
    /// contour counts of each letter (`contour_count`: the corpus draws boxes) and the monospace
    /// heuristics (`opentype/monospace`: the boxes share one width; fontbakery 1.1.0 also stops
    /// with a KeyError on any CFF font there).
    static let excluded = ["case_mapping", "contour_count", "opentype/monospace"]

    /// Marlowe from the round-trip corpus, finished as any real font is: every letter drawn (a
    /// box where the corpus left it empty), a no-break space as wide as the space, a descender.
    static func document() throws -> Replica {
        var a = Replica(0xA)
        try FontRoundTripTests.marlowe(&a)
        if GlyphIndex(a.state).holder(of: 0xA0) == nil { try a.perform(AddGlyphs([NewGlyph(scalar: 0xA0)])) }
        let index = GlyphIndex(a.state)
        let space = try #require(index.holder(of: 0x20))
        try a.perform(SetGlyphWidth([index.holder(of: 0xA0)!.id], to: space.advanceWidth))
        for glyph in index.glyphs where glyph.codepoints.contains(where: { Unicode.Scalar($0)?.properties.isAlphabetic == true || (0x21...0x7E).contains($0) }) {
            guard GlyphOutlines.metrics(of: glyph.id, in: a.state)?.bounds == nil, glyph.components.isEmpty else { continue }
            let descends = ["p", "q", "g", "j", "y"].contains(glyph.name)
            try TypefaceFixture.box(40, descends ? -500 : -700, max(glyph.advanceWidth - 80, 40), descends ? 700 : 700, on: glyph.id, in: &a)
        }
        return a
    }

    @Test(.enabled(if: executable != nil), arguments: FontCompiler.Format.allCases)
    func generatedFontsPassTheUniversalChecks(format: FontCompiler.Format) async throws {
        let tool = try #require(Self.executable)
        let keep = ProcessInfo.processInfo.environment["WT_FONTBAKERY_OUT"].map(URL.init(fileURLWithPath:))
        let folder = keep ?? FileManager.default.temporaryDirectory.appending(path: "fontbakery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: folder) } }
        let font = folder.appending(path: "Marlowe-Regular.\(format.fileExtension)")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try await FontGeneration.generate(try Self.document().state, format: format, date: date).data.write(to: font)
        let report = folder.appending(path: "fontbakery-\(format.fileExtension).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["check-universal", "--skip-network", "--json", report.path, "-l", "FAIL"] + Self.excluded.flatMap { ["-x", $0] } + [font.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        let failures = Self.results(json).filter { $0.result == "FAIL" || $0.result == "ERROR" }
        #expect(failures.isEmpty, "\(format): \(failures.map { "\($0.check): \($0.message)" }.joined(separator: "; "))")
        let counts = try #require(json["result"] as? [String: Int])
        #expect((counts["PASS"] ?? 0) > 40 && (counts["FAIL"] ?? 0) == 0 && (counts["ERROR"] ?? 0) == 0, "\(counts)")
    }

    /// Every check result of a fontbakery JSON report: check id, result, first message.
    static func results(_ json: [String: Any]) -> [(check: String, result: String, message: String)] {
        var found: [(String, String, String)] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let id = dictionary["key"] as? [Any], let result = dictionary["result"] as? String, id.count > 1 {
                    let logs = dictionary["logs"] as? [[String: Any]] ?? []
                    found.append(("\(id[1])", result, logs.compactMap { $0["message"] as? String }.first ?? ""))
                } else if let result = dictionary["result"] as? String, let check = dictionary["key"] as? String ?? dictionary["id"] as? String {
                    let logs = dictionary["logs"] as? [[String: Any]] ?? []
                    found.append((check, result, logs.compactMap { $0["message"] as? String }.first ?? ""))
                }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(json)
        return found
    }
}
