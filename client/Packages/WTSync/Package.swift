// swift-tools-version: 6.0
// WTSync: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTSync",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTSync", targets: ["WTSync"]),
    ],
    dependencies: [
        .package(path: "../WTModel"),
        .package(path: "../WTCRDT"),
        .package(path: "../WTProto"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "WTSync",
            dependencies: [
                .product(name: "WTModel", package: "WTModel"),
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTCRDTSchema", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WTSyncTests",
            dependencies: [
                "WTSync",
                .product(name: "WTModel", package: "WTModel"),
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
