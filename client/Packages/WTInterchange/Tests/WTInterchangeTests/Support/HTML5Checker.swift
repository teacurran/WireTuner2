// WEB-008: an HTML5 conformance checker for the publisher's output, run in-process so the corpus
// validates offline with no external tool.  It tokenizes the document as the HTML syntax
// defines it for the subset the publisher writes -- doctype, elements, double-quoted attributes,
// character references, foreign (SVG) content with self-closing tags -- and checks what the W3C
// validator (vnu) reports for such pages: the document structure, content models of the
// elements used, per-element attributes, required attributes (img `src` and `alt`, area `alt`
// with `href`, map `name`), integer `width`/`height`, `usemap` references, unique ids and map
// names, bare ampersands, obsolete elements and attributes, and that every referenced file is in
// the bundle.

import Foundation

enum HTML5Checker {
    /// Elements with no end tag.
    static let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
    /// The elements the publisher may write, with the attributes each allows beyond the global ones.
    static let elements: [String: Set<String>] = [
        "html": ["lang"], "head": [], "body": [], "title": [],
        "meta": ["charset", "name", "content"], "link": ["rel", "href", "type"], "style": [],
        "section": [], "nav": [], "div": [], "a": ["href", "rel", "target"],
        "img": ["src", "alt", "width", "height", "usemap"],
        "object": ["data", "type", "width", "height", "name"],
        "map": ["name"], "area": ["shape", "coords", "href", "alt", "target", "rel"],
        "svg": [],
    ]
    static let global: Set<String> = ["id", "class", "style", "lang", "title", "role", "hidden", "tabindex", "dir"]
    static let obsolete: Set<String> = ["font", "center", "big", "strike", "tt", "frame", "frameset", "marquee", "applet", "acronym", "basefont", "dir"]
    static let obsoleteAttributes: Set<String> = ["align", "border", "bgcolor", "hspace", "vspace", "valign", "language", "nohref"]
    static let areaShapes: Set<String> = ["rect", "circle", "poly", "default"]
    static let targets: Set<String> = ["_blank", "_self", "_parent", "_top"]

    struct Element {
        let name: String
        let attributes: [String: String]
        let parent: String?
        let foreign: Bool
    }

