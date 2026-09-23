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
}
