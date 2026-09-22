// swift-tools-version: 6.0
// WTInterchange: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTInterchange",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTInterchange", targets: ["WTInterchange"]),
    ],
    dependencies: [
        .package(path: "../WTText"),
        .package(path: "../WTRender"),
        .package(path: "../WTGeometry"),
        .package(path: "../WTModel"),
    ],
    targets: [
        .target(
            name: "WTInterchange",
            dependencies: [
                .product(name: "WTText", package: "WTText"),
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTModel", package: "WTModel"),
            ]
        ),
        .testTarget(
            name: "WTInterchangeTests",
            dependencies: ["WTInterchange"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
