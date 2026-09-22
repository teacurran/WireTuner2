import Testing
@testable import WTProto

@Suite struct WTProtoPackageTests {
    @Test func nameAndRuntimeLink() {
        #expect(WTProtoPackage.name == "WTProto")
        #expect(WTProtoPackage.protobufVersion.split(separator: ".").count == 3)
    }

    @Test func descriptorRoundTrips() {
        let descriptor = WTProtoPackage.descriptor(service: "wiretuner.sync.v1.SyncService", method: "Subscribe")
        #expect(descriptor.fullyQualifiedMethod == "wiretuner.sync.v1.SyncService/Subscribe")
    }
}
