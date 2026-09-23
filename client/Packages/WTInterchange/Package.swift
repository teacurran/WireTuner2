// swift-tools-version: 6.0
// WTInterchange: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
// It needs only WTRender and WTGeometry: exporters read WTRender's display list and importers
// produce a neutral `ImportedScene` that WTModel converts (import-formats.adoc, "Client").
import PackageDescription

let package = Package(
    name: "WTInterchange",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTInterchange", targets: ["WTInterchange"]),
    ],
    dependencies: [
        .package(path: "../WTRender"),
        .package(path: "../WTGeometry"),
    ],
    targets: [
        .target(
            name: "WTInterchange",
            dependencies: [
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
            ]
        ),
        .testTarget(
            name: "WTInterchangeTests",
            dependencies: [
                "WTInterchange",
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
            ],
            // Golden PNGs are read by path from the source tree, not bundled, so
            // `WTINTERCHANGE_RECORD_GOLDENS=1` can write them back in place.
            exclude: ["Goldens"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
