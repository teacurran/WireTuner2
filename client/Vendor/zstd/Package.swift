// swift-tools-version: 6.0
// zstd 1.5.7 (Meta; BSD licence, LICENSE), the upstream single-file library built from source:
// `Sources/CZstd/zstd.c` is upstream's build/single_file_libs/combine.py over lib/ without
// dictBuilder and multithreading, `include/` upstream's lib/zstd.h and lib/zstd_errors.h.  All of
// it is written by tools/zstd/vendor.sh from the pinned release tarball -- never edit it by hand.
// One copy for the whole client (docs/spec/decisions.adoc D-098): WTCRDT compresses and
// decompresses snapshots with it (crdt-model.adoc, "Snapshots"), WTInterchange decompresses
// Illustrator 2020 and later's private data (import-formats.adoc, "Adobe Illustrator");
// Compression.framework has no zstd.  Third-party code: it lives outside client/Packages so the
// coverage gate and SonarQube do not measure it, and it is built without coverage
// instrumentation.  Platform-neutral C: it builds for macOS and iOS (D-073).
import PackageDescription

let package = Package(
    name: "zstd",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "CZstd", targets: ["CZstd"]),
    ],
    targets: [
        .target(
            name: "CZstd",
            exclude: ["LICENSE"],
            cSettings: [
                .unsafeFlags(["-w", "-fno-profile-instr-generate", "-fno-coverage-mapping"]),
            ]
        ),
    ]
)
