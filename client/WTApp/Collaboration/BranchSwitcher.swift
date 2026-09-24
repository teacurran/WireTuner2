import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTSync

/// A window's branches (COLLAB-016; branches.adoc): whether the document is the parent (*main*)
/// or a branch of it, the parent's active branches from `BranchService` with the ones made on
/// this Mac that the server does not hold yet, and the lifecycle actions -- create, rename,
/// archive or restore, trash, switch and compare.  Switching opens the other document's own
/// store (so each branch keeps its own zoom and page) and closes this window.
@MainActor
@Observable
final class WindowBranches {
    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let features: CollaborationFeatures
    /// The parent document's id (this document's own when it is the parent).
    private(set) var parentID: String
    /// This document as a branch; nil for the parent.
    private(set) var current: BranchInfo?
    /// The parent's active branches (and those not yet on the server), by name.
    private(set) var branches: [BranchInfo] = []
    private(set) var archived: [BranchInfo] = []
    private(set) var message: String?
    private(set) var isLoading = false

    init(window: DocumentWindowController, features: CollaborationFeatures) {
        self.window = window
        document = window.documentHandle
        self.features = features
        parentID = window.documentHandle.id
    }

    var isBranch: Bool { current != nil }
    /// The popup's title: *main* in the parent, the branch's name in a branch.
    var title: String { current?.name ?? "main" }

    /// Reads the branch stores on this Mac and, when online, the parent's branches.
    @discardableResult
    func load() async -> [BranchInfo] {
        isLoading = true
        defer { isLoading = false }
        let local = ((try? BranchStores.branches(in: features.storeRoot())) ?? []).map(BranchInfo.init)
        if let own = local.first(where: { $0.id == document.id }) {
            parentID = own.parentID
            current = own
        }
        var listed: [BranchInfo] = []
        if let client = features.branchClient() {
            if current == nil, let own = await client.branch(document.id) {
                parentID = own.parentID
                current = own
            }
            do {
                listed = try await client.list(parent: parentID, includeArchived: true)
                if let own = listed.first(where: { $0.id == document.id }) { current = own }
            } catch {
                message = "Branches could not be listed: \(error.localizedDescription)"
            }
        }
        let serverIDs = Set(listed.map(\.id))
        let pending = local.filter { $0.parentID == parentID && !serverIDs.contains($0.id) }
        let all = (listed + pending).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        branches = all.filter { $0.state == .active }
        archived = all.filter { $0.state != .active }
        return branches
    }

    /// The popup's rows: *main*, then each active branch.
    var targets: [(id: String?, title: String, detail: String)] {
        [(nil, "main", "")] + branches.map { ($0.id, $0.name, $0.detail()) }
    }

    /// Opens the parent (nil) or branch `id` in place of this window.
    func switchTo(_ id: String?) {
        let target = id ?? parentID
        guard target != document.id else { return }
        let name = id.flatMap { id in (branches + archived).first { $0.id == id }?.name } ?? features.parentTitle(document)
        features.openDocument(target, name)
        window?.close()
    }

