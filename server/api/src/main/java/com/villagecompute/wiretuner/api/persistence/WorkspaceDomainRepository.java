package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Workspace domains per team, and who has verified a domain. */
@ApplicationScoped
public class WorkspaceDomainRepository implements PanacheRepositoryBase<WorkspaceDomain, WorkspaceDomainId> {

    public Uni<List<WorkspaceDomain>> listForTeam(UUID teamId) {
        return list("id.teamId", Sort.by("id.domain"), teamId);
    }

    /** The claim that has verified the domain, whichever team made it; null when none has. */
    public Uni<WorkspaceDomain> findVerified(String domain) {
        return find("id.domain = ?1 and verifiedAt is not null", domain).firstResult();
    }
}
