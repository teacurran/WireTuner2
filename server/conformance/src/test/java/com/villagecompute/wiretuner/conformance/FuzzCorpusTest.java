package com.villagecompute.wiretuner.conformance;

import static org.assertj.core.api.Assertions.assertThat;

import com.villagecompute.wiretuner.conformance.v1.Replica;
import com.villagecompute.wiretuner.conformance.v1.Vector;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/**
 * The Java half of the cross-engine fuzzer (CRDT-012; docs/spec/testing.adoc, "Fuzzing"): replays
 * the corpus WTCRDTTests' FuzzTests wrote to {@code WT_FUZZ_CORPUS} through wt-crdt and fails on
 * any vector whose deliveries disagree or do not reach the hashes WTCRDT recorded. The failing
 * files are listed in {@code <corpus>-java-failures.txt} for {@code make -C crdt-conformance
 * fuzz-minimize}. Without {@code WT_FUZZ_CORPUS} the test is skipped.
 */
class FuzzCorpusTest {

    @Test
    void wtCrdtReachesTheHashesWtcrdtRecorded() throws IOException {
        String corpus = System.getenv("WT_FUZZ_CORPUS");
        Assumptions.assumeTrue(corpus != null && !corpus.isEmpty(), "WT_FUZZ_CORPUS names no corpus");
        Path root = Path.of(corpus);
        long started = System.nanoTime();
        List<Path> files = ConformanceRunner.vectors(root);
        List<String> failed = new ArrayList<>();
        List<String> reports = new ArrayList<>();
        long ops = 0;
        for (Path file : files) {
            Vector vector = ConformanceRunner.load(file);
            for (Replica replica : vector.getReplicaList()) {
                ops += replica.getChangeList().stream().mapToLong(change -> change.getOpsCount()).sum();
            }
            ConformanceRunner.Outcome outcome = ConformanceRunner.run(vector, ConformanceRunner.expectedName(root, file));
            if (!outcome.passed()) {
                failed.add(file.toAbsolutePath().toString());
                reports.add(outcome.report());
            }
        }
        Files.write(Path.of(root.toAbsolutePath() + "-java-failures.txt"), failed);
        System.out.printf("Fuzz (wt-crdt): %d ops in %d vectors, %.1f s%n", ops, files.size(), (System.nanoTime() - started) / 1e9);
        assertThat(files).isNotEmpty();
        assertThat(failed).as(String.join("\n", reports)).isEmpty();
    }
}
