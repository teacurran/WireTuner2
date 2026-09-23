package com.villagecompute.wiretuner.api.data;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/** {@code data_allowed_host} (DATA-007): host keys per scope, exact match. */
@ApplicationScoped
public class AllowedHostRepository {

    /** A permitted host. */
    public record Entry(String host, UUID addedBy, String addedByName, OffsetDateTime addedAt) {
    }

    static final String COLUMNS = "h.host, h.added_by, coalesce(a.display_name, '') AS added_by_name, h.added_at";

    @Inject
    Pool pool;

    /** Permits the host (already a key); an existing entry is kept as it was. Returns the entry. */
    public Uni<Entry> put(DataScope scope, String host, UUID by) {
        return pool.preparedQuery("INSERT INTO data_allowed_host (id, team_id, account_id, host, added_by)"
                + " VALUES ($1, $2, $3, $4, $5) ON CONFLICT (" + scope.column() + ", host) WHERE " + scope.column()
                + " IS NOT NULL DO NOTHING")
                .execute(Tuple.of(UUID.randomUUID(), scope.teamId(), scope.accountId(), host, by))
                .chain(() -> list(scope, host, true, 1))
                .map(found -> found.get(0));
    }

    public Uni<Boolean> delete(DataScope scope, String host) {
        return pool.preparedQuery("DELETE FROM data_allowed_host WHERE " + scope.column() + " = $1 AND host = $2")
                .execute(Tuple.of(scope.id(), host)).map(rows -> rows.rowCount() > 0);
    }

    /** Up to {@code limit} entries after {@code afterHost} (null for the first), by host. */
    public Uni<List<Entry>> list(DataScope scope, String afterHost, int limit) {
        return list(scope, afterHost == null ? "" : afterHost, false, limit);
    }

    public Uni<Boolean> contains(DataScope scope, String host) {
        return pool.preparedQuery("SELECT 1 FROM data_allowed_host WHERE " + scope.column() + " = $1 AND host = $2")
                .execute(Tuple.of(scope.id(), host)).map(rows -> rows.size() > 0);
    }

    private Uni<List<Entry>> list(DataScope scope, String host, boolean exact, int limit) {
        return pool.preparedQuery("SELECT " + COLUMNS + " FROM data_allowed_host h LEFT JOIN account a ON a.id = h.added_by"
                + " WHERE h." + scope.column() + " = $1 AND h.host " + (exact ? "=" : ">") + " $2 ORDER BY h.host LIMIT $3")
                .execute(Tuple.of(scope.id(), host, limit))
                .map(rows -> {
                    List<Entry> found = new ArrayList<>();
                    for (Row row : rows) {
                        found.add(new Entry(row.getString("host"), row.getUUID("added_by"), row.getString("added_by_name"),
                                row.getOffsetDateTime("added_at")));
                    }
                    return found;
                });
    }
}
