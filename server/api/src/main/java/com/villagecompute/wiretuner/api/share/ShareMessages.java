package com.villagecompute.wiretuner.api.share;

import java.time.Instant;
import java.util.UUID;

import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.auth.DocumentRoles.Access;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.AccessRequest;
import com.villagecompute.wiretuner.api.persistence.DocumentInvite;
import com.villagecompute.wiretuner.api.persistence.DocumentMember;
import com.villagecompute.wiretuner.api.persistence.ShareLink;
import com.villagecompute.wiretuner.docs.v1.AccessSource;
import com.villagecompute.wiretuner.docs.v1.Member;

/** Sharing rows to {@code wiretuner.docs.v1} messages, and the request enums to roles. */
final class ShareMessages {

    private ShareMessages() {
    }

    /** A role the request's validation restricted to editor, commenter or viewer; UNSPECIFIED is none. */
    static Role role(DocumentRole role) {
        return switch (role) {
            case DOCUMENT_ROLE_EDITOR -> Role.EDITOR;
            case DOCUMENT_ROLE_COMMENTER -> Role.COMMENTER;
            case DOCUMENT_ROLE_VIEWER -> Role.VIEWER;
            default -> Role.NONE;
        };
    }

    /**
     * A person as the People list shows them. {@code row} is their {@code document_member} row, or
     * null; {@code owner} is true for the document's one owner; the email is shown to owners only.
     */
    static Member member(Account account, Access access, DocumentMember row, boolean owner, boolean showEmail,
            UUID creator) {
        Member.Builder member = Member.newBuilder()
                .setAccountId(account.id.toString())
                .setDisplayName(account.displayName)
                .setRole(DocumentMessages.role(owner ? Role.OWNER : access.named()))
                .setEffectiveRole(DocumentMessages.role(access.effective()))
                .setColorIndex(row == null || row.colorIndex == null ? 0 : row.colorIndex)
                .setIsCreator(account.id.equals(creator));
        if (owner || access.named() != Role.NONE) {
            member.addSources(AccessSource.ACCESS_SOURCE_NAMED);
        }
        if (access.team() != Role.NONE) {
            member.addSources(AccessSource.ACCESS_SOURCE_TEAM_DEFAULT);
        }
        if (access.link() != Role.NONE) {
            member.addSources(AccessSource.ACCESS_SOURCE_LINK);
        }
        if (showEmail) {
            member.setEmail(account.email);
        }
        return member.build();
    }

    /** An invitation no account has claimed yet: shown with its address, pending. */
    static Member pending(DocumentInvite invite) {
        Role role = Role.fromDb(invite.role);
        return Member.newBuilder()
                .setEmail(invite.email)
                .setRole(DocumentMessages.role(role))
                .addSources(AccessSource.ACCESS_SOURCE_NAMED)
                .setPending(true)
                .build();
    }

    static com.villagecompute.wiretuner.docs.v1.ShareLink link(ShareLink link, long uses) {
        com.villagecompute.wiretuner.docs.v1.ShareLink.Builder out = com.villagecompute.wiretuner.docs.v1.ShareLink
                .newBuilder()
                .setId(link.id.toString())
                .setDocumentId(link.documentId.toString())
                .setRole(DocumentMessages.role(Role.fromDb(link.role)))
                .setRevokeOnExpiry(link.revokeOnExpiry)
                .setHasPassword(link.passwordHash != null)
                .setTeamMembersOnly(link.teamMembersOnly)
                .setCreatedByAccountId(link.createdBy.toString())
                .setCreatedAt(timestamp(link.createdAt))
                .setUses((int) uses);
        if (link.expiresAt != null) {
            out.setExpiresAt(timestamp(link.expiresAt));
        }
        if (link.revokedAt != null) {
            out.setRevokedAt(timestamp(link.revokedAt));
        }
        return out.build();
    }

    static com.villagecompute.wiretuner.docs.v1.AccessRequest request(AccessRequest request, Account account) {
        return com.villagecompute.wiretuner.docs.v1.AccessRequest.newBuilder()
                .setId(request.id.toString())
                .setDocumentId(request.documentId.toString())
                .setAccountId(request.accountId.toString())
                .setDisplayName(account.displayName)
                .setEmail(account.email)
                .setMessage(request.message)
                .setCreatedAt(timestamp(request.createdAt))
                .build();
    }

    static Timestamp timestamp(Instant instant) {
        return Timestamp.newBuilder().setSeconds(instant.getEpochSecond()).setNanos(instant.getNano()).build();
    }

    /** A request timestamp as an instant; the zero timestamp is null ("never"). */
    static Instant instant(Timestamp timestamp) {
        return timestamp.getSeconds() == 0 && timestamp.getNanos() == 0 ? null
                : Instant.ofEpochSecond(timestamp.getSeconds(), timestamp.getNanos());
    }
}