    /// *New Branch…*: created on the server (it needs the network) at the head this window has
    /// applied, then opened.
    @discardableResult
    func create(named name: String) async -> BranchInfo? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let client = features.branchClient() else {
            message = CollaborationFeatures.offline
            return nil
        }
        do {
            let branch = try await client.create(parent: parentID, branchID: features.makeID(), name: name, forkServerSeq: 0)
            branches.append(branch)
            features.openDocument(branch.id, branch.name)
            return branch
        } catch {
            message = "The branch could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    /// *Rename Branch…*.
    @discardableResult
    func rename(to name: String) async -> Bool {
        guard let current, let client = features.branchClient(), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        do {
            self.current = try await client.rename(current.id, to: name)
            await load()
            return true
        } catch {
            message = "The branch could not be renamed: \(error.localizedDescription)"
            return false
        }
    }

    /// *Archive Branch* / *Restore Branch*.
    @discardableResult
    func setArchived(_ archived: Bool) async -> Bool {
        guard let current, let client = features.branchClient() else { return false }
        do {
            self.current = try await client.setArchived(current.id, archived)
            await load()
            return true
        } catch {
            message = "The branch could not be \(archived ? "archived" : "restored"): \(error.localizedDescription)"
            return false
        }
    }

    /// *Archive Branch* or *Restore Branch*, as the branch is now.
    @discardableResult
    func toggleArchived() -> Task<Bool, Never> {
        Task { await setArchived(current?.state == .active) }
    }

    /// The menu's *Move Branch to Trash*.
    @discardableResult
    func trashLater() -> Task<Bool, Never> {
        Task { await trash() }
    }

    /// *Move Branch to Trash*: kept 30 days like any document; the window goes back to main.
    @discardableResult
    func trash() async -> Bool {
        guard let current, let client = features.branchClient() else { return false }
        guard window?.confirm("Move “\(current.name)” to the Trash?", "The branch is kept in the Trash for 30 days.") == true else { return false }
        do {
            try await client.delete(current.id)
            switchTo(nil)
            return true
        } catch {
            message = "The branch could not be moved to the Trash: \(error.localizedDescription)"
            return false
        }
    }

    /// *Compare With*: the review sheet in compare mode, this document against the parent or
    /// branch `id` as this Mac last saw it; nothing is written.
    @discardableResult
    func compare(with id: String?) async -> CompareSheetModel? {
        let other = id ?? parentID
        guard other != document.id, let state = await features.state(other) else {
            message = "That version is not on this Mac yet"
            return nil
        }
        let otherTitle = id.flatMap { id in (branches + archived).first { $0.id == id }?.name } ?? "Main"
        let mine = isBranch ? "Branch" : "Main"
        let comparison = DocumentComparison(a: document.state, b: state)
        let model = CompareSheetModel(comparison: comparison, titleA: mine, titleB: otherTitle == mine ? "Other" : otherTitle,
                                      heading: "Compare \(title) with \(id == nil ? "main" : otherTitle)")
        features.presentCompare(model, window)
        return model
    }
}

/// The branch popup in the title bar: *main* and every active branch with who last worked in it
/// and when, a "not yet on the server" marker, and *New Branch…*.
struct BranchPopupView: View {
    let branches: WindowBranches

    static func switchTo(_ branches: WindowBranches, _ id: String?) -> () -> Void { { branches.switchTo(id) } }
    static func newBranch(_ branches: WindowBranches) -> () -> Void { { branches.features.presentNewBranch(branches) } }

    var body: some View {
        Menu {
            ForEach(branches.targets, id: \.title) { target in
                Button(target.detail.isEmpty ? target.title : "\(target.title) — \(target.detail)", action: Self.switchTo(branches, target.id))
            }
            Divider()
            Button("New Branch…", action: Self.newBranch(branches)).disabled(branches.features.branchClient() == nil)
        } label: {
            Label(branches.title, systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("branch.popup")
    }
}

/// A name for a new or renamed branch.
struct BranchNameSheet: View {
    let title: String
    let button: String
    @State var name: String
    let finish: @MainActor (String?) -> Void

    static func cancel(_ finish: @escaping @MainActor (String?) -> Void) -> () -> Void { { finish(nil) } }
    static func confirm(_ name: String, _ finish: @escaping @MainActor (String?) -> Void) -> () -> Void { { finish(name) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Name", text: $name).frame(width: 260).accessibilityIdentifier("branch.name")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(finish)).keyboardShortcut(.cancelAction)
                Button(button, action: Self.confirm(name, finish)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// *Switch To…* and *Compare With…*: *main* and the branches to choose from.
struct BranchChooserSheet: View {
    let title: String
    let targets: [(id: String?, title: String, detail: String)]
    let finish: @MainActor (String??) -> Void

    static func choose(_ id: String?, _ finish: @escaping @MainActor (String??) -> Void) -> () -> Void { { finish(.some(id)) } }
    static func cancel(_ finish: @escaping @MainActor (String??) -> Void) -> () -> Void { { finish(nil) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(targets, id: \.title) { target in
                Button(action: Self.choose(target.id, finish)) {
                    VStack(alignment: .leading) {
                        Text(target.title)
                        if !target.detail.isEmpty { Text(target.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.link)
            }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(finish)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 280)
    }
}
