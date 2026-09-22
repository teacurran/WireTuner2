package com.villagecompute.wiretuner.conformance;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

/**
 * Locates the conformance vectors ({@code crdt-conformance/vectors/**.textproto}) that the
 * runner replays through {@code wt-crdt}. Replay itself arrives with the engine (CRDT track);
 * this skeleton only knows where the vectors live and which files count as one.
 */
public final class ConformanceRunner {

    /** The vector directory relative to the repository root. */
    public static final Path VECTORS_DIR = Path.of("crdt-conformance", "vectors");

    private static final String VECTOR_SUFFIX = ".textproto";

    private ConformanceRunner() {
    }

    /**
     * Every vector file under {@code root}, sorted by path. A missing directory yields no
     * vectors rather than an error, so the module builds before the vectors exist.
     *
     * @throws IOException if the directory cannot be walked
     */
    public static List<Path> vectors(Path root) throws IOException {
        if (!Files.isDirectory(root)) {
            return List.of();
        }
        try (Stream<Path> files = Files.walk(root)) {
            return files.filter(ConformanceRunner::isVector).sorted().toList();
        }
    }

    static boolean isVector(Path path) {
        return Files.isRegularFile(path) && path.getFileName().toString().endsWith(VECTOR_SUFFIX);
    }
}
