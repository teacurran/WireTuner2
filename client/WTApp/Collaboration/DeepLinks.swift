import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTSync

/// `ShareService.RequestAccess` (sharing.adoc, "Requesting access"): the request page's one call.
protocol AccessRequesting: Sendable {
    /// Asks the owners for access; the pending request's id.
    func requestAccess(documentID: String, message: String, accessToken: String) async throws -> String
}

extension GRPCShareClient: AccessRequesting {
    func requestAccess(documentID: String, message: String, accessToken: String) async throws -> String {
        let request = Share.RequestAccess.Input.with {
            $0.documentID = documentID
            $0.message = message
        }
        let response: Share.RequestAccess.Output = try await caller.unary(Share.RequestAccess.descriptor, request, accessToken: accessToken)
        return response.requestID
    }
}

/// Links to objects (inspect.adoc, "Links to an object"; COLLAB-038): menu:Edit[Copy Link to
/// Object] and the object context menu's *Copy Link* put the first selected object's
/// `wiretuner://doc/<id>/node/<id>` on the pasteboard, and a `wiretuner://` link (or its
/// `https://<host>/d/…` form) handed to the app opens it: the document's window comes forward or
/// opens -- through the library, like a Handoff (`ContinuityOpener`'s rules) -- the session catches
/// up (nothing is decided before it has: a node may arrive with the changes the Mac is behind by),
/// then the page holding the object is shown, the object scrolled to and selected, Inspect mode
/// entered with the Inspect panel for a viewer; a thread link opens the thread.  A deleted object
/// posts "That object was deleted" in the status bar; an object the caught-up document lacks posts
/// "That object isn't in this document".  A document the account cannot open shows the request
/// page; one this Mac has no copy of while offline shows "Available when online" in the Library.
@MainActor
final class DeepLinkFeatures {
    enum ID {
        static let copyLinkToObject = ContextMenuCatalog.ID.copyLinkToObject
    }

    /// What opening a link did.
    enum Outcome: Equatable {
        case landed(DeepLinkLanding)
        case library(String)
        case requestAccess(String)
    }

