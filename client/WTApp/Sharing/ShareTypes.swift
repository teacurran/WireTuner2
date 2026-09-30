import Foundation
import SwiftProtobuf
import WTProto

/// How a person's access to a document arises (`docs.v1.AccessSource`).
enum AccessSourceKind: String, Equatable, Sendable {
    case named, teamDefault, link

    init?(_ source: Wiretuner_Docs_V1_AccessSource) {
        switch source {
        case .named: self = .named
        case .teamDefault: self = .teamDefault
        case .link: self = .link
        default: return nil
        }
    }
}

/// One person in the Share sheet's People list (`docs.v1.Member`).
struct ShareMember: Equatable, Sendable, Identifiable {
    var accountID: String
    var displayName: String
    var email = ""
    /// The named role; nil when access is only through the team or a link.
    var role: DocumentRole?
    var sources: [AccessSourceKind] = [.named]
    var effectiveRole: DocumentRole?
    var colorIndex = 0
    var isCreator = false
    /// An invitation by email no account has claimed yet.
    var isPending = false

    var id: String { accountID.isEmpty ? "pending:\(email)" : accountID }
    /// Access only through the team default: shown as the one "Everyone in <team>" row.
    var isOnlyThroughTeam: Bool { role == nil && sources == [.teamDefault] }
    var name: String { displayName.isEmpty ? email : displayName }
}

extension ShareMember {
    init(_ member: Wiretuner_Docs_V1_Member) {
        self.init(
            accountID: member.accountID, displayName: member.displayName, email: member.email, role: DocumentRole(member.role),
            sources: member.sources.compactMap(AccessSourceKind.init), effectiveRole: DocumentRole(member.effectiveRole),
            colorIndex: Int(member.colorIndex), isCreator: member.isCreator, isPending: member.pending
        )
    }
}

/// A team document's "Everyone in <team>" row (`docs.v1.TeamAccess`).
struct TeamAccessInfo: Equatable, Sendable {
    var teamID: String
    var teamName: String
    /// The team's default document role; nil is none.
    var teamDefault: DocumentRole?
    /// This document's override; nil uses the team default.
    var override: DocumentRole?

    /// What members get on this document.
    var effective: DocumentRole? { override ?? teamDefault }
}

extension TeamAccessInfo {
    init(_ access: Wiretuner_Docs_V1_TeamAccess) {
        self.init(teamID: access.teamID, teamName: access.teamName, teamDefault: DocumentRole(access.teamDefault), override: DocumentRole(access.override))
    }
}

/// `ListMembers`, every page: the people and, for a team document, the team row.
struct ShareRoster: Equatable, Sendable {
    var members: [ShareMember]
    var teamAccess: TeamAccessInfo?
}

/// A live share link, without its token (`docs.v1.ShareLink`).
struct ShareLinkInfo: Equatable, Sendable, Identifiable {
    var id: String
    var role: DocumentRole
    var expiresAt: Date?
    var revokeOnExpiry = false
    var hasPassword = false
    var teamMembersOnly = false
    var createdAt: Date?
    var uses = 0
}

extension ShareLinkInfo {
    init(_ link: Wiretuner_Docs_V1_ShareLink) {
        self.init(
            id: link.id, role: DocumentRole(link.role) ?? .viewer, expiresAt: link.hasExpiresAt ? link.expiresAt.date : nil,
            revokeOnExpiry: link.revokeOnExpiry, hasPassword: link.hasPassword_p, teamMembersOnly: link.teamMembersOnly,
            createdAt: link.hasCreatedAt ? link.createdAt.date : nil, uses: Int(link.uses)
        )
    }
}

/// What a new link is made with (sharing.adoc, "Share links").
struct ShareLinkOptions: Equatable, Sendable {
    var role: DocumentRole = .viewer
    var expiresAt: Date?
    var revokeOnExpiry = false
    /// Empty: no password.
    var password = ""
    var teamMembersOnly = false
}

