import SwiftUI
import WTCRDT
import WTModel

/// The *Link* criterion of menu:Edit[Find and Replace > Graphics]'s Select tab (urls.adoc, "Finding
/// every use of a link"; WEB-003): every object and every text block that uses the chosen link --
/// as the object's own link or on a range of its text -- within the panel's *Search in*.
@MainActor
enum LinkUseSearch {
    /// The objects and blocks in `scope` that use `url`, in stacking order.
    static func find(_ url: String, document: DocumentHandle, selection: Selection, scope: SearchScope) -> [OpID] {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let state = document.state
        let uses = LinkIndex(state).uses(of: trimmed, in: state)
        let using = Set(uses.nodes + uses.ranges.map(\.node))
        let query = ObjectAttributeSearch.scope(scope, document: document, selection: selection)
        var candidates = AttributeQuery.candidates(query, in: state)
        if case .page(let id) = query, let page = PageList(state)[id] {
            candidates = candidates.filter { AttributeQuery.bounds(of: $0, in: state)?.intersects(page.rect) == true }
        }
        return candidates.filter(using.contains)
    }

    /// The links the document uses, for the criterion's pop-up.
    static func urls(in document: DocumentHandle) -> [String] {
        LinkIndex(document.state).urls(in: document.state)
    }
}

/// The criterion's field: a link typed or picked from the ones the document uses.
struct LinkUseSearchField: View {
    let document: DocumentHandle?
    @Binding var link: String

    var body: some View {
        TextField("Link", text: $link).accessibilityIdentifier("findReplace.link")
        if let document {
            let urls = LinkUseSearch.urls(in: document)
            if !urls.isEmpty {
                Picker("Used links", selection: $link) {
                    Text("Choose…").tag("")
                    ForEach(urls, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("findReplace.links")
            }
        }
    }
}
