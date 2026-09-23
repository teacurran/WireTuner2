package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

class LamportClockTest {

    @Test
    void nextIsOneMoreThanTheLargestCreatedOrSeen() {
        LamportClock clock = new LamportClock();
        assertThat(clock.peek()).isEqualTo(1);
        assertThat(clock.allocate(3)).isEqualTo(1);   // created 1, 2, 3
        assertThat(clock.max()).isEqualTo(3);
        clock.observe(10);                              // seen 10
        clock.observe(4);                               // smaller: no effect
        assertThat(clock.peek()).isEqualTo(11);
        assertThat(clock.allocate(1)).isEqualTo(11);
    }

    @Test
    void comparesCountersUnsigned() {
        LamportClock clock = new LamportClock(5);
        clock.observe(-2);                              // 2^64-2 is larger than 5
        assertThat(clock.max()).isEqualTo(-2);
        clock.observe(7);
        assertThat(clock.max()).isEqualTo(-2);
    }

    @Test
    void aChangeHasAtLeastOneOp() {
        assertThatThrownBy(() -> new LamportClock().allocate(0)).isInstanceOf(IllegalArgumentException.class);
    }
}
