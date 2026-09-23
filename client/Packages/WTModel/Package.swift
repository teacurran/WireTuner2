// swift-tools-version: 6.0
// WTModel: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table,
// except that WTModel builds WTRender's display list and change summaries, so it depends on WTRender
// (and WTGeometry below it); neither of those imports WTModel (client.adoc, "Packages", deviation).
// It also turns WTInterchange's neutral `ImportedScene` into ops and packs and unpacks `.wiretuner`
// packages, so it depends on WTInterchange, which imports nothing above WTRender and WTProto
// (import-formats.adoc, "Imported scene to document"; saving.adoc, "Client").
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
        .package(path: "../WTInterchange"),
    ],
    targets: [
        .target(
            name: "WTModel",
            dependencies: [
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTInterchange", package: "WTInterchange"),
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
                .product(name: "WTInterchange", package: "WTInterchange"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
