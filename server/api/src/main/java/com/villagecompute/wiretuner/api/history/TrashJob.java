package com.villagecompute.wiretuner.api.history;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.RowSet;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The daily Trash job (SRV-013; docs/spec/server.adoc, Jobs). A document trashed more than
 * {@code wt.trash.ttl} (30 days) ago is deleted for good with its branches: its snapshot and cold
 * segment objects are removed from object storage, then its row (every table referencing it
 * cascades). Then every blob nothing references any more -- no document, thumbnail or published
 * file, and older than {@code wt.trash.blob-grace} (a day, so an upload whose reference is still
 * being written is never taken) -- is removed from object storage and from {@code blob}; this is
 * also where replaced thumbnails go (sync-protocol.adoc, Blobs).
 */
@ApplicationScoped
public class TrashJob {

    private static final Logger LOG = Logger.getLogger(TrashJob.class);

    static final String EXPIRED = """
            SELECT id FROM document WHERE trashed_at < now() - make_interval(secs => $1)
            UNION
            SELECT b.document_id FROM branch b JOIN document p ON p.id = b.parent_document_id
            WHERE p.trashed_at < now() - make_interval(secs => $1)
            LIMIT $2
            """;

    static final String OBJECTS = """
            SELECT object_key FROM snapshot WHERE document_id = $1
            UNION ALL
            SELECT object_key FROM cold_segment WHERE document_id = $1
            """;

    static final String DELETE_DOCUMENT = "DELETE FROM document WHERE id = $1";

    static final String ORPHANS = """
            SELECT sha256, storage_key FROM blob b
            WHERE b.created_at < now() - make_interval(secs => $1)
              AND NOT EXISTS (SELECT 1 FROM document_blob r WHERE r.sha256 = b.sha256)
              AND NOT EXISTS (SELECT 1 FROM document d WHERE d.thumbnail_blob = b.sha256)
              AND NOT EXISTS (SELECT 1 FROM publish_file f WHERE f.sha256 = b.sha256)
            LIMIT $2
            """;

    static final String DELETE_BLOB = "DELETE FROM blob WHERE sha256 = $1";

    @ConfigProperty(name = "wt.trash.ttl", defaultValue = "30D")
    Duration ttl;

    @ConfigProperty(name = "wt.trash.blob-grace", defaultValue = "1D")
    Duration blobGrace;

    @ConfigProperty(name = "wt.trash.batch", defaultValue = "500")
    int batch;

    @Inject
    Pool pool;

    @Inject
    JobLocks locks;

    @Inject
    BlobStore store;

    @Scheduled(identity = "trash", every = "${wt.jobs.trash.every:24h}", delayed = "${wt.jobs.trash.delay:4m}",
            concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("trash", this::run).replaceWithVoid();
    }

    /** One run: expired documents, then orphaned blobs. */
    Uni<Void> run() {
        return pool.preparedQuery(EXPIRED).execute(Tuple.of(ttl.toSeconds(), batch))
                .chain(rows -> Multi.createFrom().iterable(ids(rows))
                        .onItem().transformToUniAndConcatenate(this::delete)
                        .collect().asList())
                .invoke(deleted -> LOG.infof("trash: %d documents deleted", deleted.size()))
                .chain(() -> pool.preparedQuery(ORPHANS).execute(Tuple.of(blobGrace.toSeconds(), batch)))
                .chain(rows -> {
                    List<Row> orphans = new ArrayList<>();
                    rows.forEach(orphans::add);
                    return Multi.createFrom().iterable(orphans)
                            .onItem().transformToUniAndConcatenate(row -> store.delete(row.getString(1))
                                    .chain(() -> pool.preparedQuery(DELETE_BLOB).execute(Tuple.of(row.getString(0)))))
                            .collect().asList()
                            .invoke(deleted -> LOG.infof("trash: %d orphaned blobs deleted", deleted.size()));
                })
                .replaceWithVoid();
    }

    /** Deletes one document's objects, then its row. */
    Uni<Void> delete(UUID documentId) {
        return pool.preparedQuery(OBJECTS).execute(Tuple.of(documentId))
                .chain(rows -> {
                    List<String> keys = new ArrayList<>();
                    rows.forEach(row -> keys.add(row.getString(0)));
                    return Multi.createFrom().iterable(keys)
                            .onItem().transformToUniAndConcatenate(store::delete)
                            .collect().asList();
                })
                .chain(() -> pool.preparedQuery(DELETE_DOCUMENT).execute(Tuple.of(documentId)))
                .replaceWithVoid();
    }

    private static List<UUID> ids(RowSet<Row> rows) {
        List<UUID> ids = new ArrayList<>();
        rows.forEach(row -> ids.add(row.getUUID(0)));
        return ids;
    }
}
