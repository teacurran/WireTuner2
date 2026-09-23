package com.villagecompute.wiretuner.api.persistence;

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

    /**
     * Rewrites the document's search record. {@code names} and {@code bodyText} are lines with a
     * field prefix ({@code o:}, {@code s:}, {@code st:}, {@code sy:}, {@code k:}, {@code p:} for
     * names; {@code t:}, {@code n:} for text and notes; docs/spec/server.adoc, Search); the
     * vectors are built from the lines with their prefixes stripped, and {@code body_text} keeps
     * the lines so highlights have source text.
     */
    public Uni<Integer> upsert(UUID documentId, long serverSeq, String names, String bodyText) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO document_search (document_id, server_seq, names, body, names_body, body_text, updated_at)
                        VALUES (?1, ?2, ?3, to_tsvector('simple', regexp_replace(cast(?4 as text), '^[a-z]+:', '', 'gn')),
                                to_tsvector('simple', regexp_replace(cast(?3 as text), '^[a-z]+:', '', 'gn')), ?4, now())
                        ON CONFLICT (document_id) DO UPDATE SET
                            server_seq = EXCLUDED.server_seq, names = EXCLUDED.names, body = EXCLUDED.body,
                            names_body = EXCLUDED.names_body, body_text = EXCLUDED.body_text, updated_at = now()
                        """)
                .setParameter(1, documentId)
                .setParameter(2, serverSeq)
                .setParameter(3, names)
                .setParameter(4, bodyText)
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
}
