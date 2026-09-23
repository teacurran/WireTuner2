package com.villagecompute.wiretuner.api;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/**
 * The perf run's figures (docs/spec/testing.adoc, Performance gates): each {@link PerfTest} prints
 * its measure and appends a Markdown table row -- measure, measured value, budget, and whether it
 * was met or why it was skipped -- to {@code wt.perf.report} ({@code target/perf-results.md}), which
 * the CI perf job copies into the job summary. The file is started afresh once per test JVM.
 */
public final class PerfReport {

    static final String HEADER = "| Measure | Measured | Budget | Result |\n|---|---|---|---|\n";

    /** A JVM-wide flag (the tests' classes load twice, once in Quarkus's class loader): the file is started. */
    static final String STARTED = "wt.perf.report.started";

    private PerfReport() {
    }

    /** Records a measured figure against its budget. */
    public static void measured(String measure, String measured, String budget, boolean met) {
        System.out.printf("PERF %s: %s (budget %s) %s%n", measure, measured, budget, met ? "met" : "MISSED");
        append(measure, measured, budget, met ? "met" : "**missed**");
    }

    /** Records a budget test the machine was too loaded to run. */
    public static void skipped(String measure, String reason) {
        System.out.printf("PERF %s: skipped, %s%n", measure, reason);
        append(measure, "-", "-", "skipped: " + reason);
    }

    private static synchronized void append(String measure, String measured, String budget, String result) {
        Path file = Path.of(System.getProperty("wt.perf.report", "target/perf-results.md"));
        String row = "| " + measure + " | " + measured + " | " + budget + " | " + result + " |\n";
        try {
            Files.createDirectories(file.toAbsolutePath().getParent());
            if (System.getProperties().putIfAbsent(STARTED, "true") == null) {
                Files.writeString(file, HEADER + row, StandardCharsets.UTF_8);
            } else {
                Files.writeString(file, row, StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
