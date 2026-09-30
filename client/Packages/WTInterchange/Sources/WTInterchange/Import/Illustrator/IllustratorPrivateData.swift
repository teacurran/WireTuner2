// Illustrator's private data (import-formats.adoc, "Adobe Illustrator"; D-085): a PDF-compatible
// Illustrator file keeps its native document in the page's `/PieceInfo /Illustrator /Private`
// dictionary as the streams `/AIPrivateData1` … `/AIPrivateDataN` (`/AIPDFPrivateData1` … in a
// `.pdf` saved with *Preserve Illustrator Editing Capabilities*), which join into Illustrator's
// PostScript-like native format -- from Illustrator CS (version 11) on mostly behind a
// `%AI12_CompressedData` marker as one zlib stream.  The importer reads only its layer table --
// every `%AI5_BeginLayer` record's `Lb` flags (visible, preview, enabled, printing …) and `Ln`
// name, nested as the records nest -- and the artboards' names from the document data's
// `ArtboardArray` (Illustrator CS4 and later).  The artwork itself always comes from the PDF.

import Compression
import CoreGraphics
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

    /// Whether Illustrator wrote `pdf`: one of its pages has Illustrator's piece info.
    static func isIllustrator(_ pdf: CGPDFDocument) -> Bool {
        (1...max(pdf.numberOfPages, 1)).contains { number in
            pdf.page(at: number)?.dictionary.map { PDFImportDict(ref: $0).dict("PieceInfo")?.dict("Illustrator") != nil } ?? false
        }
    }

    /// The joined, decompressed private data of `page`, or nil when it has none or it is
    /// compressed in a way the importer does not read (Illustrator 2020's Zstandard data).
    static func data(page: PDFImportDict) -> Data? {
        guard let privateData = page.dict("PieceInfo")?.dict("Illustrator")?.dict("Private") else {
            return nil
        }
        let blocks = privateData.keys.compactMap { key -> (Int, PDFImportStream)? in
            let prefix = ["AIPrivateData", "AIPDFPrivateData"].first { key.hasPrefix($0) }
            guard let prefix, let number = Int(key.dropFirst(prefix.count)), let stream = privateData.stream(key) else { return nil }
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

// MARK: Document data

/// One value of Illustrator's document data: a scalar's text, or a dictionary's or an array's
/// entries in file order (an array's entries have no keys).
indirect enum IllustratorDataValue {
    case scalar(Data)
    case container([(key: String?, value: IllustratorDataValue)])

    /// The first entry named `key`.
    subscript(key: String) -> IllustratorDataValue? {
        guard case .container(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    /// A container's values.
    var values: [IllustratorDataValue] {
        guard case .container(let entries) = self else { return [] }
        return entries.map(\.value)
    }

    /// A string scalar as text: UTF-16BE with its byte-order mark, else UTF-8, else Latin-1.
    var text: String? {
        guard case .scalar(let data) = self else { return nil }
        if data.starts(with: [0xFE, 0xFF]) || !data.contains(where: { $0 >= 0x80 }) {
            return PDFImportOperand.text(data)
        }
        return String(data: data, encoding: .utf8) ?? PDFImportOperand.text(data)
    }
}

extension IllustratorPrivateData {
    /// The names of the file's artboards in artboard order -- the order Illustrator writes them as
    /// the PDF's pages -- from the document data's `ArtboardArray`; empty for a file from before
    /// Illustrator CS4, which has one artboard and no names.
    static func artboardNames(_ data: Data) -> [String] {
        guard let document = documentData(data) else { return [] }
        return artboards(document).map { $0["Name"]?.text ?? "" }
    }

    /// The artboard dictionaries of the first `ArtboardArray` anywhere in `value`.
    static func artboards(_ value: IllustratorDataValue) -> [IllustratorDataValue] {
        guard case .container(let entries) = value else { return [] }
        if let array = entries.first(where: { $0.key == "ArtboardArray" }) {
            return array.value.values
        }
        for entry in entries {
            let found = artboards(entry.value)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// The document data (`%AI9_BeginDocumentData` … `%AI9_EndDocumentData`, each line behind
    /// `%_`) parsed, or nil when the native data has none.
    static func documentData(_ data: Data) -> IllustratorDataValue? {
        guard let begin = data.range(of: Data("%AI9_BeginDocumentData".utf8)) else { return nil }
        let end = data.range(of: Data("%AI9_EndDocumentData".utf8), in: begin.upperBound..<data.endIndex)?.lowerBound ?? data.endIndex
        var body = Data()
        for line in data[begin.upperBound..<end].split(whereSeparator: { $0 == 10 || $0 == 13 }) {
            if line.starts(with: Data("%_".utf8)) {
                body.append(line.dropFirst(2))
                body.append(10)
            } else if line.first != UInt8(ascii: "%") {
                body.append(line)
                body.append(10)
            }
        }
        return dictionary(body)
    }

    /// Illustrator's dictionary serialisation read as one root container: a scalar is
    /// `value /Type (key) ,` (a point `x y /RealPoint (key) ,`), a container
    /// `/Type : entries ; (key) ,`, with the key left out inside an array, flags such as
    /// `/NotRecorded` ignored, and the outermost `/Document : … ;` closed without a comma.
    static func dictionary(_ body: Data) -> IllustratorDataValue {
        var stack: [[(key: String?, value: IllustratorDataValue)]] = [[]]
        var closed: IllustratorDataValue?
        var operands: [PDFImportOperand] = []
        var parser = PDFImportParser(body)
        func key(_ operands: ArraySlice<PDFImportOperand>) -> String? {
            operands.last(where: { $0.string != nil })?.string.map(PDFImportOperand.text)
        }
        while let item = parser.next() {
            switch item {
            case .operand(let operand):
                operands.append(operand)
            case .op(":"):
                stack.append([])
                closed = nil
                operands = []
            case .op(";"):
                if stack.count > 1 {
                    closed = .container(stack.removeLast())
                }
                operands = []
            case .op(","):
                if let container = closed {
                    stack[stack.count - 1].append((key(operands[...]), container))
                    closed = nil
                } else if let type = operands.lastIndex(where: { $0.name != nil && !["NotRecorded", "Recorded"].contains($0.name!) }) {
                    let value: Data
                    switch operands[..<type].first {
                    case .string(let data)?: value = data
                    case .number(let number)?: value = Data(String(number).utf8)
                    default: value = Data()
                    }
                    stack[stack.count - 1].append((key(operands[(type + 1)...]), .scalar(value)))
                }
                operands = []
            case .op, .comment:
                operands = []
            }
        }
        // The document closes without a key; a cut-off section closes what is open.
        if let container = closed {
            stack[stack.count - 1].append((nil, container))
        }
        while stack.count > 1 {
            let inner = stack.removeLast()
            stack[stack.count - 1].append((nil, .container(inner)))
        }
        return .container(stack[0])
    }
}
