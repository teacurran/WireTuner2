// FONT-019: the feature-file grammar subset (opentype-features.adoc, "The Features editor"; Adobe's
// OpenType Feature File Specification): a lexer and a recovering parser from `.fea` text to a
// syntax tree with a line and column on every node.  The checker, the compiler and *Rename in
// feature file* share it.  Supported: `languagesystem`, glyph classes (named, bracketed, ranges),
// `markClass`, `feature` and `lookup` blocks (`useExtension` accepted), `script`, `language`,
// `lookupflag` (the named flags), `lookup` references, `subtable`, single, multiple, alternate,
// ligature and chaining contextual substitutions (`ignore sub` too), single, pair (`enum` too),
// mark-to-base and mark-to-mark positioning, chaining contextual positioning with named lookups,
// and `table GDEF { GlyphClassDef … }`.  Anything else is reported where it stands and skipped.

/// A place in the feature text: 1-based line and column (columns count Unicode scalars).
public struct FeatureLocation: Hashable, Sendable, Comparable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.line, a.column) < (b.line, b.column)
    }
}

/// A token of the feature text.
struct FeatureToken: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A glyph name or keyword; `escaped` when written `\name` (always a glyph name).
        case name(String, escaped: Bool)
        /// `@name`.
        case className(String)
        case number(Int)
        case string(String)
        /// One of `{ } [ ] ( ) < > ; , = ' -`, or any other character the grammar has no use for.
        case symbol(Character)
    }

    var kind: Kind
    var location: FeatureLocation
    /// Offset of the token's first scalar in the text, and its length in scalars.
    var offset: Int
    var length: Int
}

enum FeatureLexer {
    static let nameStart: Set<Unicode.Scalar> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_.".unicodeScalars)
    static let nameBody: Set<Unicode.Scalar> = nameStart.union("0123456789-*+~^".unicodeScalars)
    static let digits: Set<Unicode.Scalar> = Set("0123456789".unicodeScalars)

    /// The tokens of `text`, comments and whitespace dropped.
    static func tokens(_ text: String) -> [FeatureToken] {
        let scalars = Array(text.unicodeScalars)
        var result: [FeatureToken] = []
        var index = 0
        var line = 1
        var lineStart = 0
        func location(_ at: Int) -> FeatureLocation { FeatureLocation(line: line, column: at - lineStart + 1) }
        func scanName(from start: Int) -> Int {
            var end = start
            while end < scalars.count, nameBody.contains(scalars[end]) { end += 1 }
            return end
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\n" {
                index += 1
                line += 1
                lineStart = index
            } else if scalar == "#" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else if scalar.properties.isWhitespace || scalar.value < 0x20 {
                index += 1
            } else if nameStart.contains(scalar) || digits.contains(scalar) && !isNumber(scalars, index) {
                let end = scanName(from: index)
                result.append(FeatureToken(kind: .name(String(String.UnicodeScalarView(scalars[index..<end])), escaped: false), location: location(index),
                                           offset: index, length: end - index))
                index = end
            } else if isNumber(scalars, index) {
                var end = index + 1
                while end < scalars.count, digits.contains(scalars[end]) { end += 1 }
                let value = Int(String(String.UnicodeScalarView(scalars[index..<end]))) ?? 0
                result.append(FeatureToken(kind: .number(value), location: location(index), offset: index, length: end - index))
                index = end
            } else if (scalar == "@" || scalar == "\\"), index + 1 < scalars.count, nameStart.contains(scalars[index + 1]) || digits.contains(scalars[index + 1]) {
                let end = scanName(from: index + 1)
                let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                result.append(FeatureToken(kind: scalar == "@" ? .className(name) : .name(name, escaped: true), location: location(index),
                                           offset: index, length: end - index))
                index = end
            } else if scalar == "\"" {
                var end = index + 1
                while end < scalars.count, scalars[end] != "\"" { end += 1 }
                let string = String(String.UnicodeScalarView(scalars[(index + 1)..<min(end, scalars.count)]))
                result.append(FeatureToken(kind: .string(string), location: location(index), offset: index, length: min(end + 1, scalars.count) - index))
                // A string may span lines.
                for position in index..<min(end, scalars.count) where scalars[position] == "\n" {
                    line += 1
                    lineStart = position + 1
                }
                index = min(end + 1, scalars.count)
            } else {
                result.append(FeatureToken(kind: .symbol(Character(scalar)), location: location(index), offset: index, length: 1))
                index += 1
            }
        }
        return result
    }

    /// Whether a number starts at `index`: digits (not followed by name characters), or `-` then
    /// digits.
    static func isNumber(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
        var start = index
        if scalars[index] == "-" { start += 1 }
        guard start < scalars.count, digits.contains(scalars[start]) else { return false }
        var end = start
        while end < scalars.count, digits.contains(scalars[end]) { end += 1 }
        return end == scalars.count || !nameBody.contains(scalars[end]) || scalars[end] == "-"
    }
}

