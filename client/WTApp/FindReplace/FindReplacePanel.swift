import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Find & Replace Graphics panel as far as the type attributes go (find-replace.adoc;
/// TYPE-022's *Font* in both tabs, TYPE-037's *Text effect* in the Select tab).  The other
/// attributes and `ReplaceCommand` are OBJ-022/OBJ-023's; the attribute pop-ups list what exists.
@MainActor
@Observable
final class FindReplaceState {
    enum Tab: String, CaseIterable, Identifiable {
        case replace, select
        var id: String { rawValue }
        var title: String { self == .replace ? "Find & Replace" : "Select" }
    }

    /// The attributes the panel has (find-replace.adoc's tables, as far as they are built).
    enum Attribute: String, CaseIterable, Identifiable {
        case font, textEffect
        // The object attributes of the Select tab (OBJ-022's query; `ObjectAttributeSearch`).
        case name, objectType, sameAs, pathShape, strokeWidth, size, halftone, overprint
        var id: String { rawValue }
        var title: String {
            switch self {
            case .font: "Font"
            case .textEffect: "Text effect"
            default: objectAttribute!.title
            }
        }
        /// The object attribute this is, nil for the type attributes.
        var objectAttribute: ObjectAttributeSearch.Attribute? { ObjectAttributeSearch.Attribute(rawValue: rawValue) }
        /// The Replace tab has *Font*; text effects and the object attributes are found, not replaced.
        static func available(in tab: Tab) -> [Attribute] { tab == .replace ? [.font] : allCases }
    }

    var tab = Tab.replace
    var attribute = Attribute.font
    var scope = SearchScope.document
    /// *From* (Replace tab) or the font to find (Select tab).
    var from = FontCriteria()
    var to = FontReplacement()
    var effect = EffectCriteria.any
    /// The object attributes' settings and the candidates cache.
    let objects = ObjectAttributeSearch()
    /// *Add to selection* (page, document) or *Remove from selection* (selection scope).
    var adjustSelection = false
    /// The count shown at the bottom of the panel.
    private(set) var result: String?

    init() {}

    /// btn:[Change]: one font replacement on the front window; the count of blocks it changed.
    @discardableResult
    func change(_ selection: ActiveSelection?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let document = selection?.document, let current = selection?.model?.selection else { return nil }
        let search = TypeAttributeSearch(document: document, selection: current)
        guard let (command, blocks) = search.replaceFont(from, with: to, in: scope) else {
            result = "No blocks changed"
            return nil
        }
        result = blocks == 1 ? "1 block changed" : "\(blocks) blocks changed"
        return selection?.editing?.perform(command) ?? document.perform(command)
    }

    /// btn:[Find]: selects the matching blocks; the count found.
    @discardableResult
    func find(_ selection: ActiveSelection?) -> [OpID] {
        guard let document = selection?.document, let model = selection?.model else { return [] }
        let search = TypeAttributeSearch(document: document, selection: model.selection)
        let found: [OpID]
        switch attribute {
        case .font: found = search.find(in: scope) { from.matches($0) }
        case .textEffect: found = search.find(in: scope) { effect.matches($0) }
        default:
            objects.attribute = attribute.objectAttribute!
            guard let objectsFound = objects.find(document: document, selection: model.selection, scope: scope) else {
                result = "Nothing to find"
                return []
            }
            model.set(TypeAttributeSearch.selection(after: objectsFound, current: model.selection, scope: scope, adjust: adjustSelection))
            result = objectsFound.count == 1 ? "1 object found" : "\(objectsFound.count) objects found"
            return objectsFound
        }
        model.set(TypeAttributeSearch.selection(after: found, current: model.selection, scope: scope, adjust: adjustSelection))
        result = found.count == 1 ? "1 block found" : "\(found.count) blocks found"
        return found
    }

    /// Switching tabs keeps an attribute the new tab has.
    func select(_ tab: Tab) {
        self.tab = tab
        if !Attribute.available(in: tab).contains(attribute) { attribute = .font }
        result = nil
    }
}

struct FindReplacePanelBody: View {
    let selection: ActiveSelection?
    let state: FindReplaceState

    static let anyFont = "Any font"
    static let anyStyle = "Any style"
    static let noChange = "No change"

    /// The families a pop-up offers after its *Any*/*No change* item.
    static var families: [String] { NSFontManager.shared.availableFontFamilies }

    static func styles(of family: String?) -> [String] {
        TextSectionView.styles(of: family, including: nil)
    }

    /// A family or face pop-up whose first item (`none`) stands for nil.
    static func optional(_ value: Binding<String?>, none: String) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? none }, set: { value.wrappedValue = $0 == none ? nil : $0 })
    }

    /// A size field that may be empty (nil).
    static func size(_ value: Binding<Double?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(FontCriteria.points) ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed).flatMap { $0 > 0 ? $0 : nil } ?? value.wrappedValue
                })
    }

    /// The tab control: switching keeps an attribute the new tab has.
    static func tab(_ state: FindReplaceState) -> Binding<FindReplaceState.Tab> {
        Binding(get: { state.tab }, set: { state.select($0) })
    }

    /// btn:[Change].
    func change() {
        state.change(selection)
    }

    /// btn:[Find].
    func find() {
        state.find(selection)
    }

    static func effectTitle(_ criteria: EffectCriteria) -> String {
        switch criteria {
        case .any: "Any effect"
        case .kind(let kind): kind.title
        }
    }

    static func effect(_ state: FindReplaceState) -> Binding<String> {
        Binding(get: { effectTitle(state.effect) }, set: { chosen in
            state.effect = TextEffectKind.effects.first { $0.title == chosen }.map { .kind($0) } ?? .any
        })
    }

    @ViewBuilder
    static func fontCriteria(_ title: String, _ criteria: Binding<FontCriteria>) -> some View {
        Section(title) {
            Picker("Font", selection: optional(criteria.family, none: anyFont)) {
                Text(anyFont).tag(anyFont)
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("findReplace.\(title.lowercased()).family")
            Picker("Style", selection: optional(criteria.style, none: anyStyle)) {
                Text(anyStyle).tag(anyStyle)
                ForEach(styles(of: criteria.wrappedValue.family), id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("findReplace.\(title.lowercased()).style")
            TextField("Min", text: size(criteria.minSize)).accessibilityIdentifier("findReplace.\(title.lowercased()).min")
            TextField("Max", text: size(criteria.maxSize)).accessibilityIdentifier("findReplace.\(title.lowercased()).max")
        }
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tab", selection: Self.tab(state)) {
                ForEach(FindReplaceState.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("findReplace.tab")
            Form {
                Picker(state.tab == .replace ? "Change in" : "Search in", selection: $state.scope) {
                    ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("findReplace.scope")
                Picker("Attribute", selection: $state.attribute) {
                    ForEach(FindReplaceState.Attribute.available(in: state.tab)) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("findReplace.attribute")
                if state.tab == .replace {
                    Self.fontCriteria("From", $state.from)
                    Section("To") {
                        Picker("Font", selection: Self.optional($state.to.family, none: Self.noChange)) {
                            Text(Self.noChange).tag(Self.noChange)
                            ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("findReplace.to.family")
                        Picker("Style", selection: Self.optional($state.to.style, none: Self.noChange)) {
                            Text(Self.noChange).tag(Self.noChange)
                            ForEach(Self.styles(of: state.to.family ?? state.from.family), id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("findReplace.to.style")
                        TextField("Size", text: Self.size($state.to.size)).accessibilityIdentifier("findReplace.to.size")
                    }
                } else if state.attribute == .font {
                    Self.fontCriteria("Font", $state.from)
                } else if let object = state.attribute.objectAttribute {
                    ObjectAttributeFields(search: state.objects, attribute: object)
                } else {
                    Picker("Effect", selection: Self.effect(state)) {
                        Text(Self.effectTitle(.any)).tag(Self.effectTitle(.any))
                        ForEach(TextEffectKind.effects) { Text($0.title).tag($0.title) }
                    }
                    .accessibilityIdentifier("findReplace.effect")
                }
                if state.tab == .select {
                    Toggle(state.scope == .selection ? "Remove from selection" : "Add to selection", isOn: $state.adjustSelection)
                        .accessibilityIdentifier("findReplace.adjustSelection")
                }
            }
            HStack {
                if let result = state.result {
                    Text(result).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("findReplace.result")
                }
                Spacer()
                if state.tab == .replace {
                    Button("Change", action: change).accessibilityIdentifier("findReplace.change")
                } else {
                    Button("Find", action: find).accessibilityIdentifier("findReplace.find")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The panel's registration: it replaces the catalog's *Find & Replace Graphics* placeholder.
enum FindReplacePanel {
    static func descriptor(selection: ActiveSelection?, state: FindReplaceState) -> PanelDescriptor {
        PanelDescriptor(id: "findReplace", title: "Find & Replace Graphics", icon: "magnifyingglass", defaultGroup: PanelCatalog.Group.findSelect,
                        menuOrder: 80, helpSlug: "find-replace") {
            FindReplacePanelBody(selection: selection, state: state)
        }
    }
}
