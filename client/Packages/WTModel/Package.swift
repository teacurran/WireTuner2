// swift-tools-version: 6.0
// WTModel: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTModel",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTModel", targets: ["WTModel"]),
    ],
    dependencies: [
        .package(path: "../WTCRDT"),
        .package(path: "../WTProto"),
    ],
    targets: [
        .target(
            name: "WTModel",
            dependencies: [
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
            ]
        ),
        .testTarget(
            name: "WTModelTests",
            dependencies: [
                "WTModel",
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
