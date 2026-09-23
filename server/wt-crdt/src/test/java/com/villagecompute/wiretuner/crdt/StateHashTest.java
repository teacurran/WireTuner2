package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

/**
 * The canonical encoding, pinned byte for byte. WTCRDTTests' StateHashTests pins the same
 * bytes and hashes in Swift.
 */
class StateHashTest {

    static NodeStore sample() {
        NodeStore store = new NodeStore();
        store.create(new OpId(1, 7), 150);
        store.write(new OpId(1, 7), RegisterPath.of(150, 1, 1), new byte[] {0x0A, 0x01, 0x41}, new OpId(2, 1));
        store.write(new OpId(1, 7), RegisterPath.of(150, 1, 3), null, new OpId(3, 2));
        return store;
    }

    @Test
    void emptyStateHashesFourZeroBytes() {
        assertThat(StateHash.hex(StateHash.of(new NodeStore())))
                .isEqualTo("df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119");
    }

    @Test
    void encodesNodesAsSpecified() {
        String expected = "0000000000000001" + "0000000000000007" + "00000096" + "00000002"
                + "0000000f" + "0100000096" + "0100000001" + "0100000001"
                + "0000000000000002" + "0000000000000001" + "01" + "00000003" + "0a0141"
                + "0000000f" + "0100000096" + "0100000001" + "0100000003"
                + "0000000000000003" + "0000000000000002" + "00";
        assertThat(StateHash.hex(StateHash.encodeNode(sample(), new OpId(1, 7)))).isEqualTo(expected);
    }

    @Test
    void pinnedHashesMatchTheSwiftEngine() {
        assertThat(StateHash.hex(StateHash.of(sample())))
                .isEqualTo("0ef585c6ddbe9bc2235886fcf76521e4eac3699731d6b334e075dd1cf7811544");
        assertThat(StateHash.hex(StateHash.ofNode(sample(), new OpId(1, 7))))
                .isEqualTo("c724b8cc2df751dd6d8ace2ac01c75e059202821ee67a943ebe85c5c711abc8a");
    }

    @Test
    void anUnavailableAlgorithmIsAnError() {
        assertThatThrownBy(() -> StateHash.digest("no-such-digest")).isInstanceOf(IllegalStateException.class);
    }
}
