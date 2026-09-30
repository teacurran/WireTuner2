// The document package embedded in PDF and EPS exports, and finding it again on open (IO-028;
// export-pdf.adoc *Embed {product} document*, export-vector.adoc "Client").
//
// PDF: the package is an embedded file (`/EmbeddedFiles` in the catalog's name tree and the
// catalog's `/AF`, `AFRelationship /Source`), stored as is -- a package is already a zip -- less its
// thumbnail and preview, which the file carrying it makes redundant.
// EPS: a `%%BeginData … %%EndData` block before `%%EOF`, tagged `%WireTunerPackage`, the package
// in base64 with every line a comment so a PostScript interpreter skips it.
//
// On open, `EmbeddedPackage.find(in:)` looks for either and returns the package only when its
// manifest reads, so a PDF or EPS without one -- or with a damaged one -- falls through to the
// PDF or EPS importer.

import CoreGraphics
import Foundation

public enum EmbeddedPackage {
    /// The embedded file's media type (`/Subtype`).
    static let mediaType = "application/vnd.wiretuner.package+zip"
    static let description = "WireTuner document"
    /// The EPS block's tag line.
    static let epsTag = "%WireTunerPackage"
    /// Base64 characters per EPS comment line.
    static let lineLength = 76

    /// The attachment's file name: the scene's name with the package extension.
    static func fileName(_ name: String) -> String {
        (name.isEmpty ? "Untitled" : name) + ".wiretuner"
    }

    /// `package` without its thumbnail and page-1 preview, which the PDF or EPS carrying it
    /// already shows: the manifest, snapshot and blobs -- everything opening it reads -- are
    /// kept, so the reopened document is the original.  An archive that cannot be read is
    /// embedded as it is.
    static func slimmed(_ package: Data) -> Data {
        guard let zip = try? ZipReader(data: package) else {
            return package
        }
        var data = Data()
        // The package's own stamp, not the clock's: the same package always embeds as the same bytes.
        let stamp = zip.entries.first.flatMap { zip.stamp(of: $0) } ?? ZipWriter.dosTimestamp(Date())
        let writer = ZipWriter(stamp: stamp) { data.append($0) }
        do {
            for entry in zip.entries where entry.name != PackageEntry.thumbnail && entry.name != PackageEntry.preview {
                try writer.add(entry.name, data: zip.contents(of: entry), method: entry.method == ZipMethod.stored.rawValue ? .stored : .deflate)
            }
            try writer.finish()
        } catch {
            return package
        }
        return data
    }

    /// The EPS data block carrying `package`.
    static func epsBlock(_ package: Data) -> String {
        let encoded = package.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: lineLength, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append("%" + encoded[index..<end])
            index = end
        }
        return "%%BeginData: \(lines.count + 1) ASCII Lines\n\(epsTag) \(package.count)\n" + lines.map { $0 + "\n" }.joined() + "%%EndData\n"
    }

    /// The package inside a PDF or EPS file, when there is one whose manifest reads.
    public static func find(in data: Data) -> Data? {
        let candidate = data.starts(with: Data("%PDF".utf8)) ? fromPDF(data) : fromEPS(data)
        guard let candidate, (try? PackageReader.manifest(of: candidate)) != nil else {
            return nil
        }
        return candidate
    }

    /// The package of a PDF or EPS file opened as a new document (menu:File[Open Package…] and
    /// Finder double-click): nil when the file carries none, so the caller falls through to the
    /// PDF or EPS importer; a package that is there but cannot be opened throws its error.
    public static func open(_ data: Data, reader: PackageReader) throws -> OpenedPackage? {
        guard let package = find(in: data) else {
            return nil
        }
        return try reader.open(package)
    }

    /// The package block of an EPS file (the DOS binary header's PostScript included).
    static func fromEPS(_ data: Data) -> Data? {
        guard let tag = data.range(of: Data((epsTag + " ").utf8)) else {
            return nil
        }
        guard let lineEnd = data[tag.upperBound...].firstIndex(of: 0x0A), let end = data.range(of: Data("%%EndData".utf8), in: lineEnd..<data.endIndex) else {
            return nil
        }
        let body = String(decoding: data[(lineEnd + 1)..<end.lowerBound], as: UTF8.self)
        let encoded = body.split(whereSeparator: \.isNewline).map { $0.hasPrefix("%") ? $0.dropFirst() : $0[...] }.joined()
        return Data(base64Encoded: encoded)
    }

    /// The first embedded file of a PDF that is a package (by media type or file name).
    static func fromPDF(_ data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let catalog = document.catalog else {
            return nil
        }
        var names: CGPDFDictionaryRef?
        var files: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names, CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &files), let files else {
            return nil
        }
        return search(files, depth: 0)
    }

    /// A name-tree node: its `/Names` pairs, then its `/Kids`.
    static func search(_ node: CGPDFDictionaryRef, depth: Int) -> Data? {
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &array), let array {
            var index = 1
            while index < CGPDFArrayGetCount(array) {
                var spec: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(array, index, &spec), let spec, let package = package(in: spec) {
                    return package
                }
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if depth < 16, CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid, let package = search(kid, depth: depth + 1) {
                    return package
                }
            }
        }
        return nil
    }

    /// The file of a file specification, when it is a package.
    static func package(in spec: CGPDFDictionaryRef) -> Data? {
        var embedded: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(spec, "EF", &embedded), let embedded,
              CGPDFDictionaryGetStream(embedded, "F", &stream) || CGPDFDictionaryGetStream(embedded, "UF", &stream), let stream
        else {
            return nil
        }
        var subtype: UnsafePointer<CChar>?
        var fileName: CGPDFStringRef?
        let typed = CGPDFStreamGetDictionary(stream).map { CGPDFDictionaryGetName($0, "Subtype", &subtype) } == true && subtype.map { String(cString: $0) } == mediaType
        let named = (CGPDFDictionaryGetString(spec, "UF", &fileName) || CGPDFDictionaryGetString(spec, "F", &fileName)) && fileName.flatMap { CGPDFStringCopyTextString($0) as String? }?.hasSuffix(".wiretuner") == true
        guard typed || named else {
            return nil
        }
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(stream, &format) as Data?
    }
}
