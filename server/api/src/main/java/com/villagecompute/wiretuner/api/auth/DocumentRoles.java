package com.villagecompute.wiretuner.api.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberId;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLink;
import com.villagecompute.wiretuner.api.persistence.ShareLinkRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUse;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseId;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The effective document role (docs/spec/security.adoc, Document roles): the maximum of the explicit
 * {@code document_member} row, the team default for team members (team owners and admins hold the
 * owner's powers on team documents; guests hold nothing by membership alone), and the role of any
 * live share link the account has used.
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

    @Inject
    ShareLinkUseRepository shareLinkUses;

    /** {@link Role#NONE} for an unknown document, so callers cannot tell "deleted" from "never yours". */
    public Uni<Role> effectiveRole(UUID documentId, UUID accountId) {
        return documents.findById(documentId)
                .flatMap(document -> document == null ? Uni.createFrom().item(Role.NONE) : roleOn(document, accountId));
    }

    private Uni<Role> roleOn(Document document, UUID accountId) {
        if (accountId.equals(document.ownerAccountId)) {
            return Uni.createFrom().item(Role.OWNER);
        }
        return explicitRole(document.id, accountId)
                .flatMap(explicit -> teamRole(document.teamId, accountId).map(team -> Role.max(explicit, team)))
                .flatMap(sofar -> shareLinkRole(document.id, accountId).map(link -> Role.max(sofar, link)));
    }

    private Uni<Role> explicitRole(UUID documentId, UUID accountId) {
        return members.findById(new DocumentMemberId(documentId, accountId))
                .map(member -> member == null ? Role.NONE : Role.fromDb(member.role));
    }

    private Uni<Role> teamRole(UUID teamId, UUID accountId) {
        if (teamId == null) {
            return Uni.createFrom().item(Role.NONE);
        }
        return teamMembers.findById(new TeamMemberId(teamId, accountId)).flatMap(member -> {
            if (member == null) {
                return Uni.createFrom().item(Role.NONE);
            }
            return switch (member.role) {
                case TEAM_OWNER, TEAM_ADMIN -> Uni.createFrom().item(Role.OWNER);
                case TEAM_MEMBER -> teams.findById(teamId)
                        .map(team -> team.deletedAt == null ? Role.fromDb(team.defaultDocumentRole) : Role.NONE);
                default -> Uni.createFrom().item(Role.NONE);
            };
        });
    }

    private Uni<Role> shareLinkRole(UUID documentId, UUID accountId) {
        Instant now = Instant.now();
        return shareLinks.listUsedBy(documentId, accountId).map(links -> maxLive(links, now));
    }

    static Role maxLive(List<ShareLink> links, Instant now) {
        Role best = Role.NONE;
        for (ShareLink link : links) {
            if (isLive(link, now)) {
                best = Role.max(best, Role.fromDb(link.role));
            }
        }
        return best;
    }

    static boolean isLive(ShareLink link, Instant now) {
        return link.revokedAt == null && (link.expiresAt == null || link.expiresAt.isAfter(now));
    }

    /**
     * Records that the account opened the link named by {@code token}, so the link's role becomes
     * part of its effective role from now on. A link that does not exist, has expired or was
     * revoked is {@code DOCUMENT_NOT_FOUND}: the link is the only thing the caller knows about the
     * document. Returns the link's role.
     */
    public Uni<Role> useShareLink(String token, UUID accountId) {
        Instant now = Instant.now();
        return shareLinks.findByTokenHash(tokenHash(token)).flatMap(link -> {
            if (link == null || !isLive(link, now)) {
                return Uni.createFrom().failure(StatusExceptions.documentNotFound());
            }
            ShareLinkUseId id = new ShareLinkUseId(link.id, accountId);
            Role role = Role.fromDb(link.role);
            return shareLinkUses.findById(id).flatMap(use -> {
                if (use != null) {
                    return Uni.createFrom().item(role);
                }
                ShareLinkUse fresh = new ShareLinkUse();
                fresh.id = id;
                return shareLinkUses.persist(fresh).replaceWith(role);
            });
        });
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
