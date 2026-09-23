package com.villagecompute.wiretuner.api.sync;

import java.util.UUID;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Presence colors (SRV-012; presence.adoc, Data model and Colors): each person has one index into the
 * 12-color palette per document, stored on {@code document_member.color_index} and assigned on their
 * first Subscribe as the lowest index not held by anyone who has opened the document, wrapping (the
 * thirteenth gets 0, the fourteenth 1, ...) once all twelve are taken. Someone with access only
 * through the team or a link gets a {@code none} row to hold it. Assignment takes a per-document
 * advisory lock so two first subscriptions cannot pick the same free index.
 */
@ApplicationScoped
public class Colors {

    static final String FIND = """
            SELECT color_index FROM document_member WHERE document_id = $1 AND account_id = $2 AND color_index IS NOT NULL
            """;

    static final String LOCK = "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))";

    static final String ASSIGN = """
            INSERT INTO document_member AS m (document_id, account_id, role, color_index)
            SELECT $1, $2, 'none', CASE WHEN count(*) >= 12 THEN count(*) % 12
                   ELSE (SELECT min(g.i) FROM generate_series(0, 11) AS g(i) WHERE g.i NOT IN
                         (SELECT color_index FROM document_member WHERE document_id = $1 AND color_index IS NOT NULL))
                   END
            FROM document_member WHERE document_id = $1 AND color_index IS NOT NULL
            ON CONFLICT (document_id, account_id) DO UPDATE SET color_index = COALESCE(m.color_index, EXCLUDED.color_index)
            RETURNING color_index
            """;

    @Inject
    Pool pool;

    /** The account's color on the document, assigned now if it has none. */
    public Uni<Integer> of(UUID documentId, UUID accountId) {
        return pool.preparedQuery(FIND).execute(Tuple.of(documentId, accountId)).chain(rows -> rows.size() > 0
                ? Uni.createFrom().item(rows.iterator().next().getInteger(0))
                : pool.withTransaction(connection -> connection.preparedQuery(LOCK)
                        .execute(Tuple.of("color:" + documentId))
                        .chain(() -> connection.preparedQuery(ASSIGN).execute(Tuple.of(documentId, accountId)))
                        .map(assigned -> assigned.iterator().next().getInteger(0))));
    }
}
