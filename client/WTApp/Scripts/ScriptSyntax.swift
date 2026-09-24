import AppKit
import Foundation
import WTModel

/// JavaScript syntax coloring for the Script Editor (scripting.adoc, "Script Editor panel"): the
/// ranges of comments, strings, numbers and keywords, found with one scan so a comment's or a
/// string's contents are never colored as code.
enum ScriptSyntax {
    enum Token: Equatable {
        case comment, string, number, keyword
    }

    static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends",
        "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "super", "switch",
        "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "yield",
    ]

    /// The colored ranges of `text` (UTF-16 ranges, as `NSTextStorage` takes them).
    static func tokens(in text: String) -> [(range: NSRange, token: Token)] {
        let units = Array(text.utf16)
        var result: [(NSRange, Token)] = []
        var index = 0
        func isIdentifier(_ unit: UInt16) -> Bool {
            (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24
        }
        while index < units.count {
            let unit = units[index]
            let start = index
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2F {
                while index < units.count, units[index] != 0x0A { index += 1 }
                result.append((NSRange(location: start, length: index - start), .comment))
            } else if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                index += 2
                while index < units.count, !(units[index] == 0x2F && units[index - 1] == 0x2A && index - 1 > start + 1) { index += 1 }
                index = min(index + 1, units.count)
                result.append((NSRange(location: start, length: index - start), .comment))
            } else if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                index += 1
                while index < units.count, units[index] != unit {
                    if units[index] == 0x5C { index += 1 }
                    if unit != 0x60, index < units.count, units[index] == 0x0A { break }
                    index += 1
                }
                index = min(index, units.count)
                if index < units.count, units[index] == unit { index += 1 }
                result.append((NSRange(location: start, length: index - start), .string))
            } else if unit >= 0x30, unit <= 0x39, start == 0 || !isIdentifier(units[start - 1]) {
                while index < units.count, isIdentifier(units[index]) || units[index] == 0x2E { index += 1 }
                result.append((NSRange(location: start, length: index - start), .number))
            } else if isIdentifier(unit) {
                while index < units.count, isIdentifier(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                if keywords.contains(word) { result.append((NSRange(location: start, length: index - start), .keyword)) }
            } else {
                index += 1
            }
        }
        return result
    }

    static func color(_ token: Token) -> NSColor {
        switch token {
        case .comment: .systemGreen
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemPurple
        }
    }

    /// Colors `storage` (the whole text).
    @MainActor
    static func highlight(_ storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        for (range, token) in tokens(in: storage.string) where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(token), range: range)
        }
        storage.endEditing()
    }

    /// The UTF-16 range of 1-based line `line` in `text` (nil past the end).
    static func range(ofLine line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let string = text as NSString
        var location = 0
        for _ in 1..<line {
            let found = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound else { return nil }
            location = NSMaxRange(found)
        }
        return string.lineRange(for: NSRange(location: location, length: 0))
    }
}

/// Completion for the `wt` API from `wiretuner.d.ts` (the same file an external editor reads): the
/// members of each interface and object type, keyed by the expression they follow (`wt`,
/// `wt.document`, `wt.ui` ...), each with its doc comment.
struct ScriptCompletions {
    struct Member: Hashable {
        let name: String
        let doc: String
    }

    /// Members by scope: an interface's name, or `wt` / `wt.<const>` for the namespace.
    private(set) var scopes: [String: [Member]] = [:]
    /// The interface a namespace constant has (`wt.document` → `Document`).
    private(set) var types: [String: String] = [:]

    init(declarations: String = ScriptTypings.declarations) {
        var stack: [String] = []
        var doc = ""
        func add(_ name: String, to scope: String) {
            if !(scopes[scope]?.contains { $0.name == name } ?? false) { scopes[scope, default: []].append(Member(name: name, doc: doc)) }
            doc = ""
        }
        for raw in declarations.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/**") {
                doc = line.replacingOccurrences(of: "/**", with: "").replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("declare namespace ") {
                stack.append(String(line.dropFirst("declare namespace ".count).prefix { $0 != " " }))
            } else if let name = Self.capture(line, "^interface (\\w+)") {
                if line.contains("}") {
                    for member in Self.inlineMembers(line) { add(member, to: name) }
                } else {
                    stack.append(name)
                }
            } else if let name = Self.capture(line, "^const (\\w+): \\{$"), let namespace = stack.last {
                add(name, to: namespace)
                stack.append("\(namespace).\(name)")
            } else if let name = Self.capture(line, "^const (\\w+): "), let namespace = stack.last {
                add(name, to: namespace)
                types["\(namespace).\(name)"] = Self.capture(line, "^const \\w+: (\\w+)")
            } else if let name = Self.capture(line, "^function (\\w+)"), let namespace = stack.last {
                add(name, to: namespace)
            } else if line == "}" || line == "};" {
                _ = stack.popLast()
            } else if let scope = stack.last, stack.count > 1, let name = Self.capture(line, "^(?:readonly )?(\\w+)\\??\\s*[(<:]") {
                add(name, to: scope)
            }
        }
    }

    private static func capture(_ line: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func inlineMembers(_ line: String) -> [String] {
        guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close else { return [] }
        return line[line.index(after: open)..<close].split(separator: ";").compactMap { capture($0.trimmingCharacters(in: .whitespaces), "^(?:readonly )?(\\w+)") }
    }

    /// The members that can follow `expression` (`wt.document`): its constant's interface, its
    /// object type, or an object's members for anything else ending in a dot.
    func members(after expression: String) -> [Member] {
        if let type = types[expression], let members = scopes[type] { return members }
        if let members = scopes[expression] { return members }
        return scopes["WTObject"] ?? []
    }

    /// The completions for the text before the caret: the expression before the last dot and the
    /// partial word after it (`wt.document.cre` → `createRectangle` ...); top level offers `wt`.
    func completions(before prefix: String) -> [Member] {
        let tail = prefix.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }
        let expression = String(tail.reversed())
        guard let dot = expression.lastIndex(of: ".") else {
            return [Member(name: "wt", doc: "The WireTuner scripting API")].filter { $0.name.hasPrefix(expression) && !expression.isEmpty }
        }
        let partial = String(expression[expression.index(after: dot)...])
        return members(after: String(expression[..<dot])).filter { partial.isEmpty || $0.name.hasPrefix(partial) }
    }
}
