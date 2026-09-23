// IO-023: the Photoshop writer, read back by a minimal PSD/PSB reader (header, resources, layer
// records with names, opacity and rectangles, RLE channel data) and by ImageIO for the composite.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// A minimal PSD and PSB reader for the tests.
struct PSDFile {
    struct Layer {
        var top = 0, left = 0, bottom = 0, right = 0
        var channels: [(id: Int16, length: Int)] = []
        var blend = ""
        var opacity = 0
        var flags = 0
        var pascalName = ""
        var name = ""
        /// Decoded channel samples by id (bytes, big-endian for 16 bits).
        var data: [Int16: [UInt8]] = [:]
    }

    var version = 0
    var channels = 0
    var width = 0
    var height = 0
    var depth = 0
    var mode = 0
    var resources: [Int: Data] = [:]
    var layerCount = 0
    var layers: [Layer] = []
    var compression = -1

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var position = 0
        func u8() -> Int { defer { position += 1 }; return Int(bytes[position]) }
        func u16() -> Int { u8() << 8 | u8() }
        func u32() -> Int { u16() << 16 | u16() }
        func u64() -> Int { u32() << 32 | u32() }
        func length(_ big: Bool) -> Int { big ? u64() : u32() }
        func string(_ count: Int) -> String { defer { position += count }; return String(decoding: bytes[position..<(position + count)], as: UTF8.self) }
        guard string(4) == "8BPS" else { throw ExportError.writeFailed("not a PSD") }
        version = u16()
        let big = version == 2
        position += 6
        channels = u16()
        height = u32()
        width = u32()
        depth = u16()
        mode = u16()
        position += u32()
        let resourcesEnd = u32() + position
        while position < resourcesEnd {
            _ = string(4)
            let id = u16()
            let nameLength = u8()
            position += nameLength + (nameLength % 2 == 0 ? 1 : 0)
            let size = u32()
            resources[id] = Data(bytes[position..<(position + size)])
            position += size + size % 2
        }
        let sectionLength = length(big)
        let sectionEnd = position + sectionLength
        _ = length(big)
        layerCount = Int(Int16(bitPattern: UInt16(u16())))
        for _ in 0..<abs(layerCount) {
            var layer = Layer()
            layer.top = Int(Int32(bitPattern: UInt32(u32())))
            layer.left = Int(Int32(bitPattern: UInt32(u32())))
            layer.bottom = Int(Int32(bitPattern: UInt32(u32())))
            layer.right = Int(Int32(bitPattern: UInt32(u32())))
            for _ in 0..<u16() {
                layer.channels.append((Int16(bitPattern: UInt16(u16())), length(big)))
            }
            _ = string(4)
            layer.blend = string(4)
            layer.opacity = u8()
            _ = u8()
            layer.flags = u8()
            _ = u8()
            let extraEnd = u32() + position
            position += u32()
            position += u32()
            let nameLength = u8()
            layer.pascalName = string(nameLength)
            position += (4 - (nameLength + 1) % 4) % 4
            while position < extraEnd {
                _ = string(4)
                let key = string(4)
                let size = u32()
                let start = position
                if key == "luni" {
                    let count = u32()
                    layer.name = String(utf16CodeUnits: (0..<count).map { _ in UInt16(u16()) }, count: count)
                }
                position = start + size
            }
            layers.append(layer)
        }
        let bytesPerSample = depth / 8
        for index in layers.indices {
            let width = layers[index].right - layers[index].left, height = layers[index].bottom - layers[index].top
            for channel in layers[index].channels {
                let end = position + channel.length
                let compression = u16()
                var samples: [UInt8] = []
                if compression == 1 {
                    let counts = (0..<height).map { _ in big ? u32() : u16() }
                    for count in counts {
                        samples += PackBits.decode(Array(bytes[position..<(position + count)]))
                        position += count
                    }
                }
                #expect(samples.count == width * height * bytesPerSample)
                layers[index].data[channel.id] = samples
                position = end
            }
        }
        position = sectionEnd
        compression = u16()
    }
}

