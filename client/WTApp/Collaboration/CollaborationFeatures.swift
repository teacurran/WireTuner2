import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTSync

/// What one window gets from `CollaborationFeatures`: its branches and title-bar popup, Inspect
/// mode, and the access bar once its sync session is connected.
@MainActor
final class WindowCollaborationUI {
    weak var window: DocumentWindowController?
    let branches: WindowBranches
    let inspect: InspectModeController
    private(set) var popup: NSTitlebarAccessoryViewController?
    private(set) var access: AccessBarAccessory?
    private var statusToken: UUID?

    init(window: DocumentWindowController, features: CollaborationFeatures) {
        self.window = window
        branches = WindowBranches(window: window, features: features)
        inspect = InspectModeController(window: window)
    }

    func install(features: CollaborationFeatures) {
        guard let window else { return }
        let hosting = NSHostingView(rootView: BranchPopupView(branches: branches))
        hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        let popup = NSTitlebarAccessoryViewController()
        popup.view = hosting
        popup.layoutAttribute = .leading
        window.window?.addTitlebarAccessoryViewController(popup)
        self.popup = popup
        Task { await branches.load() }
        attachAccess(features: features)
        statusToken = window.syncStatus.observe { [weak self, weak features] in
            if let features { self?.attachAccess(features: features) }
        }
    }

    /// The access bar, once the session's controller exists.
    func attachAccess(features: CollaborationFeatures) {
        guard access == nil, let window, let offer = features.accessOffer(window) else { return }
        let model = AccessBarModel(offer: offer, title: window.documentHandle.title)
        model.openDocument = features.openDocument
        model.closeWindow = { [weak window] in window?.close() }
        access = AccessBarAccessory(model: model, window: window.window)
        model.start()
    }

    func tearDown() {
        if let statusToken { window?.syncStatus.stopObserving(statusToken) }
        statusToken = nil
        access?.remove()
        inspect.leave()
    }
}

/// The collaboration features of the COLLAB epic's client-ui tasks beyond comments: the branch
/// popup and menu:File[Branch] (COLLAB-016), compare mode for branches and versions (COLLAB-002),
/// menu:File[Restore Version…] (COLLAB-021's UI), Inspect mode (COLLAB-035's app half) and the
/// access bar of a role change (COLLAB-014's UI).
@MainActor
final class CollaborationFeatures {
    enum ID {
        static let newBranch: CommandID = "file.branch.new"
        static let switchBranch: CommandID = "file.branch.switch"
        static let compareBranch: CommandID = "file.branch.compare"
        static let mergeBranch: CommandID = "file.branch.merge"
        static let renameBranch: CommandID = "file.branch.rename"
        static let archiveBranch: CommandID = "file.branch.archive"
        static let trashBranch: CommandID = "file.branch.trash"
        static let restoreVersion: CommandID = "file.restoreVersion"
        static let inspectMode: CommandID = "view.inspectMode"
    }

    static let branchMenu = "Branch"
    static let noDocument = DocumentSetupFeatures.noDocument
    static let offline = "Creating, renaming and archiving branches needs a connection"
    static let notABranch = "This document is not a branch"
    static let mergeLater = "Merging a branch arrives with the merge flow (COLLAB-018)"
    static let noVersions = "Restoring a version needs a connection to list the versions"
    static let restoreSheet = "restore-version-sheet"
    static let branchSheet = "branch-sheet"

    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// `BranchService`, nil offline or signed out.
    var branchClient: @MainActor () -> (any BranchClient)? = { nil }
    /// `VersionService.ListVersions`, nil offline or signed out.
    var versionListing: @MainActor () -> (any VersionListing)? = { nil }
    /// Where branch stores live.
    var storeRoot: @MainActor () throws -> URL = { try BranchStores.defaultRoot() }
    /// Opens a document window (a branch, the parent, a copy).
    var openDocument: @MainActor (String, String) -> Void = { _, _ in }
    /// The state of another document of this Mac (a branch or the parent), nil when not here.
    var state: @MainActor (String) async -> EngineState? = { _ in nil }
    /// The state of `window`'s document at a server seq.
    var versionState: @MainActor (DocumentWindowController, UInt64) async throws -> EngineState = { window, seq in
        guard let session = window.session else { throw BranchError.noStore }
        return try await session.state(atServerSeq: seq)
    }
    /// The access offer of `window`'s session, once connected.
    var accessOffer: @MainActor (DocumentWindowController) -> (any AccessOffering)? = { $0.session?.makeAccessController() }
    var makeID: @MainActor () -> String = { UUIDv7.make() }
    /// Presents a sheet on a window (replaceable in tests).
    var presentSheet: @MainActor (NSWindow, NSWindow?) -> Void = { sheet, parent in
        if let parent { parent.beginSheet(sheet) } else { sheet.makeKeyAndOrderFront(nil) }
    }
    private var windows: [ObjectIdentifier: (window: DocumentWindowController, ui: WindowCollaborationUI)] = [:]
    private var closing: [ObjectIdentifier: NSObjectProtocol] = [:]
    private(set) var sheets: [String: NSWindow] = [:]

