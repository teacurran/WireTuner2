package com.villagecompute.wiretuner.crdt;

import java.lang.management.ManagementFactory;
import java.util.Locale;

import org.junit.jupiter.api.extension.ConditionEvaluationResult;
import org.junit.jupiter.api.extension.ExecutionCondition;
import org.junit.jupiter.api.extension.ExtensionContext;

/**
 * Skips a {@link PerfTest} on a machine too loaded to measure: when the one-minute load average
 * ({@code getloadavg(3)}, through the OS MXBean) exceeds the cores times {@code wt.perf.load-factor}
 * (1.5), the test is reported skipped with the measured load -- "load 97.2 over 18.0 (12 cores x
 * 1.5)" -- and the skip is written to the {@link PerfReport}, rather than failing a budget the machine
 * could not have met. {@code -Dwt.perf.load-factor=0} disables the guard (for example, to see the
 * figures anyway).  The api module's tests carry the same guard.
 */
public final class LoadGuard implements ExecutionCondition {

    static final double DEFAULT_FACTOR = 1.5;

    @Override
    public ConditionEvaluationResult evaluateExecutionCondition(ExtensionContext context) {
        if (context.getTestMethod().isEmpty()) {
            return ConditionEvaluationResult.enabled("load is checked per test");
        }
        double factor = Double.parseDouble(System.getProperty("wt.perf.load-factor", Double.toString(DEFAULT_FACTOR)));
        int cores = Runtime.getRuntime().availableProcessors();
        double load = ManagementFactory.getOperatingSystemMXBean().getSystemLoadAverage();
        String measure = context.getRequiredTestClass().getSimpleName() + "." + context.getRequiredTestMethod().getName();
        String reason = reason(load, cores, factor);
        if (reason != null) {
            PerfReport.skipped(measure, reason);
            return ConditionEvaluationResult.disabled(reason);
        }
        return ConditionEvaluationResult.enabled(String.format(Locale.ROOT, "load %.1f", load));
    }

    /** Why a machine with this load is too busy to measure on, or null when it is not (or the guard is off). */
    static String reason(double load, int cores, double factor) {
        double limit = cores * factor;
        if (factor <= 0 || load < 0 || load <= limit) {
            return null;
        }
        return String.format(Locale.ROOT, "load %.1f over %.1f (%d cores x %s)", load, limit, cores, factor);
    }
}
