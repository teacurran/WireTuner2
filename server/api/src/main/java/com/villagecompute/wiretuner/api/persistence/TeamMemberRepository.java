package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Team memberships, by (team, account) or per account. */
@ApplicationScoped
public class TeamMemberRepository implements PanacheRepositoryBase<TeamMember, TeamMemberId> {

    public Uni<List<TeamMember>> listForAccount(UUID accountId) {
        return list("id.accountId", Sort.by("joinedAt"), accountId);
    }

    public Uni<Long> countForTeam(UUID teamId) {
        return count("id.teamId", teamId);
    }

    /** Sets one member's role at once (a bulk update, so the one-owner index sees the statements in order). */
    public Uni<Integer> setRole(UUID teamId, UUID accountId, String role) {
        return update("role = ?1 where id.teamId = ?2 and id.accountId = ?3", role, teamId, accountId);
    }
}