    init() {}

    func install(commands: CommandRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        for command in self.commands() { commands.replace(command) }
    }

    // MARK: Windows

    @discardableResult
    func attach(_ window: DocumentWindowController) -> WindowCollaborationUI {
        let key = ObjectIdentifier(window)
        if let existing = windows[key] { return existing.ui }
        let ui = WindowCollaborationUI(window: window, features: self)
        windows[key] = (window, ui)
        ui.install(features: self)
        if let nswindow = window.window {
            closing[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.detach(window) } }
            }
        }
        return ui
    }

    func detach(_ window: DocumentWindowController) {
        let key = ObjectIdentifier(window)
        guard let entry = windows.removeValue(forKey: key) else { return }
        if let observer = closing.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
        entry.ui.tearDown()
    }

    var front: WindowCollaborationUI? { window().map(attach) }

    /// The parent's name for *main* when switching back from a branch.
    func parentTitle(_ document: DocumentHandle) -> String {
        document.title.components(separatedBy: " — ")[0]
    }

    // MARK: Commands

    func commands() -> [Command] {
        let branch: (Int) -> MenuPath = { MenuPath(StandardCommands.Menu.file, Self.branchMenu, section: 1, subsection: $0) }
        let online: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let self, self.front != nil else { return .disabled(Self.noDocument) }
            return self.branchClient() == nil ? .disabled(Self.offline) : .enabled
        }
        let inBranch: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let self, let ui = self.front else { return .disabled(Self.noDocument) }
            guard ui.branches.isBranch else { return .disabled(Self.notABranch) }
            return self.branchClient() == nil ? .disabled(Self.offline) : .enabled
        }
        let hasWindow: @MainActor @Sendable () -> CommandValidation = { [weak self] in self?.front == nil ? .disabled(Self.noDocument) : .enabled }
        return [
            Command(id: ID.newBranch, title: "New Branch…", menu: branch(0), keywords: ["branch", "fork"], validation: online,
                    action: .perform { [weak self] in if let ui = self?.front { self?.presentNewBranch(ui.branches) } }),
            Command(id: ID.switchBranch, title: "Switch To…", menu: branch(1), keywords: ["branch", "main"], validation: hasWindow,
                    action: .perform { [weak self] in self?.presentChooser(compare: false) }),
            Command(id: ID.compareBranch, title: "Compare With…", menu: branch(1), keywords: ["branch", "compare", "diff"], validation: hasWindow,
                    action: .perform { [weak self] in self?.presentChooser(compare: true) }),
            Command(id: ID.mergeBranch, title: "Merge…", menu: branch(1), keywords: ["branch", "merge"],
                    validation: { .disabled(Self.mergeLater) }, action: .perform(Command.noop)),
            Command(id: ID.renameBranch, title: "Rename Branch…", menu: branch(2), keywords: ["branch"], validation: inBranch,
                    action: .perform { [weak self] in if let ui = self?.front { self?.presentRename(ui.branches) } }),
            Command(id: ID.archiveBranch, title: "Archive Branch", menu: branch(2), keywords: ["branch", "archive", "restore"],
                    validation: { [weak self] in
                        let validation = inBranch()
                        guard validation.isEnabled, let current = self?.front?.branches.current else { return validation }
                        return CommandValidation(title: current.state == .active ? "Archive Branch" : "Restore Branch")
                    },
                    action: .perform { [weak self] in self?.front?.branches.toggleArchived() }),
            Command(id: ID.trashBranch, title: "Move Branch to Trash", menu: branch(2), keywords: ["branch", "delete"], validation: inBranch,
                    action: .perform { [weak self] in self?.front?.branches.trashLater() }),
            Command(id: ID.restoreVersion, title: "Restore Version…", menu: MenuPath(StandardCommands.Menu.file, section: 1), keywords: ["history", "version", "revert"],
                    validation: { [weak self] in
                        guard let self, self.front != nil else { return .disabled(Self.noDocument) }
                        return self.versionListing() == nil ? .disabled(Self.noVersions) : .enabled
                    },
                    action: .perform { [weak self] in self?.presentRestore() }),
            Command(id: ID.inspectMode, title: "Inspect Mode", key: KeyEquivalent("i", [.command, .shift]),
                    menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewModes), keywords: ["inspect", "measure", "handoff"],
                    validation: { [weak self] in
                        guard let ui = self?.front else { return .disabled(Self.noDocument) }
                        return .checked(ui.inspect.isOn)
                    },
                    action: .perform { [weak self] in self?.front?.inspect.toggle() }),
        ]
    }

    // MARK: Sheets

    @discardableResult
    func present<Content: View>(_ content: Content, identifier: String, on window: DocumentWindowController?) -> NSWindow {
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: content))
        sheet.identifier = NSUserInterfaceItemIdentifier(identifier)
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        sheets[identifier] = sheet
        presentSheet(sheet, window?.window)
        return sheet
    }

    func dismiss(_ identifier: String) {
        guard let sheet = sheets.removeValue(forKey: identifier) else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }

    /// *New Branch…*: its name, then the branch.
    func presentNewBranch(_ branches: WindowBranches) {
        present(BranchNameSheet(title: "New Branch", button: "Create", name: "") { [weak self] name in
            self?.dismiss(Self.branchSheet)
            if let name { Task { await branches.create(named: name) } }
        }, identifier: Self.branchSheet, on: branches.window)
    }

    func presentRename(_ branches: WindowBranches) {
        present(BranchNameSheet(title: "Rename Branch", button: "Rename", name: branches.current?.name ?? "") { [weak self] name in
            self?.dismiss(Self.branchSheet)
            if let name { Task { await branches.rename(to: name) } }
        }, identifier: Self.branchSheet, on: branches.window)
    }

    /// *Switch To…* or *Compare With…*: main and the branches.
    func presentChooser(compare: Bool) {
        guard let branches = front?.branches else { return }
        let targets = branches.targets.filter { ($0.id ?? branches.parentID) != branches.document.id }
        present(BranchChooserSheet(title: compare ? "Compare With" : "Switch To", targets: targets) { [weak self] choice in
            self?.dismiss(Self.branchSheet)
            guard let choice else { return }
            if compare { Task { await branches.compare(with: choice) } } else { branches.switchTo(choice) }
        }, identifier: Self.branchSheet, on: branches.window)
    }

    func presentCompare(_ model: CompareSheetModel, _ window: DocumentWindowController?) {
        let sheet = present(CompareSheetView(model: model), identifier: CompareSheet.identifier.rawValue, on: window)
        sheet.styleMask.insert(.resizable)
        model.onClose = { [weak self] in self?.dismiss(CompareSheet.identifier.rawValue) }
    }

    /// menu:File[Restore Version…].
    @discardableResult
    func presentRestore() -> RestoreVersionModel? {
        guard let window = window(), let listing = versionListing() else { return nil }
        let document = window.documentHandle
        let model = RestoreVersionModel(
            documentTitle: document.title, list: { try await listing.versions(of: document.id) },
            state: { [self] seq in try await versionState(window, seq) },
            current: { document.state }, perform: { window.objectEditing.perform($0) }
        )
        model.onClose = { [weak self] in self?.dismiss(Self.restoreSheet) }
        model.compare = { [weak self, weak window] compare in
            self?.dismiss(Self.restoreSheet)
            self?.presentCompare(compare, window)
        }
        present(RestoreVersionSheet(model: model), identifier: Self.restoreSheet, on: window)
        Task { await model.load() }
        return model
    }
}

