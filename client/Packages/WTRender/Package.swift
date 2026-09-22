// swift-tools-version: 6.0
// WTRender: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTRender",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTRender", targets: ["WTRender"]),
    ],
    dependencies: [
        .package(path: "../WTGeometry"),
        .package(path: "../WTModel"),
    ],
    targets: [
        .target(
            name: "WTRender",
            dependencies: [
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTModel", package: "WTModel"),
            ]
        ),
        .testTarget(
            name: "WTRenderTests",
            dependencies: ["WTRender"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
