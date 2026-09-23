package com.villagecompute.wiretuner.api.team;

import java.time.Instant;
import java.util.List;

import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.account.v1.TeamInvite;
import com.villagecompute.wiretuner.account.v1.TeamMember;
import com.villagecompute.wiretuner.account.v1.Workspace;
import com.villagecompute.wiretuner.account.v1.WorkspaceDomain;
import com.villagecompute.wiretuner.account.v1.WorkspaceSettings;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.Team;

/** Team rows to {@code wiretuner.account.v1} messages. */
final class TeamMessages {

    private TeamMessages() {
    }

    static com.villagecompute.wiretuner.account.v1.Team team(Team row, String callerRole, long memberCount,
            com.villagecompute.wiretuner.api.persistence.Workspace workspace,
            List<com.villagecompute.wiretuner.api.persistence.WorkspaceDomain> domains) {
        var team = com.villagecompute.wiretuner.account.v1.Team.newBuilder()
                .setId(row.id.toString())
                .setName(row.name)
                .setSlug(row.slug)
                .setOwnerAccountId(row.ownerAccountId.toString())
                .setCreatedAt(timestamp(row.createdAt))
                .setMemberCount((int) memberCount)
                .setDefaultDocumentRole(DocumentMessages.role(Role.fromDb(row.defaultDocumentRole)))
                .setCallerRole(TeamRoles.toProto(callerRole))
                .setHistoryRetentionDays(row.historyRetentionDays == null ? 0 : row.historyRetentionDays);
        if (row.deletedAt != null) {
            team.setDeletedAt(timestamp(row.deletedAt));
        }
        if (workspace != null) {
            team.setWorkspace(workspace(workspace, domains));
        }
        return team.build();
    }

    static Workspace workspace(com.villagecompute.wiretuner.api.persistence.Workspace row,
            List<com.villagecompute.wiretuner.api.persistence.WorkspaceDomain> domains) {
        Workspace.Builder workspace = Workspace.newBuilder().setSettings(WorkspaceSettings.newBuilder()
                .setSsoIdpAlias(row.ssoIdpAlias == null ? "" : row.ssoIdpAlias)
                .setRequireSso(row.requireSso)
                .setAutoAdmit(row.autoAdmit)
                .setRestrictSharing(row.restrictSharing)
                .setRestrictPackageExport(row.restrictPackageExport));
        domains.forEach(d -> workspace.addDomains(domain(d)));
        return workspace.build();
    }

    static WorkspaceDomain domain(com.villagecompute.wiretuner.api.persistence.WorkspaceDomain row) {
        WorkspaceDomain.Builder domain = WorkspaceDomain.newBuilder()
                .setDomain(row.id.domain())
                .setVerificationToken(row.verificationToken);
        if (row.verifiedAt != null) {
            domain.setVerifiedAt(timestamp(row.verifiedAt));
        }
        return domain.build();
    }

    static TeamMember member(com.villagecompute.wiretuner.api.persistence.TeamMember row, Account account) {
        return TeamMember.newBuilder()
                .setAccountId(account.id.toString())
                .setDisplayName(account.displayName)
                .setEmail(account.email)
                .setRole(TeamRoles.toProto(row.role))
                .setJoinedAt(timestamp(row.joinedAt))
                .build();
    }

    static TeamInvite invite(com.villagecompute.wiretuner.api.persistence.TeamInvite row) {
        TeamInvite.Builder invite = TeamInvite.newBuilder()
                .setId(row.id.toString())
                .setTeamId(row.teamId.toString())
                .setEmail(row.email)
                .setRole(TeamRoles.toProto(row.role))
                .setInvitedByAccountId(row.invitedByAccountId == null ? "" : row.invitedByAccountId.toString())
                .setExpiresAt(timestamp(row.expiresAt));
        if (row.acceptedAt != null) {
            invite.setAcceptedAt(timestamp(row.acceptedAt));
        }
        return invite.build();
    }

    /** The stored default document role; UNSPECIFIED selects editor. */
    static String defaultDocumentRole(DocumentRole role) {
        return switch (role) {
            case DOCUMENT_ROLE_COMMENTER -> Role.COMMENTER.dbName();
            case DOCUMENT_ROLE_VIEWER -> Role.VIEWER.dbName();
            default -> Role.EDITOR.dbName();
        };
    }

    static Timestamp timestamp(Instant instant) {
        return Timestamp.newBuilder().setSeconds(instant.getEpochSecond()).setNanos(instant.getNano()).build();
    }
}
