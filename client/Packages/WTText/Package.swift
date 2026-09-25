// swift-tools-version: 6.0
// WTText: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTText",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "WTText", targets: ["WTText"]),
    ],
    dependencies: [
        .package(path: "../WTRender"),
        .package(path: "../WTGeometry"),
    ],
    targets: [
        .target(
            name: "WTText",
            dependencies: [
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
            ]
        ),
        .testTarget(
            name: "WTTextTests",
            dependencies: [
                "WTText",
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
            ],
            // Layout goldens (glyph positions as JSON, renders as PNG) are read by path from the
            // source tree, so `WTTEXT_RECORD_GOLDENS=1` can write them back in place.
            exclude: ["Goldens"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
