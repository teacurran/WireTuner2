package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

class NodeStoreTest {

    @Test
    void wellKnownNodesExistWithoutBeingCreated() {
        NodeStore store = new NodeStore();
        assertThat(store.exists(OpId.wellKnown(15))).isTrue();
        assertThat(store.exists(OpId.wellKnown(16))).isFalse();
        assertThat(store.exists(new OpId(3, 1))).isFalse();
        assertThat(store.kind(OpId.ZERO)).isEqualTo(1);
        assertThat(store.kind(OpId.wellKnown(1))).isEqualTo(2);
        assertThat(store.kind(OpId.wellKnown(4))).isZero();
        assertThat(store.create(OpId.wellKnown(2), 3)).isFalse();
        assertThat(store.create(new OpId(3, 1), 150)).isTrue();
        assertThat(store.create(new OpId(3, 1), 50)).isFalse();
        assertThat(store.kind(new OpId(3, 1))).isEqualTo(150);
    }

    @Test
    void readsOfUnwrittenRegistersAreEmpty() {
        NodeStore store = new NodeStore();
        RegisterPath path = RegisterPath.of(1, 1, 1);
        assertThat(store.register(OpId.ZERO, path)).isNull();
        assertThat(store.registers(OpId.ZERO)).isEmpty();
        assertThat(store.writes(OpId.ZERO, path)).isEmpty();
        assertThat(store.losingWrites(OpId.ZERO, path)).isEmpty();

        assertThat(store.write(OpId.ZERO, path, null, new OpId(2, 1))).isTrue();
        assertThat(store.write(OpId.ZERO, path, new byte[] {1}, new OpId(1, 1))).isFalse();
        assertThat(store.writes(OpId.ZERO, RegisterPath.of(1, 1, 2))).isEmpty();
        assertThat(store.register(new OpId(5, 5), path)).isNull();
        assertThatThrownBy(() -> store.registers(OpId.ZERO).clear()).isInstanceOf(UnsupportedOperationException.class);
        assertThat(store.nodes()).containsExactly(OpId.ZERO);
    }
}
