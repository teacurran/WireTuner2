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
