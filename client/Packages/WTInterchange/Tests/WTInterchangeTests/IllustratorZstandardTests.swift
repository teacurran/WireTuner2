// D-098: Illustrator 2020 and later's private data -- `%AI24_ZStandard_Data` and one Zstandard
// frame without a declared size, split over `/AIPrivateData` blocks -- reads like an older file's
// zlib data: artboard names, the layer table, Acrobat layers' lock, print and outline settings.
// The artwork stays the PDF's.  Every fixture is written here; the frames are compressed by the
// reference library (`ZstandardTests.compress`).

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

@Suite struct IllustratorZstandardTests {
    typealias F = PDFImportFixture
    typealias L = IllustratorLayerTests
    typealias A = IllustratorArtboardTests

    /// `/PieceInfo` as Illustrator 2020 and later write it: `%AI24_ZStandard_Data` and `native`
    /// compressed as one streamed frame, split into `blocks` `/AIPrivateData` streams (some
    /// Flate-filtered, as the PDF writer may); `damage` changes the payload first.
    static func pieceInfo(_ native: Data, blocks: Int = 3, into f: inout F, damage: (inout Data) -> Void = { _ in }) -> String {
        var payload = Data("%AI24_ZStandard_Data".utf8) + ZstandardTests.compress(native, level: 19, streamed: true)
        damage(&payload)
        let size = (payload.count + blocks - 1) / blocks
        let entries = (0..<blocks).map { index in
            let slice = payload[min(index * size, payload.count)..<min((index + 1) * size, payload.count)]
            return "/AIPrivateData\(index + 1) \(f.stream("", Data(slice), flate: index == 1)) 0 R"
        }
        return "/PieceInfo << /Illustrator << /Private << /ContainerVersion 12 /CreatorVersion 30 /NumBlock \(blocks) /RoundtripVersion 24 \(entries.joined(separator: " ")) >> >> >>"
    }

    /// `pages` unmarked pages (the artwork outside any layer mark), the first with the piece info
    /// of `records` and the artboards `names`.
    static func unmarked(_ records: String, names: [String], pages: Int = 1, damage: (inout Data) -> Void = { _ in }) -> Data {
        var f = F()
        let info = pieceInfo(L.native(records + A.documentData(names)), into: &f, damage: damage)
        return f.document((0..<pages).map { index in
            F.Page("0 0 10 10 re f 20 20 5 5 re f", extra: "/MediaBox [0 0 200 150]\(index == 0 ? " \(info)" : "")")
        })
    }

    @Test func artboardNamesAndTheLayerTableComeThrough() throws {
        let data = Self.unmarked(L.record("Artwork", enabled: false, body: L.record("Inner")), names: ["(Front)", "<FEFF00C9007400E9>"], pages: 2)
        let document = try L.open(data)
        #expect(document.pages.map(\.name) == ["Front", "Été"])
        #expect(document.layerSource == .privateData && document.notes.isEmpty)
        let layers = L.layers(document.pages[0].nodes)
        #expect(layers.map(\.name) == ["Artwork"] && layers[0].layerState == ImportedLayerState(locked: true))
        // The artwork is the PDF's.
        #expect(F.paths(layers[0].children).count == 2)
        // Imported, the layer is kept.
        let one = Self.unmarked(L.record("Artwork", enabled: false), names: ["(Front)"])
        #expect(L.layers(try IllustratorImportTests.convert(one).nodes).map(\.name) == ["Artwork"])
        // The reader's view of the same data.
        var f = F()
        let info = Self.pieceInfo(L.native(L.record("A") + L.record("B", visible: false)), into: &f)
        let pdf = try PDFImporter.document(f.document([F.Page("", extra: "/MediaBox [0 0 10 10] \(info)")]), name: "z.ai")
        let native = IllustratorImporter.nativeData(pdf)
        #expect(IllustratorImporter.nativeLayers(native).map(\.name) == ["A", "B"])
        #expect(IllustratorImporter.nativeLayers(native).map(\.state.visible) == [true, false])
    }

    @Test func acrobatLayersTakeTheirSettingsFromZstandardData() throws {
        var f = F()
        let base = f.add("<< /Type /OCG /Name (Base) >>")
        let top = f.add("<< /Type /OCG /Name (Top) >>")
        let info = Self.pieceInfo(L.native(L.record("Base", enabled: false) + L.record("Top", preview: false, printing: false)), blocks: 5, into: &f)
        let resources = "<< /Properties << /MC0 \(base) 0 R /MC1 \(top) 0 R >> >>"
        let page = F.Page("/OC /MC0 BDC 0 0 10 10 re f EMC /OC /MC1 BDC 9 9 1 1 re f EMC", resources: resources, extra: "/MediaBox [0 0 200 150] \(info)")
        let document = try L.open(f.document([page], catalog: "/OCProperties << /OCGs [\(base) 0 R \(top) 0 R] >>"))
        #expect(document.layerSource == .optionalContent)
        #expect(L.layers(document.pages[0].nodes).map(\.layerState) == [ImportedLayerState(locked: true), ImportedLayerState(printing: false, outline: true)])
    }

    @Test func layerMarksWithZstandardDataNameTheArtboard() throws {
        var f = F()
        let info = Self.pieceInfo(L.native(L.record("Art") + A.documentData(["(Poster)"])), into: &f)
        let resources = "<< /Properties << /MC0 \(L.layer("Art")) >> >>"
        let document = try L.open(f.document([F.Page("/Layer /MC0 BDC 0 0 10 10 re f EMC", resources: resources, extra: "/MediaBox [0 0 200 150] \(info)")]))
        #expect(document.layerSource == .layerMarks && document.layerNames == ["Art"] && document.pages[0].name == "Poster")
    }

    @Test func damagedZstandardDataOpensAsThePDFReads() throws {
        let damages: [(inout Data) -> Void] = [
            { $0.replaceSubrange($0.count - 4..<$0.count, with: Data([0, 0, 0, 0])) },  // the checksum
            { $0.removeLast($0.count / 2) },                                              // cut off
            { $0.replaceSubrange(20..<24, with: Data("junk".utf8)) },                     // no frame
            { $0 += ZstandardTests.withDictionary },                                     // needs a dictionary
        ]
        for (index, damage) in damages.enumerated() {
            let data = Self.unmarked(L.record("Artwork"), names: ["(Front)"], damage: damage)
            let document = try L.open(data)
            #expect(document.pages.map(\.name) == [nil], "damage \(index)")
            #expect(document.layerSource == ImportedLayerSource.none && L.layers(document.pages[0].nodes).isEmpty, "damage \(index)")
            #expect(F.paths(document.pages[0].nodes).count == 2, "damage \(index)")
        }
    }

    @Test func theNativeDataKeepsWhatPrecedesTheMarker() {
        let native = L.native(L.record("Solo"))
        let head = Data("%AI7_Thumbnail: 1 1 8\r".utf8)
        let joined = head + Data("%AI24_ZStandard_Data".utf8) + ZstandardTests.compress(native, streamed: true) + Data("\r".utf8)
        #expect(IllustratorPrivateData.native(joined) == head + native)
        #expect(IllustratorPrivateData.native(Data("%AI24_ZStandard_Data".utf8)) == nil)
        #expect(IllustratorPrivateData.native(Data("%AI24_ZStandard_Data(\u{28})".utf8)) == nil)
    }
}
