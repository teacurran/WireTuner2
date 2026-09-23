package com.villagecompute.wiretuner.conformance;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;

/**
 * Replays every vector under crdt-conformance/vectors through wt-crdt (CRDT-011). The Swift
 * twin is WTCRDTTests' ConformanceTests; both check the same committed hashes, which is what
 * proves the engines agree.
 */
class ConformanceTest {

    static Path vectorsRoot() {
        String configured = System.getProperty("crdt.conformance.vectors");
        return configured != null ? Path.of(configured) : Path.of("..", "..").resolve(ConformanceRunner.VECTORS_DIR);
    }

    @Test
    void theVectorDirectoryHoldsVectors() throws IOException {
        assertThat(ConformanceRunner.vectors(vectorsRoot())).isNotEmpty();
    }

    @TestFactory
    Stream<DynamicTest> everyVectorConverges() throws IOException {
        Path root = vectorsRoot();
        List<Path> files = ConformanceRunner.vectors(root);
        return files.stream().map(file -> DynamicTest.dynamicTest(ConformanceRunner.expectedName(root, file), () -> {
            ConformanceRunner.Outcome outcome = ConformanceRunner.run(root, file);
            assertThat(outcome.passed()).as(outcome::report).isTrue();
        }));
    }
}
