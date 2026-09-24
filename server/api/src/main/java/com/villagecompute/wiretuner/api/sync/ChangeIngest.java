package com.villagecompute.wiretuner.api.sync;

import java.util.Arrays;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.comments.CommentIndex;
import com.villagecompute.wiretuner.api.comments.CommentOps;
import com.villagecompute.wiretuner.api.comments.CommentRules;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.history.ChangeIndex;
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
 * and is held until the batch commits; then the {@code change_log} insert at the new head, with the
 * change's horizon (D-067): the publication the replica last confirmed receiving (its
 * {@code horizon_seq} and {@code horizon_ms}), capped by the change's {@code base_server_seq}. When
 * nothing was written the replica row and the logged change are read back to say why: a replica
 * bound elsewhere or retired, an already-accepted seq with identical content (silently acked with
 * its original {@code server_seq}) or different content ({@code REPLICA_CONFLICT}), or a gap
 * ({@code SEQ_GAP}). The same statement writes the change's history index ({@link ChangeIndex}: the
 * nodes it names and the names it gives) at the new {@code server_seq} (COLLAB-020).
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
                RETURNING t.horizon_seq, t.horizon_ms
            ), d AS (
                UPDATE document SET head_seq = head_seq + 1
                WHERE id = $1 AND EXISTS (SELECT 1 FROM r)
                RETURNING head_seq
            ), n AS (
                INSERT INTO change_node (document_id, node_replica, node_counter, server_seq)
                SELECT $1, t.r, t.c, d.head_seq FROM d, unnest($9::bigint[], $10::bigint[]) AS t(r, c)
            ), m AS (
                INSERT INTO node_name (document_id, node_replica, node_counter, server_seq, kind, name)
                SELECT $1, t.r, t.c, d.head_seq, t.k, t.n
                FROM d, unnest($11::bigint[], $12::bigint[], $13::int[], $14::text[]) AS t(r, c, k, n)
            )
            INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size, horizon_seq, horizon_ms)
            SELECT $1, d.head_seq, $2, $5, $6, $7, LEAST(r.horizon_seq, $8), r.horizon_ms FROM d, r
            RETURNING server_seq
            """;

    static final String REPLICA = """
            SELECT account_id, device_id, last_seq, retired_at IS NOT NULL FROM replica
            WHERE document_id = $1 AND replica_id = $2
            """;

    static final String LOGGED = """
            SELECT server_seq, bytes FROM change_log WHERE document_id = $1 AND replica_id = $2 AND seq = $3
            """;

    /**
     * A caller whose role allows pushing (commenter or above; a commenter only under the comments
     * collection, {@link CommentRules}), with the author every subscriber sees on its changes.
     */
    public record Pusher(Principal principal, Participant author, Role role) {
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

    @Inject
    CommentIndex comments;

    /** A write's {@code server_seq}, and whether it was new (not the ack of an identical retry). */
    record Written(long serverSeq, boolean fresh) {
    }

    /**
     * Accepts one change; the result is its {@code server_seq}. Local-only writes are taken out
     * first ({@link ChangeRules#withoutLocalOnly}), so what is logged, fanned out and compared with
     * a retry never carries them. What the change does to comments is
     * checked against the caller's role before the write and recorded after it, before the change is
     * fanned out (COLLAB-030).
     */
    public Uni<Long> accept(Pusher pusher, UUID documentId, Change change) {
        long started = System.nanoTime();
        Change pushed = ChangeRules.withoutLocalOnly(schema, change);
        if (pushed != change) {
            LOG.debugf("stripped local-only writes from %s replica %s seq %d", documentId,
                    Long.toUnsignedString(change.getReplica()), change.getSeq());
        }
        return Uni.createFrom().item(pushed)
                .invoke(c -> ChangeRules.check(schema, c))
                .chain(c -> comments.check(pusher, documentId, CommentOps.parse(c)))
                .chain(checked -> write(pusher, documentId, pushed, checked, started));
    }

    private Uni<Long> write(Pusher pusher, UUID documentId, Change change, CommentIndex.Checked checked, long started) {
        byte[] bytes = change.toByteArray();
        Principal principal = pusher.principal();
        Tuple args = Tuple.from(new Object[] {documentId, change.getReplica(), principal.accountId(),
                ReplicaBinding.device(principal), change.getSeq(), Buffer.buffer(bytes), bytes.length,
                change.getBaseServerSeq()});
        for (Object column : ChangeIndex.entries(change).columns()) {
            args.addValue(column);
        }
        return writer.write(documentId, args)
                .chain(serverSeq -> serverSeq == null ? explain(principal, documentId, change, bytes).map(seq -> new Written(seq, false))
                        : Uni.createFrom().item(new Written(serverSeq, true)))
                .call(written -> comments.index(pusher, documentId, written.serverSeq(), checked))
                .map(written -> {
                    if (written.fresh()) {
                        published(pusher, documentId, change, written.serverSeq(), started);
                    }
                    return written.serverSeq();
                });
    }

    private void published(Pusher pusher, UUID documentId, Change change, long serverSeq, long started) {
        LOG.debugf("accepted %s replica %s seq %d as server_seq %d", documentId,
                Long.toUnsignedString(change.getReplica()), change.getSeq(), serverSeq);
        metrics.accepted(documentId);
        metrics.ingest(System.nanoTime() - started);
        ServerFrame frame = ServerFrame.newBuilder().setChange(SequencedChange.newBuilder()
                .setServerSeq(serverSeq).setChange(change).setAuthor(pusher.author())).build();
        // This node's subscribers have the frame once publish returns; the Valkey leg is not
        // waited for: a node that misses it fills the gap from the log at the next frame.
        bus.publish(documentId, frame).subscribe().with(LOG::trace, LOG::warn);
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
