// Import options (import-formats.adoc; IMG-008): each importer describes its options as a schema
// the Import sheet renders with a SwiftUI form, so adding a format never touches the sheet.  The
// values are a small keyed dictionary that persists per format (`ImportOptionsStore`), and each
// importer reads them through its typed options struct.

import Foundation

/// One option value.
public enum ImportOptionValue: Hashable, Sendable, Codable {
    case bool(Bool)
    case string(String)
    case number(Double)
}

/// One control of the options sheet.
public struct ImportOptionField: Hashable, Sendable {
    public enum Control: Hashable, Sendable {
        /// A checkbox.
        case toggle
        /// A pop-up menu of `(value, label)` choices.
        case choice([Choice])
        /// A text field; `placeholder` shows while it is empty.
        case text(placeholder: String)
    }

    public struct Choice: Hashable, Sendable {
        public var value: String
        public var label: String

        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    /// The key the value is stored under.
    public var key: String
    public var label: String
    public var help: String
    public var control: Control
    public var defaultValue: ImportOptionValue

    public init(key: String, label: String, help: String = "", control: Control, defaultValue: ImportOptionValue) {
        self.key = key
        self.label = label
        self.help = help
        self.control = control
        self.defaultValue = defaultValue
    }

    /// Whether `value` is one this field can hold.
    public func accepts(_ value: ImportOptionValue) -> Bool {
        switch (control, value) {
        case (.toggle, .bool), (.text, .string):
            return true
        case (.choice(let choices), .string(let string)):
            return choices.contains { $0.value == string }
        default:
            return false
        }
    }
}

/// A format's options.
public struct ImportOptionsSchema: Hashable, Sendable {
    public var fields: [ImportOptionField]

    public init(fields: [ImportOptionField]) {
        self.fields = fields
    }

    /// Whether the sheet shows an btn:[Options…] button.
    public var isEmpty: Bool { fields.isEmpty }

    /// Every field at its default.
    public var defaults: ImportOptionValues {
        ImportOptionValues(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) }))
    }

    /// `values` with unknown keys dropped and missing or invalid ones at their defaults, so a
    /// stored value from an older schema never reaches an importer.
    public func normalized(_ values: ImportOptionValues) -> ImportOptionValues {
        var result = ImportOptionValues()
        for field in fields {
            if let value = values[field.key], field.accepts(value) {
                result[field.key] = value
            } else {
                result[field.key] = field.defaultValue
            }
        }
        return result
    }
}

/// Option values by key.
public struct ImportOptionValues: Hashable, Sendable, Codable {
    public var values: [String: ImportOptionValue]

    public init(_ values: [String: ImportOptionValue] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> ImportOptionValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// The boolean at `key`, or `fallback`.
    public func bool(_ key: String, default fallback: Bool) -> Bool {
        if case .bool(let value) = values[key] {
            return value
        }
        return fallback
    }

    /// The string at `key`, or `fallback`.
    public func string(_ key: String, default fallback: String) -> String {
        if case .string(let value) = values[key] {
            return value
        }
        return fallback
    }
}

/// Where option values persist: `UserDefaults` in the app, a dictionary in tests.
public protocol ImportOptionsStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: ImportOptionsStorage {}

/// Remembers each format's options until they are changed (importing.adoc: "Options are
/// remembered per format"), across launches.
public final class ImportOptionsStore {
    public let storage: any ImportOptionsStorage

    public init(storage: any ImportOptionsStorage = UserDefaults.standard) {
        self.storage = storage
    }

    static func key(_ format: ImportFormat) -> String {
        "WTImportOptions.\(format.rawValue)"
    }

    /// The remembered options of `format`, normalized by `schema`.
    public func options(for format: ImportFormat, schema: ImportOptionsSchema) -> ImportOptionValues {
        guard let data = storage.data(forKey: ImportOptionsStore.key(format)),
              let values = try? JSONDecoder().decode(ImportOptionValues.self, from: data) else {
            return schema.defaults
        }
        return schema.normalized(values)
    }

    /// Remembers `values` for `format`.
    public func save(_ values: ImportOptionValues, for format: ImportFormat) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        storage.set(try? encoder.encode(values), forKey: ImportOptionsStore.key(format))
    }

