import Foundation
import WTCRDT
import WTProto

// DATA-003: record resolution (data-merge.adoc, "Client", "Record resolution").  `RecordSet` is
// the resolved list for a source -- raw records from a parser, the data service or a script,
// with the mapping applied, per-field type coercion, formats and transforms -- and is what
// preview, merge and export all read, so the three cannot disagree.

/// One raw record: column name (or JSONPath, for JSON and HTTP sources) to its value as text.  A
/// column that is missing or null is absent.
public struct DataRecord: Hashable, Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(_ column: String) -> String? { values[column] }
}

/// A field's value in one record, resolved.
public struct DataValue: Hashable, Sendable {
    /// The value after mapping and the transform, before formatting (nil: absent).
    public var raw: String?
    /// What a placeholder, a barcode or a text binding shows: the formatted value, else the raw
    /// text, else "".
    public var text: String
    /// Boolean coercion (`true`, `yes`, `1`, `x`, `on`, any case; anything else is no).
    public var isTrue: Bool

    public init(raw: String?, text: String) {
        self.raw = raw
        self.text = text
        isTrue = raw.map(DataCoercion.isTrue) ?? false
    }
}

/// One row of the merge report (data-merge.adoc, "Finishing options", *Report*): what went wrong
/// with which record (1-based, the record's number in the merge).
public struct MergeIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A text block's text does not fit (after shrink-to-fit, if on).
        case overflow(node: OpID)
        /// An IMAGE field's picture could not be obtained.
        case unfetchableImage(url: String)
        /// A barcode's value cannot be encoded by its symbology.
        case unencodableBarcode(node: OpID)
        /// A DATE value that could not be read (placed as it is).
        case unparsableDate(value: String)
        /// A NUMBER value that could not be read (placed as it is).
        case unparsableNumber(value: String)
        /// A transform threw (the raw value is placed).
        case transformFailed(message: String)
        /// A transform ran past the wall-clock limit and was stopped (the raw value is placed).
        case transformTimeout
        /// A placeholder or binding whose field is missing (deleted, or never defined).
        case missingField(name: String)
        /// A field with no value in this record.
        case emptyField
    }

    public var record: Int
    public var field: String?
    public var kind: Kind

    public init(record: Int, field: String? = nil, kind: Kind) {
        self.record = record
        self.field = field
        self.kind = kind
    }
}

/// The transform hook the DATA-011 runtime implements (`ScriptTransformer`): runs the `script`
/// node's exported `transform(value, record, field)`.  `record` holds the record's raw values by
/// field name.  Throwing `ScriptError.timeout` reports a timeout; any other error a failure.
public protocol FieldTransforming {
    func transform(script: OpID, value: String?, record: [String: String], field: String) throws -> String?
}

/// Parsing and formatting of field values.
public enum DataCoercion {
    /// The Boolean spellings that count as yes.
    public static let truthy: Set<String> = ["true", "yes", "1", "x", "on"]

