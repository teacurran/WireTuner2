package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Team invitations by token hash, and a team's pending ones. */
@ApplicationScoped
public class TeamInviteRepository implements PanacheRepositoryBase<TeamInvite, UUID> {

    public Uni<TeamInvite> findByTokenHash(String tokenHash) {
        return find("tokenHash", tokenHash).firstResult();
    }

    /** Unaccepted, unexpired invitations, newest first. */
    public Uni<List<TeamInvite>> listPending(UUID teamId, Instant now) {
        return list("teamId = ?1 and acceptedAt is null and expiresAt > ?2 order by createdAt desc, id", teamId, now);
    }

    /** Drops unaccepted invitations for the address, so a re-invitation replaces them. */
    public Uni<Long> deletePendingFor(UUID teamId, String email) {
        return delete("teamId = ?1 and email = ?2 and acceptedAt is null", teamId, email);
    }
}