    /// Forgets `format`'s options.
    public func reset(_ format: ImportFormat) {
        storage.set(nil, forKey: ImportOptionsStore.key(format))
    }
}

// MARK: - Typed options

/// *Text*: keep text editable or convert it to paths (PDF, Illustrator, SVG).
public enum ImportTextHandling: String, Hashable, Sendable, CaseIterable {
    case editable
    case outlines

    static let field = ImportOptionField(
        key: "text", label: "Text",
        help: "Editable text keeps text as text blocks; Convert to paths turns every glyph into a path.",
        control: .choice([.init("editable", "Editable text"), .init("outlines", "Convert to paths")]),
        defaultValue: .string("editable"))

    init(_ values: ImportOptionValues) {
        self = ImportTextHandling(rawValue: values.string("text", default: "editable")) ?? .editable
    }
}

/// A PDF page selection: *All* or a range such as `1`, `2-4`, `1,3,7`.
public struct ImportPageRange: Hashable, Sendable, CustomStringConvertible {
    /// 1-based pages in order, nil for all.
    public var pages: [Int]?

    public static let all = ImportPageRange(pages: nil)

    public init(pages: [Int]?) {
        self.pages = pages
    }

    /// Parses `All`, empty, or comma-separated pages and ranges; nil when malformed.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "all" {
            self = .all
            return
        }
        var pages: [Int] = []
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch bounds.count {
            case 1:
                guard let page = bounds[0], page >= 1 else { return nil }
                pages.append(page)
            case 2:
                guard let from = bounds[0], let to = bounds[1], from >= 1, to >= from else { return nil }
                pages += Array(from...to)
            default:
                return nil
            }
        }
        self.pages = pages
    }

    /// The selected pages of a document with `count` pages; pages past the end are refused.
    public func resolve(pageCount count: Int, name: String) throws -> [Int] {
        guard let pages else {
            return Array(1...max(count, 1)).filter { $0 <= count }
        }
        if let beyond = pages.first(where: { $0 > count }) {
            throw ImportError.invalidOption(name: name, reason: "page \(beyond) is beyond the last page (\(count)).")
        }
        return pages
    }

    public var description: String {
        pages.map { $0.map(String.init).joined(separator: ",") } ?? "All"
    }
}

/// PDF (and PDF-compatible Illustrator) options (import-formats.adoc, "PDF").
public struct PDFImportOptions: Hashable, Sendable {
    public var pages: ImportPageRange
    public var text: ImportTextHandling
    public var importNotes: Bool
    public var importLinks: Bool
    public var keepPageClip: Bool

    public init(pages: ImportPageRange = .all, text: ImportTextHandling = .editable, importNotes: Bool = true, importLinks: Bool = true, keepPageClip: Bool = false) {
        self.pages = pages
        self.text = text
        self.importNotes = importNotes
        self.importLinks = importLinks
        self.keepPageClip = keepPageClip
    }

    public static let schema = ImportOptionsSchema(fields: [
        ImportOptionField(key: "pages", label: "Pages", help: "All, or pages such as 1, 2-4 or 1,3,7.", control: .text(placeholder: "All"), defaultValue: .string("All")),
        ImportTextHandling.field,
        ImportOptionField(key: "importNotes", label: "Import notes", help: "Places comments on the Notes layer as text blocks.", control: .toggle, defaultValue: .bool(true)),
        ImportOptionField(key: "importLinks", label: "Import links", help: "Places link areas on the URLs layer as unfilled rectangles carrying the URL.", control: .toggle, defaultValue: .bool(true)),
        ImportOptionField(key: "keepPageClip", label: "Keep page clip", help: "Wraps each page's content in a clipping group the size of its crop box.", control: .toggle, defaultValue: .bool(false)),
    ])

    /// The options in `values`; a malformed page range is refused naming the file.
    public init(_ values: ImportOptionValues, name: String) throws {
        let text = values.string("pages", default: "All")
        guard let pages = ImportPageRange(parsing: text) else {
            throw ImportError.invalidOption(name: name, reason: "“\(text)” is not a page range.")
        }
        self.init(pages: pages, text: ImportTextHandling(values), importNotes: values.bool("importNotes", default: true), importLinks: values.bool("importLinks", default: true), keepPageClip: values.bool("keepPageClip", default: false))
    }