    public static func isTrue(_ value: String) -> Bool {
        truthy.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// A number read from `text`: plain (`1234.5`, `-3`, `1e3`), else in `locale`'s form
    /// (`1.234,5`).
    public static func number(_ text: String, locale: Locale) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed), value.isFinite { return value }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        return formatter.number(from: trimmed)?.doubleValue
    }

    /// A date read from `text`: ISO 8601 (`2026-09-21`, `2026-09-21T14:30:00Z`, with fractional
    /// seconds or an offset), else the locale's short, medium and long forms.  `dateOnly` is
    /// true for a value without a time (formatted in UTC so the day never shifts).
    public static func date(_ text: String, locale: Locale) -> (date: Date, dateOnly: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if trimmed.count == 10, let date = day.date(from: trimmed) { return (date, true) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return (date, false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return (date, false) }
        let local = DateFormatter()
        local.locale = locale
        local.timeZone = TimeZone(identifier: "UTC")
        local.isLenient = false
        for style in [DateFormatter.Style.short, .medium, .long] {
            local.dateStyle = style
            local.timeStyle = .none
            if let date = local.date(from: trimmed) { return (date, true) }
        }
        return nil
    }

    /// `value` formatted as the NUMBER pattern `pattern` in `locale` (`#,##0.00`, `€#,##0.00`,
    /// `0%`); nil when the value is not a number.  An empty pattern is *As is*.
    public static func formatNumber(_ value: String, pattern: String, locale: Locale) -> String? {
        guard let number = number(value, locale: locale) else { return nil }
        guard !pattern.isEmpty else { return value }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.positiveFormat = pattern
        formatter.negativeFormat = "-" + pattern
        return formatter.string(from: NSNumber(value: number))
    }

    /// `value` formatted as the DATE pattern `pattern` (`d MMMM yyyy`, or *Short*, *Medium*,
    /// *Long*) in `locale`; nil when the value is not a date.  An empty pattern is *As is*.
    public static func formatDate(_ value: String, pattern: String, locale: Locale, timeZone: TimeZone) -> String? {
        guard let (date, dateOnly) = date(value, locale: locale) else { return nil }
        guard !pattern.isEmpty else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = dateOnly ? TimeZone(identifier: "UTC") : timeZone
        switch pattern.lowercased() {
        case "short": formatter.dateStyle = .short
        case "medium": formatter.dateStyle = .medium
        case "long": formatter.dateStyle = .long
        default: formatter.dateFormat = pattern
        }
        return formatter.string(from: date)
    }

    /// The type *Add Fields from Source* guesses from a column's first values: Boolean when every
    /// value is a yes/no spelling, Number when every value is a number, Date when every value is
    /// a date, Image when every value ends in an image extension, Link when every value is an
    /// `http(s)` address, else Text.  Empty values are skipped; a column of none is Text.
    public static func guess(_ values: [String]) -> DataFieldKind {
        let present = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !present.isEmpty else { return .text }
        let posix = Locale(identifier: "en_US_POSIX")
        let images = [".png", ".jpg", ".jpeg", ".gif", ".tif", ".tiff", ".heic", ".webp"]
        if present.allSatisfy({ truthy.contains($0.lowercased()) || ["false", "no", "0", "off"].contains($0.lowercased()) }),
           !present.allSatisfy({ $0 == "0" || $0 == "1" }) {
            return .boolean
        }
        if present.allSatisfy({ Double($0) != nil }) { return .number }
        if present.allSatisfy({ date($0, locale: posix) != nil }) { return .date }
        if present.allSatisfy({ value in images.contains { value.lowercased().hasSuffix($0) } }) { return .image }
        if present.allSatisfy({ $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }) { return .link }
        return .text
    }
}

/// The resolved records of one source (data-merge.adoc, "Record resolution").
public struct RecordSet: Sendable {
    /// One record's values by field id.
    public struct Record: Hashable, Sendable {
        /// 1-based: the record's number in the merge.
        public let number: Int
        public let values: [OpID: DataValue]
        /// The raw values by field name (what a transform sees as `record`).
        public let byName: [String: String]

        /// The value of `field` (an empty value when the record has none).
        public func value(_ field: OpID) -> DataValue {
            values[field] ?? DataValue(raw: nil, text: "")
        }
    }

