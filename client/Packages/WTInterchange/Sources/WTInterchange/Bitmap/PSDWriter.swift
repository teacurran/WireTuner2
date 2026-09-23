// The Photoshop writer (export-bitmap.adoc, "Photoshop (PSD)"; IO-023): PSD, or PSB when the image
// is wider or taller than 30,000 pixels.  Each layer group at the top of the page's display list
// becomes a Photoshop layer holding its artwork rendered to pixels with transparency (runs of other
// top-level artwork become layers of their own); the composite is the whole page as the bitmap
// options render it, for readers that ignore layers.  Channels are PackBits (RLE) compressed; the
// image resources carry the resolution, the ICC profile and the Document Info as XMP.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

/// PSD options (`PsdOptions`).
public struct PSDOptions: BitmapFormatOptions, Hashable {
    public var common: BitmapCommonOptions
    /// Layers from the document's layers; false writes one layer.
    public var layers: Bool
    /// 8 or 16.
    public var bitsPerChannel: Int

    public init(common: BitmapCommonOptions = BitmapCommonOptions(), layers: Bool = true, bitsPerChannel: Int = 8) {
        self.common = common
        self.layers = layers
        self.bitsPerChannel = bitsPerChannel
    }

    public static var defaults: PSDOptions { PSDOptions() }
}

/// One Photoshop layer before rendering: its name, artwork and opacity.
struct PSDLayerSource {
    var name: String
    var page: ExportPage
    var opacity: Double
}

/// One channel's pixels, big-endian samples, rows top to bottom.
struct PSDChannel {
    var id: Int16
    var data: [UInt8]
}

/// A rendered layer: its rectangle on the canvas and its channels.
struct PSDLayer {
    var name: String
    var opacity: Double
    var top: Int
    var left: Int
    var bottom: Int
    var right: Int
    var channels: [PSDChannel]

    var width: Int { right - left }
    var height: Int { bottom - top }
}

enum PSDWriter {
    /// PSD's size limit; larger images are PSB.
    static let psdLimit = 30_000

    /// The layers of `page`: each top-level layer group on its own, each run of other top-level
    /// items together; one layer holding everything when `layered` is off.
    static func layerSources(of page: ExportPage, scene: ExportScene, layered: Bool) -> [PSDLayerSource] {
        let list = page.displayList
        func subpage(_ indices: [Int]) -> ExportPage {
            var result = page
            result.displayList = DisplayList(canvas: list.canvas, items: indices.map { list.items[$0] }, nodeIDs: indices.map { $0 < list.nodeIDs.count ? list.nodeIDs[$0] : nil })
            result.background = nil
            return result
        }
        guard layered else {
            return [PSDLayerSource(name: "Layer 1", page: subpage(Array(list.items.indices)), opacity: 1)]
        }
        var sources: [PSDLayerSource] = []
        var run: [Int] = []
        func flush() {
            if !run.isEmpty {
                sources.append(PSDLayerSource(name: "Layer \(sources.count + 1)", page: subpage(run), opacity: 1))
                run = []
            }
        }
        for index in list.items.indices {
            guard let node = page.nodeID(at: [index]), let info = scene.nodes[node], info.isLayer else {
                run.append(index)
                continue
            }
            flush()
            var layer = subpage([index])
            var opacity = 1.0
            if case .group(var group) = list.items[index] {
                // The layer's opacity becomes the Photoshop layer's; its pixels render opaque.
                opacity = group.opacity
                group.opacity = 1
                layer.displayList = DisplayList(canvas: list.canvas, items: [.group(group)], nodeIDs: [node])
            }
            let name = info.name?.isEmpty == false ? info.name! : "Layer \(sources.count + 1)"
            sources.append(PSDLayerSource(name: name, page: layer, opacity: opacity))
        }
        flush()
        return sources
    }

