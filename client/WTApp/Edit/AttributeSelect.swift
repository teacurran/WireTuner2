import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel

/// The object attributes of the Find & Replace panel's Select tab (find-replace.adoc, "The Select
/// tab"; OBJ-022's `AttributeQuery` behind OBJ-023's tab): *Name*, *Object type*, *Same as
/// selection*, *Path shape*, *Stroke width*, *Size*, *Halftone* and *Overprint*.  btn:[Find] runs the
/// query over the scope's candidates, which are kept per document revision -- walking the tree for
/// them is most of a query's cost on a large document.
@MainActor
@Observable
final class ObjectAttributeSearch {
    enum Attribute: String, CaseIterable, Identifiable {
        case name, objectType, sameAs, pathShape, strokeWidth, size, halftone, overprint
        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Name"
            case .objectType: "Object type"
            case .sameAs: "Same as selection"
            case .pathShape: "Path shape"
            case .strokeWidth: "Stroke width"
            case .size: "Size"
            case .halftone: "Halftone"
            case .overprint: "Overprint"
            }
        }
    }

    static let typeTitles: [(AttributeQuery.ObjectType, String)] = [
        (.path, "Path"), (.rectangle, "Rectangle"), (.ellipse, "Ellipse"), (.polygon, "Polygon"), (.compositePath, "Composite path"),
        (.clippingPath, "Clipping path"), (.group, "Group"), (.blend, "Blend"), (.textBlock, "Text block"), (.bitmap, "Bitmap"),
        (.embeddedFile, "Embedded file"), (.envelope, "Envelope"), (.extrusion, "Extrusion"), (.connectorLine, "Connector line"),
        (.symbolInstance, "Symbol instance"),
    ]

    var attribute = Attribute.name
    var name = ""
    var objectType = AttributeQuery.ObjectType.path
    var minimum: Double?
    var maximum: Double?
    var minimumHeight: Double?
    var maximumHeight: Double?

    /// The candidates of the last query: the document, its revision and the scope they are for.
    @ObservationIgnored private(set) var cached: (document: ObjectIdentifier, revision: Int, scope: AttributeQuery.Scope, candidates: [OpID])?
    /// How many times the candidates were walked (tests).
    @ObservationIgnored private(set) var walks = 0

    init() {}

    /// The query's scope for the panel's *Search in*.
    static func scope(_ scope: SearchScope, document: DocumentHandle, selection: Selection) -> AttributeQuery.Scope {
        switch scope {
        case .selection: .selection(selection.ids.map(\.opID))
        case .page: .page(document.activePage.id)
        case .document: .document
        }
    }

    /// The criterion the settings make; nil when they are incomplete (no sample for *Same as
    /// selection* or *Path shape*, an empty name).
    func criterion(selection: Selection, state: EngineState) -> AttributeQuery.Criterion? {
        switch attribute {
        case .name:
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .name(trimmed)
        case .objectType:
            return .objectType(objectType)
        case .sameAs:
            return selection.ids.first.map { .sameAs($0.opID) }
        case .pathShape:
            return selection.ids.first.flatMap { PathShape($0.opID, in: state) }.map { .pathShape($0) }
        case .strokeWidth:
            return .strokeWidth(ValueRange(min: minimum, max: maximum))
        case .size:
            return .size(width: ValueRange(min: minimum, max: maximum), height: ValueRange(min: minimumHeight, max: maximumHeight))
        case .halftone:
            return .halftone
        case .overprint:
            return .overprint
        }
    }

    /// The scope's candidates for `document` now, walked again only when the document changed.
    func candidates(_ scope: AttributeQuery.Scope, document: DocumentHandle) -> [OpID] {
        let key = ObjectIdentifier(document)
        let revision = document.model?.revision ?? 0
        if let cached, cached.document == key, cached.revision == revision, cached.scope == scope { return cached.candidates }
        walks += 1
        let candidates = AttributeQuery.candidates(scope, in: document.state)
        cached = (key, revision, scope, candidates)
        return candidates
    }

    /// btn:[Find]: the matching objects; nil when the settings name nothing to find.
    func find(document: DocumentHandle, selection: Selection, scope: SearchScope) -> [OpID]? {
        let state = document.state
        guard let criterion = criterion(selection: selection, state: state) else { return nil }
        let query = AttributeQuery(criterion, in: Self.scope(scope, document: document, selection: selection))
        let found = query.run(in: state, candidates: candidates(query.scope, document: document))
        // *Same as selection* and *Path shape* do not find their own sample.
        guard attribute == .sameAs || attribute == .pathShape, let sample = selection.ids.first?.opID else { return found }
        return found.filter { $0 != sample }
    }
}

/// The Select tab's fields for the object attributes.
struct ObjectAttributeFields: View {
    @Bindable var search: ObjectAttributeSearch
    /// The attribute the panel shows.
    let attribute: ObjectAttributeSearch.Attribute

    static func optional(_ value: Binding<Double?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(FontCriteria.points) ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed) ?? value.wrappedValue
                })
    }

    var body: some View {
        switch attribute {
        case .name:
            TextField("Name contains", text: $search.name).accessibilityIdentifier("findReplace.name")
        case .objectType:
            Picker("Type", selection: $search.objectType) {
                ForEach(ObjectAttributeSearch.typeTitles, id: \.0) { Text($0.1).tag($0.0) }
            }
            .accessibilityIdentifier("findReplace.objectType")
        case .strokeWidth, .size:
            TextField(attribute == .size ? "Min width" : "Min", text: Self.optional($search.minimum)).accessibilityIdentifier("findReplace.min")
            TextField(attribute == .size ? "Max width" : "Max", text: Self.optional($search.maximum)).accessibilityIdentifier("findReplace.max")
            if attribute == .size {
                TextField("Min height", text: Self.optional($search.minimumHeight)).accessibilityIdentifier("findReplace.minHeight")
                TextField("Max height", text: Self.optional($search.maximumHeight)).accessibilityIdentifier("findReplace.maxHeight")
            }
        case .sameAs, .pathShape:
            Text("Finds objects like the first selected one.").font(.caption).foregroundStyle(.secondary)
        case .halftone, .overprint:
            EmptyView()
        }
    }
}
