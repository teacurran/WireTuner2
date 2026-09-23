package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Documents by id and by space (a personal account or a team). Trashed documents are included. */
@ApplicationScoped
public class DocumentRepository implements PanacheRepositoryBase<Document, UUID> {

    public Uni<List<Document>> listPersonal(UUID ownerAccountId) {
        return list("ownerAccountId", Sort.by("name"), ownerAccountId);
    }

    public Uni<List<Document>> listTeam(UUID teamId) {
        return list("teamId", Sort.by("name"), teamId);
    }
}