    /// The file.  `composite` holds the colour channels (and alpha) of the whole image.
    static func data(width: Int, height: Int, depth: Int, mode: BitmapCommonOptions.ColorMode, layers: [PSDLayer], composite: [PSDChannel], resolution: Double, profile: Data?, xmp: Data?) -> Data {
        let big = width > psdLimit || height > psdLimit
        var out = Data("8BPS".utf8)
        out.appendBigEndian(UInt16(big ? 2 : 1))
        out.append(contentsOf: [UInt8](repeating: 0, count: 6))
        out.appendBigEndian(UInt16(composite.count))
        out.appendBigEndian(UInt32(height))
        out.appendBigEndian(UInt32(width))
        out.appendBigEndian(UInt16(depth))
        let modes: [BitmapCommonOptions.ColorMode: UInt16] = [.gray: 1, .rgb: 3, .cmyk: 4]
        out.appendBigEndian(modes[mode]!)
        out.appendBigEndian(UInt32(0))  // colour mode data
        out.append(resources(resolution: resolution, profile: profile, xmp: xmp))
        let bytesPerSample = depth / 8
        // Layer and mask information.
        var layerInfo = Data()
        let transparentComposite = composite.contains { $0.id == -1 }
        let count = Int16(layers.count)
        layerInfo.appendBigEndian(UInt16(bitPattern: transparentComposite ? -count : count))
        var channelData = Data()
        for layer in layers {
            var record = Data()
            for value in [layer.top, layer.left, layer.bottom, layer.right] {
                record.appendBigEndian(UInt32(bitPattern: Int32(value)))
            }
            record.appendBigEndian(UInt16(layer.channels.count))
            for channel in layer.channels {
                let encoded = rle(channel.data, width: layer.width, height: layer.height, bytesPerSample: bytesPerSample, big: big)
                record.appendBigEndian(UInt16(bitPattern: channel.id))
                if big {
                    record.appendBigEndian(UInt64(encoded.count))
                } else {
                    record.appendBigEndian(UInt32(encoded.count))
                }
                channelData.append(encoded)
            }
            record.append(Data("8BIMnorm".utf8))
            record.append(UInt8((min(max(layer.opacity, 0), 1) * 255).rounded()))
            record.append(contentsOf: [0, 0x08, 0])  // clipping base, visible (bit 3: bit 4 valid), filler
            var extra = Data()
            extra.appendBigEndian(UInt32(0))  // layer mask
            extra.appendBigEndian(UInt32(0))  // blending ranges
            extra.append(pascal(layer.name, multiple: 4))
            extra.append(Data("8BIMluni".utf8))
            var unicode = Data()
            let units = Array(layer.name.utf16)
            unicode.appendBigEndian(UInt32(units.count))
            for unit in units {
                unicode.appendBigEndian(unit)
            }
            while unicode.count % 4 != 0 {
                unicode.append(0)
            }
            extra.appendBigEndian(UInt32(unicode.count))
            extra.append(unicode)
            record.appendBigEndian(UInt32(extra.count))
            record.append(extra)
            layerInfo.append(record)
        }
        layerInfo.append(channelData)
        while layerInfo.count % 4 != 0 {
            layerInfo.append(0)
        }
        var section = Data()
        appendLength(layerInfo.count, big: big, to: &section)
        section.append(layerInfo)
        section.appendBigEndian(UInt32(0))  // global layer mask info
        appendLength(section.count, big: big, to: &out)
        out.append(section)
        // The composite: RLE, every row's byte count first, then every channel's rows.
        out.appendBigEndian(UInt16(1))
        var counts = Data()
        var rows = Data()
        for channel in composite {
            for row in 0..<height {
                let start = row * width * bytesPerSample
                let packed = PackBits.encode(channel.data[start..<(start + width * bytesPerSample)])
                if big {
                    counts.appendBigEndian(UInt32(packed.count))
                } else {
                    counts.appendBigEndian(UInt16(packed.count))
                }
                rows.append(contentsOf: packed)
            }
        }
        out.append(counts)
        out.append(rows)
        return out
    }

