package com.villagecompute.wiretuner.api.grpc;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;

/** Outside a Vert.x context the caller's executor runs the task where it is. */
class CallerContextTest {

    @Test
    void withoutAContextTasksRunInline() {
        AtomicReference<Thread> ran = new AtomicReference<>();
        CallerContext.executor().execute(() -> ran.set(Thread.currentThread()));
        assertThat(ran.get()).isSameAs(Thread.currentThread());
    }
}
