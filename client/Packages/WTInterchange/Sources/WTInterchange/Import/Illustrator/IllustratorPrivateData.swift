// Illustrator's private data (import-formats.adoc, "Adobe Illustrator"; D-085): a PDF-compatible
// Illustrator file keeps its native document in the page's `/PieceInfo /Illustrator /Private`
// dictionary as the streams `/AIPrivateData1` … `/AIPrivateDataN`, which join into Illustrator's
// PostScript-like native format -- from Illustrator CS (version 11) on mostly behind a
// `%AI12_CompressedData` marker as one zlib stream.  The importer reads only its layer table:
// every `%AI5_BeginLayer` record's `Lb` flags (visible, preview, enabled, printing …) and `Ln`
// name, nested as the records nest.  The artwork itself always comes from the PDF.

import Compression
import Foundation

/// One layer record of Illustrator's native data.
struct IllustratorNativeLayer: Hashable {
    var name: String
    var state: ImportedLayerState
    /// 0 for a top-level layer, 1 for its sublayers, and so on.
    var depth: Int
}

enum IllustratorPrivateData {
    /// Decompressed private data larger than this is not read (the layer table is then unknown).
    static let limit = 1 << 30

    /// The joined, decompressed private data of `page`, or nil when it has none or it is
    /// compressed in a way the importer does not read (Illustrator 2020's Zstandard data).
    static func data(page: PDFImportDict) -> Data? {
        guard let privateData = page.dict("PieceInfo")?.dict("Illustrator")?.dict("Private") else {
            return nil
        }
        let blocks = privateData.keys.compactMap { key -> (Int, PDFImportStream)? in
            guard key.hasPrefix("AIPrivateData"), let number = Int(key.dropFirst("AIPrivateData".count)), let stream = privateData.stream(key) else { return nil }
            return (number, stream)
        }.sorted { $0.0 < $1.0 }
        guard !blocks.isEmpty else {
            return nil
        }
        var joined = Data()
        for (_, stream) in blocks { joined.append(stream.data) }
        return native(joined)
    }

    /// `joined` with its compressed part inflated: a `%AI12_CompressedData` marker is followed by
    /// one zlib stream; nil for a `%AI24_ZStandard_Data` marker or a stream that does not inflate.
    static func native(_ joined: Data) -> Data? {
        if joined.range(of: Data("%AI24_ZStandard_Data".utf8)) != nil {
            return nil
        }
        let marker = Data("%AI12_CompressedData".utf8)
        guard let range = joined.range(of: marker) else {
            return joined
        }
        guard let inflated = inflate(joined[range.upperBound...]) else {
            return nil
        }
        return joined[..<range.lowerBound] + inflated
    }

    /// A zlib (RFC 1950) stream inflated up to its end (whatever follows is ignored), or nil
    /// when it is not one or inflates past `limit`.
    static func inflate(_ zlib: Data, limit: Int = IllustratorPrivateData.limit) -> Data? {
        let bytes = [UInt8](zlib)
        guard bytes.count > 2, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 else {
            return nil
        }
        let chunk = 1 << 20
        var output = Data()
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        // Initialising a decoder for a built-in algorithm does not fail.
        _ = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        defer { compression_stream_destroy(stream) }
        return bytes.withUnsafeBufferPointer { source -> Data? in
            // Past the two-byte zlib header: COMPRESSION_ZLIB is raw DEFLATE.
            stream.pointee.src_ptr = source.baseAddress! + 2
            stream.pointee.src_size = source.count - 2
            var status = COMPRESSION_STATUS_OK
            var stalled = false
            repeat {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunk
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                stalled = stream.pointee.src_size == 0 && stream.pointee.dst_size == chunk
                output.append(destination, count: chunk - stream.pointee.dst_size)
                if output.count > limit {
                    return nil
                }
            } while status == COMPRESSION_STATUS_OK && !stalled
            // A damaged or cut-off stream keeps what inflated before the damage.
            return output.isEmpty ? nil : output
        }
    }

    /// The layer records of native data, in file order (bottom to top), each with its depth.
    static func layers(_ data: Data) -> [IllustratorNativeLayer] {
        let begin = Data("%AI5_BeginLayer".utf8)
        let end = Data("%AI5_EndLayer".utf8)
        var layers: [IllustratorNativeLayer] = []
        var depth = 0
        var position = data.startIndex
        while position < data.endIndex {
            let nextBegin = data.range(of: begin, in: position..<data.endIndex)
            let nextEnd = data.range(of: end, in: position..<data.endIndex)
            if let opening = nextBegin, nextEnd.map({ opening.lowerBound < $0.lowerBound }) ?? true {
                if let layer = record(data[opening.upperBound..<min(opening.upperBound + 1024, data.endIndex)], depth: depth) {
                    layers.append(layer)
                }
                depth += 1
                position = opening.upperBound
            } else if let closing = nextEnd {
                depth = max(depth - 1, 0)
                position = closing.upperBound
            } else {
                break
            }
        }
        return layers
    }

    /// The layer a `%AI5_BeginLayer` record starts: its first `Lb` (at least the visible,
    /// preview, enabled and printing flags) and the `Ln` name after it ("Layer" without one).
    static func record(_ bytes: Data, depth: Int) -> IllustratorNativeLayer? {
        var parser = PDFImportParser(Data(bytes))
        var operands: [PDFImportOperand] = []
        var flags: [Double]?
        while let item = parser.next() {
            switch item {
            case .operand(let operand):
                operands.append(operand)
            case .op("Lb"):
                let numbers = operands.compactMap(\.number)
                guard numbers.count >= 4 else { return nil }
                flags = numbers
                operands = []
            case .op("Ln"):
                guard let flags else { return nil }
                return layer(flags, name: operands.last?.string.map(PDFImportOperand.text) ?? "Layer", depth: depth)
            case .op:
                if let flags { return layer(flags, name: "Layer", depth: depth) }
                operands = []
            case .comment:
                break
            }
        }
        return flags.map { layer($0, name: "Layer", depth: depth) }
    }

    static func layer(_ flags: [Double], name: String, depth: Int) -> IllustratorNativeLayer {
        IllustratorNativeLayer(name: name, state: ImportedLayerState(visible: flags[0] != 0, locked: flags[2] == 0, printing: flags[3] != 0, outline: flags[1] == 0), depth: depth)
    }
}
