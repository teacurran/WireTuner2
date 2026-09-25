import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// What the Library panel's *Kind* column says and its *Show* submenu filters (library.adoc, "The
/// Library panel"; LIB-011): graphic, brush tip, hose element, master page.
enum SymbolLibraryKind: String, CaseIterable, Comparable, Sendable {
    case graphic, brushTip, hoseElement, masterPage

    init(_ usage: Wiretuner_Doc_V1_SymbolUsage) {
        switch usage {
        case .brushTip: self = .brushTip
        case .hoseElement: self = .hoseElement
        default: self = .graphic
        }
    }

    var title: String {
        switch self {
        case .graphic: "Graphic"
        case .brushTip: "Brush tip"
        case .hoseElement: "Hose element"
        case .masterPage: "Master page"
        }
    }

    /// The *Show* submenu's item.
    var plural: String {
        switch self {
        case .graphic: "Graphics"
        case .brushTip: "Brush Tips"
        case .hoseElement: "Hose Elements"
        case .masterPage: "Master Pages"
        }
    }

    static func < (a: SymbolLibraryKind, b: SymbolLibraryKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The *Date* column (library.adoc, "Specification": "the wall time and author of the newest change
/// touching the symbol subtree"): the changes this Mac applied since the document opened, per
/// document, mapped to the symbol whose subtree they touched.
@MainActor
final class SymbolChangeLog {
    static let shared = SymbolChangeLog()

    struct Entry: Equatable {
        var date: Date
        var author: String?
    }

    private(set) var entries: [String: [OpID: Entry]] = [:]

    init() {}

    /// Records `change` of `document`: each symbol whose subtree it touched, at the change's wall
    /// time, by `author` (nil: this Mac's user).
    func record(_ change: ContentChange, document: DocumentHandle, author: String?) {
        guard let applied = change.change else { return }
        let state = document.state
        let date = applied.wallTimeMs > 0 ? Date(timeIntervalSince1970: Double(applied.wallTimeMs) / 1000) : Date()
        var log = entries[document.id] ?? [:]
        for node in change.summary.touchedNodes {
            let id = OpID(node)
            let symbol = state.nodeKind(id) == .symbol ? id : Symbols.enclosingSymbol(of: id, in: state)
            if let symbol { log[symbol] = Entry(date: date, author: author) }
        }
        entries[document.id] = log
    }

    func entry(_ symbol: OpID, in document: DocumentHandle) -> Entry? {
        entries[document.id]?[symbol]
    }

    /// Follows `window`'s document from now on; `author` names a replica's person.
    static func follow(_ window: DocumentWindowController, author: @escaping @MainActor (UInt64) -> String?) {
        let document = window.documentHandle
        document.observe { change in
            let replica = change.change?.replica
            let name = change.summary.origin == .remote ? replica.flatMap(author) : nil
            SymbolChangeLog.shared.record(change, document: document, author: name)
        }
    }

    /// "Changed 3 min ago by Priya".
    static func tooltip(_ entry: Entry, now: Date = Date()) -> String {
        let when = RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: now)
        return entry.author.map { "Changed \(when) by \($0)" } ?? "Changed \(when)"
    }
}

/// The Library panel's drags (library.adoc, "Creating symbols", "Placing and modifying instances"):
/// a symbol dragged onto the canvas places an instance where it drops; the canvas selection dropped
/// on the list becomes a symbol (as *Convert to Symbol*), dropped on a symbol it replaces the
/// symbol's artwork after a sheet asks; within the list a drag onto a folder moves the dragged
/// rows into it and an kbd:[Option]-drag duplicates the dragged symbols.
@MainActor
enum SymbolLibraryDrag {
    /// The rows dragged within the list.
    static let rowsType = UTType(exportedAs: "com.villagecompute.wiretuner.library-rows", conformingTo: .data)
    static let objectsType = UTType(exportedAs: ObjectDragging.type.rawValue, conformingTo: .data)
    static let replaceSheet = "library.replace-sheet"

    /// Presents the Replace sheet for `symbol`; replaceable in tests.
    static var presentReplace: @MainActor (SymbolLibraryModel, OpID) -> Void = { _, _ in }
    static var dismissReplace: @MainActor () -> Void = {}
    /// Whether kbd:[Option] is down at a drop.
    static var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    /// The native objects payload of an instance of `symbol` with its origin at the payload's
    /// centre, so the canvas drop places it as *Place* does -- origin at the drop point.
    static func instancePayload(_ symbol: OpID, document: DocumentHandle) -> Data {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.instance.symbol.id = symbol.proto
        let payload = ClipboardPayload(nodes: [NodeTree(props: props)], bounds: Rect(x: 0, y: 0, width: 0, height: 0), sourceDocument: document.id)
        return Data(payload.encoded())
    }

    /// A symbol row's drag: the instance for the canvas and the row for the list.
    static func provider(_ row: SymbolLibraryModel.Row, model: SymbolLibraryModel) -> NSItemProvider {
        let provider = NSItemProvider()
        if row.kind == .symbol, let document = model.document {
            let data = instancePayload(row.id, document: document)
            provider.registerDataRepresentation(forTypeIdentifier: objectsType.identifier, visibility: .ownProcess) { done in
                done(data, nil)
                return nil
            }
        }
        let ids = Data(rowsPayload(model.selected.contains(row.id) ? model.selectedRows.map(\.id) : [row.id]).utf8)
        provider.registerDataRepresentation(forTypeIdentifier: rowsType.identifier, visibility: .ownProcess) { done in
            done(ids, nil)
            return nil
        }
        return provider
    }

    static func rowsPayload(_ ids: [OpID]) -> String { ids.map(\.description).joined(separator: ",") }

    static func rows(from payload: String, in model: SymbolLibraryModel) -> [OpID] {
        let names = Set(payload.split(separator: ",").map(String.init))
        return model.rows.filter { names.contains($0.id.description) }.map(\.id)
    }

    /// Canvas objects dropped on the list: a new symbol from the selection.
    @discardableResult
    static func dropObjects(on model: SymbolLibraryModel) -> Bool {
        model.newSymbol() != nil
    }

    /// Canvas objects dropped on the symbol row `symbol`: the Replace sheet asks.
    @discardableResult
    static func dropObjects(on symbol: OpID, model: SymbolLibraryModel) -> Bool {
        guard !model.canvasObjects.isEmpty else { return false }
        presentReplace(model, symbol)
        return true
    }

    /// The Replace sheet's btn:[Replace]: the symbol's artwork becomes the dragged objects.
    @discardableResult
    static func confirmReplace(_ symbol: OpID, model: SymbolLibraryModel) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        dismissReplace()
        guard !model.canvasObjects.isEmpty else { return nil }
        return model.perform(ReplaceSymbolArtwork(symbol, with: model.canvasObjects, layer: model.editing?.activeLayer))
    }

    /// Library rows dropped on `target` (a row, or the list itself when nil): with kbd:[Option]
    /// the dragged symbols are duplicated; onto a folder they move into it.
    @discardableResult
    static func dropRows(_ ids: [OpID], on target: SymbolLibraryModel.Row?, model: SymbolLibraryModel, option: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let symbols = ids.filter { id in model.rows.first { $0.id == id }?.kind == .symbol }
        if option {
            return symbols.isEmpty ? nil : model.perform(DuplicateSymbols(symbols))
        }
        guard let target, target.kind == .folder else { return nil }
        let moving = ids.filter { $0 != target.id }
        return moving.isEmpty ? nil : model.perform(MoveSymbolsToFolder(moving, to: target.id))
    }

    /// Loads a drop's providers: rows first, else objects.
    static func handle(_ providers: [NSItemProvider], on target: SymbolLibraryModel.Row?, model: SymbolLibraryModel) -> Bool {
        let option = optionHeld()
        if let rows = providers.first(where: { $0.hasItemConformingToTypeIdentifier(rowsType.identifier) }) {
            rows.loadDataRepresentation(forTypeIdentifier: rowsType.identifier) { data, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in dropRows(Self.rows(from: text, in: model), on: target, model: model, option: option) }
            }
            return true
        }
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(objectsType.identifier) }) else { return false }
        if let target, target.kind == .symbol { return dropObjects(on: target.id, model: model) }
        return dropObjects(on: model)
    }
}

