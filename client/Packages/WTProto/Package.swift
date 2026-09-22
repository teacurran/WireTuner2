// swift-tools-version: 6.0
// WTProto: generated swift-protobuf messages and grpc-swift 2 stubs (docs/spec/client.adoc,
// docs/spec/api-conventions.adoc).  buf writes into Sources/WTProto/Generated; nothing else in
// this package is hand-written once PROTO-004 has landed.
import PackageDescription

let package = Package(
    name: "WTProto",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WTProto", targets: ["WTProto"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "WTProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "WTProtoTests",
            dependencies: ["WTProto"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
