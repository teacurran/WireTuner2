package com.villagecompute.wiretuner.api.blob;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Blob storage quotas (IO-008; saving.adoc, Server): a space -- a personal account or a team --
 * uses the bytes of the distinct blobs its documents reference ({@code document_blob}) and, for a
 * team, the fonts of its font library ({@code team_font}, removed ones until the Trash job deletes
 * them), so a blob two of its documents share counts once and a thumbnail, which is not a reference, not at all. The
 * limit is the space's {@code storage_limit_bytes}, else {@code wt.storage.quota.personal} or
 * {@code wt.storage.quota.team}. Usage is computed when asked, so it is exact after dedup and drops as
 * soon as the Trash job deletes a document. An upload that would take a space past its limit is
 * refused at its header, before a byte is stored: {@code RESOURCE_EXHAUSTED / STORAGE_QUOTA} with
 * the use and the limit and no {@code RetryInfo}. A blob the space already references adds nothing
 * and is always accepted; change ingest is never quota-limited. Two concurrent uploads may both pass
 * the check and take a space a little past its limit.
 */
@ApplicationScoped
public class StorageQuota {

    /** A space's use and limit in bytes. */
    public record Usage(UUID spaceId, long usedBytes, long limitBytes) {
    }

    /** The space's use ($1 the space; $2/$3 the personal and team defaults), and whether it references blob $4. */
    static final String USAGE = """
            SELECT cast(COALESCE((SELECT sum(b.size_bytes) FROM blob b WHERE b.sha256 IN (
                       SELECT db.sha256 FROM document_blob db JOIN document d ON d.id = db.document_id
                       WHERE d.owner_account_id = $1 OR d.team_id = $1
                       UNION SELECT f.sha256 FROM team_font f WHERE f.team_id = $1)), 0) AS bigint),
                   COALESCE((SELECT storage_limit_bytes FROM account WHERE id = $1),
                            (SELECT storage_limit_bytes FROM team WHERE id = $1),
                            CASE WHEN EXISTS (SELECT 1 FROM team WHERE id = $1) THEN $3 ELSE $2 END),
                   EXISTS (SELECT 1 FROM document_blob db JOIN document d ON d.id = db.document_id
                           WHERE db.sha256 = $4 AND (d.owner_account_id = $1 OR d.team_id = $1))
                   OR EXISTS (SELECT 1 FROM team_font f WHERE f.sha256 = $4 AND f.team_id = $1)
            """;

    static final String SPACE = "SELECT coalesce(team_id, owner_account_id) FROM document WHERE id = $1";

    /** The live teams an account belongs to, by name. */
    static final String TEAMS = """
            SELECT t.id FROM team_member m JOIN team t ON t.id = m.team_id
            WHERE m.account_id = $1 AND t.deleted_at IS NULL ORDER BY t.name, t.id
            """;

    @ConfigProperty(name = "wt.storage.quota.personal", defaultValue = "10737418240")
    long personal;

    @ConfigProperty(name = "wt.storage.quota.team", defaultValue = "107374182400")
    long team;

    @Inject
    Pool pool;

    /** Admits an upload of {@code size} bytes of blob {@code sha256} to the document's space, or fails with STORAGE_QUOTA. */
    public Uni<Void> admit(UUID documentId, String sha256, long size) {
        return pool.preparedQuery(SPACE).execute(Tuple.of(documentId))
                .chain(rows -> admitSpace(rows.iterator().next().getUUID(0), sha256, size));
    }

    /** Admits an upload of {@code size} bytes of blob {@code sha256} to a space (a team's font library), or fails with STORAGE_QUOTA. */
    public Uni<Void> admitSpace(UUID spaceId, String sha256, long size) {
        return query(spaceId, sha256)
                .chain(row -> {
                    long used = row.getLong(0);
                    long limit = row.getLong(1);
                    if (row.getBoolean(2) || used + size <= limit) {
                        return Uni.createFrom().voidItem();
                    }
                    return Uni.createFrom().failure(StatusExceptions.storageQuota(used, limit));
                });
    }

    /** The account's personal space and then each live team it belongs to, with use and limit. */
    public Uni<List<Usage>> of(UUID accountId) {
        return pool.preparedQuery(TEAMS).execute(Tuple.of(accountId)).chain(rows -> {
            List<UUID> spaces = new ArrayList<>();
            spaces.add(accountId);
            rows.forEach(row -> spaces.add(row.getUUID(0)));
            return Multi.createFrom().iterable(spaces)
                    .onItem().transformToUniAndConcatenate(space -> query(space, "")
                            .map(row -> new Usage(space, row.getLong(0), row.getLong(1))))
                    .collect().asList();
        });
    }

    private Uni<Row> query(UUID spaceId, String sha256) {
        return pool.preparedQuery(USAGE).execute(Tuple.of(spaceId, personal, team, sha256))
                .map(rows -> rows.iterator().next());
    }
}
