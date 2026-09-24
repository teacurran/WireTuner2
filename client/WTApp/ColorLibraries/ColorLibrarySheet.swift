import AppKit
import Observation
import SwiftUI
import WTInterchange
import WTModel
import WTProto
import WTRender

/// The library sheet (spot-process.adoc, "Color libraries"; COLOR-013's WTApp half): a library's
/// colours as a grid of chips with their names, a search field filtering by name, a selection
/// made with click, kbd:[Cmd]-click (toggle) and kbd:[Shift]-click (range), and btn:[Add], which
/// imports the selected colours with their origin (`ImportLibraryColors`, one change).  Colours
/// already in the document from the same library and key are shown ticked and dimmed and cannot
/// be selected, so they are never added twice.
@MainActor
@Observable
final class ColorLibrarySheetModel {
    /// One chip.
    struct Entry: Hashable, Identifiable {
        let key: String
        let name: String
        let color: RenderColor
        var id: String { key }
    }

    let workspace: ColorWorkspace
    let library: ColorLibrary
    /// The `library` value the swatches record: the library's name.
    let origin: String
    /// The search field's text.
    var search = ""
    /// The selected colours' keys.
    private(set) var selected: Set<String> = []
    /// Where a Shift-click range starts.
    @ObservationIgnored private var anchor: String?

    static let sheet = "color-library-sheet"

    init(workspace: ColorWorkspace, library: ColorLibrary, origin: String? = nil) {
        self.workspace = workspace
        self.library = library
        self.origin = origin ?? library.name
    }

    /// Every colour of the library, in file order (a repeated key listed once).
    var allEntries: [Entry] {
        var seen = Set<String>()
        return library.colors.filter { seen.insert($0.key).inserted }.map(Self.entry)
    }

    /// The colours whose name (or key) contains the search text.
    var entries: [Entry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allEntries }
        return allEntries.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query) }
    }

    /// A library colour as a chip: a tint shows its base's colour tinted.
    static func entry(_ color: LibraryColor) -> Entry {
        var value = ColorValues.color(color.value)
        if color.tintPercent > 0 { value = value.tinted(color.tintPercent / 100) }
        return Entry(key: color.key, name: color.name.isEmpty ? color.key : color.name, color: value)
    }

    /// The keys already in the front document from this library.
    var present: Set<String> {
        guard let list = workspace.swatches?.list else { return [] }
        return ColorLibraries.present(library, origin: origin, in: list)
    }

    /// The grid's columns: the library's layout hint, else as many as fit.
    var columns: [GridItem] {
        library.columns > 0
            ? Array(repeating: GridItem(.flexible(minimum: 48), spacing: 6), count: Int(min(library.columns, 24)))
            : [GridItem(.adaptive(minimum: 64), spacing: 6)]
    }

    /// A click on `key`: selects it alone, kbd:[Cmd] toggles it, kbd:[Shift] extends from the last
    /// click over the visible chips.  Colours already present are not selectable.
    func click(_ key: String, modifiers: NSEvent.ModifierFlags = []) {
        let present = present
        guard !present.contains(key) else { return }
        if modifiers.contains(.command) {
            if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
        } else if modifiers.contains(.shift), let anchor, let start = entries.firstIndex(where: { $0.key == anchor }),
                  let end = entries.firstIndex(where: { $0.key == key }) {
            let range = min(start, end)...max(start, end)
            selected.formUnion(entries[range].map(\.key).filter { !present.contains($0) })
        } else {
            selected = [key]
        }
        anchor = key
    }

    /// btn:[Add]: the selected colours, as one change.
    @discardableResult
    func add() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.sheet)
        let keys = allEntries.map(\.key).filter(selected.contains)
        guard !keys.isEmpty else { return nil }
        return workspace.perform(ImportLibraryColors(library, origin: origin, keys: keys))
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}

/// The library sheet's view.
struct ColorLibrarySheet: View {
    @Bindable var model: ColorLibrarySheetModel

    /// A chip's click, reading the modifier keys held.
    static func clicking(_ key: String, _ model: ColorLibrarySheetModel, modifiers: @escaping @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) -> () -> Void {
        { model.click(key, modifiers: modifiers()) }
    }

    var body: some View {
        let present = model.present
        VStack(alignment: .leading, spacing: 10) {
            Text(model.library.name).font(.headline)
            TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).accessibilityIdentifier("color-library.search")
            ScrollView {
                LazyVGrid(columns: model.columns, spacing: 6) {
                    ForEach(model.entries) { entry in
                        ColorLibraryChip(entry: entry, isSelected: model.selected.contains(entry.key), isPresent: present.contains(entry.key))
                            .onTapGesture(perform: Self.clicking(entry.key, model))
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 360)
            if model.entries.isEmpty { Text("No colors match.").foregroundStyle(.secondary) }
            HStack {
                Text("\(model.selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Add", action: ColorAction.run(model.add)).keyboardShortcut(.defaultAction).disabled(model.selected.isEmpty)
                    .accessibilityIdentifier("color-library.add")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// One chip of the library sheet: the colour, its name, a tick when it is already present.
struct ColorLibraryChip: View {
    let entry: ColorLibrarySheetModel.Entry
    let isSelected: Bool
    let isPresent: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                ColorChipView(chip: .color(entry.color), size: CGSize(width: 40, height: 28))
                if isPresent { Image(systemName: "checkmark.circle.fill").font(.caption2).accessibilityLabel("Already added") }
            }
            Text(entry.name).font(.caption2).lineLimit(1).truncationMode(.tail)
        }
        .padding(3)
        .background(isSelected ? SwiftUI.Color.accentColor.opacity(0.3) : SwiftUI.Color.clear)
        .opacity(isPresent ? 0.45 : 1)
        .accessibilityIdentifier("color-library.chip.\(entry.key)")
    }
}
