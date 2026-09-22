import GRPCCore
import SwiftProtobuf

/// Keeps the module buildable while `Generated/` is empty and proves the protobuf and gRPC
/// products link.  The spec says WTProto carries no hand-written code; PROTO-004 may delete
/// this file once buf has populated `Generated/`.
public enum WTProtoPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTProto"

    /// The swift-protobuf runtime version this package was resolved against.
    public static var protobufVersion: String {
        "\(SwiftProtobuf.Version.major).\(SwiftProtobuf.Version.minor).\(SwiftProtobuf.Version.revision)"
    }

    /// Builds a gRPC method descriptor, which is what every generated stub does.
    public static func descriptor(service: String, method: String) -> MethodDescriptor {
        MethodDescriptor(fullyQualifiedService: service, method: method)
    }
}
