// swift-tools-version: 6.0
// WTSync: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTSync",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "WTSync", targets: ["WTSync"]),
    ],
    dependencies: [
        .package(path: "../WTModel"),
        .package(path: "../WTCRDT"),
        .package(path: "../WTProto"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // The sync client (SYNC-003): same version lines as WTProto's generated stubs.
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "WTSync",
            dependencies: [
                .product(name: "WTModel", package: "WTModel"),
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTCRDTSchema", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "WTSyncTests",
            dependencies: [
                "WTSync",
                .product(name: "WTModel", package: "WTModel"),
                .product(name: "WTCRDT", package: "WTCRDT"),
                .product(name: "WTProto", package: "WTProto"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
