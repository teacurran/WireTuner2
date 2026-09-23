package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.SnapshotCompression;
import com.villagecompute.wiretuner.doc.v1.SnapshotFrame;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

/** Snapshots (CRDT-009); mirrors WTCRDTTests' SnapshotTests. */
class SnapshotTest {

    static final String N = Scenario.N;
    static final String T = Scenario.T;

    /** Everything a snapshot holds (see WTCRDTTests' SnapshotTests.rich). */
    static Engine rich() {
        Engine engine = InverseTest.base();
        engine.apply(Scenario.change(9, 1, 13, 2, List.of(
                "move { node { counter: 2 replica: 7 } parent { counter: 1 replica: 7 } position: \"\\x80\" }",
                "set_deleted { node { counter: 2 replica: 7 } deleted: true }",
                "set { " + N + " paths { segments { field: 1000 } segments { field: 2 } } }",
                "element_move { " + N + " element { " + InverseTest.STOP3 + " } position: \"\\x90\" }",
                "element_delete { " + N + " elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 4 replica: 7 } } } deleted: true }",
                "set_remove { " + N + " set { segments { field: 1000 } segments { field: 3 } } values { test { tags: \"t\" } } }",
                "set_add { " + N + " set { segments { field: 1000 } segments { field: 3 } } values { test { tags: \"u\" } } }",
                "text_delete { " + N + " " + T + " ranges { first { counter: 8 replica: 7 } count: 1 } }",
                "create { parent { counter: 77 replica: 7 } position: \"\\x80\" props { test { label: \"orphan\" } } }",
                "set { node { counter: 0 } paths { segments { field: 1 } segments { field: 1 } segments { field: 1 } } values { document { common { name: \"Doc\" } } } }",
                "set_deleted { " + N + " }",
                "element_delete { " + N + " elements { " + InverseTest.STOP3 + " } }",
                "element_insert { " + N + " sequence { segments { field: 1000 } segments { field: 8 } } positions: \"\\xA0\" }")),
                3L);
        engine.acknowledge(5, 1, 4);
        return engine;
    }

    @Test
    void roundTripsLosslesslyAndMergesTheSameAfterwards() throws Snapshot.SnapshotException {
        Engine original = rich();
        byte[] bytes = Snapshot.encode(original, 3);
        Engine decoded = Snapshot.decode(bytes, Scenario.SCHEMA);
        assertThat(decoded.stateHash()).isEqualTo(original.stateHash());
        assertThat(Snapshot.encode(decoded, 3)).isEqualTo(bytes);
        assertThat(decoded.clock().max()).isEqualTo(original.clock().max());
        assertThat(decoded.store().moveLog()).usingRecursiveComparison().isEqualTo(original.store().moveLog());
        assertThat(decoded.store().replicas()).isEqualTo(original.store().replicas());
        assertThat(View.of(decoded)).isEqualTo(View.of(original));
        Change late = Scenario.change(4, 1, 12, 3, List.of(
                "move { node { counter: 2 replica: 7 } parent { counter: 4 } position: \"\\x70\" }",
                "set_remove { " + N + " set { segments { field: 1000 } segments { field: 3 } } values { test { tags: \"u\" } } }",
                Scenario.insert("Z", new OpId(8, 7), new OpId(9, 7)),
                Scenario.mark(null, true, null, false, "size: 9"),
                "set { " + N + " paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 7 replica: 7 } }"
                        + " segments { field: 6 } segments { field: 4 } } values { test { text { chars { paragraph { left_indent: 3 } } } } } }"));
        original.apply(late, 5L);
        decoded.apply(late, 5L);
        assertThat(decoded.stateHash()).isEqualTo(original.stateHash());
        assertThat(Snapshot.encode(decoded, 5)).isEqualTo(Snapshot.encode(original, 5));
    }

    @Test
    void anEmptyStateRoundTrips() throws Snapshot.SnapshotException {
        byte[] bytes = Snapshot.encode(new Engine(), 0);
        assertThat(Snapshot.decode(bytes, Schema.generated()).stateHash()).isEqualTo(new Engine().stateHash());
    }

    @Test
    void decodingRejectsWhatIsNotASnapshot() {
        for (byte[] bytes : List.of(new byte[] {(byte) 0xFF}, new byte[] {0x12, 0x05, 0x01}, new byte[] {0x0B}, new byte[] {0x00},
                new byte[] {0x1A, 0x02, 0x0A, (byte) 0x80}, new byte[] {0x12, 0x02, 0x22, 0x00},
                new byte[] {0x12, 0x04, 0x22, 0x02, 0x0A, 0x00}, new byte[] {0x12, 0x04, 0x0A, 0x02, 0x2A, 0x01})) {
            assertThatThrownBy(() -> Snapshot.decode(bytes, Scenario.SCHEMA)).as(Bytes.hex(bytes))
                    .isInstanceOf(Snapshot.SnapshotException.class);
        }
        byte[] tampered = Snapshot.encode(rich(), 3);
        byte[] hash = rich().stateHash();
        for (int index = 0; index + 34 <= tampered.length; index++) {
            if (tampered[index] == 0x42 && tampered[index + 1] == 0x20
                    && Arrays.equals(Arrays.copyOfRange(tampered, index + 2, index + 34), hash)) {
                tampered[index + 2] ^= (byte) 0xFF;
                break;
            }
        }
        assertThatThrownBy(() -> Snapshot.decode(tampered, Scenario.SCHEMA)).hasMessageStartingWith("state_hash");
    }

