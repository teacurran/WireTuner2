import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

/// FONT-027: WOFF2 with the null transform and Brotli; FONT-026's test install.
@Suite struct WOFF2Tests {
    @Test(arguments: FontCompiler.Format.allCases)
    func woff2RoundTripsToTheSameTables(format: FontCompiler.Format) throws {
        let font = try FontCompiler.compile(FontFixture.source(), options: .init(format: format)).data
        let woff2 = try WOFF2Writer.woff2(font)
        let reader = FontReader(woff2, context: "test")
        #expect(try reader.tag(0) == "wOF2" && (try reader.u32(8)) == woff2.count && woff2.count % 4 == 0)
        #expect(woff2.count < font.count)
        // Decoded: every table byte-identical after re-ordering.
        let decoded = try WOFF2Reader.sfnt(woff2)
        let original = try WOFF2Writer.tables(of: font).tables
        let back = try WOFF2Writer.tables(of: decoded).tables
        #expect(original.map(\.tag).sorted() == back.map(\.tag))
        for (tag, data) in back where tag != "head" {
            #expect(original.first { $0.tag == tag }?.data == data, "\(tag)")
        }
        #expect(decoded == font)
        // Core Text reads WOFF2 directly.
        #expect(CTFontManagerCreateFontDescriptorFromData(woff2 as CFData) != nil)
    }

    /// FONT-027's first done-when against the reference decoder: `woff2_decompress` (Google's
    /// woff2, `brew install woff2`) turns each WOFF2 back into the compiled font, byte for byte.
    /// Where the tool is not installed only the harness page is written.  With
    /// `WT_WOFF2_HARNESS=<folder>` the WOFF2 files and `woff2-harness.html` -- a page that loads
    /// both through `document.fonts` and prints what loaded -- go there for the browser check.
    @Test func theReferenceDecoderGivesBackTheCompiledFont() throws {
        let folder = ProcessInfo.processInfo.environment["WT_WOFF2_HARNESS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wt-woff2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var faces: [(family: String, woff2: Data)] = []
        for format in FontCompiler.Format.allCases {
            let font = try FontCompiler.compile(FontFixture.source(), options: .init(format: format)).data
            let woff2 = try WOFF2Writer.woff2(font)
            let url = folder.appendingPathComponent("Marlowe-\(format.fileExtension).woff2")
            try woff2.write(to: url)
            faces.append(("Marlowe \(format.fileExtension.uppercased())", woff2))
            let tool = "/opt/homebrew/bin/woff2_decompress"
            guard FileManager.default.isExecutableFile(atPath: tool) else { continue }
            let decoded = url.deletingPathExtension().appendingPathExtension("ttf")
            try? FileManager.default.removeItem(at: decoded)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = [url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(output)")
            let back = try Data(contentsOf: decoded)
            #expect(try WOFF2Writer.tables(of: back).tables.map(\.tag) == WOFF2Writer.tables(of: font).tables.map(\.tag).sorted())
            #expect(back == font, "\(format): the decoded font is the compiled one")
        }
        let page = Self.harnessPage(faces)
        try Data(page.utf8).write(to: folder.appendingPathComponent("woff2-harness.html"))
        #expect(page.contains("format(\"woff2\")") && faces.count == 2)
    }

    /// A page that loads each face from a `data:` URL (no file-origin rules) and writes
    /// `loaded: <family> <family>` -- or `failed: ...` -- into `#result`.
    static func harnessPage(_ faces: [(family: String, woff2: Data)]) -> String {
        let rules = faces.map { "@font-face { font-family: \"\($0.family)\"; src: url(data:font/woff2;base64,\($0.woff2.base64EncodedString())) format(\"woff2\"); }" }
        let families = faces.map { "\"\($0.family)\"" }.joined(separator: ", ")
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>WOFF2 harness</title>
            <style>\(rules.joined(separator: "\n"))</style></head>
            <body><p id="result">pending</p>
            <script>
            const families = [\(families)];
            Promise.all(families.map(f => document.fonts.load(`48px "${f}"`, "ABC").then(list => list.length ? f : Promise.reject(f + " did not load"))))
              .then(ok => { document.getElementById("result").textContent = "loaded: " + ok.join(" "); },
                    error => { document.getElementById("result").textContent = "failed: " + error; });
            </script></body></html>
            """
    }

    @Test func unknownTagsAndBase128() throws {
        #expect(WOFF2Writer.base128(0) == [0] && WOFF2Writer.base128(127) == [127] && WOFF2Writer.base128(128) == [0x81, 0])
        #expect(WOFF2Writer.base128(0x3FFF) == [0xFF, 0x7F])
        let sfnt = FontTables.assemble(["head": [UInt8](repeating: 1, count: 54), "zzzz": [1, 2, 3]], signature: 0x0001_0000)
        let woff2 = try WOFF2Writer.woff2(sfnt)
        #expect(try WOFF2Reader.sfnt(woff2) == sfnt)
        #expect(throws: FontReadError.malformed("WOFF2 signature")) { try WOFF2Reader.sfnt(Data("wOFF0000".utf8)) }
        // A transformed glyf table is refused.
        var bytes = [UInt8](woff2)
        bytes[48] = 10          // glyf, transform version 0 (the glyf transform)
        #expect(throws: FontReadError.unsupported("WOFF2 table transform")) { try WOFF2Reader.sfnt(Data(bytes)) }
        var long = [UInt8](woff2)
        long.replaceSubrange(49..<54, with: [0x80, 0x80, 0x80, 0x80, 0x80])
        #expect(throws: FontReadError.malformed("UIntBase128")) { try WOFF2Reader.sfnt(Data(long)) }
        var truncated = [UInt8](woff2)
        truncated[22] = 0xFF        // a compressed length past the end of the file
        #expect(throws: FontReadError.truncated("WOFF2")) { try WOFF2Reader.sfnt(Data(truncated)) }
        var garbage = [UInt8](woff2)
        for index in 56..<garbage.count { garbage[index] = 0xFF }
        #expect(throws: FontReadError.malformed("WOFF2 data")) { try WOFF2Reader.sfnt(Data(garbage)) }
        #expect(throws: FontReadError.truncated("sfnt")) { try WOFF2Writer.woff2(Data([0, 1, 0, 0, 0, 5])) }
    }

    @Test func installForTestingRegistersAndRemoves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-testfonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = TestFontInstaller(directory: directory, scope: .process)
        var source = FontFixture.source()
        source.names.family = "Marlowe Test \(UUID().uuidString.prefix(6))"
        source.names.postscript = "MarloweTest-\(UUID().uuidString.prefix(6))"
        let data = try FontCompiler.compile(source).data
        let url = try installer.install(data, fileName: "Marlowe-Regular.otf")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        #expect(descriptors.count == 1)
        // Installing again replaces the file.
        #expect(try installer.install(data, fileName: "Marlowe-Regular.otf") == url)
        installer.remove([url])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: TestFontInstaller.Failure.self) { try installer.install(Data([1, 2, 3]), fileName: "broken.otf") }
    }
}
