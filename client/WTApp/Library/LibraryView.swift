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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(model.searchResults == nil ? model.folders : []) { folder in
                            LibraryFolderTile(model: model, folder: folder)
                        }
                        ForEach(model.rows) { row in
                            LibraryDocumentTile(model: model, row: row, renaming: $renaming)
                        }
                    }
                    .padding(12)
                    if model.nextCursor != nil, model.searchResults == nil {
                        Button("Load More") { Task { await model.loadMore() } }
                            .padding(.bottom, 12)
                            .accessibilityIdentifier("library.loadMore")
                    }
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
        .onChange(of: renaming) { _, document in newName = document?.name ?? "" }
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
                row("Shared with Me", symbol: "person.2", section: .sharedWithMe, identifier: "library.sidebar.shared")
                row("Templates", symbol: "doc.on.doc", section: .templates, identifier: "library.sidebar.templates")
            }
            Section("Spaces") {
                ForEach(model.spaces) { space in
                    let selected = model.currentSpaceID == space.id && model.section == .folder(nil)
                    Button { Task { await model.switchSpace(to: space.id) } } label: {
                        Label(space.name, systemImage: space.kind == .personal ? "person.crop.circle" : "person.3")
                            .fontWeight(selected ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.space.\(space.id)")
                }
                if model.collaboration != nil {
                    Button(action: model.openJoinTeam) { Label("Join Team…", systemImage: "person.badge.plus") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.joinTeam")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, symbol: String, section: LibraryModel.Section, identifier: String) -> some View {
        Button { Task { await model.show(section) } } label: {
            Label(title, systemImage: symbol).fontWeight(model.section == section ? .semibold : .regular)
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
            if !model.isOnline {
                Label("Offline", systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.offline")
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
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .accessibilityIdentifier("library.refresh")
        }
        .padding(12)
    }

    /// "Personal › Clients › Acme", "Recents", "Shared with Me", or "Search results".
    var title: String {
        if model.searchResults != nil { return "Search results" }
        switch model.section {
        case .recents: return "Recents"
        case .sharedWithMe: return "Shared with Me"
        case .templates: return "\(model.currentSpace.name) › Templates"
        case .folder: return ([model.currentSpace.name] + model.folderPath.map(\.name)).joined(separator: " › ")
        }
    }
}

struct LibraryFolderTile: View {
    let model: LibraryModel
    let folder: LibraryFolder

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
            Button("Delete Folder") { Task { await model.deleteFolder(folder.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.folder.\(folder.id)")
    }
}

struct LibraryDocumentTile: View {
    let model: LibraryModel
    let row: LibraryRow
    @Binding var renaming: LibraryDocument?

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
                if model.isOfflineAvailable(document) {
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
            Button("Open") { model.open([document]) }
            Button("Rename…") { renaming = document }
            Button("Duplicate") { Task { await model.duplicate(document.id) } }
            Button("Keep Available Offline") { model.keepAvailableOffline(document.id) }
            if let remove = model.removeLocalCopy, model.hasLocalCopy(document.id) {
                Button("Remove Local Copy…") { remove(document) }
            }
            Button(document.isTemplate ? "Use as Document" : "Use as Template") { Task { await model.setTemplate(document.id, !document.isTemplate) } }
                .disabled(!model.isOnline && !document.isPendingUpload)
                .help(model.isOnline || document.isPendingUpload ? "" : LibraryModel.templateFlagOfflineMessage)
            if let use = model.useAsTeamLibrary {
                let refusal = model.teamLibraryRefusal?(document)
                Button("Use as Team Library") { use(document) }.disabled(refusal != nil).help(refusal ?? "Offer this document's symbols, styles and master pages to the team")
            }
            Divider()
            Button("Move to Trash") { Task { await model.trash(document.id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.document.\(document.id)")
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = model.thumbnailImage(for: document) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
        } else {
            Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.tertiary)
        }
    }
}
