package com.villagecompute.wiretuner.api.persistence;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
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

    /** How many rows the hot log holds up to {@code toSeq}; fewer than {@code toSeq} means part was compacted. */
    public Uni<Long> countUpTo(UUID documentId, long toSeq) {
        return count("id.documentId = ?1 and id.serverSeq <= ?2", documentId, toSeq);
    }

    /** The row carrying (replica, seq) at or below {@code toSeq}, or null. */
    public Uni<ChangeLog> findByReplicaSeq(UUID documentId, long replicaId, long seq, long toSeq) {
        return find("id.documentId = ?1 and replicaId = ?2 and seq = ?3 and id.serverSeq <= ?4",
                documentId, replicaId, seq, toSeq).firstResult();
    }

    /** The highest seq of each replica among the rows up to {@code toSeq}. */
    public Uni<Map<Long, Long>> replicaHeads(UUID documentId, long toSeq) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        SELECT replica_id, max(seq) FROM change_log
                        WHERE document_id = ?1 AND server_seq <= ?2 GROUP BY replica_id
                        """, Object[].class)
                .setParameter(1, documentId)
                .setParameter(2, toSeq)
                .getResultList())
                .map(rows -> {
                    Map<Long, Long> heads = new HashMap<>();
                    rows.forEach(r -> heads.put(((Number) r[0]).longValue(), ((Number) r[1]).longValue()));
                    return heads;
                });
    }

    /** Copies the rows up to {@code toSeq} into another document, keeping their server_seq (fork, SRV-009). */
    public Uni<Integer> copyRange(UUID fromDocument, UUID toDocument, long toSeq) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, wall_time, byte_size)
                        SELECT ?1, server_seq, replica_id, seq, bytes, wall_time, byte_size
                        FROM change_log WHERE document_id = ?2 AND server_seq <= ?3
                        """)
                .setParameter(1, toDocument)
                .setParameter(2, fromDocument)
                .setParameter(3, toSeq)
                .executeUpdate());
    }
}
