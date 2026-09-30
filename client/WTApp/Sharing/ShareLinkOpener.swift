import AppKit
import Observation
import SwiftUI
import WTProto

/// Opening a share link (sharing.adoc, "Share links" and "Requesting access"): an
/// `https://<host>/l/<token>` link (or `wiretuner://link/<token>`) handed to the app runs
/// `ShareService.OpenLink` as the signed-in person.  When it opens, the library learns of the
/// document and its window opens.  A link with a password asks for it on a small page, and
/// again when it is wrong.  A link that cannot open -- expired, revoked, or restricted to a team
/// the person is not in -- shows the request page with the document's name when the server
/// names the document, and otherwise says in the library that the link does not work.  Offline
/// or signed out, the library says why nothing opened.
@MainActor
final class ShareLinkOpener {
    enum Outcome: Equatable {
        case opened(OpenedShareLink)
        /// The password page is showing (again, when `wrong`).
        case password(wrong: Bool)
        case requestAccess(ShareLinkDocument)
        /// The library shows `message`.
        case library(String)
    }

    static let windowIdentifier = "share-link"
    static let deadMessage = "This link doesn’t work. It may have expired or been revoked; ask the person who sent it for a new one."
    static let offlineMessage = "Share links open when you are online."
    static let signedOutMessage = "Sign in to open this share link."
    static let tokenLength = 16...64

    let services: CollaborationServices
    var isOnline: @MainActor () -> Bool = { true }
    /// Brings the library up to date (the opened document is listed under *Shared with me*).
    var refreshLibrary: @MainActor () async -> Void = {}
    /// Opens the document's window.
    var open: @MainActor (_ id: String, _ name: String) -> Void = { _, _ in }
    /// Shows the library window with a message.
    var showLibrary: @MainActor (String) -> Void = { _ in }
    /// `RequestAccess` for the request page; nil when signed out.
    var requestAccess: (@MainActor (String, String) async throws -> Void)?
    /// Shows the request page.
    var presentRequest: @MainActor (RequestAccessModel) -> Void = { DeepLinkFeatures.presentWindow($0) }
    /// Shows the password page.
    var presentPassword: @MainActor (ShareLinkPasswordModel) -> Void = { ShareLinkOpener.presentWindow($0) }
    /// The password page last shown, and the request page.
    private(set) var passwordPage: ShareLinkPasswordModel?
    private(set) var request: RequestAccessModel?

    init(services: CollaborationServices) {
        self.services = services
    }

    /// The token of a share link: `http(s)://<host>/l/<token>` or `wiretuner://link/<token>`.
    static func token(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return nil }
        let path = components.percentEncodedPath.split(separator: "/").map(String.init)
        let token: String
        switch scheme {
        case "https", "http":
            guard path.count == 2, path[0] == "l" else { return nil }
            token = path[1]
        case "wiretuner":
            guard components.host?.lowercased() == "link", path.count == 1 else { return nil }
            token = path[0]
        default:
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard tokenLength.contains(token.count), token.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return token
    }

    /// Opens `url` if it is a share link; nil for any other URL.
    @discardableResult
    func opens(_ url: URL) -> Task<Outcome, Never>? {
        guard let token = Self.token(in: url) else { return nil }
        return Task { await self.open(token: token) }
    }

    /// `OpenLink` with `password`, and what follows.
    func open(token: String, password: String = "") async -> Outcome {
        guard isOnline() else { return library(Self.offlineMessage) }
        do {
            let accessToken = try await services.accessToken()
            let opened = try await services.shares.openLink(token: token, password: password, accessToken: accessToken)
            passwordPage?.close()
            passwordPage = nil
            await refreshLibrary()
            open(opened.documentID, opened.documentName)
            return .opened(opened)
        } catch AuthError.notSignedIn {
            return library(Self.signedOutMessage)
        } catch let failure as ShareLinkFailure {
            return refused(failure, token: token, password: password)
        } catch where CollaborationErrors.isOffline(error) {
            return library(Self.offlineMessage)
        } catch {
            return library(CollaborationErrors.message(for: error) ?? Self.deadMessage)
        }
    }

    private func refused(_ failure: ShareLinkFailure, token: String, password: String) -> Outcome {
        if failure == .passwordRequired {
            let wrong = !password.isEmpty
            if let page = passwordPage {
                page.refused(wrong: wrong)
            } else {
                let page = ShareLinkPasswordModel(token: token) { [weak self] token, password in
                    _ = await self?.open(token: token, password: password)
                }
                passwordPage = page
                presentPassword(page)
            }
            return .password(wrong: wrong)
        }
        passwordPage?.close()
        passwordPage = nil
        guard let document = failure.requestable else { return library(Self.deadMessage) }
        let model = RequestAccessModel(documentID: document.id, documentName: document.name, send: requestAccess)
        request = model
        presentRequest(model)
        return .requestAccess(document)
    }

    private func library(_ message: String) -> Outcome {
        showLibrary(message)
        return .library(message)
    }

    static func presentWindow(_ model: ShareLinkPasswordModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ShareLinkPasswordView(model: model)))
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.title = "Open Share Link"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        model.close = { [weak window] in window?.close() }
    }
}

/// The page a link with a password shows: the password and btn:[Open].
@MainActor
@Observable
final class ShareLinkPasswordModel {
    static let prompt = "This link is protected by a password. Type it to open the document."
    static let wrongText = "That password isn’t right. Try again, or ask the person who sent the link."

    let token: String
    var password = ""
    private(set) var isWrong = false
    private(set) var isSending = false
    @ObservationIgnored var close: @MainActor () -> Void = {}
    @ObservationIgnored private let send: @MainActor (String, String) async -> Void

    init(token: String, send: @escaping @MainActor (String, String) async -> Void) {
        self.token = token
        self.send = send
    }

    var canSubmit: Bool { !password.isEmpty && !isSending }

    func submit() async {
        guard canSubmit else { return }
        isSending = true
        await send(token, password)
        isSending = false
    }

    /// The server refused the password (or none was given).
    func refused(wrong: Bool) {
        isWrong = wrong
        password = ""
    }
}

struct ShareLinkPasswordView: View {
    @Bindable var model: ShareLinkPasswordModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This link needs a password").font(.headline)
            Text(ShareLinkPasswordModel.prompt).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $model.password)
                .onSubmit(Self.submit(model))
                .accessibilityIdentifier("share-link.password")
            if model.isWrong {
                Text(ShareLinkPasswordModel.wrongText).foregroundStyle(.red).font(.callout).accessibilityIdentifier("share-link.wrong")
            }
            HStack {
                Spacer()
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Open", action: Self.submit(model))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("share-link.open")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    static func submit(_ model: ShareLinkPasswordModel) -> () -> Void {
        { Task { await model.submit() } }
    }
}
