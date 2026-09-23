package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Named versions (SRV-011; history.adoc, Data model), plain SQL in the caller's reactive session. */
@ApplicationScoped
public class VersionRepository {

    /** A version with its author's display name; times are epoch microseconds. */
    public record VersionRow(UUID id, UUID documentId, long serverSeq, String name, String note, String authorId,
            String authorName, boolean pinned, long createdAtMicros) {
    }

    static final String COLUMNS = """
            v.id, v.document_id, v.server_seq, v.name, v.note, coalesce(cast(v.author_account_id AS text), ''),
            coalesce(a.display_name, ''), v.pinned,
            cast(extract(epoch FROM v.created_at) * 1000000 AS bigint)
            FROM version v LEFT JOIN account a ON a.id = v.author_account_id
            """;

    public Uni<Integer> insert(UUID id, UUID documentId, long serverSeq, String name, String note, UUID author) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO version (id, document_id, server_seq, name, note, author_account_id)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                        """)
                .setParameter(1, id)
                .setParameter(2, documentId)
                .setParameter(3, serverSeq)
                .setParameter(4, name)
                .setParameter(5, note)
                .setParameter(6, author)
                .executeUpdate());
    }

    /** The version, or null. */
    public Uni<VersionRow> find(UUID id) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("SELECT " + COLUMNS + " WHERE v.id = ?1", Object[].class)
                .setParameter(1, id)
                .getSingleResultOrNull())
                .map(row -> row == null ? null : toRow(row));
    }

    /** The document's versions, newest first, after the cursor ({@code Long.MAX_VALUE} for the first page). */
    public Uni<List<VersionRow>> list(UUID documentId, long afterMicros, UUID afterId, int limit) {
        return Panache.getSession().chain(session -> session.createNativeQuery("SELECT " + COLUMNS + """
                         WHERE v.document_id = ?1
                           AND (cast(extract(epoch FROM v.created_at) * 1000000 AS bigint), v.id) < (?2, ?3)
                         ORDER BY v.created_at DESC, v.id DESC LIMIT ?4
                        """, Object[].class)
                .setParameter(1, documentId)
                .setParameter(2, afterMicros)
                .setParameter(3, afterId)
                .setParameter(4, limit)
                .getResultList())
                .map(rows -> rows.stream().map(VersionRepository::toRow).toList());
    }

    /** The document's versions at {@code fromSeq <= server_seq < beforeSeq}, highest seq first (the history timeline). */
    public Uni<List<VersionRow>> between(UUID documentId, long fromSeq, long beforeSeq) {
        return Panache.getSession().chain(session -> session.createNativeQuery("SELECT " + COLUMNS + """
                         WHERE v.document_id = ?1 AND v.server_seq >= ?2 AND v.server_seq < ?3
                         ORDER BY v.server_seq DESC, v.created_at DESC
                        """, Object[].class)
                .setParameter(1, documentId)
                .setParameter(2, fromSeq)
                .setParameter(3, beforeSeq)
                .getResultList())
                .map(rows -> rows.stream().map(VersionRepository::toRow).toList());
    }

    /** Renames and re-notes the version; a {@code false} flag leaves that field as it is. */
    public Uni<Integer> update(UUID id, boolean setName, String name, boolean setNote, String note) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        UPDATE version SET name = CASE WHEN ?2 THEN ?3 ELSE name END,
                                           note = CASE WHEN ?4 THEN ?5 ELSE note END, updated_at = now()
                        WHERE id = ?1
                        """)
                .setParameter(1, id)
                .setParameter(2, setName)
                .setParameter(3, name)
                .setParameter(4, setNote)
                .setParameter(5, note)
                .executeUpdate());
    }

    public Uni<Integer> pin(UUID id, boolean pinned) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("UPDATE version SET pinned = ?2, updated_at = now() WHERE id = ?1")
                .setParameter(1, id)
                .setParameter(2, pinned)
                .executeUpdate());
    }

    public Uni<Integer> delete(UUID id) {
        return Panache.getSession().chain(session -> session.createNativeQuery("DELETE FROM version WHERE id = ?1")
                .setParameter(1, id)
                .executeUpdate());
    }

    private static VersionRow toRow(Object[] row) {
        return new VersionRow((UUID) row[0], (UUID) row[1], ((Number) row[2]).longValue(), (String) row[3],
                (String) row[4], (String) row[5], (String) row[6], (Boolean) row[7], ((Number) row[8]).longValue());
    }
}
