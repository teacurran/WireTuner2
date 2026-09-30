import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// The object attributes of the Find & Replace panel's Select tab (find-replace.adoc, "The Select
/// tab"; OBJ-022's `AttributeQuery` behind OBJ-023's tab): *Color*, *Style*, *Name*, *Object type*,
/// *Same as selection*, *Path shape* (a sample pasted in, else the first selected object), *Fill
/// type*, *Stroke type*, *Stroke width*, *Size*, *Halftone* and *Overprint*.  btn:[Find] runs the
/// query over the scope's candidates, which are kept per document revision -- walking the tree for
/// them is most of a query's cost on a large document.
@MainActor
@Observable
final class ObjectAttributeSearch {
    enum Attribute: String, CaseIterable, Identifiable {
        case name, objectType, sameAs, pathShape, strokeWidth, size, halftone, overprint
        case color, style, fillType, strokeType
        var id: String { rawValue }

        var title: String {
            switch self {
            case .color: "Color"
            case .style: "Style"
            case .fillType: "Fill type"
            case .strokeType: "Stroke type"
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

    static let fillTitles: [(Wiretuner_Doc_V1_FillKind, String)] = [
        (.basic, "Basic"), (.gradient, "Gradient"), (.lens, "Lens"), (.custom, "Custom"), (.pattern, "Pattern"), (.textured, "Textured"), (.tiled, "Tiled"),
    ]

    static let strokeTitles: [(Wiretuner_Doc_V1_StrokeKind, String)] = [
        (.basic, "Basic"), (.brush, "Brush"), (.calligraphic, "Calligraphic"), (.custom, "Custom"), (.pattern, "Pattern"),
    ]

    var attribute = Attribute.name
    var color: Wiretuner_Doc_V1_ColorRef?
    var style: OpID?
    var fillType = Wiretuner_Doc_V1_FillKind.basic
    var strokeType = Wiretuner_Doc_V1_StrokeKind.basic
    /// *Path shape*'s sample from btn:[Paste In]; nil uses the first selected object.
    var pastedSample: PathShape?
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

    /// The styles *Style* offers: the graphic styles, then the paragraph and character styles.
    static func styles(in state: EngineState) -> [(id: OpID, name: String)] {
        let resolver = GraphicStyleResolver(state)
        let names = GraphicStyleFields.displayNames(in: state, resolver)
        let graphic = GraphicStyleFields.styles(in: state, resolver).map { (id: $0, name: names[$0] ?? state.props($0).style.common.name) }
        let text = state.textStyles
        return graphic + (text.styles(.paragraph) + text.styles(.character)).map { (id: $0.id, name: $0.name) }
    }

    /// btn:[Paste In] for *Path shape*: the pasteboard's first object as the sample; false when it
    /// is not a path or shape.
    @discardableResult
    func pasteSample(_ payload: ClipboardPayload?) -> Bool {
        pastedSample = payload.flatMap(PathShape.init)
        return pastedSample != nil
    }

    /// The criterion the settings make; nil when they are incomplete (no sample for *Same as
    /// selection* or *Path shape*, an empty name, no colour or style).
    func criterion(selection: Selection, state: EngineState) -> AttributeQuery.Criterion? {
        switch attribute {
        case .color:
            return color.map { .color($0) }
        case .style:
            return style.map { .style($0) }
        case .fillType:
            return .fillType(fillType)
        case .strokeType:
            return .strokeType(strokeType)
        case .name:
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .name(trimmed)
        case .objectType:
            return .objectType(objectType)
        case .sameAs:
            return selection.ids.first.map { .sameAs($0.opID) }
        case .pathShape:
            if let pastedSample { return .pathShape(pastedSample) }
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
        // *Same as selection* and *Path shape* do not find their own sample (a pasted one is not in the document).
        guard attribute == .sameAs || attribute == .pathShape && pastedSample == nil, let sample = selection.ids.first?.opID else { return found }
        return found.filter { $0 != sample }
    }
}

/// The Select tab's fields for the object attributes.
struct ObjectAttributeFields: View {
    @Bindable var search: ObjectAttributeSearch
    /// The attribute the panel shows.
    let attribute: ObjectAttributeSearch.Attribute
    var swatches: [Swatch] = []
    var resolver: ColorResolver?
    /// *Style*'s choices.
    var styles: [(id: OpID, name: String)] = []
    /// The native pasteboard's objects (*Paste In*).
    var paste: @MainActor () -> ClipboardPayload? = { nil }

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
        case .sameAs:
            Text("Finds objects like the first selected one.").font(.caption).foregroundStyle(.secondary)
        case .pathShape:
            LabeledContent("Sample") {
                Button("Paste In") { search.pasteSample(paste()) }.accessibilityIdentifier("findReplace.shape.sample")
            }
            Text(search.pastedSample == nil ? "Finds objects like the first selected one, or a sample pasted in." : "Finds objects like the pasted sample.")
                .font(.caption).foregroundStyle(.secondary)
        case .color:
            GraphicReplaceFields.well("Color", $search.color, swatches: swatches, resolver: resolver)
        case .style:
            Picker("Style", selection: $search.style) {
                Text(GraphicReplaceFields.none).tag(OpID?.none)
                ForEach(styles, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            .accessibilityIdentifier("findReplace.style")
        case .fillType:
            Picker("Fill type", selection: $search.fillType) {
                ForEach(ObjectAttributeSearch.fillTitles, id: \.0) { Text($0.1).tag($0.0) }
            }
            .accessibilityIdentifier("findReplace.fillType")
        case .strokeType:
            Picker("Stroke type", selection: $search.strokeType) {
                ForEach(ObjectAttributeSearch.strokeTitles, id: \.0) { Text($0.1).tag($0.0) }
            }
            .accessibilityIdentifier("findReplace.strokeType")
        case .halftone, .overprint:
            EmptyView()
        }
    }
}
