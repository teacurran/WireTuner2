package com.villagecompute.wiretuner.api.sync;

import java.util.Arrays;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.observability.WtMetrics;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.smallrye.mutiny.Uni;
import io.vertx.core.buffer.Buffer;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.RowSet;
import io.vertx.mutiny.sqlclient.Tuple;

import org.jboss.logging.Logger;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * {@code ChangeIngest.accept} of docs/spec/server.adoc (Ingest path): the acceptance rules of
 * docs/spec/sync-protocol.adoc (Server log) for one change from an already-authorised caller, the
 * write, and the publish.
 *
 * <p>The write is one statement ({@link #INSERT}), group-committed with the document's other
 * inserts by the {@link ChangeWriter}: an upsert of the replica row that binds an
 * unbound replica on seq 1 and otherwise advances {@code last_seq} only when the row is bound to
 * the caller's account and device, is live, and holds {@code seq - 1}; then, only if that took,
 * {@code head_seq + 1} on the document row, whose row lock serialises {@code server_seq} per document
 * and is held until the batch commits; then the {@code change_log} insert at the new head. When
 * nothing was written the replica row and the logged change are read back to say why: a replica
 * bound elsewhere or retired, an already-accepted seq with identical content (silently acked with
 * its original {@code server_seq}) or different content ({@code REPLICA_CONFLICT}), or a gap
 * ({@code SEQ_GAP}).
 */
@ApplicationScoped
public class ChangeIngest {

    private static final Logger LOG = Logger.getLogger(ChangeIngest.class);

    static final String INSERT = """
            WITH r AS (
                INSERT INTO replica AS t (document_id, replica_id, account_id, device_id, last_seq, last_seen_at)
                SELECT $1, $2, $3, $4, $5, now()
                WHERE $5 = 1 OR EXISTS (SELECT 1 FROM replica WHERE document_id = $1 AND replica_id = $2)
                ON CONFLICT (document_id, replica_id) DO UPDATE
                    SET last_seq = EXCLUDED.last_seq, last_seen_at = EXCLUDED.last_seen_at
                    WHERE t.last_seq = EXCLUDED.last_seq - 1 AND t.account_id = EXCLUDED.account_id
                      AND t.device_id = EXCLUDED.device_id AND t.retired_at IS NULL
                RETURNING 1
            ), d AS (
                UPDATE document SET head_seq = head_seq + 1
                WHERE id = $1 AND EXISTS (SELECT 1 FROM r)
                RETURNING head_seq
            )
            INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size)
            SELECT $1, d.head_seq, $2, $5, $6, $7 FROM d
            RETURNING server_seq
            """;

    static final String REPLICA = """
            SELECT account_id, device_id, last_seq, retired_at IS NOT NULL FROM replica
            WHERE document_id = $1 AND replica_id = $2
            """;

    static final String LOGGED = """
            SELECT server_seq, bytes FROM change_log WHERE document_id = $1 AND replica_id = $2 AND seq = $3
            """;

    /** A caller whose role allows pushing, with the author every subscriber sees on its changes. */
    public record Pusher(Principal principal, Participant author) {
    }

    final Schema schema = Schema.generated();

    @Inject
    Pool pool;

    @Inject
    ChangeWriter writer;

    @Inject
    SyncBus bus;

    @Inject
    WtMetrics metrics;

    /** Accepts one change; the result is its {@code server_seq}. */
    public Uni<Long> accept(Pusher pusher, UUID documentId, Change change) {
        long started = System.nanoTime();
        return Uni.createFrom().item(change)
                .invoke(c -> ChangeRules.check(schema, c))
                .chain(c -> write(pusher, documentId, c, started));
    }

    private Uni<Long> write(Pusher pusher, UUID documentId, Change change, long started) {
        byte[] bytes = change.toByteArray();
        Principal principal = pusher.principal();
        Tuple args = Tuple.from(new Object[] {documentId, change.getReplica(), principal.accountId(),
                ReplicaBinding.device(principal), change.getSeq(), Buffer.buffer(bytes), bytes.length});
        return writer.write(documentId, args).chain(serverSeq -> {
            if (serverSeq == null) {
                return explain(principal, documentId, change, bytes);
            }
            LOG.debugf("accepted %s replica %s seq %d as server_seq %d", documentId,
                    Long.toUnsignedString(change.getReplica()), change.getSeq(), serverSeq);
            metrics.accepted(documentId);
            metrics.ingest(System.nanoTime() - started);
            ServerFrame frame = ServerFrame.newBuilder().setChange(SequencedChange.newBuilder()
                    .setServerSeq(serverSeq).setChange(change).setAuthor(pusher.author())).build();
            // This node's subscribers have the frame once publish returns; the Valkey leg is not
            // waited for: a node that misses it fills the gap from the log at the next frame.
            bus.publish(documentId, frame).subscribe().with(ignored -> { }, failure -> LOG.warnf(failure, "publishing %s failed", documentId));
            return Uni.createFrom().item(serverSeq);
        });
    }

    /** Why nothing was written: a rejection, or the original server_seq of an identical retry. */
    private Uni<Long> explain(Principal principal, UUID documentId, Change change, byte[] bytes) {
        long replica = change.getReplica();
        long seq = change.getSeq();
        return pool.preparedQuery(REPLICA).execute(Tuple.of(documentId, replica)).chain(rows -> {
            ReplicaBinding binding = binding(rows);
            ReplicaBinding.check(binding, principal, replica);
            long last = binding == null ? 0 : binding.lastSeq();
            if (seq > last) {
                metrics.seqGap();
                return Uni.createFrom().failure(StatusExceptions.seqGap(last + 1, seq));
            }
            return pool.preparedQuery(LOGGED).execute(Tuple.of(documentId, replica, seq)).map(logged -> {
                if (logged.rowCount() == 0) {
                    // Accepted once but already compacted out of the hot log: resend from the head.
                    throw StatusExceptions.seqGap(last + 1, seq);
                }
                Row row = logged.iterator().next();
                if (!Arrays.equals(row.getBuffer(1).getBytes(), bytes)) {
                    throw StatusExceptions.replicaConflict(replica, seq);
                }
                return row.getLong(0);
            });
        });
    }

    /** The replica row of a {@link #REPLICA} query, or null when the replica is unbound. */
    static ReplicaBinding binding(RowSet<Row> rows) {
        if (rows.rowCount() == 0) {
            return null;
        }
        Row row = rows.iterator().next();
        return new ReplicaBinding(row.getUUID(0), row.getUUID(1), row.getLong(2), row.getBoolean(3));
    }
}
