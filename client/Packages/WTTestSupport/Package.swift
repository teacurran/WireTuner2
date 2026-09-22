// swift-tools-version: 6.0
// WTTestSupport: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTTestSupport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTTestSupport", targets: ["WTTestSupport"]),
    ],
    dependencies: [
        .package(path: "../WTInterchange"),
        .package(path: "../WTText"),
        .package(path: "../WTRender"),
        .package(path: "../WTGeometry"),
        .package(path: "../WTSync"),
        .package(path: "../WTModel"),
        .package(path: "../WTCRDT"),
        .package(path: "../WTProto"),
    ],
    targets: [
        .target(
            name: "WTTestSupport",
            dependencies: [
                .product(name: "WTInterchange", package: "WTInterchange"),
                .product(name: "WTText", package: "WTText"),
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTSync", package: "WTSync"),
                .product(name: "WTModel", package: "WTModel"),
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
            ]
        ),
        .testTarget(
            name: "WTTestSupportTests",
            dependencies: ["WTTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
