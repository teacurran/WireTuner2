import AppKit
import Foundation
import Testing
import WTInterchange
import WTModel
@testable import WireTuner

/// The objects pasteboard type (copying.adoc, "Client"): written under the app's
/// `com.villagecompute.wiretuner.*` namespace -- the name the project exports and the one
/// `ImportPasteboard` leaves to the app -- and read under the name earlier builds wrote too.
@Suite @MainActor struct ObjectPasteboardTests {
    @Test func objectsAreWrittenUnderTheAppsNamespace() throws {
        let pasteboard = ObjectEditingTests.pasteboard()
        defer { pasteboard.pasteboard.releaseGlobally() }
        #expect(SystemObjectPasteboard.type.rawValue == "com.villagecompute.wiretuner.objects")
        #expect(SystemObjectPasteboard.type.rawValue == ImportPasteboard.objectsType)
        #expect(pasteboard.read() == nil)
        pasteboard.write([1, 2, 3])
        #expect(pasteboard.pasteboard.types == [SystemObjectPasteboard.type])
        #expect(pasteboard.read() == [1, 2, 3])
        let representations = (pasteboard.pasteboard.types ?? []).compactMap { type in
            pasteboard.pasteboard.data(forType: type).map { (type: type.rawValue, data: $0) }
        }
        #expect(ImportPasteboard.choose(representations + [("com.adobe.pdf", Data([0x25]))]) == nil, "import leaves the app's objects alone")
    }

    @Test func objectsUnderTheEarlierNameAreStillRead() {
        let pasteboard = ObjectEditingTests.pasteboard()
        defer { pasteboard.pasteboard.releaseGlobally() }
        pasteboard.pasteboard.clearContents()
        pasteboard.pasteboard.setData(Data([4, 5]), forType: NSPasteboard.PasteboardType("com.wiretuner.objects"))
        #expect(SystemObjectPasteboard.legacyType.rawValue == "com.wiretuner.objects")
        #expect(pasteboard.read() == [4, 5])
        pasteboard.write([6])
        #expect(pasteboard.read() == [6] && pasteboard.pasteboard.data(forType: SystemObjectPasteboard.legacyType) == nil, "only the new name is written")
    }

    @Test func theTypeIsExported() throws {
        let declarations = try #require(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let identifiers = declarations.compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(identifiers.contains(SystemObjectPasteboard.type.rawValue))
    }
}
