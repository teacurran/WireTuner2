import Foundation
import WTCRDT
import WTProto

// IO-011: the Document Info sheet's writes (io/file-info.adoc, "Merge semantics").  `SettingsProps.info`
// (130) is a STRUCT: every scalar is its own LWW register, `keywords` an add-wins SET, `creators` and
// `supplemental_categories` ATOMIC lists.  One change per field commit, labelled "Change Document Info".

/// The document's information as the sheet reads it, with the read-time normalizations.
public struct DocumentInfoValues: Hashable, Sendable {
    public var info: Wiretuner_Doc_V1_DocumentInfo
    /// `keywords`, sorted case-insensitively, duplicates differing only in case collapsed to the first.
    public var keywords: [String]

    public init(_ state: EngineState) {
        var info = state.props(WellKnown.settings).settings.info
        for field in DocumentInfoField.allCases where field.isText {
            info[keyPath: field.textPath] = info[keyPath: field.textPath].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        info.creators = info.creators.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.info = info
        let members = state.store.members(WellKnown.settings, DocumentInfoField.keywordsPath).map { String(decoding: $0, as: UTF8.self) }
        keywords = Self.keywords(members)
    }

    static func keywords(_ members: [String]) -> [String] {
        let trimmed = members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let sorted = trimmed.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
        var seen: Set<String> = []
        return sorted.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The value of a text field.
    public subscript(_ field: DocumentInfoField) -> String { info[keyPath: field.textPath] }
}

/// The sheet's text fields and the lists edited as one field.
public enum DocumentInfoField: UInt32, CaseIterable, Sendable {
    case title = 1, headline = 2, description = 3, category = 5, supplementalCategories = 6
    case creators = 10, creatorJobTitle = 11, credit = 12, source = 13
    case copyrightNotice = 20, copyrightStatus = 21, rightsUsageTerms = 22, webStatement = 23
    case dateCreated = 30, city = 31, state = 32, country = 33, instructions = 34, language = 35

    /// `SettingsProps.info`.
    public static let info = RegisterPath([SettingsFields.kind, 130])
    /// `DocumentInfo.keywords` (SET).
    public static let keywordsPath = info.child(4)

    public var path: RegisterPath { Self.info.child(rawValue) }

    /// Whether the field is one string.
    public var isText: Bool { ![.supplementalCategories, .creators, .copyrightStatus].contains(self) }

    /// The field's IPTC limit in characters (nil: the implementation's cap of 256 or 2,000).
    public var limit: Int {
        switch self {
        case .category: 3
        case .description, .instructions, .rightsUsageTerms: 2000
        case .copyrightNotice: 1024
        case .dateCreated: 32
        case .language: 35
        default: 256
        }
    }

    /// The name in the review sheet ("Document Info · Title").
    public var title: String {
        switch self {
        case .title: "Title"
        case .headline: "Headline"
        case .description: "Description"
        case .category: "Category"
        case .supplementalCategories: "Supplemental categories"
        case .creators: "Creator"
        case .creatorJobTitle: "Creator's job title"
        case .credit: "Credit line"
        case .source: "Source"
        case .copyrightNotice: "Copyright notice"
        case .copyrightStatus: "Copyright status"
        case .rightsUsageTerms: "Rights usage terms"
        case .webStatement: "Web statement of rights"
        case .dateCreated: "Date created"
        case .city: "City"
        case .state: "State/Province"
        case .country: "Country"
        case .instructions: "Instructions"
        case .language: "Language"
        }
    }

    var textPath: WritableKeyPath<Wiretuner_Doc_V1_DocumentInfo, String> {
        switch self {
        case .title: \.title
        case .headline: \.headline
        case .description: \.description_p
        case .category: \.category
        case .creatorJobTitle: \.creatorJobTitle
        case .credit: \.credit
        case .source: \.source
        case .copyrightNotice: \.copyrightNotice
        case .rightsUsageTerms: \.rightsUsageTerms
        case .webStatement: \.webStatement
        case .dateCreated: \.dateCreated
        case .city: \.city
        case .state: \.state
        case .country: \.country
        case .instructions: \.instructions
        case .language: \.language
        case .supplementalCategories, .creators, .copyrightStatus: \.title
        }
    }
}

/// Why a Document Info write was refused.
public enum DocumentInfoError: Error, Equatable, Sendable {
    /// Longer than the field allows.
    case tooLong(DocumentInfoField)
    /// Not a URL (*Web statement of rights*).
    case invalidURL
    case tooMany(DocumentInfoField)
    /// A value of the wrong shape for the field.
    case mismatch(DocumentInfoField)
    /// A keyword longer than 64 characters, or more than 500 keywords.
    case keywords
}

/// One Document Info field's new value; one `SetFields` on the settings node, "Change Document Info".
public struct SetDocumentInfo: Command {
    public enum Value: Hashable, Sendable {
        case text(String)
        case list([String])
        case copyrightStatus(Wiretuner_Doc_V1_CopyrightStatus)
    }

    public var field: DocumentInfoField
    public var value: Value
    public var label: String { "Change Document Info" }

    public init(_ field: DocumentInfoField, _ value: Value) {
        self.field = field
        self.value = value
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var info = Wiretuner_Doc_V1_DocumentInfo()
        switch (field, value) {
        case (.copyrightStatus, .copyrightStatus(let status)):
            info.copyrightStatus = status
        case (.creators, .list(let names)), (.supplementalCategories, .list(let names)):
            let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let (maxItems, maxLength) = field == .creators ? (32, 256) : (3, 32)
            guard cleaned.count <= maxItems else { throw DocumentInfoError.tooMany(field) }
            guard cleaned.allSatisfy({ $0.count <= maxLength }) else { throw DocumentInfoError.tooLong(field) }
            if field == .creators { info.creators = cleaned } else { info.supplementalCategories = cleaned }
        case (_, .text(let text)) where field.isText:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= field.limit else { throw DocumentInfoError.tooLong(field) }
            if field == .webStatement, !trimmed.isEmpty {
                guard let url = URL(string: trimmed), url.scheme != nil else { throw DocumentInfoError.invalidURL }
            }
            info[keyPath: field.textPath] = trimmed
        default:
            throw DocumentInfoError.mismatch(field)
        }
        builder.append(Ops.set(WellKnown.settings, [field.path], values: SettingsFields.values { $0.info = info }))
    }
}

/// Adds and removes keywords (the token field): `SetAdd` / `SetRemove` on the add-wins set, one
/// change labelled "Change Document Info".
public struct SetDocumentKeywords: Command {
    public var added: [String]
    public var removed: [String]
    public var label: String { "Change Document Info" }

    public init(adding added: [String] = [], removing removed: [String] = []) {
        self.added = added
        self.removed = removed
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let add = added.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard add.allSatisfy({ $0.count <= 64 }) else { throw DocumentInfoError.keywords }
        let existing = state.store.members(WellKnown.settings, DocumentInfoField.keywordsPath).map { String(decoding: $0, as: UTF8.self) }
        guard existing.count + add.count <= 500 else { throw DocumentInfoError.keywords }
        if !add.isEmpty {
            builder.append(Ops.setAdd(WellKnown.settings, DocumentInfoField.keywordsPath, values: SettingsFields.values { $0.info.keywords = add }))
        }
        // A removed keyword takes every member spelled like it but for case.
        let lowered = Set(removed.map { $0.lowercased() })
        let remove = existing.filter { lowered.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        if !remove.isEmpty {
            builder.append(Ops.setRemove(WellKnown.settings, DocumentInfoField.keywordsPath, values: SettingsFields.values { $0.info.keywords = remove }))
        }
    }
}
