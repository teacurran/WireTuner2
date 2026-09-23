// swift-tools-version: 6.0
// WTInterchange: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
// It needs WTRender and WTGeometry (exporters read WTRender's display list and importers produce
// a neutral `ImportedScene` that WTModel converts, import-formats.adoc, "Client") and WTProto for
// the package manifest (`wiretuner.docs.v1.PackageManifest`, saving.adoc), written as protobuf
// JSON by SwiftProtobuf.
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
        .package(path: "../WTProto"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
    ],
    targets: [
        .target(
            name: "WTInterchange",
            dependencies: [
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "WTInterchangeTests",
            dependencies: [
                "WTInterchange",
                .product(name: "WTRender", package: "WTRender"),
                .product(name: "WTGeometry", package: "WTGeometry"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            // Golden PNGs are read by path from the source tree, not bundled, so
            // `WTINTERCHANGE_RECORD_GOLDENS=1` can write them back in place.
            exclude: ["Goldens"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
