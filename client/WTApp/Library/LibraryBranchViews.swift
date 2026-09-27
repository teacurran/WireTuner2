import SwiftUI

/// A document tile's branches (COLLAB-016): "2 branches" under the name, which shows each active
/// branch nested under the parent -- who last worked in it and when, or "Not yet on the server" --
/// opened by double-click, archived or trashed from its menu.
struct LibraryNestedBranches: View {
    let branches: LibraryBranches
    let parent: LibraryDocument

    static func toggle(_ branches: LibraryBranches, _ parent: String) -> () -> Void { { branches.toggle(parent) } }
    static func open(_ branches: LibraryBranches, _ branch: BranchInfo) -> () -> Void { { branches.openBranch(branch) } }
    static func archive(_ branches: LibraryBranches, _ branch: BranchInfo) -> () -> Void { { Task { await branches.setArchived(branch, true) } } }
    static func trash(_ branches: LibraryBranches, _ branch: BranchInfo) -> () -> Void { { Task { await branches.trashBranch(branch) } } }

    var body: some View {
        let children = branches.branches(of: parent.id)
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Button(action: Self.toggle(branches, parent.id)) {
                    Label(children.count == 1 ? "1 branch" : "\(children.count) branches",
                          systemImage: branches.isExpanded(parent.id) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("library.document.\(parent.id).branches")
                if branches.isExpanded(parent.id) {
                    ForEach(children) { branch in
                        row(branch)
                    }
                }
            }
        }
    }

    private func row(_ branch: BranchInfo) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(branch.name).font(.caption).lineLimit(1)
                let detail = branch.detail()
                if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: Self.open(branches, branch))
        .contextMenu {
            Button("Open", action: Self.open(branches, branch))
            Button("Archive Branch", action: Self.archive(branches, branch)).disabled(!branch.onServer)
            Divider()
            Button("Move to Trash", action: Self.trash(branches, branch)).disabled(!branch.onServer)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.branch.\(branch.id)")
    }
}

/// *Archived* and *Trash* in place of the library's grid (branches.adoc, "Archiving and deleting a
/// branch"): archived and merged branches with their parent, to open or restore to active; the
/// space's trashed documents and branches, to restore.
struct LibraryShelfList: View {
    let branches: LibraryBranches

    static func open(_ branches: LibraryBranches, _ branch: BranchInfo) -> () -> Void { { branches.openBranch(branch) } }
    static func restore(_ branches: LibraryBranches, _ branch: BranchInfo) -> () -> Void { { Task { await branches.setArchived(branch, false) } } }
    static func trash(_ branches: LibraryBranches, _ branch: BranchInfo) -> () -> Void { { Task { await branches.trashBranch(branch) } } }
    static func restore(_ branches: LibraryBranches, _ entry: LibraryTrashEntry) -> () -> Void { { Task { await branches.restore(entry) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = branches.message {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.vertical, 4)
                    .accessibilityIdentifier("library.shelf.message")
            }
            List {
                switch branches.shelf {
                case .archived: archived
                case .trash: trash
                case nil: EmptyView()
                }
            }
        }
    }

    @ViewBuilder private var archived: some View {
        if branches.archived.isEmpty {
            Text("No archived branches").foregroundStyle(.secondary).accessibilityIdentifier("library.archived.empty")
        }
        ForEach(branches.archived) { branch in
            HStack {
                Image(systemName: branch.state == .merged ? "arrow.triangle.merge" : "archivebox")
                VStack(alignment: .leading) {
                    Text(branches.title(of: branch))
                    Text(branch.state == .merged ? "Merged" : "Archived").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open", action: Self.open(branches, branch))
                Button("Restore", action: Self.restore(branches, branch)).help("Make the branch active again")
            }
            .contextMenu {
                Button("Open", action: Self.open(branches, branch))
                Button("Restore Branch", action: Self.restore(branches, branch))
                Divider()
                Button("Move to Trash", action: Self.trash(branches, branch))
            }
            .accessibilityIdentifier("library.archived.\(branch.id)")
        }
    }

    @ViewBuilder private var trash: some View {
        if branches.trash.isEmpty {
            Text("The Trash is empty").foregroundStyle(.secondary).accessibilityIdentifier("library.trash.empty")
        }
        ForEach(branches.trash) { entry in
            HStack {
                Image(systemName: entry.parentID == nil ? "doc.richtext" : "arrow.triangle.branch")
                VStack(alignment: .leading) {
                    Text(entry.document.name)
                    Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore", action: Self.restore(branches, entry))
            }
            .onTapGesture(count: 2) { branches.openTrashed(entry) }
            .accessibilityIdentifier("library.trash.\(entry.id)")
        }
    }

    /// "Branch of Catalogue · deleted 3 days ago"; kept 30 days.
    func detail(_ entry: LibraryTrashEntry) -> String {
        let kind = entry.parentID.map { "Branch of \(branches.parentName($0))" }
        let when = entry.trashedAt.map { "deleted \($0.formatted(.relative(presentation: .named)))" }
        return ([kind, when].compactMap { $0 } + ["kept 30 days"]).joined(separator: " · ")
    }
}