/// One member of a glyph class as written.
enum FeatureGlyphItem: Hashable, Sendable {
    case glyph(String, FeatureLocation)
    case className(String, FeatureLocation)
    /// `first - last` (or `a-z` read as one token that is not a glyph name).
    case range(String, String, FeatureLocation)
}

/// A glyph or class as written: a single glyph, `@class`, or `[ … ]`.
struct FeatureGlyphs: Hashable, Sendable {
    var items: [FeatureGlyphItem]
    /// `@class` or brackets: a class even with one member.
    var isClass: Bool
    var location: FeatureLocation
}

/// `<anchor x y>`, nil for `<anchor NULL>`.
struct FeatureAnchor: Hashable, Sendable {
    var x: Int
    var y: Int
}

/// A value record: placement and advance adjustments.
struct FeatureValue: Hashable, Sendable {
    var xPlacement = 0
    var yPlacement = 0
    var xAdvance = 0
    var yAdvance = 0

    /// The OpenType ValueFormat bits of the non-zero fields.
    var format: Int {
        (xPlacement != 0 ? 1 : 0) | (yPlacement != 0 ? 2 : 0) | (xAdvance != 0 ? 4 : 0) | (yAdvance != 0 ? 8 : 0)
    }
}

/// One element of a rule's glyph sequence: a glyph or class, marked (`'`) or not, with the
/// lookups named after it.
struct FeatureElement: Hashable, Sendable {
    var glyphs: FeatureGlyphs
    var marked: Bool
    var lookups: [String]
    /// A value record written after the element (single and pair positioning).
    var value: FeatureValue?
}

/// A statement of the feature file.
indirect enum FeatureStatement: Hashable, Sendable {
    case languageSystem(script: String, language: String, FeatureLocation)
    case classDefinition(name: String, FeatureGlyphs, FeatureLocation)
    case markClass(FeatureGlyphs, FeatureAnchor, name: String, FeatureLocation)
    case feature(tag: String, [FeatureStatement], FeatureLocation)
    case lookup(name: String, [FeatureStatement], FeatureLocation)
    case lookupReference(String, FeatureLocation)
    case script(String, FeatureLocation)
    case language(String, excludeDefault: Bool, FeatureLocation)
    case lookupFlag(Int, FeatureLocation)
    case subtable(FeatureLocation)
    /// `sub`: `input` with `by` replacements, or `from` alternates; `ignore` rules carry no
    /// replacement.
    case substitute(FeatureSubstitution)
    case position(FeaturePosition)
    /// `table GDEF { GlyphClassDef base, ligature, mark, component; } GDEF;`.
    case glyphClassDefinition([FeatureGlyphs?], FeatureLocation)
}

struct FeatureSubstitution: Hashable, Sendable {
    var elements: [FeatureElement]
    var replacement: [FeatureGlyphs]
    var alternates: FeatureGlyphs?
    var ignore: Bool
    var location: FeatureLocation

    var isContextual: Bool { ignore || elements.contains { $0.marked } }
}

/// `<anchor x y> mark @class` of a mark attachment rule (nil anchor: `<anchor NULL>`).
struct FeatureAttachment: Hashable, Sendable {
    var anchor: FeatureAnchor?
    var markClass: String
}

