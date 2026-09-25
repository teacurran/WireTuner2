// swift-tools-version: 6.0
// WTGeometry: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTGeometry",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "WTGeometry", targets: ["WTGeometry"]),
    ],
    targets: [
        .target(
            name: "WTGeometry",
            dependencies: []
        ),
        .testTarget(
            name: "WTGeometryTests",
            dependencies: ["WTGeometry"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
