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
