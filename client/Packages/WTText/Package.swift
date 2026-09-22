// swift-tools-version: 6.0
// WTText: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTText",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTText", targets: ["WTText"]),
    ],
    dependencies: [
        .package(path: "../WTRender"),
        .package(path: "../WTGeometry"),
        .package(path: "../WTModel"),
    ],
    targets: [
        .target(
            name: "WTText",
            dependencies: [
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTModel", package: "WTModel"),
            ]
        ),
        .testTarget(
            name: "WTTextTests",
            dependencies: ["WTText"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
