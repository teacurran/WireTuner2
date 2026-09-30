import AppKit
import SwiftUI

extension SearchSnippet {
    /// "Text: Spring **Sale** starts", the match in bold.
    var attributed: AttributedString {
        var result = AttributedString("\(field.title): ")
        result.foregroundColor = .secondary
        for segment in segments {
            var run = AttributedString(segment.text)
            if segment.isMatch { run.inlinePresentationIntent = .stronglyEmphasized }
            result += run
        }
        return result
    }
}

/// The library window's content (APP-009): spaces and sections in the sidebar; the path, the
/// search field, New and Open above a grid of folders and document thumbnails.  Every
/// decision is `LibraryModel`'s; this only lays it out.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var renaming: LibraryDocument?
    @State private var newName = ""
    @State private var renamingFolder: LibraryFolder?
    @State private var deleting: LibraryDocument?

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(model: model)
                .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                LibraryToolbar(model: model)
                if let hint = model.searchHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                        .accessibilityIdentifier("library.hint")
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 4)
                        .accessibilityIdentifier("library.error")
                }
                if let banner = model.storageBanner {
                    Label(banner, systemImage: "externaldrive.badge.exclamationmark").font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.bottom, 6)
                        .accessibilityIdentifier("library.storage")
                }
                Divider()
                if let branches = model.branches, branches.shelf != nil {
                    LibraryShelfList(branches: branches)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(model.searchResults == nil ? model.folders : []) { folder in
                                LibraryFolderTile(model: model, folder: folder, renaming: $renamingFolder)
                            }
                            ForEach(model.rows) { row in
                                LibraryDocumentTile(model: model, row: row, renaming: $renaming, deleting: $deleting)
                            }
                        }
                        .padding(12)
                        if model.nextCursor != nil, model.searchResults == nil {
                            Button("Load More") { Task { await model.loadMore() } }
                                .padding(.bottom, 12)
                                .accessibilityIdentifier("library.loadMore")
                        }
                    }
                    // Files dragged from the Finder open as new documents (IO-040).
                    .dropDestination(for: URL.self) { urls, _ in model.openFiles(urls) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .sheet(item: $model.teamSettings) { TeamSettingsView(model: $0) }
        .sheet(item: $model.joinTeam) { JoinTeamView(model: $0) }
        .alert("Rename Document", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { renameFolder() }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .alert(
            "Delete “\(deleting?.name ?? "")” permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete Permanently", role: .destructive) { deletePermanently() }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(LibraryView.deleteWarning)
        }
        .onChange(of: renaming) { _, document in newName = document?.name ?? "" }
        .onChange(of: renamingFolder) { _, folder in newName = folder?.name ?? "" }
    }

    /// Local mode's *Delete Permanently* confirmation (D-079).
    static let deleteWarning = "It is removed from this Mac and cannot be recovered. Save a Copy As… first if you may need it."

    private func renameFolder() {
        guard let folder = renamingFolder else { return }
        renamingFolder = nil
        Task { await model.renameFolder(folder.id, to: newName) }
    }

    private func deletePermanently() {
        guard let document = deleting else { return }
        deleting = nil
        Task { await model.deletePermanently(document.id) }
    }

    private func rename() {
        guard let document = renaming else { return }
        renaming = nil
        Task { await model.rename(document.id, to: newName) }
    }
}

struct LibrarySidebar: View {
    let model: LibraryModel

