package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * The {@code document_search} row, kept as plain SQL: its {@code tsvector} columns have no entity
 * mapping worth having, and only the snapshotter writes it (docs/spec/server.adoc, Search).
 */
@ApplicationScoped
public class DocumentSearchRepository {

    /** What the row holds, minus the vectors. */
    public record SearchRecord(UUID documentId, long serverSeq, String names) {
    }

    /** Rewrites the document's search record from the names (one per line) and the body text. */
    public Uni<Integer> upsert(UUID documentId, long serverSeq, String names, String body) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO document_search (document_id, server_seq, names, body, names_body, updated_at)
                        VALUES (?1, ?2, ?3, to_tsvector('simple', cast(?4 as text)),
                                to_tsvector('simple', cast(?3 as text)), now())
                        ON CONFLICT (document_id) DO UPDATE SET
                            server_seq = EXCLUDED.server_seq, names = EXCLUDED.names, body = EXCLUDED.body,
                            names_body = EXCLUDED.names_body, updated_at = now()
                        """)
                .setParameter(1, documentId)
                .setParameter(2, serverSeq)
                .setParameter(3, names)
                .setParameter(4, body)
                .executeUpdate());
    }

    public Uni<SearchRecord> find(UUID documentId) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("SELECT document_id, server_seq, names FROM document_search WHERE document_id = ?1",
                        Object[].class)
                .setParameter(1, documentId)
                .getSingleResultOrNull())
                .map(row -> row == null ? null : new SearchRecord((UUID) row[0], ((Number) row[1]).longValue(), (String) row[2]));
    }

    /** Document ids whose names match the query by trigram similarity or whose body matches it by word. */
    public Uni<List<UUID>> search(String query) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        SELECT document_id FROM document_search
                        WHERE names % cast(?1 as text)
                           OR body @@ websearch_to_tsquery('simple', cast(?1 as text))
                           OR names_body @@ websearch_to_tsquery('simple', cast(?1 as text))
                        ORDER BY document_id
                        """, UUID.class)
                .setParameter(1, query)
                .getResultList());
    }
}