struct FeaturePosition: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Single or pair positioning, or a contextual rule when an element is marked.
        case sequence(enumerated: Bool)
        /// `pos base` / `pos mark`: the attaching glyphs and their (anchor, mark class) pairs.
        case markToBase(FeatureGlyphs, [FeatureAttachment])
        case markToMark(FeatureGlyphs, [FeatureAttachment])
    }

    var kind: Kind
    var elements: [FeatureElement]
    var ignore: Bool
    var location: FeatureLocation

    var isContextual: Bool { ignore || elements.contains { $0.marked } }
}

/// A problem found while reading or checking feature text.
public struct FeatureIssue: Hashable, Sendable {
    public enum Severity: Hashable, Sendable {
        case error, warning
    }

    public enum Kind: Hashable, Sendable {
        /// The text does not parse.
        case syntax
        /// A construct outside the supported subset.
        case unsupported
        /// A glyph name that is not in the font.
        case unknownGlyph
        /// A class, mark class or lookup used before (or without) its definition.
        case unknownName
        /// A name defined twice.
        case duplicate
        /// A feature the user's text defines that is also generated (the two are combined).
        case generated
        /// A class named with the generator's reserved `kern1.` / `kern2.` prefix.
        case reservedPrefix
        /// A rule the compiler cannot build (mismatched class sizes, a glyph in two mark classes …).
        case invalidRule
    }

    public var severity: Severity
    public var kind: Kind
    public var message: String
    public var location: FeatureLocation
    /// The glyph or class name concerned (unknown names, for the editor's underline).
    public var name: String?
    /// The nearest glyph name in the font, for an unknown glyph's tooltip.
    public var suggestion: String?

    public init(_ severity: Severity, _ kind: Kind, _ message: String, at location: FeatureLocation, name: String? = nil, suggestion: String? = nil) {
        self.severity = severity
        self.kind = kind
        self.message = message
        self.location = location
        self.name = name
        self.suggestion = suggestion
    }
}

/// The parser: statements plus the syntax issues, recovering at the next `;` or block end.
struct FeatureParser {
    private let tokens: [FeatureToken]
    private var index = 0
    private(set) var issues: [FeatureIssue] = []
    private let end: FeatureLocation

    struct Failure: Error {}

    static let substituteKeywords: Set<String> = ["sub", "substitute"]
    static let positionKeywords: Set<String> = ["pos", "position"]
    static let lookupFlagBits: [String: Int] = ["RightToLeft": 1, "IgnoreBaseGlyphs": 2, "IgnoreLigatures": 4, "IgnoreMarks": 8]
    static let unsupportedStatements: Set<String> = [
        "rsub", "reversesub", "featureNames", "parameters", "sizemenuname", "cvParameters", "anonymous", "anon", "valueRecordDef",
        "anchorDef", "include",
    ]
    /// Statements valid only at the top level or only inside blocks.
    static let placedStatements: Set<String> = [
        "languagesystem", "feature", "table", "script", "language", "lookupflag", "subtable", "ignore", "enum", "enumerate",
    ]