    /// The problems in `html`; `exists` answers whether a relative path the page references is
    /// in the bundle (relative to the page's folder).
    static func problems(_ html: String, exists: (String) -> Bool = { _ in true }) -> [String] {
        var problems: [String] = []
        var scanner = Substring(html)
        guard scanner.lowercased().hasPrefix("<!doctype html>") else { return ["no <!DOCTYPE html>"] }
        scanner = scanner.dropFirst("<!doctype html>".count)
        var stack: [(name: String, foreign: Bool)] = []
        var found: [Element] = []
        var titleText: String?
        var textByElement = ""
        while let open = scanner.firstIndex(of: "<") {
            let text = scanner[..<open]
            problems += Self.textProblems(String(text))
            if stack.last?.name == "title" { textByElement += text }
            scanner = scanner[open...]
            if scanner.hasPrefix("<!--") {
                guard let end = scanner.range(of: "-->") else { problems.append("unclosed comment"); break }
                scanner = scanner[end.upperBound...]
                continue
            }
            if scanner.hasPrefix("<![CDATA[") {
                guard stack.last?.foreign == true, let end = scanner.range(of: "]]>") else { problems.append("CDATA outside foreign content"); break }
                scanner = scanner[end.upperBound...]
                continue
            }
            guard let close = Self.tagEnd(scanner) else { problems.append("unclosed tag"); break }
            let tag = scanner[scanner.index(after: scanner.startIndex)..<close]
            scanner = scanner[scanner.index(after: close)...]
            if tag.hasPrefix("/") {
                let name = tag.dropFirst().trimmingCharacters(in: .whitespaces)
                if void.contains(name.lowercased()) && !(stack.last?.foreign ?? false) { problems.append("end tag for void element \(name)") }
                guard let top = stack.popLast() else { problems.append("stray end tag \(name)"); continue }
                if top.name != name { problems.append("end tag \(name) closes \(top.name)") }
                if name == "title" { titleText = textByElement }
                continue
            }
            guard let parsed = Self.tag(String(tag)) else { problems.append("malformed tag <\(tag)>"); continue }
            let foreign = parsed.name == "svg" || (stack.last?.foreign ?? false)
            let element = Element(name: parsed.name, attributes: parsed.attributes, parent: stack.last?.name, foreign: foreign)
            if parsed.duplicate { problems.append("duplicate attribute on <\(parsed.name)>") }
            if parsed.selfClosing && !foreign && !void.contains(parsed.name) { problems.append("self-closing non-void <\(parsed.name)/>") }
            found.append(element)
            if !(void.contains(parsed.name) && !foreign) && !parsed.selfClosing {
                stack.append((parsed.name, foreign))
                if parsed.name == "title" { textByElement = "" }
            }
        }
        problems += Self.textProblems(String(scanner))
        if !scanner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("text after </html>") }
        if !stack.isEmpty { problems.append("unclosed \(stack.map(\.name))") }
        problems += structure(found, title: titleText)
        problems += elementProblems(found, exists: exists)
        return problems
    }

    /// The `>` ending the tag `scanner` starts with, outside quoted attribute values.
    static func tagEnd(_ scanner: Substring) -> Substring.Index? {
        var quoted = false
        for index in scanner.indices {
            switch scanner[index] {
            case "\"": quoted.toggle()
            case ">" where !quoted: return index
            default: break
            }
        }
        return nil
    }

    /// A start tag's name, attributes (double-quoted or bare), whether it self-closes and whether
    /// an attribute repeats; nil when it does not parse.
    static func tag(_ source: String) -> (name: String, attributes: [String: String], selfClosing: Bool, duplicate: Bool)? {
        var characters = Substring(source)
        var selfClosing = false
        if characters.hasSuffix("/") {
            selfClosing = true
            characters = characters.dropLast()
        }
        let nameEnd = characters.firstIndex { $0 == " " || $0 == "\n" } ?? characters.endIndex
        let name = String(characters[..<nameEnd])
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }) else { return nil }
        var rest = characters[nameEnd...]
        var attributes: [String: String] = [:]
        var duplicate = false
        while true {
            rest = rest.drop { $0 == " " || $0 == "\n" }
            if rest.isEmpty { break }
            let keyEnd = rest.firstIndex { $0 == "=" || $0 == " " || $0 == "\n" } ?? rest.endIndex
            let key = String(rest[..<keyEnd])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_" }) else { return nil }
            rest = rest[keyEnd...]
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst()
                guard rest.first == "\"" else { return nil }
                rest = rest.dropFirst()
                guard let quote = rest.firstIndex(of: "\"") else { return nil }
                value = String(rest[..<quote])
                rest = rest[rest.index(after: quote)...]
                guard rest.isEmpty || rest.first == " " || rest.first == "\n" else { return nil }
                if value.contains("<") { return nil }
            }
            if attributes.updateValue(value, forKey: key) != nil { duplicate = true }
        }
        return (name, attributes, selfClosing, duplicate)
    }

    /// Bare ampersands and unknown character references in text or attribute values.
    static func textProblems(_ text: String) -> [String] {
        var problems: [String] = []
        var index = text.startIndex
        while let amp = text[index...].firstIndex(of: "&") {
            let rest = text[text.index(after: amp)...]
            let reference = rest.prefix { $0 != ";" && $0 != " " && $0 != "&" && $0 != "<" && $0 != "\"" }
            let terminated = rest.dropFirst(reference.count).first == ";"
            let named: Set<Substring> = ["amp", "lt", "gt", "quot", "apos", "nbsp"]
            let numeric = reference.hasPrefix("#") && (reference.dropFirst().allSatisfy(\.isNumber)
                || (reference.dropFirst().first == "x" && reference.dropFirst(2).allSatisfy(\.isHexDigit)))
            if !terminated || !(named.contains(reference) || (numeric && reference.count > 1)) {
                problems.append("bare or unknown reference &\(reference)")
            }
            index = text.index(after: amp)
        }
        return problems
    }

    static func structure(_ found: [Element], title: String?) -> [String] {
        var problems: [String] = []
        let top = found.filter { $0.parent == nil }
        if top.map(\.name) != ["html"] { problems.append("document element is \(top.map(\.name)), not html") }
        if found.first?.attributes["lang"]?.isEmpty ?? true { problems.append("html has no lang") }
        let children = found.filter { $0.parent == "html" }.map(\.name)
        if children != ["head", "body"] { problems.append("html children \(children)") }
        let head = found.filter { $0.parent == "head" }
        if head.first?.name != "meta" || head.first?.attributes["charset"]?.lowercased() != "utf-8" { problems.append("meta charset=utf-8 is not the head's first element") }
        if head.filter({ $0.attributes["charset"] != nil }).count != 1 { problems.append("charset declared other than once") }
        if head.filter({ $0.name == "title" }).count != 1 { problems.append("head needs exactly one title") }
        if (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("empty title") }
        for element in head where !["meta", "title", "link", "style"].contains(element.name) {
            problems.append("<\(element.name)> in head")
        }
        return problems
    }

    static func elementProblems(_ found: [Element], exists: (String) -> Bool) -> [String] {
        var problems: [String] = []
        var ids = Set<String>()
        var maps: [String] = []
        var usemaps: [String] = []
        for element in found {
            if let id = element.attributes["id"] {
                if !ids.insert(id).inserted { problems.append("duplicate id \(id)") }
                if id.isEmpty || id.contains(where: \.isWhitespace) { problems.append("bad id '\(id)'") }
            }
            if element.foreign && element.name != "svg" { continue }
            if obsolete.contains(element.name) { problems.append("obsolete element \(element.name)") }
            guard let own = elements[element.name] else { problems.append("element \(element.name) not expected"); continue }
            if element.name == "svg" { continue }
            for (key, value) in element.attributes {
                if obsoleteAttributes.contains(key) { problems.append("obsolete attribute \(element.name)@\(key)") }
                let allowed = own.contains(key) || global.contains(key) || key.hasPrefix("aria-") || key.hasPrefix("data-")
                if !allowed { problems.append("attribute \(element.name)@\(key) not allowed") }
                problems += textProblems(value)
                if ["style", "class"].contains(key), value.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("empty \(key) on \(element.name)") }
            }
            for key in ["width", "height"] {
                if let value = element.attributes[key], value.isEmpty || !value.allSatisfy(\.isNumber) {
                    problems.append("\(element.name)@\(key)=\"\(value)\" is not a non-negative integer")
                }
            }
            for key in ["href", "src", "data"] {
                guard let value = element.attributes[key] else { continue }
                if value.isEmpty || value.contains(where: \.isWhitespace) { problems.append("\(element.name)@\(key) '\(value)' is not a valid URL") }
                if Self.isRelativeFile(value), !exists(Self.file(value)) { problems.append("\(element.name)@\(key) '\(value)' is not in the bundle") }
            }
            if let target = element.attributes["target"], !targets.contains(target), target.hasPrefix("_") { problems.append("bad target \(target)") }
            switch element.name {
            case "img":
                if element.attributes["src"] == nil { problems.append("img without src") }
                if element.attributes["alt"] == nil { problems.append("img without alt") }
                if let usemap = element.attributes["usemap"] {
                    if usemap.hasPrefix("#") { usemaps.append(String(usemap.dropFirst())) } else { problems.append("usemap '\(usemap)' is not a hash name") }
                }
            case "object":
                if element.attributes["data"] == nil && element.attributes["type"] == nil { problems.append("object without data or type") }
            case "map":
                let name = element.attributes["name"] ?? ""
                if name.isEmpty || name.contains(where: \.isWhitespace) { problems.append("map name '\(name)'") }
                if maps.contains(name) { problems.append("duplicate map name \(name)") }
                maps.append(name)
                if let id = element.attributes["id"], id != name { problems.append("map id and name differ") }
            case "area":
                if element.parent != "map" { problems.append("area outside a map") }
                if element.attributes["href"] != nil && element.attributes["alt"] == nil { problems.append("area with href and no alt") }
                let shape = element.attributes["shape"] ?? "rect"
                if !areaShapes.contains(shape) { problems.append("area shape \(shape)") }
                let coords = (element.attributes["coords"] ?? "").split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                if coords.contains(where: { $0 == nil }) { problems.append("area coords not numbers") }
                switch shape {
                case "rect": if coords.count != 4 { problems.append("rect area with \(coords.count) coords") }
                case "circle": if coords.count != 3 { problems.append("circle area with \(coords.count) coords") }
                case "poly": if coords.count < 6 || coords.count % 2 != 0 { problems.append("poly area with \(coords.count) coords") }
                default: break
                }
            case "a", "link":
                if element.attributes["href"] == nil && element.name == "link" { problems.append("link without href") }
                if element.name == "link", element.attributes["rel"] == nil { problems.append("link without rel") }
            case "meta":
                if element.attributes["charset"] == nil && (element.attributes["name"] == nil || element.attributes["content"] == nil) { problems.append("meta without charset or name/content") }
            default:
                break
            }
            if ["section", "nav", "div", "a", "object", "map"].contains(element.name), element.parent == "head" { problems.append("\(element.name) in head") }
            if element.name == "area" || element.name == "img" || element.name == "object" || element.name == "map" || element.name == "section" || element.name == "nav" || element.name == "div" {
                if element.parent == "html" { problems.append("\(element.name) directly in html") }
            }
        }
        for name in usemaps where !maps.contains(name) { problems.append("usemap #\(name) has no map") }
        return problems
    }

    static func isRelativeFile(_ value: String) -> Bool {
        !value.hasPrefix("#") && !value.contains(":") && !value.hasPrefix("//")
    }

    /// The file a relative reference names: unescaped, without its fragment.
    static func file(_ value: String) -> String {
        String(unescape(value).prefix { $0 != "#" })
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Paths an SVG page references (`xlink:href`, `href`, `url(...)` in style and `@font-face`),
    /// relative files only.
    static func svgReferences(_ svg: String) -> [String] {
        var result: [String] = []
        for pattern in [##"(?:xlink:)?href="([^"#][^"]*)""##, ##"url\(['"]?([^'")#][^'")]*)['"]?\)"##] {
            let expression = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(svg.startIndex..., in: svg)
            for match in expression.matches(in: svg, range: range) {
                guard let value = Range(match.range(at: 1), in: svg).map({ String(svg[$0]) }) else { continue }
                if isRelativeFile(value) { result.append(file(value)) }
            }
        }
        return result
    }

    /// `path` resolved against the folder of `page` (both bundle-relative), ".." collapsed.
    static func resolve(_ path: String, from page: String) -> String {
        var parts = page.split(separator: "/").dropLast().map(String.init)
        for part in path.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }
}
