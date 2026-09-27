import AppKit
import Observation
import SwiftUI
import WTModel
import WTText

/// menu:Text[Font > Other…]: every family with a search field (type to filter; the recent ones
/// first, the document's missing ones in brackets) and the chosen family's faces.  btn:[OK]
/// writes the family and face as one change, "Font".
@MainActor
@Observable
final class FontSheetModel {
    static let sheet = "text-font-other"

    let list: FontFamilyList
    var query = ""
    var family: String?
    var style: String?
    @ObservationIgnored let styles: @MainActor (String) -> [String]

    init(list: FontFamilyList, family: String?, style: String?, styles: @escaping @MainActor (String) -> [String]) {
        self.list = list
        self.family = family
        self.style = style
        self.styles = styles
    }

    /// The families the list shows for the query, each once.
    var choices: [FontFamilyChoice] {
        let all = list.flattened
        let matches = FontFilter.filter(all.map(\.family), matching: query)
        let byFamily = Dictionary(all.map { ($0.family, $0) }, uniquingKeysWith: { first, _ in first })
        return matches.compactMap { byFamily[$0] }
    }

    /// The chosen family's faces (and the chosen face when the family lacks it).
    var faces: [String] {
        guard let family else { return [] }
        var faces = styles(family)
        if let style, !faces.contains(style) { faces.insert(style, at: 0) }
        return faces
    }

    /// Picks a family: its face stays when the family has it, else its first face.
    func choose(_ family: String) {
        self.family = family
        let faces = styles(family)
        if let style, faces.contains(style) { return }
        style = faces.contains(ObjectPanelModel.defaultStyle) ? ObjectPanelModel.defaultStyle : faces.first
    }

    var canCommit: Bool { family != nil }
}

struct FontSheet: View {
    @Bindable var model: FontSheetModel
    let commit: @MainActor (String, String?) -> Void
    let cancel: @MainActor () -> Void

    static func selection(_ model: FontSheetModel) -> Binding<String?> {
        Binding(get: { model.family }, set: { if let family = $0 { model.choose(family) } })
    }

    static func style(_ model: FontSheetModel) -> Binding<String> {
        Binding(get: { model.style ?? "" }, set: { model.style = $0 })
    }

    static func committing(_ model: FontSheetModel, _ commit: @escaping @MainActor (String, String?) -> Void) -> () -> Void {
        { if let family = model.family { commit(family, model.style) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Font").font(.headline)
            TextField("Search", text: $model.query).textFieldStyle(.roundedBorder).accessibilityIdentifier("font-other.search")
            List(model.choices, id: \.family, selection: Self.selection(model)) { choice in
                HStack {
                    Text(choice.title)
                    Spacer()
                    if choice.isMissing { Image(systemName: "exclamationmark.triangle").help("Missing on this Mac") }
                    if choice.inDocument { Image(systemName: "doc.text").help("Used in this document") }
                }
                .tag(choice.family)
            }
            .frame(minHeight: 240)
            .accessibilityIdentifier("font-other.families")
            Picker("Style", selection: Self.style(model)) {
                ForEach(model.faces, id: \.self) { Text($0).tag($0) }
            }
            .disabled(model.family == nil)
            .accessibilityIdentifier("font-other.style")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(model, commit)).keyboardShortcut(.defaultAction)
                    .disabled(!model.canCommit).accessibilityIdentifier("font-other.ok")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// menu:Text[Size > Other…]: any size from 1 to 10,000 points; btn:[OK] writes it, "Size".
@MainActor
@Observable
final class SizeSheetModel {
    static let sheet = "text-size-other"

    var text: String

    init(size: Double?) {
        text = size.map(TypeSizes.format) ?? ""
    }

    /// The typed size, nil while it is not a number from 1 to 10,000.
    var size: Double? { TypeSizes.parse(text) }
}

struct SizeSheet: View {
    @Bindable var model: SizeSheetModel
    let commit: @MainActor (Double) -> Void
    let cancel: @MainActor () -> Void

    static func committing(_ model: SizeSheetModel, _ commit: @escaping @MainActor (Double) -> Void) -> () -> Void {
        { if let size = model.size { commit(size) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Size").font(.headline)
            HStack {
                TextField("Size", text: $model.text, prompt: Text(TextSectionView.mixed)).frame(width: 90).accessibilityIdentifier("size-other.size")
                Text("pt")
            }
            if model.size == nil, !model.text.isEmpty {
                Text("Enter a size from 1 to 10,000 points.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(model, commit)).keyboardShortcut(.defaultAction)
                    .disabled(model.size == nil).accessibilityIdentifier("size-other.ok")
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

/// Opens the two sheets on a document window.
@MainActor
final class FontSheets {
    static let shared = FontSheets()

    var recents: FontRecentsStore

    init(recents: FontRecentsStore = .shared) {
        self.recents = recents
    }

    /// The family list for `window`'s document: the recent ones, its missing fonts, every family.
    func familyList(for window: DocumentWindowController) -> FontFamilyList {
        FontMenus.familyList(document: window.documentHandle, recents: recents.families)
    }

    /// The *Font > Other…* model for `window`'s selection.
    func fontModel(for window: DocumentWindowController) -> FontSheetModel {
        let model = FontCommands.model(window)
        let fonts = window.documentHandle.textEngine.fonts
        return FontSheetModel(list: familyList(for: window), family: model?.text?.family, style: model?.text?.style) { fonts.styles(of: $0) }
    }

    /// The *Font > Other…* sheet over `window`: btn:[OK] applies and closes.
    func fontSheet(_ model: FontSheetModel, window: DocumentWindowController, close: @escaping @MainActor () -> Void) -> FontSheet {
        let recents = recents
        return FontSheet(model: model, commit: { [weak window] family, style in
            FontCommands.apply(family: family, style: style, window: window, recents: recents)
            close()
        }, cancel: close)
    }

    /// The *Size > Other…* sheet over `window`.
    func sizeSheet(_ model: SizeSheetModel, window: DocumentWindowController, close: @escaping @MainActor () -> Void) -> SizeSheet {
        SizeSheet(model: model, commit: { [weak window] size in
            FontCommands.apply(size: size, window: window)
            close()
        }, cancel: close)
    }

    @discardableResult
    func showFont(on window: DocumentWindowController) -> NSWindow? {
        let model = fontModel(for: window)
        return window.presentSheet(FontSheetModel.sheet) { close in fontSheet(model, window: window, close: close) }
    }

    @discardableResult
    func showSize(on window: DocumentWindowController) -> NSWindow? {
        let model = SizeSheetModel(size: FontCommands.model(window)?.text?.size)
        return window.presentSheet(SizeSheetModel.sheet) { close in sizeSheet(model, window: window, close: close) }
    }
}