    init(_ text: String) {
        tokens = FeatureLexer.tokens(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        end = FeatureLocation(line: lines.count, column: (lines.last?.unicodeScalars.count ?? 0) + 1)
    }

    /// Parses the whole text.
    static func parse(_ text: String) -> (statements: [FeatureStatement], issues: [FeatureIssue], tokens: [FeatureToken]) {
        var parser = FeatureParser(text)
        let statements = parser.statements(topLevel: true)
        return (statements, parser.issues, parser.tokens)
    }

    // MARK: Tokens

    private var current: FeatureToken? { index < tokens.count ? tokens[index] : nil }
    private var location: FeatureLocation { current?.location ?? end }

    private func isSymbol(_ character: Character, at offset: Int = 0) -> Bool {
        guard index + offset < tokens.count, case .symbol(let found) = tokens[index + offset].kind else { return false }
        return found == character
    }

    /// The unescaped keyword at the cursor, if any.
    private func keyword(at offset: Int = 0) -> String? {
        guard index + offset < tokens.count, case .name(let name, false) = tokens[index + offset].kind else { return nil }
        return name
    }

    private mutating func fail(_ message: String, at location: FeatureLocation? = nil, kind: FeatureIssue.Kind = .syntax) -> Failure {
        issues.append(FeatureIssue(.error, kind, message, at: location ?? self.location))
        return Failure()
    }

    private mutating func expect(_ character: Character) throws {
        guard isSymbol(character) else { throw fail("Expected '\(character)'\(describeCurrent).") }
        index += 1
    }

    private var describeCurrent: String {
        guard let current else { return " at the end of the file" }
        switch current.kind {
        case .name(let name, _): return " before '\(name)'"
        case .className(let name): return " before '@\(name)'"
        case .number(let value): return " before '\(value)'"
        case .string: return " before a string"
        case .symbol(let character): return " before '\(character)'"
        }
    }

    private mutating func name(_ what: String) throws -> String {
        guard let current, case .name(let name, _) = current.kind else { throw fail("Expected \(what)\(describeCurrent).") }
        index += 1
        return name
    }

    private mutating func number() throws -> Int {
        guard let current, case .number(let value) = current.kind else { throw fail("Expected a number\(describeCurrent).") }
        index += 1
        return value
    }

    private mutating func className() throws -> String {
        guard let current, case .className(let name) = current.kind else { throw fail("Expected a class name (@name)\(describeCurrent).") }
        index += 1
        return name
    }

    /// Skips to just after the next `;` at this depth, or to a `}` that closes the enclosing
    /// block (left in place).
    private mutating func recover() {
        var depth = 0
        while let current {
            if case .symbol(let character) = current.kind {
                if character == "{" { depth += 1 }
                if character == "}" {
                    if depth == 0 { return }
                    depth -= 1
                    // A block closed by recovery: skip its `} tag;` tail.
                    index += 1
                    if depth == 0 {
                        if keyword() != nil { index += 1 }
                        if isSymbol(";") { index += 1 }
                        return
                    }
                    continue
                }
                if character == ";" && depth == 0 {
                    index += 1
                    return
                }
            }
            index += 1
        }
    }

    // MARK: Statements

    private mutating func statements(topLevel: Bool) -> [FeatureStatement] {
        var result: [FeatureStatement] = []
        while current != nil {
            if isSymbol("}") {
                if topLevel {
                    _ = fail("Unexpected '}'.")
                    index += 1
                    continue
                }
                return result
            }
            if isSymbol(";") {
                index += 1
                continue
            }
            do {
                if let statement = try statement(topLevel: topLevel) { result.append(statement) }
            } catch {
                recover()
            }
        }
        if !topLevel { _ = fail("Missing '}' at the end of the file.") }
        return result
    }

    private mutating func statement(topLevel: Bool) throws -> FeatureStatement? {
        let at = location
        if case .className(let name)? = current?.kind {
            index += 1
            try expect("=")
            let glyphs = try glyphClass()
            try expect(";")
            return .classDefinition(name: name, glyphs, at)
        }
        guard let word = keyword() else { throw fail("Expected a statement\(describeCurrent).") }
        switch word {
        case "languagesystem" where topLevel:
            index += 1
            let script = try name("a script tag")
            let language = try name("a language tag")
            try expect(";")
            return .languageSystem(script: script, language: language, at)
        case "feature" where topLevel:
            index += 1
            let tag = try name("a feature tag")
            guard tag.utf8.count <= 4 else { throw fail("Feature tags have at most four characters: '\(tag)'.", at: at) }
            if keyword() == "useExtension" { index += 1 }
            try expect("{")
            let body = statements(topLevel: false)
            try blockEnd(tag, at: at)
            return .feature(tag: tag, body, at)
        case "lookup":
            index += 1
            let name = try name("a lookup name")
            if isSymbol(";") {
                index += 1
                guard !topLevel else {
                    _ = fail("A lookup reference belongs inside a feature.", at: at)
                    return nil
                }
                return .lookupReference(name, at)
            }
            if keyword() == "useExtension" { index += 1 }
            try expect("{")
            let body = statements(topLevel: false)
            try blockEnd(name, at: at)
            return .lookup(name: name, body, at)
        case "markClass":
            index += 1
            let glyphs = try glyphClass()
            guard let anchor = try anchor() else { throw fail("A mark class needs an anchor, not NULL.", at: at) }
            let name = try className()
            try expect(";")
            return .markClass(glyphs, anchor, name: name, at)
        case "table" where topLevel:
            index += 1
            let tag = try name("a table tag")
            guard tag == "GDEF" else {
                // Skip the block to its end.
                _ = fail("The \(tag) table block is not supported.", at: at, kind: .unsupported)
                if isSymbol("{") {
                    var depth = 0
                    while let token = current {
                        if case .symbol("{") = token.kind { depth += 1 }
                        if case .symbol("}") = token.kind {
                            depth -= 1
                            if depth == 0 {
                                index += 1
                                break
                            }
                        }
                        index += 1
                    }
                    if current != nil { index += 1 }
                    if isSymbol(";") { index += 1 }
                }
                return nil
            }
            try expect("{")
            var classes: [FeatureGlyphs?] = []
            let classAt = location
            while !isSymbol("}") {
                guard keyword() == "GlyphClassDef" else { throw fail("Only GlyphClassDef is supported in the GDEF table.", kind: .unsupported) }
                index += 1
                classes = []
                for position in 0..<4 {
                    if isSymbol(",") || isSymbol(";") {
                        classes.append(nil)
                    } else {
                        classes.append(try glyphClass())
                    }
                    if position < 3 { try expect(",") }
                }
                try expect(";")
            }
            index += 1
            guard keyword() == "GDEF" else { throw fail("Expected 'GDEF' after the table block\(describeCurrent).") }
            index += 1
            try expect(";")
            return .glyphClassDefinition(classes, classAt)
        case "script" where !topLevel:
            index += 1
            let tag = try name("a script tag")
            try expect(";")
            return .script(tag, at)
        case "language" where !topLevel:
            index += 1
            let tag = try name("a language tag")
            var exclude = false
            while let word = keyword(), word != "" {
                if ["exclude_dflt", "excludeDFLT"].contains(word) {
                    exclude = true
                } else if !["include_dflt", "includeDFLT"].contains(word) {
                    throw fail("'\(word)' is not supported in a language statement.", kind: .unsupported)
                }
                index += 1
            }
            try expect(";")
            return .language(tag, excludeDefault: exclude, at)
        case "lookupflag" where !topLevel:
            index += 1
            var flags = 0
            if case .number(let value)? = current?.kind {
                index += 1
                flags = value
            } else {
                while let word = keyword() {
                    guard let bit = Self.lookupFlagBits[word] else { throw fail("The lookup flag '\(word)' is not supported.", kind: .unsupported) }
                    flags |= bit
                    index += 1
                }
            }
            guard (0...15).contains(flags) else { throw fail("Only the RightToLeft, IgnoreBaseGlyphs, IgnoreLigatures and IgnoreMarks flags are supported.", at: at, kind: .unsupported) }
            try expect(";")
            return .lookupFlag(flags, at)
        case "subtable" where !topLevel:
            index += 1
            try expect(";")
            return .subtable(at)
        case "ignore" where !topLevel:
            index += 1
            if let next = keyword(), Self.substituteKeywords.contains(next) {
                index += 1
                return .substitute(try substitution(at: at, ignore: true))
            }
            if let next = keyword(), Self.positionKeywords.contains(next) {
                index += 1
                return .position(try position(at: at, ignore: true, enumerated: false))
            }
            throw fail("Expected 'sub' or 'pos' after 'ignore'\(describeCurrent).")
        case _ where Self.substituteKeywords.contains(word) && !topLevel:
            index += 1
            return .substitute(try substitution(at: at, ignore: false))
        case _ where Self.positionKeywords.contains(word) && !topLevel:
            index += 1
            return .position(try position(at: at, ignore: false, enumerated: false))
        case "enum", "enumerate":
            guard !topLevel else { break }
            index += 1
            guard let next = keyword(), Self.positionKeywords.contains(next) else { throw fail("Expected 'pos' after '\(word)'\(describeCurrent).") }
            index += 1
            return .position(try position(at: at, ignore: false, enumerated: true))
        default:
            break
        }
        if Self.unsupportedStatements.contains(word) { throw fail("'\(word)' is not supported.", at: at, kind: .unsupported) }
        if Self.placedStatements.contains(word) || Self.substituteKeywords.union(Self.positionKeywords).contains(word) {
            throw fail("'\(word)' is not allowed \(topLevel ? "outside a feature or lookup block" : "inside a block").", at: at)
        }
        throw fail("Unknown statement '\(word)'.", at: at)
    }

    /// `} name;` closing a block opened as `name`.
    private mutating func blockEnd(_ name: String, at: FeatureLocation) throws {
        try expect("}")
        let closing = location
        let found = try self.name("'\(name)' after '}'")
        guard found == name else { throw fail("The block opened as '\(name)' is closed as '\(found)'.", at: closing) }
        try expect(";")
    }

    // MARK: Glyphs

    /// A glyph, `@class` or `[ … ]`.
    private mutating func glyphClass() throws -> FeatureGlyphs {
        let at = location
        guard let current else { throw fail("Expected a glyph or class at the end of the file.") }
        switch current.kind {
        case .name(let name, _):
            index += 1
            return FeatureGlyphs(items: [.glyph(name, at)], isClass: false, location: at)
        case .className(let name):
            index += 1
            return FeatureGlyphs(items: [.className(name, at)], isClass: true, location: at)
        case .symbol("["):
            index += 1
            var items: [FeatureGlyphItem] = []
            while !isSymbol("]") {
                guard let token = self.current else { throw fail("Missing ']' at the end of the file.") }
                switch token.kind {
                case .name(let name, _):
                    index += 1
                    if isSymbol("-"), index + 1 < tokens.count, case .name(let last, _) = tokens[index + 1].kind {
                        index += 2
                        items.append(.range(name, last, token.location))
                    } else {
                        items.append(.glyph(name, token.location))
                    }
                case .className(let name):
                    index += 1
                    items.append(.className(name, token.location))
                default:
                    throw fail("Expected a glyph name or class in the brackets\(describeCurrent).")
                }
            }
            index += 1
            guard !items.isEmpty else { throw fail("An empty glyph class.", at: at) }
            return FeatureGlyphs(items: items, isClass: true, location: at)
        default:
            throw fail("Expected a glyph or class\(describeCurrent).")
        }
    }

    private var atNumber: Bool {
        if case .number? = current?.kind { return true }
        return false
    }

    private var startsGlyphs: Bool {
        guard let current else { return false }
        switch current.kind {
        case .name(let name, let escaped): return escaped || !["by", "from", "lookup", "mark"].contains(name)
        case .className: return true
        case .symbol("["): return true
        default: return false
        }
    }

    /// Elements up to `by`, `from`, `;` or a value record, each with its mark and lookups.
    private mutating func elements(allowValues: Bool) throws -> [FeatureElement] {
        var result: [FeatureElement] = []
        while startsGlyphs {
            let glyphs = try glyphClass()
            var element = FeatureElement(glyphs: glyphs, marked: false, lookups: [], value: nil)
            if isSymbol("'") {
                index += 1
                element.marked = true
            }
            while keyword() == "lookup" {
                index += 1
                element.lookups.append(try name("a lookup name"))
            }
            if allowValues, isSymbol("<") || atNumber {
                element.value = try valueRecord()
            }
            result.append(element)
        }
        return result
    }

    private mutating func substitution(at: FeatureLocation, ignore: Bool) throws -> FeatureSubstitution {
        let elements = try elements(allowValues: false)
        guard !elements.isEmpty else { throw fail("Expected glyphs after 'sub'\(describeCurrent).") }
        var rule = FeatureSubstitution(elements: elements, replacement: [], alternates: nil, ignore: ignore, location: at)
        if ignore {
            guard elements.contains(where: \.marked) else { throw fail("An ignore rule needs a marked glyph (').", at: at) }
            try expect(";")
            return rule
        }
        if keyword() == "by" {
            index += 1
            if keyword() == "NULL" {
                throw fail("Glyph deletion (by NULL) is not supported.", kind: .unsupported)
            }
            while startsGlyphs { rule.replacement.append(try glyphClass()) }
            guard !rule.replacement.isEmpty else { throw fail("Expected replacement glyphs after 'by'\(describeCurrent).") }
        } else if keyword() == "from" {
            index += 1
            rule.alternates = try glyphClass()
        } else if !elements.contains(where: { !$0.lookups.isEmpty }) {
            throw fail("Expected 'by' or 'from'\(describeCurrent).")
        }
        try expect(";")
        return rule
    }

    private mutating func position(at: FeatureLocation, ignore: Bool, enumerated: Bool) throws -> FeaturePosition {
        if !ignore, let word = keyword(), ["base", "mark", "ligature", "cursive"].contains(word) {
            index += 1
            guard word == "base" || word == "mark" else { throw fail("'pos \(word)' is not supported.", at: at, kind: .unsupported) }
            let glyphs = try glyphClass()
            var attachments: [FeatureAttachment] = []
            while isSymbol("<") {
                let anchor = try self.anchor()
                guard keyword() == "mark" else { throw fail("Expected 'mark' after the anchor\(describeCurrent).") }
                index += 1
                attachments.append(FeatureAttachment(anchor: anchor, markClass: try className()))
            }
            guard !attachments.isEmpty else { throw fail("Expected '<anchor x y> mark @class'\(describeCurrent).") }
            try expect(";")
            return FeaturePosition(kind: word == "base" ? .markToBase(glyphs, attachments) : .markToMark(glyphs, attachments), elements: [],
                                   ignore: false, location: at)
        }
        var elements = try elements(allowValues: !ignore)
        guard !elements.isEmpty else { throw fail("Expected glyphs after 'pos'\(describeCurrent).") }
        // `pos a b -10;`: the value after the last element belongs to the first (pair kerning).
        if !ignore, elements.count == 2, !elements.contains(where: \.marked), elements[0].value == nil, let value = elements[1].value {
            elements[0].value = value
            elements[1].value = nil
        }
        if ignore, !elements.contains(where: \.marked) { throw fail("An ignore rule needs a marked glyph (').", at: at) }
        try expect(";")
        return FeaturePosition(kind: .sequence(enumerated: enumerated), elements: elements, ignore: ignore, location: at)
    }

    /// `<anchor x y>` or `<anchor NULL>` (nil).
    private mutating func anchor() throws -> FeatureAnchor? {
        try expect("<")
        guard keyword() == "anchor" else { throw fail("Expected 'anchor'\(describeCurrent).") }
        index += 1
        if keyword() == "NULL" {
            index += 1
            try expect(">")
            return nil
        }
        let x = try number(), y = try number()
        if !isSymbol(">") { throw fail("Only '<anchor x y>' anchors are supported.", kind: .unsupported) }
        index += 1
        return FeatureAnchor(x: x, y: y)
    }

    /// A number (x advance) or `<xPlacement yPlacement xAdvance yAdvance>` / `<NULL>`.
    private mutating func valueRecord() throws -> FeatureValue {
        if case .number(let value)? = current?.kind {
            index += 1
            return FeatureValue(xAdvance: value)
        }
        try expect("<")
        if keyword() == "NULL" {
            index += 1
            try expect(">")
            return FeatureValue()
        }
        let first = try number()
        if isSymbol(">") {
            index += 1
            return FeatureValue(xAdvance: first)
        }
        let value = FeatureValue(xPlacement: first, yPlacement: try number(), xAdvance: try number(), yAdvance: try number())
        if !isSymbol(">") { throw fail("Only four-number value records are supported.", kind: .unsupported) }
        index += 1
        return value
    }
}