extension AppDelegate {
    /// Branches, compare mode, Restore Version, Inspect mode and the access bar.
    func installCollaborationUI() {
        let documents = documents!
        let account = account
        let library = library
        let infoDictionary = Bundle.main.infoDictionary
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let caller = GRPCUnaryCaller(api: configuration.api, clientVersion: LaunchEnvironment.clientVersion(infoDictionary),
                                     deviceID: DeviceIdentity.current(defaults: preferences.defaults))
        let auth = account.auth
        let token: @Sendable () async throws -> String = { try await auth.validAccessToken() }
        let branches = GRPCBranchClient(caller: caller, accessToken: token)
        let versions = GRPCVersionListing(caller: caller, accessToken: token)
        let testing = launchEnvironment.isTesting
        collaborationUI.branchClient = { !testing && account.isSignedIn && library.isOnline ? branches : nil }
        collaborationUI.versionListing = { !testing && account.isSignedIn && library.isOnline ? versions : nil }
        collaborationUI.openDocument = { id, name in documents.open(documents.environment.makeDocument(id: id, title: name)) }
        collaborationUI.state = { id in
            if let open = documents.documents.first(where: { $0.id == id }) { return open.state }
            guard !testing, let model = try? await documents.environment.openModel(id) else { return nil }
            let state = model.state
            await DocumentOpener.close(model.backend)
            return state
        }
        collaborationUI.install(commands: commands) { documents.activeWindowController }
    }
}
