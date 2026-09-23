package com.villagecompute.wiretuner.conformance;

import com.villagecompute.wiretuner.conformance.v1.Vector;
import java.io.IOException;
import java.nio.file.Path;

/**
 * The fuzzer's Java oracle (CRDT-012): replays each vector file named on the command line through
 * wt-crdt against the hashes WTCRDT recorded in it, prints every failure, and exits 1 if any
 * vector failed. WTCRDTTests' FuzzTests calls it once per candidate while it minimises a vector
 * the engines disagree on ({@code make -C crdt-conformance fuzz-minimize}).
 */
public final class FuzzOracle {

    private FuzzOracle() {
    }

    public static void main(String[] args) throws IOException {
        int failed = 0;
        for (String arg : args) {
            Vector vector = ConformanceRunner.load(Path.of(arg));
            ConformanceRunner.Outcome outcome = ConformanceRunner.run(vector, vector.getName());
            if (!outcome.passed()) {
                System.out.println(outcome.report());
                failed++;
            }
        }
        System.exit(failed == 0 ? 0 : 1);
    }
}