    static func appendLength(_ length: Int, big: Bool, to data: inout Data) {
        if big {
            data.appendBigEndian(UInt64(length))
        } else {
            data.appendBigEndian(UInt32(length))
        }
    }

    /// One layer channel: compression 1 (RLE), the rows' byte counts, the packed rows.
    static func rle(_ samples: [UInt8], width: Int, height: Int, bytesPerSample: Int, big: Bool) -> Data {
        var out = Data()
        out.appendBigEndian(UInt16(1))
        var rows = Data()
        let rowBytes = width * bytesPerSample
        for row in 0..<height {
            let packed = PackBits.encode(samples[(row * rowBytes)..<((row + 1) * rowBytes)])
            if big {
                out.appendBigEndian(UInt32(packed.count))
            } else {
                out.appendBigEndian(UInt16(packed.count))
            }
            rows.append(contentsOf: packed)
        }
        out.append(rows)
        return out
    }

    /// A Pascal string (MacRoman-safe: non-ASCII as `?`, at most 255 bytes) padded so the
    /// length byte and the text fill a multiple of `multiple` bytes.
    static func pascal(_ text: String, multiple: Int) -> Data {
        let bytes = text.unicodeScalars.prefix(255).map { $0.value < 0x80 ? UInt8($0.value) : UInt8(ascii: "?") }
        var data = Data([UInt8(bytes.count)] + bytes)
        while data.count % multiple != 0 {
            data.append(0)
        }
        return data
    }

    /// The image resources section: resolution (0x03ED), ICC profile (0x040F), XMP (0x0424).
    static func resources(resolution: Double, profile: Data?, xmp: Data?) -> Data {
        var blocks = Data()
        func block(_ id: UInt16, _ body: Data) {
            blocks.append(Data("8BIM".utf8))
            blocks.appendBigEndian(id)
            blocks.append(contentsOf: [0, 0])  // empty name
            blocks.appendBigEndian(UInt32(body.count))
            blocks.append(body)
            if body.count % 2 != 0 {
                blocks.append(0)
            }
        }
        var info = Data()
        let fixed = UInt32((resolution * 65536).rounded())
        for _ in 0..<2 {
            info.appendBigEndian(fixed)
            info.appendBigEndian(UInt16(1))  // pixels per inch
            info.appendBigEndian(UInt16(1))  // display in inches
        }
        block(0x03ED, info)
        if let profile {
            block(0x040F, profile)
        }
        if let xmp {
            block(0x0424, xmp)
        }
        var out = Data()
        out.appendBigEndian(UInt32(blocks.count))
        out.append(blocks)
        return out
    }
}

/// The XMP packet of Document Info shared by bitmap metadata writers (PSD).
enum XMPPacket {
    static func data(_ info: ExportDocumentInfo, format: String) -> Data {
        func escape(_ text: String) -> String { XMLStream.escape(text, attribute: false) }
        var dc = "<dc:format>\(escape(format))</dc:format>"
        if let title = info.title {
            dc += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(title))</rdf:li></rdf:Alt></dc:title>"
        }
        if let author = info.author {
            dc += "<dc:creator><rdf:Seq><rdf:li>\(escape(author))</rdf:li></rdf:Seq></dc:creator>"
        }
        if let description = info.description ?? info.subject {
            dc += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(description))</rdf:li></rdf:Alt></dc:description>"
        }
        if !info.keywords.isEmpty {
            dc += "<dc:subject><rdf:Bag>" + info.keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined() + "</rdf:Bag></dc:subject>"
        }
        if let language = info.language {
            dc += "<dc:language><rdf:Bag><rdf:li>\(escape(language))</rdf:li></rdf:Bag></dc:language>"
        }
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">\
        \(dc)<xmp:CreatorTool>\(escape(info.creator))</xmp:CreatorTool></rdf:Description></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(packet.utf8)
    }
}
