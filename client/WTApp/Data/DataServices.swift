import AppKit
import Foundation
import GRPCNIOTransportHTTP2
import WTModel
import WTProto
import WTSync

/// Whose credentials and permitted hosts a document uses (data-merge.adoc, "Credentials", "Hosts
/// and permissions"): a team's, written by its admins only (D-062), or the owner's account's for a
/// personal document, written by the owner.
struct DataScope: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case personal(account: String)
        case team(id: String, name: String)
    }

    var kind: Kind
    /// Whether this person adds, replaces and removes credentials and permitted hosts here: a
    /// team admin, or the owner of a personal document.
    var canManage: Bool

    var isPersonal: Bool {
        if case .personal = kind { return true }
        return false
    }

    /// The scope the credential and allowlist RPCs take.
    var proto: Wiretuner_Data_V1_Scope {
        var scope = Wiretuner_Data_V1_Scope()
        switch kind {
        case .personal(let account): scope.accountID = account
        case .team(let id, _): scope.teamID = id
        }
        return scope
    }

    /// Who may change credentials here, for the read-only sheet's explanation.
    var managerNote: String {
        switch kind {
        case .personal: "Only the document's owner can add, replace or remove its credentials."
        case .team(_, let name): "Only admins of \(name) can add, replace or remove its credentials."
        }
    }
}

/// What the data features reach beyond the document: the data service client, the document's
/// scope, the consent sheet.  The app wires the network and the account; tests supply fakes.
@MainActor
struct DataServices {
    /// The data service on this Mac; nil when signed out (every fetch then reads as offline).
    var client: @MainActor () -> DataSourceClient? = { nil }
    /// The document's scope, from the library and the team (nil when unknown: signed out).
    var scope: @MainActor (DocumentHandle) async -> DataScope? = { _ in nil }
    /// The consent sheet on a personal document (`HOST_NOT_ALLOWED`): whether the person permits
    /// `host` for their account.  Asked once per host.
    var consent: @MainActor @Sendable (DocumentWindowController?, String) async -> Bool = { window, host in await DataConsent.ask(host: host, window: window) }
    /// The signed-in account's id: `wt.fetch` asks consent only in a personal document of it.
    var accountID: @MainActor () -> String? = { nil }
}

/// The consent sheet (data-merge.adoc, "Hosts and permissions"): an alert naming the document and
/// the host; *Allow* permits the host on the account's own list.
@MainActor
enum DataConsent {
    static func message(host: String, document: String) -> (String, String) {
        ("Allow “\(document)” to fetch data from \(host)?",
         "The request is made by the WireTuner cloud with your credentials. \(host) is added to the hosts your account permits, on every Mac you use.")
    }

    /// Runs the alert (a sheet on `window` when given); the answer.
    static func ask(host: String, window: DocumentWindowController?, run: @MainActor (NSAlert, NSWindow?) async -> NSApplication.ModalResponse = present) async -> Bool {
        let alert = NSAlert()
        let (message, detail) = message(host: host, document: window?.documentHandle.title ?? "This document")
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return await run(alert, window?.window) == .alertFirstButtonReturn
    }

    static func present(_ alert: NSAlert, on window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

/// The consent sheet was answered *Don't Allow*: the fetch fails with the documented message.
struct DataConsentDenied: Error, Equatable {
    let host: String
}

/// Messages for data-service failures, as the panel and the sheets show them.
enum DataServiceMessages {
    static let offline = "Offline -- showing the embedded sample. Refresh needs a connection to the WireTuner service."
    static let signedOut = "Sign in to fetch from a web API."

    static func text(_ error: any Error) -> String {
        switch error {
        case let error as DataServiceError:
            switch error {
            case .offline: return offline
            case .hostNotAllowed(let host, let admins):
                return admins.isEmpty ? "\(host) is not a permitted host." : "\(host) is not a permitted host. Ask \(admins) to permit it."
            case .credentialMissing: return "The credential this source names does not exist. Choose Credentials… to add it."
            case .responseTooLarge: return "The response is too large."
            case .upstream(let message): return "The web API failed: \(message)"
            case .rateLimited(let delay):
                return "The fair-use limit was reached" + (delay.map { "; fetching resumes in \(Int($0.components.seconds)) s." } ?? ".")
            case .rejected(_, let message): return message
            }
        case let error as DataConsentDenied: return "Fetching from \(error.host) was not permitted."
        case let error as DataEditError: return DataEditMessages.text(error)
        case let error as ScriptError: return error.description
        default: return String(describing: error)
        }
    }
}

/// The messages of refused data edits.
enum DataEditMessages {
    static func text(_ error: DataEditError) -> String {
        switch error {
        case .invalidName(let name): "“\(name)” is not a valid field name: use letters, digits and underscores, starting with a letter."
        case .duplicateName(let name): "A field named “\(name)” already exists."
        case .unknownField: "That field no longer exists."
        case .unknownSource: "That source no longer exists."
        case .bindingNotAllowed: "That binding does not apply to this object."
        case .secretHeader(let name): "The \(name) header cannot be stored in a source: add a credential instead."
        case .invalidURL(let url): "“\(url)” is not an https address."
        case .noPlaceholder: "There is no placeholder before the insertion point."
        case .invalidValue(let what): "\(what) is out of range."
        }
    }
}

extension LaunchEnvironment {
    /// The data service client over the configured API, caching in the data-sources folder; none
    /// in test launches.
    @MainActor
    func makeDataSourceClient(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults) -> DataSourceClient? {
        guard !isTesting, let directory = try? DataSourceClient.defaultDirectory() else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: Self.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: defaults)
        )
        guard let transport = try? GRPCDataSourceTransport.http2(api: configuration.api, identity: identity) else { return nil }
        let auth = account.auth
        return DataSourceClient(transport: transport, directory: directory) { try await auth.validAccessToken() }
    }
}
