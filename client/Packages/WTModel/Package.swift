// swift-tools-version: 6.0
// WTModel: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table,
// except that WTModel builds WTRender's display list and change summaries, so it depends on WTRender
// (and WTGeometry below it); neither of those imports WTModel (client.adoc, "Packages", deviation).
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
        .package(path: "../WTGeometry"),
        .package(path: "../WTRender"),
    ],
    targets: [
        .target(
            name: "WTModel",
            dependencies: [
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTRender", package: "WTRender"),
            ]
        ),
        .testTarget(
            name: "WTModelTests",
            dependencies: [
                "WTModel",
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTRender", package: "WTRender"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