/// The Replace sheet (library.adoc, "To replace a symbol's artwork with an object from the canvas").
struct ReplaceArtworkSheet: View {
    let model: SymbolLibraryModel
    let symbol: OpID

    static func replacing(_ model: SymbolLibraryModel, _ symbol: OpID) -> () -> Void { { SymbolLibraryDrag.confirmReplace(symbol, model: model) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace Symbol Artwork").font(.headline)
            Text("Every instance of \u{201C}\(model.document.map { SymbolLibraryModel.name(of: symbol, in: $0.state) } ?? "Symbol")\u{201D} takes on the dragged artwork; the object becomes an instance.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: SymbolLibraryDrag.dismissReplace).keyboardShortcut(.cancelAction).accessibilityIdentifier("library.replace.cancel")
                Spacer()
                Button("Replace", action: Self.replacing(model, symbol)).keyboardShortcut(.defaultAction).accessibilityIdentifier("library.replace")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// The sheet through `presenter`.
    static func connect(presenter: SheetPresenter) {
        SymbolLibraryDrag.presentReplace = { model, symbol in
            presenter.present(ReplaceArtworkSheet(model: model, symbol: symbol), title: "Replace Symbol Artwork", identifier: SymbolLibraryDrag.replaceSheet)
        }
        SymbolLibraryDrag.dismissReplace = { presenter.dismiss(SymbolLibraryDrag.replaceSheet) }
    }
}

extension View {
    /// A library row's drag and drop.
    func symbolLibraryDrags(_ row: SymbolLibraryModel.Row, model: SymbolLibraryModel) -> some View {
        onDrag { SymbolLibraryDrag.provider(row, model: model) }
            .onDrop(of: [SymbolLibraryDrag.rowsType, SymbolLibraryDrag.objectsType], isTargeted: nil) { SymbolLibraryDrag.handle($0, on: row, model: model) }
    }

    /// The list's drop (objects make a symbol; rows dropped on the list duplicate with Option).
    func symbolLibraryListDrop(model: SymbolLibraryModel) -> some View {
        onDrop(of: [SymbolLibraryDrag.rowsType, SymbolLibraryDrag.objectsType], isTargeted: nil) { SymbolLibraryDrag.handle($0, on: nil, model: model) }
    }
}