    public let fields: [DataFieldInfo]
    public let records: [Record]
    /// Coercion and transform problems, in record order.
    public let issues: [MergeIssue]

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }

    /// Resolves `raw` against the fields of `model` through `source`'s mapping: each field reads
    /// its mapped column (or the column of its own name), then its transform (through
    /// `transforms`, when the field names a script), then its type's coercion and format.
    /// `locale` is the merging user's, used where a field's format names none.
    public init(model: DataModel, source: DataSourceInfo?, raw: [DataRecord], locale: Locale = .current, timeZone: TimeZone = .current,
                transforms: (any FieldTransforming)? = nil) {
        fields = model.fields
        var issues: [MergeIssue] = []
        var records: [Record] = []
        records.reserveCapacity(raw.count)
        let paths = model.fields.map { model.path(of: $0, in: source) }
        for (index, record) in raw.enumerated() {
            let number = index + 1
            var byName: [String: String] = [:]
            for (field, path) in zip(model.fields, paths) where !field.name.isEmpty {
                if let value = record[path] { byName[field.name] = value }
            }
            var values: [OpID: DataValue] = [:]
            for (field, path) in zip(model.fields, paths) {
                var value = record[path]
                if let script = field.transform, let transforms {
                    do {
                        value = try transforms.transform(script: script, value: value, record: byName, field: field.name)
                    } catch ScriptError.timeout {
                        issues.append(MergeIssue(record: number, field: field.name, kind: .transformTimeout))
                    } catch {
                        issues.append(MergeIssue(record: number, field: field.name, kind: .transformFailed(message: String(describing: error))))
                    }
                }
                values[field.id] = Self.resolve(value, field: field, record: number, locale: locale, timeZone: timeZone, issues: &issues)
            }
            records.append(Record(number: number, values: values, byName: byName))
        }
        self.records = records
        self.issues = issues
    }

    /// The record at 0-based `index`, clamped (a preview index past the last record reads as
    /// the last record); nil for an empty set.
    public func record(at index: Int) -> Record? {
        guard !records.isEmpty else { return nil }
        return records[min(max(index, 0), records.count - 1)]
    }

    static func resolve(_ raw: String?, field: DataFieldInfo, record: Int, locale defaultLocale: Locale, timeZone: TimeZone,
                        issues: inout [MergeIssue]) -> DataValue {
        guard let raw else { return DataValue(raw: nil, text: "") }
        let locale = field.locale.isEmpty ? defaultLocale : Locale(identifier: field.locale)
        switch field.kind {
        case .number:
            if let text = DataCoercion.formatNumber(raw, pattern: field.pattern, locale: locale) { return DataValue(raw: raw, text: text) }
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(MergeIssue(record: record, field: field.name, kind: .unparsableNumber(value: raw)))
            }
        case .date:
            if let text = DataCoercion.formatDate(raw, pattern: field.pattern, locale: locale, timeZone: timeZone) { return DataValue(raw: raw, text: text) }
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(MergeIssue(record: record, field: field.name, kind: .unparsableDate(value: raw)))
            }
        case .text, .boolean, .image, .link:
            break
        }
        return DataValue(raw: raw, text: raw)
    }

    /// The fields *Add Fields from Source* would create: every column of `raw` (in first-seen
    /// order) that is not a field's name or mapped path, with its type guessed from the first 20
    /// records.  Columns that are not valid field names are cleaned (other characters become
    /// `_`, a leading digit gets `_`).
    public static func suggestedFields(for raw: [DataRecord], columns: [String]? = nil, model: DataModel, source: DataSourceInfo?) -> [AddFields.Field] {
        var order: [String] = columns ?? []
        if columns == nil {
            var seen: Set<String> = []
            for record in raw.prefix(20) {
                for key in record.values.keys.sorted() where seen.insert(key).inserted {
                    order.append(key)
                }
            }
        }
        let taken = Set(model.fields.map { model.path(of: $0, in: source).lowercased() } + model.fields.map { $0.name.lowercased() })
        var names: Set<String> = Set(model.fields.map { $0.name.lowercased() })
        var result: [AddFields.Field] = []
        for column in order where !taken.contains(column.lowercased()) {
            let name = fieldName(for: column)
            guard names.insert(name.lowercased()).inserted else { continue }
            result.append(AddFields.Field(name, kind: DataCoercion.guess(raw.prefix(20).compactMap { $0[column] })))
        }
        return result
    }

    /// A valid field name made from a column name.
    public static func fieldName(for column: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in column.unicodeScalars {
            let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            scalars.append(ok ? scalar : "_")
        }
        var name = String(scalars)
        if name.isEmpty || name.unicodeScalars.first.map({ CharacterSet.decimalDigits.contains($0) }) == true { name = "_" + name }
        return String(name.prefix(DataFieldsPaths.maxName))
    }
}
