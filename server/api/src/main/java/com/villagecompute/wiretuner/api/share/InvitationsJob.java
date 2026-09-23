package com.villagecompute.wiretuner.api.share;

import java.time.Duration;
import java.time.Instant;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.persistence.DocumentInviteRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLink;
import com.villagecompute.wiretuner.api.persistence.ShareLinkRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseRepository;
import com.villagecompute.wiretuner.api.persistence.TeamInviteRepository;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The daily Invitations job (COLLAB-011; docs/spec/server.adoc, Jobs): expires stale invitations and
 * share links. Pending document invitations by email older than {@code wt.share.invite-ttl} (30 days)
 * and team invitations past their expiry are deleted. A link that revokes on expiry stops granting
 * the moment it expires (roles are read with the clock); the job tells the people who opened it,
 * once, through {@link RoleNotices} -- {@code AccessRemoved} (no actor) or their remaining role -- so
 * their sessions and push decisions catch up within one run.
 */
@ApplicationScoped
public class InvitationsJob {

    private static final Logger LOG = Logger.getLogger(InvitationsJob.class);

    @ConfigProperty(name = "wt.share.invite-ttl", defaultValue = "30D")
    Duration inviteTtl;

    @Inject
    JobLocks locks;

    @Inject
    DocumentInviteRepository documentInvites;

    @Inject
    TeamInviteRepository teamInvites;

    @Inject
    ShareLinkRepository links;

    @Inject
    ShareLinkUseRepository linkUses;

    @Inject
    RoleNotices notices;

    /** A link whose expiry ended the access it granted, and who had opened it. */
    record Expired(UUID documentId, List<UUID> users) {
    }

    @Scheduled(identity = "invitations", every = "${wt.jobs.invitations.every:24h}",
            delayed = "${wt.jobs.invitations.delay:3m}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("invitations", this::expire).replaceWithVoid();
    }

    /** One run: deletes stale invitations, then announces links that expired since the last run. */
    Uni<Void> expire() {
        Instant now = Instant.now();
        return Panache.withTransaction(() -> documentInvites.delete("createdAt < ?1", now.minus(inviteTtl))
                .chain(invites -> teamInvites.delete("acceptedAt is null and expiresAt <= ?1", now)
                        .invoke(team -> LOG.infof("invitations: %d document and %d team invitations expired", invites, team)))
                .chain(() -> links.list("revokeOnExpiry = true and revokedAt is null and expiresAt <= ?1"
                        + " and expiryAnnouncedAt is null", now))
                .chain(expired -> Multi.createFrom().iterable(expired)
                        .onItem().transformToUniAndConcatenate(link -> announced(link, now))
                        .collect().asList()))
                .chain(expired -> Multi.createFrom().iterable(expired)
                        .onItem().transformToUniAndConcatenate(link -> notices.document(link.documentId(),
                                new HashSet<>(link.users()), null))
                        .collect().last())
                .replaceWithVoid();
    }

    private Uni<Expired> announced(ShareLink link, Instant now) {
        link.expiryAnnouncedAt = now;
        return linkUses.getSession().chain(session -> session
                .createQuery("select u.id.accountId from ShareLinkUse u where u.id.shareLinkId = ?1", UUID.class)
                .setParameter(1, link.id)
                .getResultList())
                .map(users -> new Expired(link.documentId, users));
    }
}
