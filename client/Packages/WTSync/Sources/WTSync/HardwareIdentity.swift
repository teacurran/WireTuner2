import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// The Mac a local store was created on (docs/spec/offline.adoc, `meta`; docs/spec/crdt-model.adoc
/// "Identifiers"): a store found on a different Mac -- restored from backup, or copied -- takes a
/// new replica id.
public enum HardwareIdentity {
    /// The platform UUID (`IOPlatformUUID` of `IOPlatformExpertDevice`), or "" when unreadable.
    /// iOS has no IOKit registry for apps: there it is always "", and an iOS app passes its own
    /// `hardwareUUID` to `LocalStore.Options` (client.adoc, "iOS readiness").
    public static func platformUUID() -> String {
        #if canImport(IOKit)
        registryString(service: "IOPlatformExpertDevice", key: kIOPlatformUUIDKey)
        #else
        ""
        #endif
    }

    #if canImport(IOKit)
    /// The string property `key` of the first IOKit service matching `service`, or "".
    static func registryString(service name: String, key: String) -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String ?? ""
    }
    #endif
}
