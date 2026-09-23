package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import org.junit.jupiter.api.Test;

/** The WireMessage reads snapshots and marks use, and the WireWriter defaults. */
class WireReadTest {

    @Test
    void payloadsSkipRecordsOfOtherWireTypes() {
        WireMessage message = WireMessage.parse(Wire.message().varint(1, 5).string(1, "a").varint(2, 7).build());
        assertThat(message.payloads(1)).singleElement().isEqualTo(new byte[] {0x61});
        assertThat(message.lastPayload(1)).containsExactly(0x61);
        assertThat(message.lastPayload(2)).isNull();
        assertThat(message.occurrences(1)).hasSize(1);
        assertThat(message.lastVarint(1)).isEqualTo(5);
        assertThat(message.lastField()).isEqualTo(2);
        assertThat(message.lastWireType()).isEqualTo(WireMessage.VARINT);
        assertThat(message.lastRecordPayload()).containsExactly(7);
        WireMessage empty = WireMessage.parse(new byte[0]);
        assertThat(empty.lastField()).isNull();
        assertThat(empty.lastWireType()).isNull();
        assertThat(empty.lastRecordPayload()).isNull();
    }

    @Test
    void setMembersOfBytesAndUntypedMessages() {
        WireMessage message = WireMessage.parse(Wire.message().bytes(3, new byte[] {1, 2}).build());
        assertThat(message.members(3, "bytes", null)).singleElement().isEqualTo(new byte[] {1, 2});
        assertThat(message.members(3, "message", null)).isNull();
    }

    @Test
    void writerLeavesDefaultsOut() {
        WireWriter out = new WireWriter();
        out.bytesField(1, new byte[0]);
        out.varintField(2, 0);
        out.fixed64Field(3, 0);
        out.optionalIdField(4, OpId.ZERO);
        assertThat(out.bytes()).isEmpty();
        out.bytesField(1, new byte[] {9});
        out.varintField(2, -1L);
        assertThat(out.bytes()).hasSize(3 + 11);
        assertThat(WireWriter.path(RegisterPath.of(List.of(RegisterPath.Segment.field(1), RegisterPath.Segment.element(new OpId(1, 1))))))
                .containsExactly(0x0A, 0x02, 0x08, 0x01, 0x0A, 0x0D, 0x12, 0x0B, 0x08, 0x01, 0x11, 1, 0, 0, 0, 0, 0, 0, 0);
    }

    @Test
    void snapshotsWithoutAHashDecodeAndGarbageHasNone() throws Snapshot.SnapshotException {
        assertThat(Snapshot.decode(new byte[0], Scenario.SCHEMA).stateHash()).isEqualTo(new Engine().stateHash());
        assertThat(Snapshot.stateHash(new byte[] {(byte) 0xFF})).isNull();
        assertThat(Snapshot.stateHash(new byte[0])).isNull();
    }
}
