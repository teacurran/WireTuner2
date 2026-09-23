// swift-tools-version: 6.0
// WTCRDT: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTCRDT",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTCRDT", targets: ["WTCRDT"]),
        .library(name: "WTCRDTSchema", targets: ["WTCRDTSchema"]),
    ],
    dependencies: [
        .package(path: "../WTProto"),
        // The conformance runner's vector messages (Tests/WTCRDTTests/Conformance/Generated) are
        // swift-protobuf code; same version line as WTProto.
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
    ],
    targets: [
        .target(
            name: "WTCRDTSchema",
            dependencies: [
                .product(name: "WTProto", package: "WTProto"),
            ],
            // Generated/ is written by protoc-gen-wtcrdt (tools/protoc-gen-wtcrdt, PROTO-005):
            // the JSON table is the same document Welcome.merge_table carries; SkippedRules.md
            // is for reviewers.
            exclude: ["Generated/SkippedRules.md"],
            resources: [.copy("Generated/MergeTable.json")]
        ),
        // zstd 1.5.7 (BSD, Meta), vendored as the upstream single-file library
        // (build/single_file_libs/combine.py over lib/, without dictBuilder and multithreading):
        // snapshots are zstd-compressed (docs/spec/crdt-model.adoc, "Snapshots") and
        // Compression.framework has no zstd.  Third-party code: built without coverage
        // instrumentation so it stays out of the region gate.
        .target(
            name: "CZstd",
            exclude: ["LICENSE"],
            cSettings: [
                .unsafeFlags(["-w", "-fno-profile-instr-generate", "-fno-coverage-mapping"]),
            ]
        ),
        .target(
            name: "WTCRDT",
            dependencies: [
                .product(name: "WTProto", package: "WTProto"),
                "WTCRDTSchema",
                "CZstd",
            ]
        ),
        .testTarget(
            name: "WTCRDTTests",
            dependencies: [
                "WTCRDT",
                "WTCRDTSchema",
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
