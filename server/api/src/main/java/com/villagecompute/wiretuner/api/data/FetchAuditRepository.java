package com.villagecompute.wiretuner.api.data;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * {@code data_fetch_audit} (DATA-008): one row per Fetch, FetchAsset or Proxy call, written when it
 * ends. The row has no column a query string, a header or a body could go into.
 */
@ApplicationScoped
public class FetchAuditRepository {

    /** One audited call. {@code sourceCounter} and {@code sourceReplica} are null outside Fetch. */
    public record Entry(UUID id, DataScope scope, UUID documentId, Long sourceCounter, Long sourceReplica, UUID accountId,
            String accountName, String host, String path, String kind, Instant startedAt, Instant finishedAt, String status,
            int pages, long records, long bytes) {
    }

    /** The filters and keyset position of a ListFetchAudit page. */
    public record Query(DataScope scope, UUID documentId, String host, UUID accountId, Instant beforeStartedAt, UUID beforeId,
            int limit) {
    }

    @Inject
    Pool pool;

    public Uni<Void> insert(Entry e) {
        return pool.preparedQuery("INSERT INTO data_fetch_audit (id, team_id, owner_account_id, document_id, source_counter,"
                + " source_replica, account_id, host, path, kind, started_at, finished_at, status, pages, records, bytes)"
                + " VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)")
                .execute(Tuple.tuple().addUUID(e.id()).addUUID(e.scope().teamId()).addUUID(e.scope().accountId())
                        .addUUID(e.documentId()).addLong(e.sourceCounter()).addLong(e.sourceReplica()).addUUID(e.accountId())
                        .addString(e.host()).addString(e.path()).addString(e.kind()).addOffsetDateTime(utc(e.startedAt()))
                        .addOffsetDateTime(utc(e.finishedAt())).addString(e.status()).addInteger(e.pages())
                        .addLong(e.records()).addLong(e.bytes()))
                .replaceWithVoid();
    }

    /** A page of the scope's rows, newest first, filtered. */
    public Uni<List<Entry>> list(Query q) {
        String scopeColumn = q.scope().isTeam() ? "team_id" : "owner_account_id";
        StringBuilder sql = new StringBuilder("SELECT f.*, coalesce(a.display_name, '') AS account_name FROM data_fetch_audit f"
                + " LEFT JOIN account a ON a.id = f.account_id WHERE f." + scopeColumn + " = $1");
        Tuple args = Tuple.of(q.scope().id());
        if (q.documentId() != null) {
            args.addUUID(q.documentId());
            sql.append(" AND f.document_id = $").append(args.size());
        }
        if (q.host() != null) {
            args.addString(q.host());
            sql.append(" AND f.host = $").append(args.size());
        }
        if (q.accountId() != null) {
            args.addUUID(q.accountId());
            sql.append(" AND f.account_id = $").append(args.size());
        }
        if (q.beforeStartedAt() != null) {
            args.addOffsetDateTime(utc(q.beforeStartedAt())).addUUID(q.beforeId());
            sql.append(" AND (f.started_at, f.id) < ($").append(args.size() - 1).append(", $").append(args.size()).append(')');
        }
        args.addInteger(q.limit());
        sql.append(" ORDER BY f.started_at DESC, f.id DESC LIMIT $").append(args.size());
        return pool.preparedQuery(sql.toString()).execute(args).map(rows -> {
            List<Entry> found = new ArrayList<>();
            for (Row row : rows) {
                found.add(entry(row));
            }
            return found;
        });
    }

    /** Deletes rows that started before {@code cutoff}; returns how many. */
    public Uni<Integer> deleteStartedBefore(Instant cutoff) {
        return pool.preparedQuery("DELETE FROM data_fetch_audit WHERE started_at < $1").execute(Tuple.of(utc(cutoff)))
                .map(rows -> rows.rowCount());
    }

    private static Entry entry(Row row) {
        return new Entry(row.getUUID("id"), new DataScope(row.getUUID("team_id"), row.getUUID("owner_account_id")),
                row.getUUID("document_id"), row.getLong("source_counter"), row.getLong("source_replica"),
                row.getUUID("account_id"), row.getString("account_name"), row.getString("host"), row.getString("path"),
                row.getString("kind"), row.getOffsetDateTime("started_at").toInstant(),
                row.getOffsetDateTime("finished_at").toInstant(), row.getString("status"), row.getInteger("pages"),
                row.getLong("records"), row.getLong("bytes"));
    }

    static OffsetDateTime utc(Instant instant) {
        return instant.atOffset(ZoneOffset.UTC);
    }
}
