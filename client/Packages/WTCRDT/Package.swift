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
        .target(
            name: "WTCRDT",
            dependencies: [
                .product(name: "WTProto", package: "WTProto"),
                "WTCRDTSchema",
            ]
        ),
        .testTarget(
            name: "WTCRDTTests",
            dependencies: ["WTCRDT", "WTCRDTSchema"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
