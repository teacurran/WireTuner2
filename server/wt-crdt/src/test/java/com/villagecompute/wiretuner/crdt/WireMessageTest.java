package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Set;
import org.junit.jupiter.api.Test;

class WireMessageTest {

    @Test
    void readsEveryWireType() {
        byte[] bytes = Wire.message()
                .varint(1, 150)
                .fixed64(2, 7)
                .string(3, "hi")
                .fixed32(4, 9)
                .varint(1, -1)
                .build();
        WireMessage message = WireMessage.parse(bytes);

        assertThat(message).isNotNull();
        assertThat(message.has(3)).isTrue();
        assertThat(message.has(5)).isFalse();
        assertThat(message.records(1)).isEqualTo(Wire.message().varint(1, 150).varint(1, -1).build());
        assertThat(message.records(4)).isEqualTo(Wire.message().fixed32(4, 9).build());
        assertThat(message.records(5)).isNull();
        assertThat(message.lastMessageOf(Set.of(1, 2, 3, 4))).isEqualTo(3);
        assertThat(message.lastMessageOf(Set.of(9))).isZero();
    }

    @Test
    void embeddedMessagesMergeAcrossOccurrencesAndIgnoreOtherWireTypes() {
        byte[] bytes = Wire.message()
                .message(1, Wire.message().varint(1, 1))
                .varint(1, 5)
                .message(1, Wire.message().varint(2, 2))
                .build();
        WireMessage inner = WireMessage.parse(bytes).message(1);

        assertThat(inner.records(1)).isEqualTo(Wire.message().varint(1, 1).build());
        assertThat(inner.records(2)).isEqualTo(Wire.message().varint(2, 2).build());
        assertThat(WireMessage.parse(bytes).message(2)).isNull();
        assertThat(WireMessage.parse(Wire.message().bytes(1, new byte[] {0x07}).build()).message(1)).isNull();
    }

    @Test
    void emptyBytesAreAnEmptyMessage() {
        assertThat(WireMessage.parse(new byte[0]).has(1)).isFalse();
    }

    @Test
    void rejectsMalformedBytes() {
        assertThat(WireMessage.parse(Wire.message().rawBytes(0x08, 0x80).build())).as("truncated varint").isNull();
        assertThat(WireMessage.parse(Wire.message().rawBytes(0x80).build())).as("truncated tag").isNull();
        assertThat(WireMessage.parse(Wire.message().rawBytes(0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01).build()))
                .as("eleven-byte varint").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(0, 0).raw(1).build())).as("field 0").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1 << 29, 0).raw(1).build())).as("field 2^29").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 3).build())).as("group").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 6).build())).as("wire type 6").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 2).raw(5).rawBytes(1).build())).as("short LEN").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 2).rawBytes(0x80).build())).as("truncated length").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 2).raw(-1).build())).as("negative length").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 1).rawBytes(1, 2).build())).as("short fixed64").isNull();
        assertThat(WireMessage.parse(Wire.message().tag(1, 5).rawBytes(1).build())).as("short fixed32").isNull();
    }

    @Test
    void acceptsTheLargestFieldNumberAndTenByteVarints() {
        byte[] bytes = Wire.message().varint((1 << 29) - 1, Long.MIN_VALUE).build();
        assertThat(WireMessage.parse(bytes).has((1 << 29) - 1)).isTrue();
    }
}