    static let deletedNotice = "That object was deleted"
    static let notReceivedNotice = "That object isn't in this document"
    static let noSelection = "Select an object to copy a link to it"
    static let noDocument = DocumentSetupFeatures.noDocument
    static let requestWindow = "request-access"
    static func offlineMessage(_ id: String) -> String { "Available when online: document \(id)" }

    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    var pasteboard: NSPasteboard = .general
    /// The open window of a document, if any.
    var windowFor: @MainActor (String) -> DocumentWindowController? = { _ in nil }
    /// The library's entry for a document (fetched when this Mac has none); nil offline or without access.
    var entry: @MainActor (String) async -> LibraryDocument? = { _ in nil }
    /// Whether this Mac holds a local copy of the document.
    var hasLocalCopy: @MainActor (String) -> Bool = { id in
        (try? LocalStore.defaultURL(documentID: id)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    var isOnline: @MainActor () -> Bool = { true }
    /// Opens a document in a window.
    var open: @MainActor (_ id: String, _ name: String) -> DocumentWindowController? = { _, _ in nil }
    /// Shows the Library window with a message.
    var showLibrary: @MainActor (String) -> Void = { _ in }
    /// The caller's role in a document.
    var role: @MainActor (String) -> DocumentRole = { _ in .owner }
    /// A window's Inspect mode.
    var inspect: @MainActor (DocumentWindowController) -> InspectModeController? = { _ in nil }
    var showPanel: @MainActor (PanelID) -> Void = { _ in }
    /// Opens a thread in a window (the Comments panel's select).
    var showThread: @MainActor (DocumentWindowController, OpID) -> Void = { _, _ in }
    /// Whether a window's session has caught up (or cannot: offline, signed out, no session).
    var caughtUp: @MainActor (DocumentWindowController) async -> Bool = { window in await DeepLinkFeatures.caughtUp(window) }
    /// `RequestAccess` with the signed-in account's token; nil when signed out.
    var requestAccess: (@MainActor (String, String) async throws -> Void)?
    /// Shows the request page.
    var presentRequest: @MainActor (RequestAccessModel) -> Void = { model in DeepLinkFeatures.presentWindow(model) }
    /// How often a landing checks whether the session has caught up.
    var pollInterval: Duration = .milliseconds(50)
    /// The last request page shown.
    private(set) var request: RequestAccessModel?

    init() {}

    func install(commands: CommandRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        commands.replace(command())
    }

    func command() -> Command {
        Command(id: ID.copyLinkToObject, title: "Copy Link to Object", menu: MenuPath(StandardCommands.Menu.edit, section: 1),
                contexts: ContextMenuCatalog.objectContexts, keywords: ["link", "url", "share", "deep link"],
                validation: { [weak self] in
                    guard let window = self?.window() else { return .disabled(Self.noDocument) }
                    return Self.link(for: window) == nil ? .disabled(Self.noSelection) : .enabled
                },
                action: .perform { [weak self] in self?.copyLink() })
    }

    // MARK: Copying

    /// The link to `window`'s first selected object.
    static func link(for window: DocumentWindowController) -> DeepLink? {
        guard let node = window.selection.selection.ids.first?.opID else { return nil }
        return DeepLink(documentID: window.documentHandle.id, target: .node(node))
    }

    /// *Copy Link to Object*: the link as a URL and as plain text.
    @discardableResult
    func copyLink() -> URL? {
        guard let window = window(), let link = Self.link(for: window) else { return nil }
        pasteboard.clearContents()
        pasteboard.writeObjects([link.url as NSURL])
        pasteboard.setString(link.url.absoluteString, forType: .string)
        return link.url
    }

    // MARK: Opening

    /// Opens `url` if it is a deep link; false for any other URL.
    @discardableResult
    func opens(_ url: URL) -> Task<Outcome, Never>? {
        guard let link = DeepLink(url: url) else { return nil }
        return Task { await self.open(link) }
    }

    /// Opens `link`: its document's window, then where the link points.
    func open(_ link: DeepLink) async -> Outcome {
        let id = link.documentID
        if let existing = windowFor(id) {
            existing.showWindow(nil)
            return .landed(await land(link, in: existing))
        }
        let entry = await entry(id)
        if let entry, entry.isTrashed {
            return library(ContinuityOpener.trashedMessage(entry.name))
        }
        guard entry != nil || hasLocalCopy(id) else {
            guard isOnline() else { return library(Self.offlineMessage(id)) }
            let model = RequestAccessModel(documentID: id, send: requestAccess)
            request = model
            presentRequest(model)
            return .requestAccess(id)
        }
        guard let opened = open(id, entry?.name ?? LibraryModel.untitled) else { return library(ContinuityOpener.unavailableMessage()) }
        return .landed(await land(link, in: opened))
    }

    private func library(_ message: String) -> Outcome {
        showLibrary(message)
        return .library(message)
    }

    /// Waits for the document and its catch-up, then goes where `link` points.
    func land(_ link: DeepLink, in window: DocumentWindowController) async -> DeepLinkLanding {
        _ = await window.documentHandle.openedModel()
        while true {
            let caught = await caughtUp(window)
            let landing = DeepLinkLanding.decide(link, in: window.documentHandle.state, caughtUp: caught)
            if landing != .wait {
                apply(landing, link: link, in: window)
                return landing
            }
            // The window closed meanwhile: nothing to land in.
            guard windowFor(link.documentID) === window, !Task.isCancelled else { return .wait }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func apply(_ landing: DeepLinkLanding, link: DeepLink, in window: DocumentWindowController) {
        let viewer = role(link.documentID) == .viewer
        if viewer, let inspect = inspect(window), !inspect.isOn { inspect.enter() }
        switch landing {
        case .select(let node):
            window.selection.model.set(Selection([SelectionID(node)]))
            reveal(window)
            if viewer { showPanel(InspectPanel.id) }
        case .openThread(let thread):
            showThread(window, thread)
        case .deleted:
            window.statusBar.show(message: Self.deletedNotice)
        case .notReceived:
            window.statusBar.show(message: Self.notReceivedNotice)
        case .document, .wait:
            break
        }
    }

    /// Shows the page holding the selection and scrolls it to the middle of the view.
    private func reveal(_ window: DocumentWindowController) {
        guard let bounds = window.selection.selectedBounds else { return }
        let center = Point(x: bounds.midX, y: bounds.midY)
        let document = window.documentHandle
        if let page = document.pageList.page(containing: center), page.id != document.activePage.id {
            document.selectPage(id: page.id)
        }
        window.canvas.setViewport(window.canvas.navigation.centring(window.canvas.viewport, on: center))
    }

    /// Whether `window`'s session has applied the log to the head (true without a session, and
    /// when it cannot: offline, signed out, failed).
    static func caughtUp(_ window: DocumentWindowController) async -> Bool {
        guard let session = window.session else { return true }
        if let client = session.client, await client.isCaughtUp { return true }
        switch window.syncStatus.state {
        case .offline, .needsSignIn, .error: return true
        default: return false
        }
    }

    static func presentWindow(_ model: RequestAccessModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: RequestAccessView(model: model)))
        window.identifier = NSUserInterfaceItemIdentifier(requestWindow)
        window.title = "Request Access"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

/// The request page (sharing.adoc, "Requesting access"): the document (its name when a failed
/// share link named it, else its id), a message and btn:[Request Access].
@MainActor
@Observable
final class RequestAccessModel {
    enum Phase: Equatable {
        case asking
        case sending
        case sent
        case failed(String)
    }

    static let signedOut = "Sign in to request access."
    static let sentText = "Your request was sent. You'll be told when the owner answers."

    let documentID: String
    let documentName: String
    var message = ""
    private(set) var phase = Phase.asking
    @ObservationIgnored private let send: (@MainActor (String, String) async throws -> Void)?

    init(documentID: String, documentName: String = "", send: (@MainActor (String, String) async throws -> Void)?) {
        self.documentID = documentID
        self.documentName = documentName
        self.send = send
    }

    var canSend: Bool { phase != .sending && phase != .sent }

    func submit() async {
        guard let send else {
            phase = .failed(Self.signedOut)
            return
        }
        phase = .sending
        do {
            try await send(documentID, String(message.prefix(2000)))
            phase = .sent
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct RequestAccessView: View {
    @Bindable var model: RequestAccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You don't have access to this document").font(.headline)
            if !model.documentName.isEmpty { Text("“\(model.documentName)”").accessibilityIdentifier("request-access.name") }
            Text(model.documentID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("Message to the owner (optional)", text: $model.message, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("request-access.message")
            switch model.phase {
            case .sent: Text(RequestAccessModel.sentText).foregroundStyle(.secondary)
            case .failed(let reason): Text(reason).foregroundStyle(.red)
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button("Request Access", action: Self.submit(model))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("request-access.send")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    static func submit(_ model: RequestAccessModel) -> () -> Void {
        { Task { await model.submit() } }
    }
}

extension AppDelegate {
    /// Deep links: the command, and opening through the library as a Handoff does.
    func installDeepLinks() {
        let documents = documents!
        let library = library
        let collaboration = collaboration
        let collaborationUI = collaborationUI
        let comments = comments
        let layout = layout
        deepLinks.windowFor = { documents.views(of: $0).first }
        deepLinks.entry = { await library.document(withID: $0) }
        deepLinks.isOnline = { library.isOnline }
        deepLinks.open = { id, name in documents.open(documents.environment.makeDocument(id: id, title: name)) }
        deepLinks.showLibrary = { [weak self] message in
            self?.showLibrary()
            library.show(message: message)
        }
        deepLinks.role = { library.cache.documents[$0]?.role ?? .owner }
        deepLinks.inspect = { collaborationUI.attach($0).inspect }
        deepLinks.showPanel = { layout.showPanel($0) }
        deepLinks.showThread = { window, thread in comments.attach(window).show(thread) }
        deepLinks.requestAccess = { id, message in
            guard let requests = collaboration.shares as? any AccessRequesting else { throw AuthError.notSignedIn }
            _ = try await requests.requestAccess(documentID: id, message: message, accessToken: try await collaboration.accessToken())
        }
        deepLinks.install(commands: commands) { documents.activeWindowController }
        installShareLinks()
    }

    /// Share links (`OpenLink`), and what the Share sheet needs from the library: the caller's
    /// teams for Invite's suggestions, the spaces for *Move to*, and btn:[Share]'s request badge
    /// (COLLAB-013).
    func installShareLinks() {
        let documents = documents!
        let library = library
        let shareRequests = shareRequests
        shareLinks.isOnline = { library.isOnline }
        shareLinks.refreshLibrary = { await library.refresh() }
        shareLinks.open = { id, name in documents.open(documents.environment.makeDocument(id: id, title: name)) }
        shareLinks.showLibrary = { [weak self] message in
            self?.showLibrary()
            library.show(message: message)
        }
        shareLinks.requestAccess = deepLinks.requestAccess
        sharePresenter.configure = { model in
            model.teams = library.cache.teams
            model.spaces = library.spaces
            let id = model.document.id
            model.moveToSpace = { space in await library.move(id, toSpace: space) }
            model.requestsDidChange = { shareRequests.set($0, count: $1) }
        }
    }
}
