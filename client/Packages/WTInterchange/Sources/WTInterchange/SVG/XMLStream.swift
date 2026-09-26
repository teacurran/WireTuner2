// A small streaming XML writer (export-vector.adoc: "own XML writer (`XMLDocument` is too slow
// for 50,000 nodes)").  Elements are written as they are opened; indentation is two spaces per
// level unless minified.

import Foundation

struct XMLStream {
    private(set) var text = ""
    private var open: [String] = []
    /// Whether the innermost open element has had a child written (and so needs a closing tag
    /// on its own line).
    private var hasChildren: [Bool] = []
    private var tagOpen = false
    let minify: Bool

    init(minify: Bool) {
        self.minify = minify
    }

    private mutating func newline() {
        guard !minify else { return }
        if !text.isEmpty {
            text += "\n"
        }
        text += String(repeating: "  ", count: open.count)
    }

    private mutating func finishTag() {
        if tagOpen {
            text += ">"
            tagOpen = false
        }
    }

    /// Opens `name` with `attributes` (nil values are skipped).
    mutating func start(_ name: String, _ attributes: [(String, String?)] = []) {
        finishTag()
        if !hasChildren.isEmpty {
            hasChildren[hasChildren.count - 1] = true
        }
        newline()
        text += "<" + name
        for (key, value) in attributes {
            if let value {
                text += " \(key)=\"\(XMLStream.escape(value))\""
            }
        }
        tagOpen = true
        open.append(name)
        hasChildren.append(false)
    }

    /// Closes the innermost element (self-closing when it has no content).
    mutating func end() {
        let name = open.removeLast()
        let children = hasChildren.removeLast()
        if tagOpen {
            text += "/>"
            tagOpen = false
            return
        }
        if children {
            newline()
        }
        text += "</\(name)>"
    }

    /// An element with no children.
    mutating func element(_ name: String, _ attributes: [(String, String?)] = []) {
        start(name, attributes)
        end()
    }

    /// An element holding only character data.
    mutating func element(_ name: String, _ attributes: [(String, String?)] = [], text content: String) {
        start(name, attributes)
        finishTag()
        text += XMLStream.escape(content, attribute: false)
        end()
    }

    /// An element holding character data whose line breaks are written as `&#10;`, so they
    /// survive re-indentation of the fragment (a multi-line `<desc>`).
    mutating func element(_ name: String, _ attributes: [(String, String?)] = [], lines content: String) {
        start(name, attributes)
        finishTag()
        text += content.split(separator: "\n", omittingEmptySubsequences: false).map { XMLStream.escape(String($0), attribute: false) }.joined(separator: "&#10;")
        end()
    }

    /// Character data inside the open element.
    mutating func characters(_ content: String) {
        finishTag()
        text += XMLStream.escape(content, attribute: false)
    }

    /// Markup written as is (a prepared fragment, a comment).
    mutating func raw(_ markup: String) {
        finishTag()
        if !hasChildren.isEmpty {
            hasChildren[hasChildren.count - 1] = true
        }
        newline()
        text += markup
    }

    /// `value` escaped for XML; characters XML 1.0 forbids are dropped.
    static func escape(_ value: String, attribute: Bool = true) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where attribute: result += "&quot;"
            case "\n" where attribute: result += "&#10;"
            case "\t", "\n", "\r":
                result.unicodeScalars.append(scalar)
            default:
                let value = scalar.value
                if value >= 0x20 && !(0xFFFE...0xFFFF).contains(value) {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
