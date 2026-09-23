package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class FractionalIndexTest {

    private static byte[] b(int... bytes) {
        byte[] out = new byte[bytes.length];
        for (int i = 0; i < bytes.length; i++) {
            out[i] = (byte) bytes[i];
        }
        return out;
    }

    @Test
    void splitMixMatchesTheReferenceSequence() {
        SplitMix64 random = new SplitMix64(0);
        assertThat(random.nextLong()).isEqualTo(0xE220A8397B1DCDAFL);
        assertThat(random.nextLong()).isEqualTo(0x6E789E6AA1B965F4L);
    }

    @Test
    void bodiesFollowTheDigitRules() {
        long suffix = 0x0102L;   // suffix bytes 02, 1 + 1 % 255 = 02
        assertThat(FractionalIndex.between(null, null, suffix)).containsExactly(b(0x80, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0x80, 0x10), null, suffix)).containsExactly(b(0x81, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0xFF, 0xFF, 0x05), null, suffix)).containsExactly(b(0xFF, 0xFF, 0x06, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0xFF, 0xFF), null, suffix)).containsExactly(b(0xFF, 0xFF, 0x01, 0x02, 0x02));
        assertThat(FractionalIndex.between(null, b(0x80), suffix)).containsExactly(b(0x7F, 0x02, 0x02));
        assertThat(FractionalIndex.between(null, b(0x01, 0x80), suffix)).containsExactly(b(0x00, 0xFF, 0x02, 0x02));
        assertThat(FractionalIndex.between(null, b(0x00, 0x00, 0x05), suffix)).containsExactly(b(0x00, 0x00, 0x04, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0x10), b(0x20), suffix)).containsExactly(b(0x18, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0x10, 0x05), b(0x11), suffix)).containsExactly(b(0x10, 0x06, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0x10), b(0x11), suffix)).containsExactly(b(0x10, 0x01, 0x02, 0x02));
        assertThat(FractionalIndex.between(b(0x05), b(0x05, 0x00, 0x03), suffix)).containsExactly(b(0x05, 0x00, 0x01, 0x02, 0x02));
        assertThat(FractionalIndex.between(null, null, -1L)).containsExactly(b(0x80, 0xFF, 1 + (int) Long.remainderUnsigned(-1L >>> 8, 255)));
    }

    @Test
    void generatedKeysSortStrictlyBetweenTheirNeighbours() {
        SplitMix64 random = new SplitMix64(7);
        List<byte[]> keys = new ArrayList<>();
        keys.add(FractionalIndex.between(null, null, random));
        for (int i = 0; i < 2_000; i++) {
            int at = random.nextInt(keys.size() + 1);
            byte[] lo = at == 0 ? null : keys.get(at - 1);
            byte[] hi = at == keys.size() ? null : keys.get(at);
            byte[] key = FractionalIndex.between(lo, hi, random);
            assertThat(lo == null || FractionalIndex.less(lo, key)).isTrue();
            assertThat(hi == null || FractionalIndex.less(key, hi)).isTrue();
            assertThat(key[key.length - 1]).isNotZero();
            keys.add(at, key);
        }
    }

    @Test
    void aThousandSequentialAppendsStayUnderFortyBytes() {
        SplitMix64 random = new SplitMix64(1);
        byte[] last = null;
        int longest = 0;
        for (int i = 0; i < 1_000; i++) {
            last = FractionalIndex.between(last, null, random);
            longest = Math.max(longest, last.length);
        }
        assertThat(longest).isLessThan(40);
        SplitMix64 prepend = new SplitMix64(1);
        byte[] first = null;
        for (int i = 0; i < 1_000; i++) {
            first = FractionalIndex.between(null, first, prepend);
        }
        assertThat(first.length).isLessThan(40);
    }

    @Test
    void rejectsKeysNotGeneratedOrOutOfOrder() {
        assertThatThrownBy(() -> FractionalIndex.between(new byte[0], null, 0)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> FractionalIndex.between(null, b(0x10, 0x00), 0)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> FractionalIndex.between(b(0x20), b(0x10), 0)).hasMessageContaining("does not sort before");
        assertThatThrownBy(() -> FractionalIndex.between(b(0x20), b(0x20), 0)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void childOrderIsPositionThenId() {
        assertThat(FractionalIndex.childOrder(b(0x80), new OpId(9, 9), b(0x81), new OpId(1, 1))).isNegative();
        assertThat(FractionalIndex.childOrder(b(0x80), new OpId(2, 1), b(0x80), new OpId(1, 2))).isPositive();
        assertThat(FractionalIndex.childOrder(b(0x80), new OpId(1, 1), b(0x80, 0x01), new OpId(0, 0))).isNegative();
    }
}
