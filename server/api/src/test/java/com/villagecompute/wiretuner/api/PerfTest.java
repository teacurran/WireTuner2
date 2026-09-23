package com.villagecompute.wiretuner.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

/**
 * A performance budget (docs/spec/testing.adoc, Performance gates): a test tagged {@code perf}, which
 * the default build excludes and {@code -Pperf} runs, skipped with the measured load when the
 * machine is too busy to measure ({@link LoadGuard}). The correctness a budget test also exercises
 * lives in a default-run test beside it; the budget test records its figure with {@link PerfReport}.
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Test
@Tag(PerfTest.TAG)
@ExtendWith(LoadGuard.class)
public @interface PerfTest {

    /** The JUnit tag, and the surefire group the {@code perf} profile selects. */
    String TAG = "perf";
}
