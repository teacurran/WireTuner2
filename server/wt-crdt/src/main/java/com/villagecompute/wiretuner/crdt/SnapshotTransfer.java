package com.villagecompute.wiretuner.crdt;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.doc.v1.SnapshotCompression;
import com.villagecompute.wiretuner.doc.v1.SnapshotFrame;
import com.villagecompute.wiretuner.doc.v1.SnapshotHeader;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

/**
 * Chunked snapshot transfer (docs/spec/crdt-model.adoc, "Snapshots"; {@code SnapshotFrame} in
 * doc/v1/snapshot.proto): a {@code SnapshotHeader}, then the zstd-compressed
 * {@code DocumentSnapshot} in chunks of at most 1 MiB. Mirrors {@code WTCRDT.SnapshotTransfer}.
 */
public final class SnapshotTransfer {

    /** The largest chunk a frame carries. */
    public static final int CHUNK_SIZE = 1 << 20;

    /** Assembled frames: the header and the {@code DocumentSnapshot} bytes. */
    public record Assembled(SnapshotHeader header, byte[] snapshot) {

        @Override
        public boolean equals(Object other) {
            return other instanceof Assembled(var thatHeader, var thatSnapshot)
                    && Objects.equals(header, thatHeader)
                    && Arrays.equals(snapshot, thatSnapshot);
        }

        @Override
        public int hashCode() {
            return Objects.hash(header, Arrays.hashCode(snapshot));
        }

        /** {@inheritDoc} Byte arrays show as their length only (they can be large or secret). */
        @Override
        public String toString() {
            return "Assembled[header=" + header
                    + ", snapshot=" + snapshot.length + " bytes" + "]";
        }
    }

    private SnapshotTransfer() {
    }

    /** The frames carrying {@code snapshot} (an encoded {@code DocumentSnapshot}). */
    public static List<SnapshotFrame> frames(byte[] snapshot, long serverSeq, byte[] stateHash, int nodeCount,
            SnapshotCompression compression) {
        byte[] payload = compression == SnapshotCompression.SNAPSHOT_COMPRESSION_ZSTD ? Zstd.compress(snapshot) : snapshot;
        List<SnapshotFrame> frames = new ArrayList<>();
        for (int start = 0; start < payload.length; start += CHUNK_SIZE) {
            int end = Math.min(start + CHUNK_SIZE, payload.length);
            frames.add(SnapshotFrame.newBuilder().setChunk(ByteString.copyFrom(payload, start, end - start)).build());
        }
        SnapshotHeader header = SnapshotHeader.newBuilder()
                .setServerSeq(serverSeq)
                .setStateHash(ByteString.copyFrom(stateHash))
                .setCompression(compression)
                .setCompressedSize(payload.length)
                .setUncompressedSize(snapshot.length)
                .setChunkCount(frames.size())
                .setNodeCount(nodeCount)
                .build();
        frames.add(0, SnapshotFrame.newBuilder().setHeader(header).build());
        return frames;
    }

    /** The zstd frames of {@code engine}'s snapshot at {@code serverSeq}. */
    public static List<SnapshotFrame> frames(Engine engine, long serverSeq) {
        byte[] snapshot = Snapshot.encode(engine, serverSeq);
        return frames(snapshot, serverSeq, Snapshot.stateHash(snapshot), engine.store().nodes().size(),
                SnapshotCompression.SNAPSHOT_COMPRESSION_ZSTD);
    }

    /**
     * The {@code DocumentSnapshot} bytes {@code frames} carry, checked against the header's counts
     * and sizes.
     *
     * @throws Snapshot.SnapshotException when the frames do not match their header
     */
    public static Assembled assemble(List<SnapshotFrame> frames) throws Snapshot.SnapshotException {
        if (frames.isEmpty() || !frames.get(0).hasHeader()) {
            throw new Snapshot.SnapshotException("the first frame is not a header");
        }
        SnapshotHeader header = frames.get(0).getHeader();
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        for (SnapshotFrame frame : frames.subList(1, frames.size())) {
            if (frame.getFrameCase() != SnapshotFrame.FrameCase.CHUNK || frame.getChunk().size() > CHUNK_SIZE) {
                throw new Snapshot.SnapshotException("a frame after the header is not a chunk of at most 1 MiB");
            }
            payload.writeBytes(frame.getChunk().toByteArray());
        }
        if (frames.size() - 1 != header.getChunkCount() || payload.size() != header.getCompressedSize()) {
            throw new Snapshot.SnapshotException((frames.size() - 1) + " chunks of " + payload.size()
                    + " bytes, the header says " + header.getChunkCount() + " of " + header.getCompressedSize());
        }
        byte[] snapshot;
        if (header.getCompression() == SnapshotCompression.SNAPSHOT_COMPRESSION_ZSTD) {
            try {
                snapshot = Zstd.decompress(payload.toByteArray(), (int) header.getUncompressedSize());
            } catch (IllegalArgumentException e) {
                throw new Snapshot.SnapshotException(e.getMessage());
            }
        } else {
            if (payload.size() != header.getUncompressedSize()) {
                throw new Snapshot.SnapshotException("uncompressed payload of " + payload.size()
                        + " bytes, the header says " + header.getUncompressedSize());
            }
            snapshot = payload.toByteArray();
        }
        return new Assembled(header, snapshot);
    }

    /**
     * The state {@code frames} carry: {@link #assemble}, a check that the header names the
     * snapshot's {@code state_hash}, then {@link Snapshot#decode}, which checks the decoded state
     * against it.
     *
     * @throws Snapshot.SnapshotException when the frames or the snapshot are inconsistent
     */
    public static Engine state(List<SnapshotFrame> frames, Schema schema) throws Snapshot.SnapshotException {
        Assembled assembled = assemble(frames);
        if (!Arrays.equals(Snapshot.stateHash(assembled.snapshot()), assembled.header().getStateHash().toByteArray())) {
            throw new Snapshot.SnapshotException("the header's state_hash does not match the snapshot");
        }
        return Snapshot.decode(assembled.snapshot(), schema);
    }
}
