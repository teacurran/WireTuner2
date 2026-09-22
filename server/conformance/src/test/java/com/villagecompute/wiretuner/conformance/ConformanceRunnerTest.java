package com.villagecompute.wiretuner.conformance;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ConformanceRunnerTest {

    @Test
    void missingDirectoryYieldsNoVectors() throws IOException {
        assertThat(ConformanceRunner.vectors(Path.of("does", "not", "exist"))).isEmpty();
    }

    @Test
    void listsTextprotoFilesRecursivelyInPathOrder(@TempDir Path root) throws IOException {
        Path nested = Files.createDirectories(root.resolve("text"));
        Path b = Files.writeString(nested.resolve("b_insert.textproto"), "");
        Path a = Files.writeString(root.resolve("a_move.textproto"), "");
        Files.writeString(root.resolve("README.adoc"), "not a vector");

        assertThat(ConformanceRunner.vectors(root)).containsExactly(a, b);
    }

    @Test
    void onlyRegularTextprotoFilesAreVectors(@TempDir Path root) throws IOException {
        Path dirWithSuffix = Files.createDirectories(root.resolve("folder.textproto"));
        Path vector = Files.writeString(root.resolve("v.textproto"), "");

        assertThat(ConformanceRunner.isVector(dirWithSuffix)).isFalse();
        assertThat(ConformanceRunner.isVector(vector)).isTrue();
        assertThat(ConformanceRunner.VECTORS_DIR).hasFileName("vectors");
    }
}
