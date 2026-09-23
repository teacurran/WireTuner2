package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Team libraries by document, and a team's libraries with their documents. */
@ApplicationScoped
public class TeamLibraryRepository implements PanacheRepositoryBase<TeamLibrary, UUID> {

    /** One page of the team's libraries whose documents are not trashed, by name then id, with their documents. */
    public Uni<List<Object[]>> page(UUID teamId, int offset, int limit) {
        return getSession().chain(session -> session.createQuery("select l, d from TeamLibrary l, Document d"
                + " where d.id = l.documentId and l.teamId = ?1 and d.trashedAt is null order by l.name, l.documentId",
                Object[].class)
                .setParameter(1, teamId)
                .setFirstResult(offset)
                .setMaxResults(limit)
                .getResultList());
    }
}