    public var values: ImportOptionValues {
        ImportOptionValues(["pages": .string(pages.description), "text": .string(text.rawValue), "importNotes": .bool(importNotes), "importLinks": .bool(importLinks), "keepPageClip": .bool(keepPageClip)])
    }
}

/// SVG options (import-formats.adoc, "SVG"; svg-animation.adoc).
public struct SVGImportOptions: Hashable, Sendable {
    /// What happens to a file with animation.
    public enum Animation: String, Hashable, Sendable, CaseIterable {
        /// Animated files are placed, static ones converted.
        case automatic
        /// Always placed as an animation.
        case place
        /// Always converted to objects (the animation is dropped).
        case convert
    }

    public var text: ImportTextHandling
    public var flattenGroups: Bool
    public var animation: Animation

    public init(text: ImportTextHandling = .editable, flattenGroups: Bool = false, animation: Animation = .automatic) {
        self.text = text
        self.flattenGroups = flattenGroups
        self.animation = animation
    }

    public static let schema = ImportOptionsSchema(fields: [
        ImportTextHandling.field,
        ImportOptionField(key: "flattenGroups", label: "Flatten groups", help: "Replaces the file's nested groups with one group around everything.", control: .toggle, defaultValue: .bool(false)),
        ImportOptionField(key: "animation", label: "Animation", help: "Animated files are placed as live objects; static files are converted.", control: .choice([.init("automatic", "Automatic"), .init("place", "Place as animation"), .init("convert", "Convert to objects")]), defaultValue: .string("automatic")),
    ])

    public init(_ values: ImportOptionValues) {
        self.init(text: ImportTextHandling(values), flattenGroups: values.bool("flattenGroups", default: false), animation: Animation(rawValue: values.string("animation", default: "automatic")) ?? .automatic)
    }

    public var values: ImportOptionValues {
        ImportOptionValues(["text": .string(text.rawValue), "flattenGroups": .bool(flattenGroups), "animation": .string(animation.rawValue)])
    }
}

/// DXF options (import-formats.adoc, "AutoCAD DXF").
public struct DXFImportOptions: Hashable, Sendable {
    /// How to read drawing units the file does not state.
    public enum Units: String, Hashable, Sendable, CaseIterable {
        case inches
        case millimeters
        case points

        /// Points per drawing unit.
        public var points: Double {
            switch self {
            case .inches: return 72
            case .millimeters: return 72 / 25.4
            case .points: return 1
            }
        }
    }

    public var importInvisibleAttributes: Bool
    public var whiteStrokesToBlack: Bool
    public var whiteFillsToBlack: Bool
    public var units: Units

    public init(importInvisibleAttributes: Bool = false, whiteStrokesToBlack: Bool = true, whiteFillsToBlack: Bool = true, units: Units = .inches) {
        self.importInvisibleAttributes = importInvisibleAttributes
        self.whiteStrokesToBlack = whiteStrokesToBlack
        self.whiteFillsToBlack = whiteFillsToBlack
        self.units = units
    }

    public static let schema = ImportOptionsSchema(fields: [
        ImportOptionField(key: "invisibleAttributes", label: "Import invisible block attributes", control: .toggle, defaultValue: .bool(false)),
        ImportOptionField(key: "whiteStrokes", label: "Convert white strokes to black", control: .toggle, defaultValue: .bool(true)),
        ImportOptionField(key: "whiteFills", label: "Convert white fills to black", control: .toggle, defaultValue: .bool(true)),
        ImportOptionField(key: "units", label: "Units", help: "How to read the drawing units when the file does not say.", control: .choice([.init("inches", "Inches"), .init("millimeters", "Millimeters"), .init("points", "Points")]), defaultValue: .string("inches")),
    ])

    public init(_ values: ImportOptionValues) {
        self.init(importInvisibleAttributes: values.bool("invisibleAttributes", default: false), whiteStrokesToBlack: values.bool("whiteStrokes", default: true), whiteFillsToBlack: values.bool("whiteFills", default: true), units: Units(rawValue: values.string("units", default: "inches")) ?? .inches)
    }

    public var values: ImportOptionValues {
        ImportOptionValues(["invisibleAttributes": .bool(importInvisibleAttributes), "whiteStrokes": .bool(whiteStrokesToBlack), "whiteFills": .bool(whiteFillsToBlack), "units": .string(units.rawValue)])
    }
}
