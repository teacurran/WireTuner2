import Foundation
import SwiftProtobuf
import WTProto

/// A document role (security.adoc, "Document roles"): the library's `Role`, ranked, with its
/// proto spelling.
typealias DocumentRole = LibraryDocument.Role

extension LibraryDocument.Role {
    /// The roles an invitation, a role popup or a link may grant: never owner (ownership is
    /// transferred, sharing.adoc).
    static let grantable: [DocumentRole] = [.editor, .commenter, .viewer]

    /// Higher is more: viewer 1 … owner 4.
    var rank: Int {
        switch self {
        case .viewer: 1
        case .commenter: 2
        case .editor: 3
        case .owner: 4
        }
    }

    var proto: Wiretuner_Account_V1_DocumentRole {
        switch self {
        case .owner: .owner
        case .editor: .editor
        case .commenter: .commenter
        case .viewer: .viewer
        }
    }

    /// The grantable roles at or below `self` ("You cannot grant a role above your own").
    var grantableRoles: [DocumentRole] { Self.grantable.filter { $0.rank <= rank } }
}

/// A team role (security.adoc, "Teams"): owner, admin, member, guest.
enum TeamRole: String, Codable, Sendable, CaseIterable {
    case owner, admin, member, guest

    var title: String { rawValue.capitalized }

    var rank: Int {
        switch self {
        case .guest: 0
        case .member: 1
        case .admin: 2
        case .owner: 3
        }
    }

    init?(_ role: Wiretuner_Account_V1_TeamRole) {
        switch role {
        case .owner: self = .owner
        case .admin: self = .admin
        case .member: self = .member
        case .guest: self = .guest
        default: return nil
        }
    }

    var proto: Wiretuner_Account_V1_TeamRole {
        switch self {
        case .owner: .owner
        case .admin: .admin
        case .member: .member
        case .guest: .guest
        }
    }

    /// Whether this role administers the team: members, invitations, the workspace.
    var administers: Bool { rank >= TeamRole.admin.rank }

    /// The roles this role may give by invitation or role change (SEC-001 as built): only the
    /// owner deals in admins; nobody grants owner (that is a transfer).
    var assignableRoles: [TeamRole] {
        switch self {
        case .owner: [.admin, .member, .guest]
        case .admin: [.member, .guest]
        case .member, .guest: []
        }
    }
}

/// A team's workspace switches (`WorkspaceSettings`).
struct WorkspaceSettingsValue: Equatable, Sendable {
    var ssoAlias = ""
    var requireSSO = false
    var autoAdmit = false
    var restrictSharing = false
    var restrictPackageExport = false

    var proto: Wiretuner_Account_V1_WorkspaceSettings {
        var settings = Wiretuner_Account_V1_WorkspaceSettings()
        settings.ssoIdpAlias = ssoAlias
        settings.requireSso = requireSSO
        settings.autoAdmit = autoAdmit
        settings.restrictSharing = restrictSharing
        settings.restrictPackageExport = restrictPackageExport
        return settings
    }
}

extension WorkspaceSettingsValue {
    init(_ settings: Wiretuner_Account_V1_WorkspaceSettings) {
        self.init(
            ssoAlias: settings.ssoIdpAlias, requireSSO: settings.requireSso, autoAdmit: settings.autoAdmit,
            restrictSharing: settings.restrictSharing, restrictPackageExport: settings.restrictPackageExport
        )
    }
}

/// A verified-or-not email domain of a workspace.
struct WorkspaceDomainInfo: Equatable, Sendable, Identifiable {
    var domain: String
    var verificationToken: String
    var verifiedAt: Date?

    var id: String { domain }
    var isVerified: Bool { verifiedAt != nil }
    /// The DNS TXT record that verifies the domain (SEC-001 as built).
    var txtRecord: String { "wiretuner-verification=\(verificationToken)" }
}

extension WorkspaceDomainInfo {
    init(_ domain: Wiretuner_Account_V1_WorkspaceDomain) {
        self.init(domain: domain.domain, verificationToken: domain.verificationToken, verifiedAt: domain.hasVerifiedAt ? domain.verifiedAt.date : nil)
    }
}

struct WorkspaceInfo: Equatable, Sendable {
    var settings = WorkspaceSettingsValue()
    var domains: [WorkspaceDomainInfo] = []
}

extension WorkspaceInfo {
    init(_ workspace: Wiretuner_Account_V1_Workspace) {
        self.init(settings: WorkspaceSettingsValue(workspace.settings), domains: workspace.domains.map(WorkspaceDomainInfo.init))
    }
}

/// A team as its settings sheet shows it (`GetTeam`).
struct TeamDetail: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var slug = ""
    var memberCount = 0
    /// What members get on every team document; nil is none.
    var defaultDocumentRole: DocumentRole?
    /// The caller's role; nil when the server did not say.
    var callerRole: TeamRole?
    var workspace = WorkspaceInfo()
}

extension TeamDetail {
    init(_ team: Wiretuner_Account_V1_Team) {
        self.init(
            id: team.id, name: team.name, slug: team.slug, memberCount: Int(team.memberCount),
            defaultDocumentRole: DocumentRole(team.defaultDocumentRole), callerRole: TeamRole(team.callerRole),
            workspace: WorkspaceInfo(team.workspace)
        )
    }
}

struct TeamMemberInfo: Equatable, Sendable, Identifiable {
    var accountID: String
    var displayName: String
    var email: String
    var role: TeamRole
    var joinedAt: Date?

    var id: String { accountID }
}

extension TeamMemberInfo {
    init(_ member: Wiretuner_Account_V1_TeamMember) {
        self.init(
            accountID: member.accountID, displayName: member.displayName, email: member.email, role: TeamRole(member.role) ?? .member,
            joinedAt: member.hasJoinedAt ? member.joinedAt.date : nil
        )
    }
}

struct TeamInviteInfo: Equatable, Sendable, Identifiable {
    var id: String
    var email: String
    var role: TeamRole
    var expiresAt: Date?
}

extension TeamInviteInfo {
    init(_ invite: Wiretuner_Account_V1_TeamInvite) {
        self.init(id: invite.id, email: invite.email, role: TeamRole(invite.role) ?? .member, expiresAt: invite.hasExpiresAt ? invite.expiresAt.date : nil)
    }
}

/// An invitation link: `wiretuner://invite/<token>`, the mail's
/// `https://<links host>/invite/<token>`, or the bare token pasted (security.adoc, SEC-001 as
/// built: the token is 32 random bytes, base64url).
enum InviteLink {
    static let pathComponent = "invite"
    static let minimumTokenLength = 16
    static let maximumTokenLength = 512

    /// The token in `text`, or nil when it is not an invitation link.
    static func token(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return token(in: url) }
        return isToken(trimmed) ? trimmed : nil
    }

    /// The token of an invitation URL: `wiretuner://invite/<token>` (host `invite`) or any
    /// `.../invite/<token>` path.
    static func token(in url: URL) -> String? {
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.host == pathComponent { parts.insert(pathComponent, at: 0) }
        guard parts.count >= 2, parts[parts.count - 2] == pathComponent, let token = parts.last, isToken(token) else { return nil }
        return token
    }

    static func isToken(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return (minimumTokenLength...maximumTokenLength).contains(text.count) && text.unicodeScalars.allSatisfy(allowed.contains)
    }
}
