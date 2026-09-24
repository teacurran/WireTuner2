import Foundation
import WTCRDT
import WTModel
import WTProto
import WTSync
import WTText

/// The *Font substitutions* preference (`text.font_substitutions`, font-substitution.adoc, "The
/// substitution table") as `FontSubstitution` rows.  Each row is one string: the missing face's
/// family and style and the substitute's family and style, separated by tabs, a style empty
/// when the row names none.  Rows are keyed by the missing *face*: a row naming a style covers
/// that style only, one without covers the family (WTText's `FontSubstitutionTable`).
enum FontSubstitutionRows {
    static let separator: Character = "\t"

    static func encode(_ row: FontSubstitution) -> String {
        [row.missing.family, row.missing.style ?? "", row.substitute.family, row.substitute.style ?? ""].joined(separator: String(separator))
    }

    /// The row a string holds; nil for one that is not four fields with both families named.
    static func decode(_ string: String) -> FontSubstitution? {
        let fields = string.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, !fields[0].isEmpty, !fields[2].isEmpty else { return nil }
        return FontSubstitution(missing: FaceName(family: fields[0], style: fields[1].isEmpty ? nil : fields[1]),
                                substitute: FaceName(family: fields[2], style: fields[3].isEmpty ? nil : fields[3]))
    }

    /// The remembered rows and the *Default substitute* from `preferences`.
    @MainActor
    static func table(_ preferences: PreferenceStore) -> FontSubstitutionTable {
        let fallback = preferences[PreferenceCatalog.Text.defaultSubstitute].trimmingCharacters(in: .whitespaces)
        return FontSubstitutionTable(rows: preferences[PreferenceCatalog.Text.fontSubstitutions].compactMap(decode),
                                     defaultSubstitute: fallback.isEmpty ? FontSubstitutionTable.standardDefault : FaceName(family: fallback))
    }

    /// Adds `rows` to the remembered ones, each replacing a row for the same missing face.
    @MainActor
    static func remember(_ rows: [FontSubstitution], in preferences: PreferenceStore) {
        guard !rows.isEmpty else { return }
        let keys = Set(rows.map { key($0.missing) })
        var kept = preferences[PreferenceCatalog.Text.fontSubstitutions].filter { decode($0).map { !keys.contains(key($0.missing)) } ?? false }
        kept += rows.map(encode)
        _ = preferences.set(kept, for: PreferenceCatalog.Text.fontSubstitutions)
    }

    /// A missing face's identity in the table: family, and style ignoring case.
    static func key(_ face: FaceName) -> String {
        "\(face.family)\(separator)\(face.style?.lowercased() ?? "")"
    }

    /// What the preference table shows for a row: "Missing Bold → Georgia".
    static func title(_ row: FontSubstitution) -> String {
        "\(row.missing) → \(row.substitute)"
    }
}

/// A document's own substitutions (the sheet without *Remember this substitution*): a per-Mac
/// record in the local store's `view` table, so reopening the document does not ask again
/// (font-substitution.adoc, "Data model").  A memory document keeps them for the session.
@MainActor
final class DocumentSubstitutionStore {
    static let viewKey = "font_substitutions"
    private var memory: [String: [FontSubstitution]] = [:]

    func rows(for document: DocumentHandle) async -> [FontSubstitution] {
        if let store = await document.openedModel()?.backend as? LocalStore,
           let data = try? await store.viewValue(forKey: Self.viewKey), let strings = try? JSONDecoder().decode([String].self, from: data) {
            return strings.compactMap(FontSubstitutionRows.decode)
        }
        return memory[document.id] ?? []
    }

    func setRows(_ rows: [FontSubstitution], for document: DocumentHandle) async {
        memory[document.id] = rows
        guard let store = await document.openedModel()?.backend as? LocalStore else { return }
        try? await store.setViewValue(JSONEncoder().encode(rows.map(FontSubstitutionRows.encode)), forKey: Self.viewKey)
    }
}
