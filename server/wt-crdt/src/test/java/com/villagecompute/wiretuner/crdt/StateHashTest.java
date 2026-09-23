package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

/**
 * The canonical encoding, pinned byte for byte. WTCRDTTests' StateHashTests pins the same
 * bytes and hashes in Swift.
 */
class StateHashTest {

    static final OpId NODE = new OpId(1, 7);

    /** A node with a placement, a deleted flag, a register, an element and a set member. */
    static NodeStore sample() {
        NodeStore store = new NodeStore();
        store.create(NODE, 1000);
        store.applyTree(NODE, NODE, OpId.wellKnown(4), new byte[] {(byte) 0x80}, true);
        store.setDeleted(NODE, true, new OpId(5, 1));
        store.write(NODE, RegisterPath.of(1000, 2), new byte[] {0x12, 0x01, 0x41}, new OpId(2, 1));
        RegisterPath stop = RegisterPath.of(1000, 8).element(new OpId(3, 1));
        store.insertElement(NODE, stop, new byte[] {(byte) 0x80}, new OpId(3, 1));
        store.deleteElement(NODE, stop, true, new OpId(4, 1));
        store.addMember(NODE, RegisterPath.of(1000, 3), new byte[] {0x61}, new NodeStore.SetAddition(new OpId(6, 1), 1));
        return store;
    }

    @Test
    void emptyStateHashesFourZeroBytes() {
        assertThat(StateHash.hex(StateHash.of(new NodeStore())))
                .isEqualTo("df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119");
    }

    @Test
    void encodesNodesAsSpecified() {
        String expected = "0000000000000001" + "0000000000000007" + "000003e8"                 // id, kind 1000
                + "01" + "0000000000000004" + "0000000000000000" + "00000001" + "80"           // placed under 0:4 at 80
                + "0000000000000001" + "0000000000000007"                                     //   by 1:7
                + "01" + "01" + "0000000000000005" + "0000000000000001"                       // deleted = true @5:1
                + "00000001"                                                                   // one register
                + "0000000a" + "01000003e8" + "0100000002"                                    //   1000.2
                + "0000000000000002" + "0000000000000001" + "01" + "00000003" + "120141"       //   @2:1 = 12 01 41
                + "00000001"                                                                   // one element
                + "0000001b" + "01000003e8" + "0100000008" + "02" + "0000000000000003" + "0000000000000001"
                + "00000001" + "80" + "0000000000000003" + "0000000000000001"                 //   at 80 @3:1
                + "01" + "01" + "0000000000000004" + "0000000000000001"                       //   deleted @4:1
                + "00000001"                                                                   // one set
                + "0000000a" + "01000003e8" + "0100000003"                                    //   1000.3
                + "00000001" + "00000001" + "61"                                               //   member "a"
                + "00000001" + "0000000000000006" + "0000000000000001";                       //   tag 6:1
        assertThat(StateHash.hex(StateHash.encodeNode(sample(), NODE))).isEqualTo(expected);
    }

    @Test
    void pinnedHashesMatchTheSwiftEngine() {
        assertThat(StateHash.hex(StateHash.of(sample()))).isEqualTo("fa626e18065a8a8bf711f66463d4aad23da553c67909eb15af84f9aa60137674");
        assertThat(StateHash.hex(StateHash.ofNode(sample(), NODE))).isEqualTo("7297a45276ef41d03f6356188e303a3fed4178d6bf0dba2930f6d6da2a9c71fc");
    }

    @Test
    void anUnavailableAlgorithmIsAnError() {
        assertThatThrownBy(() -> StateHash.digest("no-such-digest")).isInstanceOf(IllegalStateException.class);
    }
}
