package com.villagecompute.wiretuner.api.sync;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
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
 * replica is bound to), for the subscription's replay, catch-up downloads and gap backfill. Reads
 * page by page on demand, so a slow reader holds back the query rather than filling memory.
 * Cold segments arrive with SRV-007: a range that is no longer contiguous in the hot log is
 * {@code FAILED_PRECONDITION / HISTORY_UNAVAILABLE}.
 */
@ApplicationScoped
public class ChangeReader {

    /** Rows per query; also the {@code max_items} of a {@code FetchChangesResponse}. */
    public static final int PAGE = 256;

    static final String PAGE_QUERY = """
            SELECT c.server_seq, c.bytes, r.account_id, a.display_name FROM change_log c
            LEFT JOIN replica r ON r.document_id = c.document_id AND r.replica_id = c.replica_id
            LEFT JOIN account a ON a.id = r.account_id
            WHERE c.document_id = $1 AND c.server_seq > $2 AND c.server_seq <= $3
            ORDER BY c.server_seq LIMIT $4
            """;

    static final String HEAD = "SELECT head_seq FROM document WHERE id = $1";

    @Inject
    Pool pool;

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
        return pool.preparedQuery(PAGE_QUERY).execute(Tuple.of(documentId, after, until, PAGE)).map(rows -> {
            List<SequencedChange> page = new ArrayList<>(rows.rowCount());
            long expected = after + 1;
            for (Row row : rows) {
                long seq = row.getLong(0);
                if (seq != expected) {
                    break;
                }
                page.add(sequenced(row));
                expected++;
            }
            if (page.isEmpty()) {
                throw StatusExceptions.historyUnavailable(after + 1, until);
            }
            cursor.set(expected - 1);
            return page;
        });
    }

    private static SequencedChange sequenced(Row row) {
        SequencedChange.Builder change = SequencedChange.newBuilder()
                .setServerSeq(row.getLong(0))
                .setChange(Protos.change(row.getBuffer(1).getBytes()));
        UUID author = row.getUUID(2);
        if (author != null) {
            change.setAuthor(Participant.newBuilder().setUserId(author.toString()).setDisplayName(row.getString(3)));
        }
        return change.build();
    }
}
