package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Teams by id or slug. */
@ApplicationScoped
public class TeamRepository implements PanacheRepositoryBase<Team, UUID> {

    public Uni<Team> findBySlug(String slug) {
        return find("slug", slug).firstResult();
    }
}
