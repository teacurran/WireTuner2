package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** The hot change log; rows are keyed by (document, server_seq) and read in seq order. */
@ApplicationScoped
public class ChangeLogRepository implements PanacheRepositoryBase<ChangeLog, ChangeLogId> {

    /** Rows with {@code fromSeq <= server_seq <= toSeq}, ascending. */
    public Uni<List<ChangeLog>> listRange(UUID documentId, long fromSeq, long toSeq) {
        return list("id.documentId = ?1 and id.serverSeq between ?2 and ?3 order by id.serverSeq",
                documentId, fromSeq, toSeq);
    }
}
