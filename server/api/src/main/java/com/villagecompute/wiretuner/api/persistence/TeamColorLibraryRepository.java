package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Team color libraries (COLOR-020) with what their listing needs from the document: the head, and
 * the time the head change was sequenced, which is when an automatic library's version was
 * published. A library whose document is in the trash is not read.
 */
@ApplicationScoped
public class TeamColorLibraryRepository implements PanacheRepositoryBase<TeamColorLibrary, UUID> {

    /** A library as listed. {@code headMillis} is null when the head change is not in the hot log (or there is none). */
    public record Listed(UUID documentId, UUID teamId, String name, boolean manual, long publishedSeq, UUID publishedBy,
            long publishedMillis, long headSeq, Long headMillis) {
    }

    static final String SELECT = """
            SELECT c.document_id, c.team_id, c.name, c.manual, c.published_seq, c.published_by,
                   cast(extract(epoch FROM c.published_at) * 1000 AS bigint), d.head_seq,
                   (SELECT cast(extract(epoch FROM l.wall_time) * 1000 AS bigint) FROM change_log l
                    WHERE l.document_id = d.id AND l.server_seq = d.head_seq)
            FROM color_library c JOIN document d ON d.id = c.document_id
            WHERE d.trashed_at IS NULL AND
            """;

    /** The library of a document not in the trash, or null. */
    public Uni<Listed> listed(UUID documentId) {
        return getSession().chain(session -> session.createNativeQuery(SELECT + " c.document_id = ?1", Object[].class)
                .setParameter(1, documentId)
                .getResultList())
                .map(rows -> rows.isEmpty() ? null : toListed(rows.get(0)));
    }

    /** One page of the team's libraries, by name then document id. */
    public Uni<List<Listed>> page(UUID teamId, int offset, int limit) {
        return getSession().chain(session -> session.createNativeQuery(SELECT
                + " c.team_id = ?1 ORDER BY c.name, c.document_id", Object[].class)
                .setParameter(1, teamId)
                .setFirstResult(offset)
                .setMaxResults(limit)
                .getResultList())
                .map(rows -> rows.stream().map(TeamColorLibraryRepository::toListed).toList());
    }

    static Listed toListed(Object[] r) {
        return new Listed((UUID) r[0], (UUID) r[1], (String) r[2], (Boolean) r[3], ((Number) r[4]).longValue(),
                (UUID) r[5], ((Number) r[6]).longValue(), ((Number) r[7]).longValue(), LibraryRepository.longOrNull(r[8]));
    }
}
