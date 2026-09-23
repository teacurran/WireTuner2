package com.villagecompute.wiretuner.api.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;

import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberId;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLink;
import com.villagecompute.wiretuner.api.persistence.ShareLinkRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The effective document role (docs/spec/security.adoc, Document roles; sharing.adoc, Roles and
 * Access for the whole team): the maximum of the role through the team and the role of any share
 * link the account has used that still grants (not revoked; not expired, when it revokes on expiry).
 * The role through the team is the explicit {@code document_member} row when there is one -- higher
 * or lower than the team's access, the named role wins (COLLAB-011) -- and otherwise the team's
 * access for a team member: the document's override ({@code document.team_access_override}) or the
 * team default. Team owners and admins hold the owner's powers on team documents whatever their
 * named role; guests hold nothing by membership alone. A {@code document_member} row with role
 * {@code none} only holds a presence color.
 *
 * <p>Exactly one owner: a personal document's owner is {@code document.owner_account_id}; a team
 * document's owner is its single {@code document_member} row with role {@code owner}, which the
 * schema's partial unique index keeps single. Both resolve to {@link Role#OWNER} here.
 *
 * <p>Every lookup runs sequentially on the request's reactive session; the session is not safe for
 * concurrent use.
 */
@ApplicationScoped
public class DocumentRoles {

    static final String TEAM_OWNER = "owner";
    static final String TEAM_ADMIN = "admin";
    static final String TEAM_MEMBER = "member";

    @Inject
    DocumentRepository documents;

    @Inject
    DocumentMemberRepository members;

    @Inject
    TeamMemberRepository teamMembers;

    @Inject
    TeamRepository teams;

    @Inject
    ShareLinkRepository shareLinks;

    /**
     * Where one account's access to one document comes from (the People list shows it): the named
     * role ({@code NONE} for none, or a color-only row), the role through the team, the best role
     * through a used link that still grants, and whether the account is a personal document's owner.
     */
    public record Access(Role named, Role team, Role link, boolean personalOwner) {

        /**
         * The effective role: a personal owner, or a team owner or admin, is the owner; otherwise the
         * named role if any, else the team's access, raised by a link.
         */
        public Role effective() {
            if (personalOwner || team == Role.OWNER) {
                return Role.OWNER;
            }
            return Role.max(named == Role.NONE ? team : named, link);
        }
    }

    static final Access NO_ACCESS = new Access(Role.NONE, Role.NONE, Role.NONE, false);

    /** {@link Role#NONE} for an unknown document, so callers cannot tell "deleted" from "never yours". */
    public Uni<Role> effectiveRole(UUID documentId, UUID accountId) {
        return documents.findById(documentId)
                .flatMap(document -> document == null ? Uni.createFrom().item(Role.NONE)
                        : access(document, accountId).map(Access::effective));
    }

    /** Every source of the account's access to the document. */
    public Uni<Access> access(Document document, UUID accountId) {
        boolean personalOwner = accountId.equals(document.ownerAccountId);
        return explicitRole(document.id, accountId)
                .flatMap(named -> teamRole(document, accountId)
                        .flatMap(team -> shareLinkRole(document.id, accountId)
                                .map(link -> new Access(named, team, link, personalOwner))));
    }

    private Uni<Role> explicitRole(UUID documentId, UUID accountId) {
        return members.findById(new DocumentMemberId(documentId, accountId))
                .map(member -> member == null ? Role.NONE : Role.fromDb(member.role));
    }

    /**
     * The account's role on the document through its team membership: the owner's powers for team
     * owners and admins, the document's override or the team default for members of a live team,
     * NONE for guests, outsiders and personal documents.
     */
    Uni<Role> teamRole(Document document, UUID accountId) {
        UUID teamId = document.teamId;
        if (teamId == null) {
            return Uni.createFrom().item(Role.NONE);
        }
        return teamMembers.findById(new TeamMemberId(teamId, accountId)).flatMap(member -> {
            if (member == null) {
                return Uni.createFrom().item(Role.NONE);
            }
            return switch (member.role) {
                case TEAM_OWNER, TEAM_ADMIN -> Uni.createFrom().item(Role.OWNER);
                case TEAM_MEMBER -> teams.findById(teamId).map(team -> team.deletedAt != null ? Role.NONE
                        : Role.fromDb(document.teamAccessOverride != null ? document.teamAccessOverride
                                : team.defaultDocumentRole));
                default -> Uni.createFrom().item(Role.NONE);
            };
        });
    }

    private Uni<Role> shareLinkRole(UUID documentId, UUID accountId) {
        Instant now = Instant.now();
        return shareLinks.listUsedBy(documentId, accountId).map(links -> maxGranted(links, now));
    }

    static Role maxGranted(List<ShareLink> links, Instant now) {
        Role best = Role.NONE;
        for (ShareLink link : links) {
            if (grants(link, now)) {
                best = Role.max(best, Role.fromDb(link.role));
            }
        }
        return best;
    }

    /**
     * Whether a link still grants its role to the accounts that opened it: until it is revoked, and
     * past its expiry only when it does not revoke on expiry (sharing.adoc, Share links).
     */
    public static boolean grants(ShareLink link, Instant now) {
        return link.revokedAt == null && (!link.revokeOnExpiry || !expired(link, now));
    }

    /** Whether the link still opens: neither revoked nor expired. */
    public static boolean opens(ShareLink link, Instant now) {
        return link.revokedAt == null && !expired(link, now);
    }

    static boolean expired(ShareLink link, Instant now) {
        return link.expiresAt != null && !link.expiresAt.isAfter(now);
    }

    /** sha256 of a link or invitation token as lower-case hex, the form the schema stores. */
    public static String tokenHash(String token) {
        return digestHex("SHA-256", token);
    }

    static String digestHex(String algorithm, String value) {
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance(algorithm).digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(algorithm + " is not available in this JDK", e);
        }
    }
}
