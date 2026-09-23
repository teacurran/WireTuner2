package com.villagecompute.wiretuner.api.sync;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.history.SegmentCodec;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Reads the hot change log as {@code SequencedChange}s with their authors (the account the
 * replica is bound to; for a change a branch merge replayed, bound on the branch), for the
 * subscription's replay, catch-up downloads and gap backfill. Reads page by page on demand, so a slow reader holds back the query rather than filling memory.
 * Where the hot log does not continue the range, the cold segment holding the next server_seq is
 * read from object storage (SRV-007) and its changes in the range form the page; a range neither
 * holds is {@code FAILED_PRECONDITION / HISTORY_UNAVAILABLE}.
 */
@ApplicationScoped
public class ChangeReader {

    /** Rows per query; also the {@code max_items} of a {@code FetchChangesResponse}. */
    public static final int PAGE = 256;

    static final String PAGE_QUERY = """
            SELECT c.server_seq, c.bytes, r.account_id, a.display_name FROM change_log c
            LEFT JOIN replica r ON r.document_id = coalesce(c.merged_from_branch_id, c.document_id)
                                AND r.replica_id = c.replica_id
            LEFT JOIN account a ON a.id = r.account_id
            WHERE c.document_id = $1 AND c.server_seq > $2 AND c.server_seq <= $3
            ORDER BY c.server_seq LIMIT $4
            """;

    static final String HEAD = "SELECT head_seq FROM document WHERE id = $1";

    static final String SEGMENT = """
            SELECT object_key FROM cold_segment WHERE document_id = $1 AND from_seq <= $2 AND to_seq >= $2
            """;

    /**
     * Who each replica is bound to: on the document, else on one of its branches -- a change a branch
     * merge replayed keeps its replica, which is bound on the branch (COLLAB-004).
     */
    static final String AUTHORS = """
            SELECT DISTINCT ON (r.replica_id) r.replica_id, r.account_id, a.display_name FROM replica r
            LEFT JOIN account a ON a.id = r.account_id
            WHERE r.replica_id = ANY($2)
              AND (r.document_id = $1 OR r.document_id IN (SELECT document_id FROM branch WHERE parent_document_id = $1))
            ORDER BY r.replica_id, r.document_id = $1 DESC
            """;

    @Inject
    Pool pool;

    @Inject
    BlobStore store;

    /** The document's head server_seq now. */
    public Uni<Long> head(UUID documentId) {
        return pool.preparedQuery(HEAD).execute(Tuple.of(documentId)).map(rows -> rows.iterator().next().getLong(0));
    }

    /** The changes with {@code after < server_seq <= until}, oldest first; the range must be contiguous. */
    public Multi<SequencedChange> range(UUID documentId, long after, long until) {
        AtomicLong cursor = new AtomicLong(after);
        return Multi.createBy().repeating()
                .uni(() -> page(documentId, cursor, until))
                .until(List::isEmpty)
                .onItem().disjoint();
    }

    /** The next page after {@code cursor}, advancing it; empty once the cursor reaches {@code until}. */
    private Uni<List<SequencedChange>> page(UUID documentId, AtomicLong cursor, long until) {
        long after = cursor.get();
        if (after >= until) {
            return Uni.createFrom().item(List.of());
        }
        return pool.preparedQuery(PAGE_QUERY).execute(Tuple.of(documentId, after, until, PAGE)).chain(rows -> {
            List<SequencedChange> page = new ArrayList<>(rows.rowCount());
            long expected = after + 1;
            for (Row row : rows) {
                if (row.getLong(0) != expected) {
                    break;
                }
                page.add(sequenced(row));
                expected++;
            }
            return page.isEmpty() ? cold(documentId, after, until) : Uni.createFrom().item(page);
        }).invoke(page -> cursor.set(page.get(page.size() - 1).getServerSeq()));
    }

    /** The changes of the cold segment holding {@code after + 1} that are in the range, with their authors. */
    private Uni<List<SequencedChange>> cold(UUID documentId, long after, long until) {
        return pool.preparedQuery(SEGMENT).execute(Tuple.of(documentId, after + 1)).chain(rows -> {
            if (rows.rowCount() == 0) {
                return Uni.createFrom().failure(StatusExceptions.historyUnavailable(after + 1, until));
            }
            return store.bytes(rows.iterator().next().getString(0))
                    .map(object -> SegmentCodec.decode(object).stream()
                            .filter(change -> change.getServerSeq() > after && change.getServerSeq() <= until)
                            .toList())
                    .chain(changes -> withAuthors(documentId, changes));
        });
    }

    /** {@code changes} with the account each one's replica is bound to on {@code documentId} as its author. */
    public Uni<List<SequencedChange>> withAuthors(UUID documentId, List<SequencedChange> changes) {
        Long[] replicas = changes.stream().map(change -> change.getChange().getReplica()).distinct().toArray(Long[]::new);
        return pool.preparedQuery(AUTHORS).execute(Tuple.of(documentId, replicas)).map(rows -> {
            Map<Long, Participant> authors = new HashMap<>();
            for (Row row : rows) {
                authors.put(row.getLong(0), participant(row.getUUID(1), row.getString(2)));
            }
            return changes.stream().map(change -> {
                Participant author = authors.get(change.getChange().getReplica());
                return author == null ? change : change.toBuilder().setAuthor(author).build();
            }).toList();
        });
    }

    private static SequencedChange sequenced(Row row) {
        SequencedChange.Builder change = SequencedChange.newBuilder()
                .setServerSeq(row.getLong(0))
                .setChange(Protos.change(row.getBuffer(1).getBytes()));
        UUID author = row.getUUID(2);
        if (author != null) {
            change.setAuthor(participant(author, row.getString(3)));
        }
        return change.build();
    }

    private static Participant participant(UUID account, String displayName) {
        return Participant.newBuilder().setUserId(account.toString()).setDisplayName(displayName).build();
    }
}
