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
        // The compose scenarios' document and token calls (tests only; WTSync resolves them anyway).
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.0.0"),
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
                .product(name: "WTCRDTSchema", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
            ]
        ),
        .testTarget(
            name: "WTTestSupportTests",
            dependencies: [
                "WTTestSupport",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
