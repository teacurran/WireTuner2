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
            ]
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
            dependencies: ["WTCRDT"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
