package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class RegisterTest {

    @Test
    void registersCompareByValueAndOp() {
        Register set = new Register(new byte[] {8, 1}, new OpId(2, 1));
        Register unset = new Register(null, new OpId(2, 1));

        assertThat(set).isEqualTo(new Register(new byte[] {8, 1}, new OpId(2, 1)))
                .hasSameHashCodeAs(new Register(new byte[] {8, 1}, new OpId(2, 1)))
                .isNotEqualTo(unset)
                .isNotEqualTo(new Register(new byte[] {8, 1}, new OpId(2, 2)))
                .isNotEqualTo("x")
                .hasToString("0801@2:1");
        assertThat(set.isSet()).isTrue();
        assertThat(unset.isSet()).isFalse();
        assertThat(unset.value()).isNull();
        assertThat(unset).hasToString("unset@2:1");
        byte[] copy = set.value();
        copy[0] = 0;
        assertThat(set.value()).containsExactly(8, 1);
    }

    @Test
    void writesCompareByEveryComponent() {
        RegisterPath path = RegisterPath.of(150, 1, 1);
        Write write = new Write(new OpId(1, 7), path, new byte[] {1}, new OpId(3, 2));

        assertThat(write).isEqualTo(new Write(new OpId(1, 7), path, new byte[] {1}, new OpId(3, 2)))
                .hasSameHashCodeAs(new Write(new OpId(1, 7), path, new byte[] {1}, new OpId(3, 2)))
                .isNotEqualTo(new Write(new OpId(1, 8), path, new byte[] {1}, new OpId(3, 2)))
                .isNotEqualTo(new Write(new OpId(1, 7), RegisterPath.of(150), new byte[] {1}, new OpId(3, 2)))
                .isNotEqualTo(new Write(new OpId(1, 7), path, null, new OpId(3, 2)))
                .isNotEqualTo(new Write(new OpId(1, 7), path, new byte[] {1}, new OpId(3, 3)))
                .isNotEqualTo("x")
                .hasToString("1:7/150.1.1=01@3:2");
        assertThat(new Write(new OpId(1, 7), path, null, new OpId(3, 2))).hasToString("1:7/150.1.1=unset@3:2");
        assertThat(new Write(new OpId(1, 7), path, null, new OpId(3, 2)).value()).isNull();
        assertThat(write.value()).containsExactly(1);
    }
}
