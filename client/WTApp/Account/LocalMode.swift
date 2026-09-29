import Foundation
import Observation

/// Local mode (decisions.adoc D-079; saving.adoc, "Using WireTuner without an account"): the app
/// used fully without a server.  A build is a *Local mode build* when `WT_LOCAL_MODE` is `YES`
/// (the Release default until a server exists) or when it has no server configured (`WT_API_URL`
/// or `WT_AUTH_ISSUER` empty or absent).  A build with a server runs in Local mode while nobody is
/// signed in and the person chose *Use Without an Account*; signing in leaves it.
///
/// In Local mode no document syncs (the indicator reads *On this Mac*), nothing asks to sign in,
/// quitting never waits for uploads, the library works on this Mac's cache alone, and the features
/// that need the server are disabled with `LocalMode.needsAccount` as the reason.  Documents keep
/// their pending-upload state, so they upload to the personal space once an account exists.
@MainActor
@Observable
final class LocalMode {
    /// The Info.plist key `WT_LOCAL_MODE` is written to.
    nonisolated static let infoKey = "WTLocalMode"
    /// Where *Use Without an Account* is remembered.
    static let choiceKey = "WTUseWithoutAccount"
    /// The reason every server-only feature gives in Local mode.
    static let needsAccount = "Needs a WireTuner account"
    /// Why *Remove Local Copy* is refused in Local mode: the copy on this Mac is the only one.
    static let onlyCopy = "This Mac has the only copy of documents made without an account"

    /// The build has no server (`WT_LOCAL_MODE`, or no endpoints): sign-in is not offered at all.
    let isLocalBuild: Bool
    /// The person chose *Use Without an Account* (a build with a server).
    private(set) var usesWithoutAccount: Bool
    @ObservationIgnored let defaults: UserDefaults?
    /// Whether an account is signed in (`AccountModel.isSignedIn`).
    @ObservationIgnored var isSignedIn: @MainActor () -> Bool = { false }
    @ObservationIgnored private var observers: [UUID: @MainActor (Bool) -> Void] = [:]
    /// The last answer observers were told, so a sign-in that ends Local mode is noticed once.
    @ObservationIgnored private var lastActive: Bool?

    init(isLocalBuild: Bool, defaults: UserDefaults? = nil) {
        self.isLocalBuild = isLocalBuild
        self.defaults = defaults
        usesWithoutAccount = defaults?.bool(forKey: Self.choiceKey) ?? false
    }

    /// From the Info.plist: `WTLocalMode` true, or a server endpoint missing, empty or unexpanded.
    convenience init(infoDictionary: [String: Any]?, defaults: UserDefaults?) {
        self.init(isLocalBuild: Self.isLocalBuild(infoDictionary), defaults: defaults)
    }

    /// Whether the Info.plist describes a Local mode build.
    nonisolated static func isLocalBuild(_ infoDictionary: [String: Any]?) -> Bool {
        if let flag = infoDictionary?[infoKey] as? Bool { if flag { return true } }
        if let text = infoDictionary?[infoKey] as? String, ["YES", "TRUE", "1"].contains(text.uppercased()) { return true }
        func configured(_ key: String) -> Bool {
            guard let text = infoDictionary?[key] as? String else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("$(") && URL(string: trimmed)?.scheme != nil
        }
        return !configured(AuthConfiguration.apiInfoKey) || !configured(AuthConfiguration.issuerInfoKey)
    }

    /// Whether the app is in Local mode now.
    var isActive: Bool { isLocalBuild || (usesWithoutAccount && !isSignedIn()) }

    /// Whether signing in is offered (menu, popover, account window): never in a Local mode build.
    var offersSignIn: Bool { !isLocalBuild }

    /// *Use Without an Account*: Local mode until someone signs in (kept across launches).
    func useWithoutAccount() {
        guard !usesWithoutAccount else { return }
        usesWithoutAccount = true
        defaults?.set(true, forKey: Self.choiceKey)
        changed()
    }

    /// The account signed in or out: observers hear whether that ended or started Local mode.
    func accountDidChange() {
        changed()
    }

    /// Told `isActive` whenever it changes.
    @discardableResult
    func observe(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
        if lastActive == nil { lastActive = isActive }
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    private func changed() {
        let active = isActive
        guard active != lastActive else { return }
        lastActive = active
        for observer in observers.values { observer(active) }
    }

    /// The validation of a command that needs the server: disabled with the reason in Local mode.
    func gate(_ id: CommandID) -> CommandValidation? {
        guard isActive else { return nil }
        if id == LocalCopyRemoval.id { return .disabled(Self.onlyCopy) }
        return ServerFeatures.commands.contains(id) ? .disabled(Self.needsAccount) : nil
    }
}

/// The commands that need the server (D-079): sharing, comments, branches and merging, the server's
/// version list, collaborators' presence, team libraries.  Local mode disables each with
/// `LocalMode.needsAccount`; nothing is removed from the menus, so the menus look the same in
/// every build.
enum ServerFeatures {
    static let commands: Set<CommandID> = [
        // Sharing (sharing.adoc).
        "file.share",
        // Comments (comments.adoc).
        "object.addComment", "view.comments.showPins", "view.comments.showResolved", "view.comments.followFilter", "tool.comment",
        // Branches and merging (branches.adoc, collaboration.adoc).
        "file.branch.new", "file.branch.switch", "file.branch.compare", "file.branch.merge", "file.branch.rename",
        "file.branch.archive", "file.branch.trash", "file.reviewMerge",
        // The server's version list (history.adoc).  Save Version, Name This Version and the
        // History panel work on this Mac's log; their versions wait to upload (D-079).
        "file.restoreVersion",
        // Collaborators (presence.adoc).
        "view.collaborators.spotlight", "view.collaborators.stopFollowing", "view.collaborators.inspectSelection",
        // Team libraries (library.adoc, exporting-colors.adoc).
        "file.makeTeamColorLibrary", "file.publishLibraryVersion",
        // Web data sources are fetched by the service (data-merge.adoc).
        "data.credentials", "data.showHosts",
    ]
}
