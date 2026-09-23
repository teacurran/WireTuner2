// The SVG importer's front end (import-formats.adoc, "Client", *SVG*; IMG-012): `.svgz` gzip
// members inflated, the XML parsed with Foundation's `XMLParser` into a small element tree the
// converter and the animation scan walk.  Element names lose their namespace prefix (`svg:rect`
// reads as `rect`); attribute names keep theirs (`xlink:href`, `inkscape:label`).

import Foundation

/// One element of a parsed SVG file.
final class SVGImportElement {
    /// Element content in document order.
    enum Content {
        case element(SVGImportElement)
        case text(String)
    }

    let name: String
    let attributes: [String: String]
    var content: [Content] = []
    weak var parent: SVGImportElement?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// The child elements.
    var children: [SVGImportElement] {
        content.compactMap { if case .element(let element) = $0 { return element } else { return nil } }
    }

    /// The character data directly inside the element.
    var text: String {
        content.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }

    /// The element and every descendant, depth first.
    var descendants: [SVGImportElement] {
        [self] + children.flatMap(\.descendants)
    }

    /// `href` or `xlink:href`.
    var href: String? {
        attributes["href"] ?? attributes["xlink:href"]
    }

    /// The element's classes.
    var classes: [String] {
        (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Parses SVG bytes.
enum SVGImportTree {
    /// The root element of `data` (gzip-compressed or not).
    static func parse(_ data: Data, name: String) throws -> SVGImportElement {
        let bytes = try inflateIfCompressed(data, name: name)
        let delegate = Delegate()
        let parser = XMLParser(data: bytes)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            throw ImportError.unreadable(name: name, reason: "the XML is malformed (line \(parser.lineNumber)).")
        }
        guard root.name == "svg" else {
            throw ImportError.unreadable(name: name, reason: "it is XML but not SVG.")
        }
        return root
    }

    /// `data` inflated when it is a gzip member (`.svgz`), else unchanged.
    static func inflateIfCompressed(_ data: Data, name: String) throws -> Data {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B else {
            return data
        }
        guard let inflated = gunzip(data) else {
            throw ImportError.unreadable(name: name, reason: "its gzip compression is damaged.")
        }
        return inflated
    }

    /// The payload of a gzip member (RFC 1952): the header's optional fields skipped, the raw
    /// DEFLATE body inflated with Compression.framework.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[2] == 8 else {
            return nil
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            // The length of the extra field; `bytes` holds at least 18.
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            while index < bytes.count && bytes[index] != 0 {
                index += 1
            }
            index += 1
        }
        if flags & 0x02 != 0 {
            index += 2
        }
        guard index < bytes.count - 8 else {
            return nil
        }
        let body = Data(bytes[index..<(bytes.count - 8)])
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var root: SVGImportElement?
        var stack: [SVGImportElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = elementName.components(separatedBy: ":").last!
            let element = SVGImportElement(name: local, attributes: attributes)
            if let parent = stack.last {
                element.parent = parent
                parent.content.append(.element(element))
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.content.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.content.append(.text(String(decoding: CDATABlock, as: UTF8.self)))
        }
    }
}
