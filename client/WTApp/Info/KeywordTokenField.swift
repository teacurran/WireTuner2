import AppKit
import SwiftUI

/// The Document Info sheet's keyword field (file-info.adoc, *Keywords*; IO-011): a hosted
/// `NSTokenField`, one token per keyword.  Typing a word and pressing kbd:[Return] (or a comma)
/// adds it; kbd:[Delete] on a token removes it.  Each edit is the difference between the tokens
/// shown and the document's keywords: the added words in one `SetDocumentKeywords`, each removed
/// one in its own.
struct KeywordTokenField: NSViewRepresentable {
    let keywords: [String]
    let add: @MainActor (String) -> Void
    let remove: @MainActor (String) -> Void

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: KeywordTokenField

        init(parent: KeywordTokenField) {
            self.parent = parent
        }

        /// The tokens now in `field` against the document's keywords: what to add and remove.
        static func difference(tokens: [String], keywords: [String]) -> (added: [String], removed: [String]) {
            let cleaned = tokens.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let current = Set(keywords.map { $0.lowercased() })
            let shown = Set(cleaned.map { $0.lowercased() })
            return (cleaned.filter { !current.contains($0.lowercased()) }, keywords.filter { !shown.contains($0.lowercased()) })
        }

        func apply(_ tokens: [String]) {
            let (added, removed) = Self.difference(tokens: tokens, keywords: parent.keywords)
            if !added.isEmpty { parent.add(added.joined(separator: ",")) }
            for keyword in removed { parent.remove(keyword) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            apply(field.objectValue as? [String] ?? [])
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            apply((tokenField.objectValue as? [String] ?? []) + tokens.compactMap { $0 as? String })
            return tokens
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        field.placeholderString = "Add keywords"
        field.setAccessibilityIdentifier("documentInfo.keyword")
        field.objectValue = keywords
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        if (field.objectValue as? [String]) != keywords, field.currentEditor() == nil {
            field.objectValue = keywords
        }
    }
}
