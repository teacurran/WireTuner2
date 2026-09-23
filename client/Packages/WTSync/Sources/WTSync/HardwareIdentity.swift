import Foundation
import IOKit

/// The Mac a local store was created on (docs/spec/offline.adoc, `meta`; docs/spec/crdt-model.adoc
/// "Identifiers"): a store found on a different Mac -- restored from backup, or copied -- takes a
/// new replica id.
public enum HardwareIdentity {
    /// The platform UUID (`IOPlatformUUID` of `IOPlatformExpertDevice`), or "" when unreadable.
    public static func platformUUID() -> String {
        registryString(service: "IOPlatformExpertDevice", key: kIOPlatformUUIDKey)
    }

    /// The string property `key` of the first IOKit service matching `service`, or "".
    static func registryString(service name: String, key: String) -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String ?? ""
    }
}