    @Test
    void framesCarryTheSnapshotInChunks() throws Snapshot.SnapshotException {
        Engine engine = rich();
        List<SnapshotFrame> frames = SnapshotTransfer.frames(engine, 3);
        assertThat(frames).hasSize(2);
        assertThat(frames.get(0).getHeader().getChunkCount()).isEqualTo(1);
        assertThat(frames.get(0).getHeader().getCompression()).isEqualTo(SnapshotCompression.SNAPSHOT_COMPRESSION_ZSTD);
        assertThat(frames.get(0).getHeader().getNodeCount()).isEqualTo(engine.store().nodes().size());
        assertThat(SnapshotTransfer.state(frames, Scenario.SCHEMA).stateHash()).isEqualTo(engine.stateHash());
        byte[] big = new byte[SnapshotTransfer.CHUNK_SIZE * 2 + 5];
        Arrays.fill(big, (byte) 7);
        List<SnapshotFrame> plain = SnapshotTransfer.frames(big, 1, new byte[32], 0,
                SnapshotCompression.SNAPSHOT_COMPRESSION_UNSPECIFIED);
        assertThat(plain).hasSize(4);
        assertThat(plain.get(3).getChunk().size()).isEqualTo(5);
        assertThat(SnapshotTransfer.assemble(plain).snapshot()).isEqualTo(big);
    }

    @Test
    void assemblingChecksTheFramesAgainstTheirHeader() {
        List<SnapshotFrame> frames = SnapshotTransfer.frames(rich(), 3);
        assertThatThrownBy(() -> SnapshotTransfer.state(List.of(), Scenario.SCHEMA)).hasMessage("the first frame is not a header");
        assertThatThrownBy(() -> SnapshotTransfer.state(frames.subList(1, 2), Scenario.SCHEMA))
                .hasMessage("the first frame is not a header");
        List<SnapshotFrame> extra = new ArrayList<>(frames);
        extra.add(frames.get(0));
        assertThatThrownBy(() -> SnapshotTransfer.state(extra, Scenario.SCHEMA))
                .hasMessage("a frame after the header is not a chunk of at most 1 MiB");
        SnapshotFrame oversized = SnapshotFrame.newBuilder().setChunk(ByteString.copyFrom(new byte[SnapshotTransfer.CHUNK_SIZE + 1])).build();
        assertThatThrownBy(() -> SnapshotTransfer.state(List.of(frames.get(0), oversized), Scenario.SCHEMA))
                .hasMessage("a frame after the header is not a chunk of at most 1 MiB");
        assertThatThrownBy(() -> SnapshotTransfer.state(List.of(frames.get(0)), Scenario.SCHEMA)).hasMessageStartingWith("0 chunks of 0 bytes");
        byte[] junk = new byte[frames.get(1).getChunk().size()];
        Arrays.fill(junk, (byte) 0x55);
        assertThatThrownBy(() -> SnapshotTransfer.state(List.of(frames.get(0),
                SnapshotFrame.newBuilder().setChunk(ByteString.copyFrom(junk)).build()), Scenario.SCHEMA)).hasMessageStartingWith("zstd:");
        SnapshotFrame plainHeader = frames.get(0).toBuilder().setHeader(frames.get(0).getHeader().toBuilder()
                .setCompression(SnapshotCompression.SNAPSHOT_COMPRESSION_UNSPECIFIED)).build();
        assertThatThrownBy(() -> SnapshotTransfer.state(List.of(plainHeader, frames.get(1)), Scenario.SCHEMA))
                .hasMessageStartingWith("uncompressed payload of");
        SnapshotFrame wrongHash = frames.get(0).toBuilder().setHeader(frames.get(0).getHeader().toBuilder()
                .setStateHash(ByteString.copyFrom(new byte[32]))).build();
        assertThatThrownBy(() -> SnapshotTransfer.state(List.of(wrongHash, frames.get(1)), Scenario.SCHEMA))
                .hasMessage("the header's state_hash does not match the snapshot");
    }

    @Test
    void zstdRoundTripsAndReportsBadInput() {
        byte[] data = "snapshot snapshot snapshot".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        byte[] compressed = Zstd.compress(data);
        assertThat(Zstd.decompress(compressed, data.length)).isEqualTo(data);
        assertThatThrownBy(() -> Zstd.decompress(compressed, data.length + 1)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> Zstd.decompress(new byte[] {1, 2, 3}, 3)).isInstanceOf(IllegalArgumentException.class);
    }
}
