package com.villagecompute.wiretuner.api.data;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.core.buffer.Buffer;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.RowSet;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * {@code data_credential} (DATA-005) through the reactive pool: metadata in clear, the secret sealed by
 * {@link Envelope}. Nothing here ever decrypts; the sealed parts travel in {@link Stored} to the one
 * place that opens them, the fetch path.
 */
@ApplicationScoped
public class CredentialRepository {

    /** A credential row: metadata, and the sealed secret (null in list results). */
    public record Stored(UUID id, String name, String kind, String host, UUID createdBy, String createdByName,
            OffsetDateTime createdAt, OffsetDateTime rotatedAt, Envelope.Sealed sealed) {
    }

    static final String META = "c.id, c.name, c.kind, c.host, c.created_by, coalesce(a.display_name, '') AS created_by_name,"
            + " c.created_at, c.rotated_at";

    @Inject
    Pool pool;

    /** Inserts a credential or replaces the one of the same name in the scope (keeping its id, creator and creation time). */
    public Uni<Stored> put(DataScope scope, String name, String kind, String host, Envelope.Sealed sealed, UUID by) {
        String sql = "WITH c AS (INSERT INTO data_credential (id, team_id, account_id, name, kind, host, key_id, wrapped_key,"
                + " ciphertext, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)"
                + " ON CONFLICT (" + scope.column() + ", name) WHERE " + scope.column() + " IS NOT NULL DO UPDATE SET"
                + " kind = EXCLUDED.kind, host = EXCLUDED.host, key_id = EXCLUDED.key_id, wrapped_key = EXCLUDED.wrapped_key,"
                + " ciphertext = EXCLUDED.ciphertext, rotated_at = now() RETURNING *)"
                + " SELECT " + META + " FROM c LEFT JOIN account a ON a.id = c.created_by";
        Tuple args = Tuple.tuple().addUUID(UUID.randomUUID()).addUUID(scope.teamId()).addUUID(scope.accountId())
                .addString(name).addString(kind).addString(host).addString(sealed.keyId())
                .addBuffer(Buffer.buffer(sealed.wrappedKey())).addBuffer(Buffer.buffer(sealed.ciphertext())).addUUID(by);
        return pool.preparedQuery(sql).execute(args).map(rows -> meta(rows.iterator().next()));
    }

    /** Removes a credential; true when one was removed. */
    public Uni<Boolean> delete(DataScope scope, String name) {
        return pool.preparedQuery("DELETE FROM data_credential WHERE " + scope.column() + " = $1 AND name = $2")
                .execute(Tuple.of(scope.id(), name)).map(rows -> rows.rowCount() > 0);
    }

    /** Up to {@code limit} credentials after {@code afterName} (null for the first), by name; metadata only. */
    public Uni<List<Stored>> list(DataScope scope, String afterName, int limit) {
        return pool.preparedQuery("SELECT " + META + " FROM data_credential c LEFT JOIN account a ON a.id = c.created_by"
                + " WHERE c." + scope.column() + " = $1 AND c.name > $2 ORDER BY c.name LIMIT $3")
                .execute(Tuple.of(scope.id(), afterName == null ? "" : afterName, limit))
                .map(CredentialRepository::metas);
    }

    /** The credential with its sealed secret, or null. */
    public Uni<Stored> find(DataScope scope, String name) {
        return pool.preparedQuery("SELECT " + META + ", c.key_id, c.wrapped_key, c.ciphertext FROM data_credential c"
                + " LEFT JOIN account a ON a.id = c.created_by WHERE c." + scope.column() + " = $1 AND c.name = $2")
                .execute(Tuple.of(scope.id(), name))
                .map(rows -> rows.size() == 0 ? null : sealed(rows.iterator().next()));
    }

    /** Up to {@code limit} rows wrapped with another key than {@code currentKeyId}, with the scope they belong to. */
    public Uni<List<Rotatable>> wrappedWithOtherKey(String currentKeyId, int limit) {
        return pool.preparedQuery("SELECT id, team_id, account_id, name, key_id, wrapped_key, ciphertext FROM data_credential"
                + " WHERE key_id <> $1 ORDER BY id LIMIT $2")
                .execute(Tuple.of(currentKeyId, limit))
                .map(rows -> {
                    List<Rotatable> found = new java.util.ArrayList<>();
                    for (Row row : rows) {
                        found.add(new Rotatable(row.getUUID("id"), new DataScope(row.getUUID("team_id"), row.getUUID("account_id")),
                                row.getString("name"), sealedOf(row)));
                    }
                    return found;
                });
    }

    /** A row the rotation job rewraps. */
    public record Rotatable(UUID id, DataScope scope, String name, Envelope.Sealed sealed) {
    }

    /** Stores a rewrapped data key, unless the row changed since it was read; the rows written (0 or 1). */
    public Uni<Integer> rewrap(UUID id, String previousKeyId, Envelope.Sealed sealed) {
        return pool.preparedQuery("UPDATE data_credential SET key_id = $1, wrapped_key = $2 WHERE id = $3 AND key_id = $4")
                .execute(Tuple.tuple().addString(sealed.keyId()).addBuffer(Buffer.buffer(sealed.wrappedKey())).addUUID(id)
                        .addString(previousKeyId))
                .map(rows -> rows.rowCount());
    }

    private static List<Stored> metas(RowSet<Row> rows) {
        List<Stored> found = new java.util.ArrayList<>();
        for (Row row : rows) {
            found.add(meta(row));
        }
        return found;
    }

    private static Stored meta(Row row) {
        return stored(row, null);
    }

    private static Stored sealed(Row row) {
        return stored(row, sealedOf(row));
    }

    private static Envelope.Sealed sealedOf(Row row) {
        return new Envelope.Sealed(row.getString("key_id"), row.getBuffer("wrapped_key").getBytes(),
                row.getBuffer("ciphertext").getBytes());
    }

    private static Stored stored(Row row, Envelope.Sealed sealed) {
        return new Stored(row.getUUID("id"), row.getString("name"), row.getString("kind"), row.getString("host"),
                row.getUUID("created_by"), row.getString("created_by_name"), row.getOffsetDateTime("created_at"),
                row.getOffsetDateTime("rotated_at"), sealed);
    }
}
