package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.junit.jupiter.api.Test;

class OpIdTest {

    @Test
    void ordersByCounterThenReplicaUnsigned() {
        OpId huge = new OpId(2, -16);          // replica 2^64-16: above every signed-positive id
        List<OpId> ids = new ArrayList<>(List.of(huge, new OpId(2, 2), new OpId(1, 9), new OpId(-1, 0), new OpId(2, 1)));
        Collections.sort(ids);

        assertThat(ids).containsExactly(new OpId(1, 9), new OpId(2, 1), new OpId(2, 2), huge, new OpId(-1, 0));
        assertThat(new OpId(3, 3)).isEqualByComparingTo(new OpId(3, 3));
    }

    @Test
    void convertsAndPrints() {
        OpId id = new OpId(-1, 7);
        assertThat(OpId.of(id.toProto())).isEqualTo(id);
        assertThat(id).hasToString("18446744073709551615:7");
        assertThat(OpId.wellKnown(4)).isEqualTo(new OpId(4, 0));
        assertThat(OpId.ZERO).isEqualTo(OpId.wellKnown(0));
    }
}
