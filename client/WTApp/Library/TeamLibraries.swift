import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The *Team libraries* sections of the Swatches, Styles and Library panels (sharing.adoc, "Team
/// libraries"; COLLAB-015's app half): each cached team library's swatches, graphic styles or
/// symbols (`LibraryCatalog.sections`), expanded per library, where a double-click copies the item
/// into the front document with its provenance ("Add swatch “Brand red” from Marketing library",
/// `CopyFromLibrary`); and, under *In this document*, the items already copied from a library with
/// their badge -- the library's name, or "From a library you can't access", and *update available*
/// when the library moved on -- with btn:[Update] (`UpdateFromLibrary`, needing the library cached)
/// and btn:[Detach] (`DetachFromLibrary`).  The cached stores come from `opener` (WTSync's
/// `LibraryStoreOpening`); without one the sections say there are none on this Mac.
@MainActor
@Observable
final class TeamLibraryCatalogModel {
    static let empty = "No team libraries are cached on this Mac"
    static let noDocument = "No document is open"

    /// Opens the cached library stores; nil (no store on this Mac yet) lists none.
    @ObservationIgnored var opener: (any LibraryStoreOpening)?
    /// The front document window.
    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    private(set) var catalog = LibraryCatalog([])
    /// The libraries shown expanded, by document id.
    var expanded: Set<String> = []
    /// Why the last load or copy failed.
    private(set) var message: String?
    /// Bumped when the front document changes, so *In this document* re-reads.
    private(set) var revision = 0

    init() {}

    func touch() { revision += 1 }

    /// The collections copied items live in: swatches, styles, symbols.
    static let collections: Set<OpID> = [WellKnown.swatches, OpID.wellKnown(6), WellKnown.symbols]

    /// A change to the front document: *In this document* re-reads when it wrote a swatch, style
    /// or symbol (or cannot tell).
    func documentDidChange(_ change: Wiretuner_Doc_V1_Change?, state: EngineState) {
        guard let change else { return touch() }
        if ColorUses.touched(by: change).contains(where: { state.store.placement($0).map { Self.collections.contains($0.parent) } ?? false }) { touch() }
    }

    /// Re-reads the cached libraries.
    func reload() async {
        guard let opener else {
            catalog = LibraryCatalog([])
            return
        }
        do {
            catalog = try await LibraryCatalog.load(from: opener)
            message = nil
        } catch {
            message = "The team libraries could not be read: \(error.localizedDescription)"
        }
    }

    func sections(_ kind: LibraryCatalog.Kind) -> [LibraryCatalog.Section] {
        catalog.sections(kind)
    }

    /// A double-click on `item`: copied into the front document with its provenance.
    @discardableResult
    func copy(_ item: LibraryCatalog.Item) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window() else {
            message = Self.noDocument
            return nil
        }
        guard let library = catalog.library(item.library) else { return nil }
        message = nil
        return window.objectEditing.perform(CopyFromLibrary(item.node, from: library))
    }

    /// One item of the front document copied from a library.
    struct Copied: Identifiable, Hashable {
        let node: OpID
        let name: String
        let badge: LibraryBadge
        var id: OpID { node }
    }

    /// The front document's items of `kind` that came from a library, with their badges.
    func copied(_ kind: LibraryCatalog.Kind) -> [Copied] {
        _ = revision
        guard let state = window()?.documentHandle.state else { return [] }
        let nodes: [(OpID, String)]
        switch kind {
        case .swatch: nodes = SwatchList(state).swatches.map { ($0.id, $0.name) }
        case .style: nodes = state.liveChildren(OpID.wellKnown(6)).map { ($0, state.props($0).style.common.name) }
        case .symbol: nodes = Symbols.symbols(in: state).map { ($0, state.props($0).symbol.common.name) }
        }
        return nodes.compactMap { node, name in
            LibraryBadge.of(node, in: state, catalog: catalog).map { Copied(node: node, name: name, badge: $0) }
        }
    }

    /// btn:[Update]: the copy takes the library's current version; nil when the library is not cached.
    @discardableResult
    func update(_ copied: Copied) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window(), let library = catalog.library(copied.badge.documentID) else { return nil }
        return window.objectEditing.perform(UpdateFromLibrary([copied.node], from: library))
    }

    /// btn:[Detach]: the copy forgets where it came from.
    @discardableResult
    func detach(_ copied: Copied) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        window()?.objectEditing.perform(DetachFromLibrary([copied.node]))
    }

    /// Whether `library` is shown expanded.
    func isExpanded(_ library: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(library) }, set: { if $0 { self.expanded.insert(library) } else { self.expanded.remove(library) } })
    }

    /// `descriptor` with this kind's *Team libraries* section below its body.
    func adding(_ kind: LibraryCatalog.Kind, to descriptor: PanelDescriptor) -> PanelDescriptor {
        var wrapped = descriptor
        let make = descriptor.makeView
        wrapped.makeView = { [self] in
            let section = NSHostingView(rootView: TeamLibraryCatalogSection(model: self, kind: kind))
            section.setAccessibilityIdentifier("panel.\(descriptor.id.rawValue).teamLibraries")
            let stack = NSStackView(views: [make(), section])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 0
            stack.setHuggingPriority(.defaultLow, for: .vertical)
            return stack
        }
        return wrapped
    }
}

/// One panel's *Team libraries* section.
struct TeamLibraryCatalogSection: View {
    let model: TeamLibraryCatalogModel
    let kind: LibraryCatalog.Kind

    static func copy(_ item: LibraryCatalog.Item, _ model: TeamLibraryCatalogModel) -> () -> Void { { model.copy(item) } }
    static func update(_ copied: TeamLibraryCatalogModel.Copied, _ model: TeamLibraryCatalogModel) -> () -> Void { { model.update(copied) } }
    static func detach(_ copied: TeamLibraryCatalogModel.Copied, _ model: TeamLibraryCatalogModel) -> () -> Void { { model.detach(copied) } }

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Team libraries").font(.caption.bold()).foregroundStyle(.secondary)
            let sections = model.sections(kind)
            if sections.isEmpty {
                Text(TeamLibraryCatalogModel.empty).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("team-libraries.empty")
            }
            ForEach(sections, id: \.library) { section in
                DisclosureGroup(section.name, isExpanded: model.isExpanded(section.library)) {
                    ForEach(section.items) { item in
                        Text(item.name.isEmpty ? "Untitled" : item.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2, perform: Self.copy(item, model))
                            .accessibilityIdentifier("team-libraries.item.\(item.id)")
                    }
                }
                .accessibilityIdentifier("team-libraries.library.\(section.library)")
            }
            let copied = model.copied(kind)
            if !copied.isEmpty {
                Text("In this document").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(copied) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.badge.updateAvailable ? "books.vertical.circle.fill" : "books.vertical.circle")
                            .help(item.badge.tooltip)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Button("Update", action: Self.update(item, model)).controlSize(.small)
                            .disabled(model.catalog.library(item.badge.documentID) == nil)
                        Button("Detach", action: Self.detach(item, model)).controlSize(.small)
                    }
                    .accessibilityIdentifier("team-libraries.copied.\(item.node)")
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("team-libraries.message") }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
