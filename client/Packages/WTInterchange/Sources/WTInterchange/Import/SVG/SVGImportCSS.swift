// The small CSS cascade the SVG importer applies (import-formats.adoc, "SVG": "CSS in `<style>`
// elements and `style` attributes is applied"; IMG-012): rules from every `<style>` element with
// type, class, id, universal and compound selectors, descendant (` `) and child (`>`)
// combinators, selector lists, specificity and source order, and `!important`.  At-rules are
// skipped (their contents are what the animation scan reads).  Presentation attributes sit below
// every rule, `style` attributes above them, as CSS specifies.

import Foundation

/// One `property: value` declaration.
struct SVGImportDeclaration: Equatable {
    var property: String
    var value: String
    var important: Bool
}

/// A parsed style sheet.
struct SVGImportStyleSheet {
    struct Rule {
        var selector: SVGImportSelector
        var declarations: [SVGImportDeclaration]
        var order: Int
    }

    var rules: [Rule] = []

    /// Every rule in `text`.
    init(_ text: String) {
        let source = SVGImportStyleSheet.stripComments(text)
        var index = source.startIndex
        var order = 0
        while index < source.endIndex {
            guard let open = source[index...].firstIndex(of: "{") else {
                break
            }
            let prelude = source[index..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            // At-rules with a block (`@keyframes`, `@media`, `@font-face`) are skipped whole.
            if prelude.hasPrefix("@") {
                index = SVGImportStyleSheet.matchingBrace(in: source, from: open)
                continue
            }
            guard let close = source[open...].firstIndex(of: "}") else {
                break
            }
            let declarations = SVGImportStyleSheet.declarations(String(source[source.index(after: open)..<close]))
            for selectorText in prelude.split(separator: ",") {
                if let selector = SVGImportSelector(String(selectorText)) {
                    rules.append(Rule(selector: selector, declarations: declarations, order: order))
                    order += 1
                }
            }
            index = source.index(after: close)
        }
    }

    /// The index after the brace that closes the one at `open`.
    static func matchingBrace(in text: String, from open: String.Index) -> String.Index {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "/*") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "*/") else {
                return result
            }
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    /// The declarations of a block or `style` attribute.
    static func declarations(_ text: String) -> [SVGImportDeclaration] {
        text.split(separator: ";").compactMap { part in
            guard let colon = part.firstIndex(of: ":") else {
                return nil
            }
            let property = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let bang = value.range(of: "!important", options: .caseInsensitive) {
                important = true
                value = value[..<bang.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !property.isEmpty, !value.isEmpty else {
                return nil
            }
            return SVGImportDeclaration(property: property, value: value, important: important)
        }
    }

    /// The declarations of rules matching `element`, in cascade order (lowest first):
    /// specificity, then source order; `!important` ones are returned separately.
    func matching(_ element: SVGImportElement) -> (normal: [SVGImportDeclaration], important: [SVGImportDeclaration]) {
        let matched = rules.filter { $0.selector.matches(element) }
            .sorted { ($0.selector.specificity, $0.order) < ($1.selector.specificity, $1.order) }
        let all = matched.flatMap(\.declarations)
        return (all.filter { !$0.important }, all.filter(\.important))
    }
}

/// A complex selector: compounds joined by descendant or child combinators.
struct SVGImportSelector {
    struct Compound {
        var element: String?
        var id: String?
        var classes: [String] = []

        func matches(_ element: SVGImportElement) -> Bool {
            if let name = self.element, name != element.name {
                return false
            }
            if let id, element.attributes["id"] != id {
                return false
            }
            let own = element.classes
            return classes.allSatisfy(own.contains)
        }
    }

    /// Rightmost compound last; `child[i]` is true when compound i+1 must be a child of i.
    var compounds: [Compound]
    var childCombinators: [Bool]

    init?(_ text: String) {
        var compounds: [Compound] = []
        var child: [Bool] = []
        var pendingChild = false
        let tokens = text.replacingOccurrences(of: ">", with: " > ").split(whereSeparator: \.isWhitespace)
        for token in tokens {
            if token == ">" {
                pendingChild = true
                continue
            }
            guard let compound = SVGImportSelector.compound(String(token)) else {
                return nil
            }
            if !compounds.isEmpty {
                child.append(pendingChild)
            }
            pendingChild = false
            compounds.append(compound)
        }
        guard !compounds.isEmpty else {
            return nil
        }
        self.compounds = compounds
        childCombinators = child
    }

    /// `rect.a.b#c`, `.a`, `#c`, `*`; nil for pseudo-classes, attribute selectors and anything
    /// else this cascade does not read.
    static func compound(_ text: String) -> Compound? {
        guard !text.contains(where: { ":[]+~()".contains($0) }) else {
            return nil
        }
        var compound = Compound()
        var current = ""
        var kind: Character = "e"
        func flush() {
            switch kind {
            case ".": compound.classes.append(current)
            case "#": compound.id = current
            default: compound.element = current.isEmpty || current == "*" ? nil : current
            }
        }
        for character in text {
            if character == "." || character == "#" {
                flush()
                kind = character
                current = ""
            } else {
                current.append(character)
            }
        }
        flush()
        return compound
    }

    /// Ids, classes and element names weighted 10000 : 100 : 1.
    var specificity: Int {
        compounds.reduce(0) { $0 + ($1.id == nil ? 0 : 10_000) + $1.classes.count * 100 + ($1.element == nil ? 0 : 1) }
    }

    func matches(_ element: SVGImportElement) -> Bool {
        match(compounds.count - 1, element)
    }

    private func match(_ index: Int, _ element: SVGImportElement) -> Bool {
        guard compounds[index].matches(element) else {
            return false
        }
        if index == 0 {
            return true
        }
        if childCombinators[index - 1] {
            return element.parent.map { match(index - 1, $0) } ?? false
        }
        var ancestor = element.parent
        while let candidate = ancestor {
            if match(index - 1, candidate) {
                return true
            }
            ancestor = candidate.parent
        }
        return false
    }
}
