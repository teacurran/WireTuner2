package com.villagecompute.wiretuner.api.history;

import java.util.UUID;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.sync.ChangeReader;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.crdt.Snapshot;
import com.villagecompute.wiretuner.crdt.Zstd;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * A document's merged state at a server_seq, built the way the snapshotter builds it
 * (docs/spec/server.adoc, Jobs): the newest snapshot at or before the seq, decoded through
 * {@code wt-crdt}, then every change after it up to the seq replayed from the hot log and cold
 * segments ({@link ChangeReader}). A range the retained history does not hold is
 * {@code FAILED_PRECONDITION / HISTORY_UNAVAILABLE}. One engine per call: {@link Engine} is not
 * thread-safe.
 */
@ApplicationScoped
public class DocumentStates {

    static final String BASE = """
            SELECT server_seq, object_key, uncompressed_size FROM snapshot
            WHERE document_id = $1 AND server_seq <= $2 ORDER BY server_seq DESC LIMIT 1
            """;

    /** A snapshot a state starts from: its seq and the engine it decodes to. */
    record Base(long serverSeq, Engine engine) {
    }

    final Schema schema = Schema.generated();

    @Inject
    Pool pool;

    @Inject
    BlobStore store;

    @Inject
    ChangeReader reader;

    /** The state at exactly {@code serverSeq}. */
    public Uni<Engine> at(UUID documentId, long serverSeq) {
        return base(documentId, serverSeq).chain(base -> reader.range(documentId, base.serverSeq(), serverSeq)
                .onItem().invoke(change -> base.engine().apply(change.getChange(), change.getServerSeq()))
                .collect().last()
                .replaceWith(base.engine()));
    }

    private Uni<Base> base(UUID documentId, long serverSeq) {
        return pool.preparedQuery(BASE).execute(Tuple.of(documentId, serverSeq)).chain(rows -> {
            if (rows.rowCount() == 0) {
                return Uni.createFrom().item(new Base(0, new Engine(schema)));
            }
            Row row = rows.iterator().next();
            long seq = row.getLong(0);
            int size = (int) row.getLong(2).longValue();
            return store.bytes(row.getString(1)).map(object -> new Base(seq, decode(Zstd.decompress(object, size))));
        });
    }

    /** The engine a snapshot's bytes decode to. */
    Engine decode(byte[] snapshot) {
        try {
            return Snapshot.decode(snapshot, schema);
        } catch (Snapshot.SnapshotException e) {
            throw new IllegalStateException("snapshot does not decode: " + e.getMessage(), e);
        }
    }
}