    var body: some View {
        List {
            Section("Library") {
                row("Recents", symbol: "clock", section: .recents, identifier: "library.sidebar.recents")
                if model.isLocal() {
                    // Local mode (D-079): nothing is shared, and the Trash is this Mac's.
                    row("Templates", symbol: "doc.on.doc", section: .templates, identifier: "library.sidebar.templates")
                    row("Trash", symbol: "trash", section: .trash, identifier: "library.sidebar.localTrash")
                } else {
                    row("Shared with Me", symbol: "person.2", section: .sharedWithMe, identifier: "library.sidebar.shared")
                    row("Templates", symbol: "doc.on.doc", section: .templates, identifier: "library.sidebar.templates")
                }
                if !model.isLocal(), let branches = model.branches {
                    shelf(branches, "Archived", symbol: "archivebox", shelf: .archived, identifier: "library.sidebar.archived")
                    shelf(branches, "Trash", symbol: "trash", shelf: .trash, identifier: "library.sidebar.trash")
                }
            }
            Section("Spaces") {
                ForEach(model.spaces) { space in
                    let selected = model.currentSpaceID == space.id && model.section == .folder(nil)
                    Button { Task { await model.branches?.show(nil); await model.switchSpace(to: space.id); await model.branches?.load() } } label: {
                        Label(space.name, systemImage: space.kind == .personal ? "person.crop.circle" : "person.3")
                            .fontWeight(selected ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.space.\(space.id)")
                }
                if model.collaboration != nil, !model.isLocal() {
                    Button(action: model.openJoinTeam) { Label("Join Team…", systemImage: "person.badge.plus") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.joinTeam")
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// *Archived* or *Trash* (COLLAB-016).
    private func shelf(_ branches: LibraryBranches, _ title: String, symbol: String, shelf: LibraryBranches.Shelf, identifier: String) -> some View {
        Button { Task { await branches.show(shelf) } } label: {
            Label(title, systemImage: symbol).fontWeight(branches.shelf == shelf ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func row(_ title: String, symbol: String, section: LibraryModel.Section, identifier: String) -> some View {
        Button { Task { await model.branches?.show(nil); await model.show(section) } } label: {
            Label(title, systemImage: symbol).fontWeight(model.section == section && model.branches?.shelf == nil ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct LibraryToolbar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline).lineLimit(1).accessibilityIdentifier("library.path")
            if let note = model.connectionNote {
                Label(note.title, systemImage: note.symbol).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(model.isLocal() ? "library.local" : "library.offline")
            }
            Spacer()
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("library.search")
            Menu("New") {
                Button("New Document") { model.newDocument() }
                Button("New from Template…") { model.showGallery() }
                Button("New Folder") { Task { await model.createFolder(named: "New Folder") } }
            } primaryAction: {
                model.newDocument()
            }
            .fixedSize()
            .accessibilityIdentifier("library.new")
            if model.canShowTeamSettings {
                Button(action: model.openTeamSettings) { Image(systemName: "person.3.sequence") }
                    .help("Team Settings…")
                    .accessibilityIdentifier("library.teamSettings")
            }
            Button("Open") { model.openSelection() }
                .disabled(model.selection.isEmpty)
                .accessibilityIdentifier("library.open")
            Button("Open File…") { model.openFile() }
                .help("Open an Illustrator, PDF, SVG, EPS or DXF file, or a WireTuner package, as a new document")
                .accessibilityIdentifier("library.openFile")
            if model.section == .trash {
                Button("Empty Trash") { Task { await model.emptyTrash() } }
                    .disabled(model.documents.isEmpty)
                    .accessibilityIdentifier("library.emptyTrash")
            }
            if !model.isLocal() {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .accessibilityIdentifier("library.refresh")
            }
        }
        .padding(12)
    }

    /// "Personal › Clients › Acme", "Recents", "Shared with Me", or "Search results".
    var title: String {
        if let shelf = model.branches?.shelf { return "\(model.currentSpace.name) › \(shelf == .archived ? "Archived" : "Trash")" }
        if model.searchResults != nil { return "Search results" }
        switch model.section {
        case .recents: return "Recents"
        case .sharedWithMe: return "Shared with Me"
        case .templates: return "\(model.currentSpace.name) › Templates"
        case .trash: return "\(model.currentSpace.name) › Trash"
        case .folder: return ([model.currentSpace.name] + model.folderPath.map(\.name)).joined(separator: " › ")
        }
    }
}

struct LibraryFolderTile: View {
    let model: LibraryModel
    let folder: LibraryFolder
    @Binding var renaming: LibraryFolder?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.system(size: 48)).foregroundStyle(.tint)
                .frame(height: 110)
            Text(folder.name).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.show(.folder(folder.id)) } }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { Task { await model.move(id, toFolder: folder.id) } }
            return !ids.isEmpty
        }
        .contextMenu {
            Button("Rename Folder…") { renaming = folder }
            Button("Delete Folder") { Task { await model.deleteFolder(folder.id) } }
                .help("What the folder holds moves up to the folder around it")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.folder.\(folder.id)")
    }
}

struct LibraryDocumentTile: View {
    let model: LibraryModel
    let row: LibraryRow
    @Binding var renaming: LibraryDocument?
    @Binding var deleting: LibraryDocument?

    private var document: LibraryDocument { row.document }

    var body: some View {
        let selected = model.selection.contains(document.id)
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            HStack(spacing: 4) {
                Text(document.name).lineLimit(1).accessibilityIdentifier("library.document.\(document.id).name")
                if model.mentioned.contains(document.id) {
                    Circle().fill(Color.blue).frame(width: 7, height: 7)
                        .help("You were mentioned in a comment you have not seen")
                        .accessibilityIdentifier("library.document.\(document.id).mention")
                }
                if document.isTemplate {
                    Image(systemName: "doc.on.doc").foregroundStyle(.secondary).help("Template")
                        .accessibilityIdentifier("library.document.\(document.id).template")
                }
                // Local mode: everything is on this Mac and nothing is waiting (D-079).
                if !model.isLocal(), model.isOfflineAvailable(document) {
                    Image(systemName: document.isPendingUpload ? "icloud.and.arrow.up" : "laptopcomputer")
                        .foregroundStyle(.secondary)
                        .help(document.isPendingUpload ? "Waiting to upload" : "Available offline")
                        .accessibilityIdentifier("library.document.\(document.id).badge")
                }
                if let badge = LibrarySyncBadge.badge(model.syncState(document.id)) {
                    Image(systemName: badge.symbol)
                        .foregroundStyle(.secondary)
                        .help(badge.help)
                        .accessibilityLabel(badge.help)
                        .accessibilityIdentifier("library.document.\(document.id).sync")
                }
            }
            if let branches = model.branches {
                LibraryNestedBranches(branches: branches, parent: document)
            }
            if let snippet = row.snippet {
                Text(snippet.attributed).font(.caption).lineLimit(2)
                    .accessibilityIdentifier("library.document.\(document.id).snippet")
            } else if document.isSharedWithMe, let role = document.role {
                Text(role.title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(model.isAvailable(document) ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open([document]) }
        .onTapGesture { model.selection = [document.id] }
        .draggable(document.id)
        .contextMenu {
            if document.isTrashed {
                // Local mode's Trash (D-079).
                Button("Restore") { model.restore(document.id) }
                Button("Delete Permanently…") { deleting = document }
            } else {
                menu
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.document.\(document.id)")
    }

    /// A document's menu; Local mode leaves out what only an account's library has (D-079).
    @ViewBuilder private var menu: some View {
        let local = model.isLocal()
        Group {
            Button("Open") { model.open([document]) }
            Button("Rename…") { renaming = document }
            Button("Duplicate") { Task { await model.duplicate(document.id) } }
            if !local {
                Button("Keep Available Offline") { model.keepAvailableOffline(document.id) }
                if let remove = model.removeLocalCopy, model.hasLocalCopy(document.id) {
                    Button("Remove Local Copy…") { remove(document) }
                }
            }
            Button(document.isTemplate ? "Use as Document" : "Use as Template") { Task { await model.setTemplate(document.id, !document.isTemplate) } }
                .disabled(!local && !model.isOnline && !document.isPendingUpload)
                .help(local || model.isOnline || document.isPendingUpload ? "" : LibraryModel.templateFlagOfflineMessage)
            if let use = model.useAsTeamLibrary {
                let refusal: String? = local ? LocalMode.needsAccount : model.teamLibraryRefusal?(document)
                Button("Use as Team Library") { use(document) }.disabled(refusal != nil).help(refusal ?? "Offer this document's symbols, styles and master pages to the team")
            }
            Divider()
            Button("Move to Trash") { Task { await model.trash(document.id) } }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = model.thumbnailImage(for: document) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
        } else {
            Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.tertiary)
        }
    }
}