/// `CreateLink`'s answer: the link and its token, which is never returned again.
struct CreatedShareLink: Equatable, Sendable {
    var link: ShareLinkInfo
    var token: String
}

/// A pending request for access (`docs.v1.AccessRequest`).
struct AccessRequestInfo: Equatable, Sendable, Identifiable {
    var id: String
    var accountID: String
    var displayName: String
    var email: String
    var message = ""
    var createdAt: Date?

    var name: String { displayName.isEmpty ? email : displayName }
}

extension AccessRequestInfo {
    init(_ request: Wiretuner_Docs_V1_AccessRequest) {
        self.init(
            id: request.id, accountID: request.accountID, displayName: request.displayName, email: request.email, message: request.message,
            createdAt: request.hasCreatedAt ? request.createdAt.date : nil
        )
    }
}

/// What `UpdateLink` changes on an existing link (sharing.adoc, "Share links"): only the fields
/// set.  `expiresAt` `.some(nil)` makes the link never expire; `password` `""` clears it.
struct ShareLinkChanges: Equatable, Sendable {
    var role: DocumentRole?
    var expiresAt: Date??
    var revokeOnExpiry: Bool?
    var password: String?
    var teamMembersOnly: Bool?

    var isEmpty: Bool { self == ShareLinkChanges() }
}

/// Who an invitation is for: an address, or a person picked from the suggestions (the people
/// of the caller's teams, by account id).
enum ShareInvitee: Equatable, Sendable {
    case email(String)
    case account(id: String, name: String)

    var title: String {
        switch self {
        case let .email(email): email
        case let .account(_, name): name
        }
    }
}

/// A person the Invite field suggests: a member of one of the caller's teams.
struct InviteSuggestion: Equatable, Sendable, Identifiable {
    var accountID: String
    var displayName: String
    var email: String
    /// The team the person was found in.
    var teamName: String

    var id: String { accountID }
    var name: String { displayName.isEmpty ? email : displayName }

    /// Whether `query` (case and diacritics ignored) starts the name, a word of it, or the address.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !query.isEmpty else { return false }
        let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = fold(displayName).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return fold(displayName).hasPrefix(query) || words.contains { $0.hasPrefix(query) } || fold(email).hasPrefix(query)
    }
}

/// `OpenLink`'s answer: the document the link opened and the caller's role in it.
struct OpenedShareLink: Equatable, Sendable {
    var documentID: String
    var documentName: String
    var role: DocumentRole?
}

/// Why a share link did not open (sharing.adoc, "Requesting access"), from the error's
/// `ErrorInfo`: the reason and, when the server knows the link's document, its id and name
/// (`document_id`, `document_name`) so the request page can ask for access.
enum ShareLinkFailure: Error, Equatable, Sendable {
    /// `LINK_PASSWORD_REQUIRED`: missing or wrong.
    case passwordRequired
    /// `LINK_INVALID`: unknown, expired or revoked.
    case invalid(ShareLinkDocument?)
    /// `ROLE_INSUFFICIENT`: a team-members-only link opened by someone outside the team.
    case teamOnly(ShareLinkDocument?)

    /// The document to request access to, when the server named one.
    var requestable: ShareLinkDocument? {
        switch self {
        case .passwordRequired: nil
        case let .invalid(document), let .teamOnly(document): document
        }
    }

    /// The failure an `ErrorInfo` reason and metadata stand for; nil for any other reason.
    init?(reason: String, metadata: [String: String]) {
        let document = metadata["document_id"].flatMap { id in
            id.isEmpty || metadata["can_request_access"] != "true" ? nil : ShareLinkDocument(id: id, name: metadata["document_name"] ?? "")
        }
        switch reason {
        case "LINK_PASSWORD_REQUIRED": self = .passwordRequired
        case "LINK_INVALID": self = .invalid(document)
        case "ROLE_INSUFFICIENT": self = .teamOnly(document)
        default: return nil
        }
    }
}

/// The document a failed link belongs to.
struct ShareLinkDocument: Equatable, Sendable {
    var id: String
    var name: String
}
