package com.villagecompute.wiretuner.api.history;

import java.util.Arrays;
import java.util.HexFormat;
import java.util.Objects;
import java.util.UUID;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.Snapshot;
import com.villagecompute.wiretuner.crdt.Zstd;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Writes a snapshot (docs/spec/server.adoc, Persistence): the engine's {@code DocumentSnapshot}
 * at a server_seq, zstd-compressed as one object in R2/MinIO under
 * {@code snapshots/<document>/<server_seq>}, and its {@code snapshot} row with the state hash, the
 * compressed and decompressed sizes, the node count and the collection point it was collected at.
 * {@code FetchSnapshot} serves the object in 1 MiB chunks. A snapshot at a seq already recorded is
 * left as it is: the state at a seq never changes, only how much of it was collected.
 */
@ApplicationScoped
public class Snapshots {

    static final String INSERT = """
            INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, uncompressed_size,
                                  node_count, collect_seq, collect_time_ms)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (document_id, server_seq) DO NOTHING
            """;

    static final String EXISTING = "SELECT state_hash FROM snapshot WHERE document_id = $1 AND server_seq = $2";

    @Inject
    Pool pool;

    @Inject
    BlobStore store;

    /** The object key of a document's snapshot at {@code serverSeq}. */
    public static String key(UUID documentId, long serverSeq) {
        return "snapshots/" + documentId + "/" + serverSeq;
    }

    /**
     * Stores {@code engine}'s state as the document's snapshot at {@code serverSeq} unless one is
     * recorded there already; the result is the recorded snapshot's state hash (hex).
     */
    public Uni<String> write(UUID documentId, long serverSeq, Engine engine, long collectSeq, long collectTimeMs) {
        return pool.preparedQuery(EXISTING).execute(Tuple.of(documentId, serverSeq)).chain(rows -> rows.rowCount() > 0
                ? Uni.createFrom().item(rows.iterator().next().getString(0))
                : store(documentId, serverSeq, engine, collectSeq, collectTimeMs));
    }

    private Uni<String> store(UUID documentId, long serverSeq, Engine engine, long collectSeq, long collectTimeMs) {
        Encoded encoded = encode(documentId, serverSeq, engine);
        return put(encoded)
                .chain(() -> pool.preparedQuery(INSERT).execute(Tuple.from(new Object[] {documentId, serverSeq,
                        encoded.key(), encoded.stateHash(), (long) encoded.object().length, encoded.uncompressedSize(),
                        encoded.nodeCount(), collectSeq, collectTimeMs})))
                .replaceWith(encoded.stateHash());
    }

    /** A snapshot ready to store: its key, zstd object, state hash (hex), decompressed size and node count. */
    public record Encoded(String key, byte[] object, String stateHash, long uncompressedSize, int nodeCount) {

        @Override
        public boolean equals(Object other) {
            return other instanceof Encoded(var thatKey, var thatObject, var thatStateHash, var thatUncompressedSize,
                    var thatNodeCount)
                    && Objects.equals(key, thatKey)
                    && Arrays.equals(object, thatObject)
                    && Objects.equals(stateHash, thatStateHash)
                    && uncompressedSize == thatUncompressedSize
                    && nodeCount == thatNodeCount;
        }

        @Override
        public int hashCode() {
            return Objects.hash(key, Arrays.hashCode(object), stateHash, uncompressedSize, nodeCount);
        }

        /** {@inheritDoc} Byte arrays show as their length only (they can be large or secret). */
        @Override
        public String toString() {
            return "Encoded[key=" + key
                    + ", object=" + object.length + " bytes"
                    + ", stateHash=" + stateHash
                    + ", uncompressedSize=" + uncompressedSize
                    + ", nodeCount=" + nodeCount + "]";
        }
    }

    /** {@code engine}'s snapshot at {@code serverSeq} as the document's. */
    public static Encoded encode(UUID documentId, long serverSeq, Engine engine) {
        byte[] snapshot = Snapshot.encode(engine, serverSeq);
        return new Encoded(key(documentId, serverSeq), Zstd.compress(snapshot),
                HexFormat.of().formatHex(Snapshot.stateHash(snapshot)), snapshot.length, engine.store().nodes().size());
    }

    /** Stores the object of an encoded snapshot. */
    public Uni<Void> put(Encoded encoded) {
        return store.put(encoded.key(), encoded.object(), SegmentCodec.MEDIA_TYPE);
    }
}