@Suite struct PSDTests {
    static func export(_ page: ExportPage, options: PSDOptions = PSDOptions(), nodes: [NodeID: ExportNodeInfo] = [:], info: ExportDocumentInfo = ExportDocumentInfo()) throws -> (file: PSDFile, data: Data) {
        let data = try PSDExporter().data(scene: Corpus.scene([page], nodes: nodes, info: info), page: 0, options: options)
        return (try PSDFile(data), data)
    }

    static let background = Corpus.node(1), art = Corpus.node(2)
    static let layered = Corpus.page([
        .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 200, 150), [Corpus.fill(.solid(Corpus.yellow))])])),
        .group(GroupItem(children: [Corpus.path(Corpus.ellipse(50, 30, 100, 80), [Corpus.fill(.solid(Color(red: 1, green: 0, blue: 0)))])], opacity: 0.5)),
        Corpus.path(Corpus.rect(10, 10, 20, 20), [Corpus.fill(.solid(.black))]),
    ], nodes: [background, art, nil])
    static let nodes = [background: ExportNodeInfo(name: "Background", isLayer: true), art: ExportNodeInfo(name: "Kunst ✓", isLayer: true)]

    @Test func layersKeepNamesOrderOpacityAndTransparency() throws {
        let result = try Self.export(Self.layered, nodes: Self.nodes, info: ExportDocumentInfo(title: "Poster"))
        let file = result.file
        #expect(file.version == 1 && file.width == 200 && file.height == 150 && file.depth == 8 && file.mode == 3)
        #expect(file.channels == 4)
        #expect(file.layerCount == -3)
        #expect(file.layers.map(\.name) == ["Background", "Kunst ✓", "Layer 3"])
        #expect(file.layers[1].pascalName == "Kunst ?")
        #expect(file.layers.map(\.opacity) == [255, 128, 255])
        #expect(file.layers.allSatisfy { $0.blend == "norm" && $0.flags & 2 == 0 })
        let ellipse = file.layers[1]
        #expect(ellipse.left == 50 && ellipse.top == 30 && ellipse.right == 150 && ellipse.bottom == 110)
        let alpha = try #require(ellipse.data[-1])
        let red = try #require(ellipse.data[0])
        let center = 40 * 100 + 50
        #expect(alpha[center] == 255 && red[center] == 255 && ellipse.data[1]![center] == 0)
        #expect(alpha[0] == 0)
        #expect(file.layers[2].right == 30)
        #expect(file.resources[0x03ED] != nil)
        #expect(file.resources[0x040F] != nil)
        #expect(String(decoding: try #require(file.resources[0x0424]), as: UTF8.self).contains("Poster"))
        #expect(file.compression == 1)
        // ImageIO reads the composite, which matches the PNG export of the page.
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let composite = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let png = try BitmapTests.export(.png, PNGOptions(), page: Self.layered)
        let expected = Corpus.pixels(png.images[0].image, background: .white).bytes
        let actual = Corpus.pixels(composite, background: .white).bytes
        #expect(zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()! <= 2)
    }

    @Test func flattenedSixteenBitAndProfiles() throws {
        let result = try Self.export(Self.layered, options: PSDOptions(common: BitmapCommonOptions(background: .white, embedProfile: false), layers: false, bitsPerChannel: 16), nodes: Self.nodes)
        #expect(result.file.layerCount == 1)
        #expect(result.file.channels == 3)
        #expect(result.file.depth == 16)
        #expect(result.file.resources[0x040F] == nil)
        #expect(result.file.resources[0x0424] == nil)
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyDepth] as? Int == 16)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    @Test func grayAndCMYKLayers() throws {
        let gray = try Self.export(Self.layered, options: PSDOptions(common: BitmapCommonOptions(background: .white, color: .gray)), nodes: Self.nodes)
        #expect(gray.file.mode == 1 && gray.file.channels == 1)
        let yellow = try #require(gray.file.layers[0].data[0])
        // Yellow's luminance is light grey, and straight (not darkened by coverage).
        #expect(yellow[75 * 200 + 100] > 180)
        #expect(gray.file.layers[1].data[-1]![40 * 100 + 50] == 255)
        let cmyk = try Self.export(Self.layered, options: PSDOptions(common: BitmapCommonOptions(background: .white, color: .cmyk)), nodes: Self.nodes)
        #expect(cmyk.file.mode == 4 && cmyk.file.channels == 4)
        // Photoshop stores CMYK inverted: yellow has almost no cyan (≈255) and much yellow ink (low).
        let cyan = try #require(cmyk.file.layers[0].data[0]), yellowInk = try #require(cmyk.file.layers[0].data[2])
        #expect(cyan[75 * 200 + 100] > 200 && yellowInk[75 * 200 + 100] < 80)
        for data in [gray.data, cmyk.data] {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        }
    }

    @Test func documentsWiderThan30000PixelsArePSB() throws {
        let page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 30_001, 2), [Corpus.fill(.solid(Corpus.blue))])], width: 30_001, height: 2)
        let result = try Self.export(page, options: PSDOptions(common: BitmapCommonOptions(antiAliasing: 1)))
        #expect(result.file.version == 2)
        #expect(result.file.width == 30_001)
        #expect(result.file.layers.count == 1)
        #expect(result.file.layers[0].data[2]!.allSatisfy { $0 > 200 })
        let directory = Corpus.directory()
        let summary = try PSDExporter().export(scene: Corpus.scene([page]), options: PSDOptions(common: BitmapCommonOptions(antiAliasing: 1)), to: ExportDestination(url: directory.appendingPathComponent("wide.psd")))
        #expect(summary.files.map(\.lastPathComponent) == ["wide.psd"])
    }

    @Test func filesScalesAndErrors() throws {
        let directory = Corpus.directory()
        let summary = try PSDExporter().export(scene: Corpus.scene([Self.layered]), options: PSDOptions(common: BitmapCommonOptions(scales: [1, 2])), to: ExportDestination(url: directory.appendingPathComponent("art.psd"), namePattern: .standard))
        #expect(summary.files.map(\.lastPathComponent) == ["art-1.psd", "art-1@2x.psd"])
        #expect(try PSDFile(Data(contentsOf: summary.files[1])).width == 400)
        let empty = try Self.export(Corpus.page([]), nodes: [:])
        #expect(empty.file.layers.isEmpty)
        let blank = try Self.export(Corpus.page([Corpus.path(Corpus.rect(500, 500, 5, 5), [Corpus.fill(.solid(.black))])]))
        #expect(blank.file.layers[0].right == 0)
        let unnamed = try Self.export(Corpus.page([Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(.black))])], nodes: [Self.art]), nodes: [Self.art: ExportNodeInfo(name: "", isLayer: true)])
        #expect(unnamed.file.layers.map(\.name) == ["Layer 1"])
        for options in [PSDOptions(bitsPerChannel: 12), PSDOptions(common: BitmapCommonOptions(color: .gray)), PSDOptions(common: BitmapCommonOptions(ppi: 0))] {
            #expect(throws: ExportError.self) { try PSDExporter().data(scene: Corpus.scene([Self.layered]), page: 0, options: options) }
        }
        #expect(throws: ExportError.nothingToExport) { try PSDExporter().data(scene: Corpus.scene([Self.layered]), page: 2, options: PSDOptions()) }
        #expect(throws: ExportError.nothingToExport) { try PSDExporter().export(scene: Corpus.scene([]), options: PSDOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.psd"))) }
        #expect(throws: ExportError.wrongOptions(format: .psd)) { try PSDExporter().export(scene: Corpus.scene([Self.layered]), options: PNGOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.psd"))) }
        #expect(throws: ExportError.self) { try PSDExporter().export(scene: Corpus.scene([Self.layered]), options: PSDOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.psd"))) }
        #expect(PSDExporter().optionsType is PSDOptions.Type)
        #expect(PSDExporter().capabilities == ExportFormat.psd.capabilities)
        #expect(PSDOptions.defaults == PSDOptions())
        #expect(PSDWriter.pascal("abc", multiple: 4).count == 4)
        #expect(PSDWriter.pascal("abcd", multiple: 4).count == 8)
    }
}
