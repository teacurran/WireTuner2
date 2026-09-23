// Hand-built PDFs for the PDF and Illustrator import tests (IMG-009, IMG-010): a tiny writer of
// numbered objects, uncompressed or Flate streams, pages and a cross-reference table, so every
// operator, colour space, font and image kind the importer reads can be exercised without
// third-party files.

import Foundation
@testable import WTInterchange

struct PDFImportFixture {
    private(set) var objects: [Data] = []

    /// Adds an object and returns its number.
    @discardableResult
    mutating func add(_ body: String) -> Int {
        objects.append(Data(body.utf8))
        return objects.count
    }

    /// Reserves a number for an object set later.
    mutating func reserve() -> Int {
        objects.append(Data())
        return objects.count
    }

    mutating func set(_ number: Int, _ body: String) {
        objects[number - 1] = Data(body.utf8)
    }

    /// Adds a stream with `dictionary` entries (without `/Length`); `flate` compresses it.
    @discardableResult
    mutating func stream(_ dictionary: String = "", _ data: Data, flate: Bool = false) -> Int {
        let payload = flate ? Zlib.compress(data) : data
        var body = Data("<< \(dictionary) /Length \(payload.count)\(flate ? " /Filter /FlateDecode" : "") >>\nstream\n".utf8)
        body.append(payload)
        body.append(Data("\nendstream".utf8))
        objects.append(body)
        return objects.count
    }

    @discardableResult
    mutating func stream(_ dictionary: String = "", _ text: String, flate: Bool = false) -> Int {
        stream(dictionary, Data(text.utf8), flate: flate)
    }

    /// One page of a document.
    struct Page {
        var content: Data
        var resources: String
        var extra: String
        /// Content streams given as object numbers instead of `content`; `[0]` writes no
        /// `/Contents` at all.
        var contents: [Int]?

        init(_ content: String, resources: String = "<< >>", extra: String = "/MediaBox [0 0 200 150]") {
            self.content = Data(content.utf8)
            self.resources = resources
            self.extra = extra
        }

        init(data: Data, resources: String = "<< >>", extra: String = "/MediaBox [0 0 200 150]") {
            content = data
            self.resources = resources
            self.extra = extra
        }
    }

    /// The file with `pages`, `catalog` entries added to the catalog.
    mutating func document(_ pages: [Page], catalog: String = "") -> Data {
        let parent = reserve()
        var kids: [Int] = []
        for page in pages {
            let contents = page.contents.map { $0 == [0] ? "" : "/Contents [\($0.map { "\($0) 0 R" }.joined(separator: " "))]" } ?? "/Contents \(stream("", page.content)) 0 R"
            kids.append(add("<< /Type /Page /Parent \(parent) 0 R /Resources \(page.resources) \(contents) \(page.extra) >>"))
        }
        set(parent, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>")
        let root = add("<< /Type /Catalog /Pages \(parent) 0 R \(catalog) >>")
        var file = Data("%PDF-1.7\n%\u{E2}\u{E3}\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(file.count)
            file.append(Data("\(index + 1) 0 obj\n".utf8))
            file.append(object)
            file.append(Data("\nendobj\n".utf8))
        }
        let xref = file.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            table += String(format: "%010d 00000 n \n", offset)
        }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        file.append(Data(table.utf8))
        return file
    }

    /// A one-page document.
    static func page(_ content: String, resources: String = "<< >>", extra: String = "/MediaBox [0 0 200 150]", objects: (inout PDFImportFixture) -> Void = { _ in }) -> Data {
        var fixture = PDFImportFixture()
        objects(&fixture)
        return fixture.document([Page(content, resources: resources, extra: extra)])
    }

    /// `data` imported as PDF with `options`.
    static func importPDF(_ data: Data, _ options: PDFImportOptions = PDFImportOptions(), context: ImportContext = ImportContext()) throws -> ImportedScene {
        try PDFImporter().convert(data, name: "fixture.pdf", format: .pdf, options: options.values, context: context)
    }

    /// Every path of `scene` (layers included), in scene space.
    static func paths(_ nodes: [ImportedNode]) -> [ImportedPath] {
        nodes.flatMap(\.descendants).compactMap { node -> ImportedPath? in
            if case .path(let path) = node { return path }
            return nil
        }
    }

    static func groups(_ nodes: [ImportedNode]) -> [ImportedGroup] {
        nodes.flatMap(\.descendants).compactMap { node -> ImportedGroup? in
            if case .group(let group) = node { return group }
            return nil
        }
    }

    static func texts(_ nodes: [ImportedNode]) -> [ImportedText] {
        nodes.flatMap(\.descendants).compactMap { node -> ImportedText? in
            if case .text(let text) = node { return text }
            return nil
        }
    }

    static func images(_ nodes: [ImportedNode]) -> [ImportedImage] {
        nodes.flatMap(\.descendants).compactMap { node -> ImportedImage? in
            if case .image(let image) = node { return image }
            return nil
        }
    }

    /// Hex of `bytes`.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
