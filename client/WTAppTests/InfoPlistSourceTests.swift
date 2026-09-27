import Foundation
import Testing
import UniformTypeIdentifiers
import WTModel
@testable import WireTuner

/// `client/project.yml` is the source of the app's Info.plist: `xcodegen generate` rewrites
/// `WTApp/Info.plist` from its `info.properties`, so a key or a declared type only in the plist
/// would be dropped by the next generate.
@Suite @MainActor struct InfoPlistSourceTests {
    static let clientDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func projectText() throws -> String {
        try String(contentsOf: clientDirectory.appendingPathComponent("project.yml"), encoding: .utf8)
    }

    static func committedPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: clientDirectory.appendingPathComponent("WTApp/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The app target's `info.properties` block of project.yml.
    static func appProperties(_ text: String) throws -> Substring {
        let start = try #require(text.range(of: "      path: WTApp/Info.plist\n      properties:\n"))
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    entitlements:")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    @Test func everyKeyOfTheCommittedPlistComesFromProjectYml() throws {
        let properties = try Self.appProperties(try Self.projectText())
        // Keys Xcodegen writes itself for an application target.
        let generated: Set<String> = ["CFBundleDevelopmentRegion", "CFBundleExecutable", "CFBundleIdentifier",
                                      "CFBundleInfoDictionaryVersion", "CFBundlePackageType"]
        for key in try Self.committedPlist().keys where !generated.contains(key) {
            #expect(properties.contains("\n        \(key):") || properties.hasPrefix("        \(key):"), "\(key) is not in project.yml")
        }
    }

    /// Every type identifier and URL scheme the app's code relies on is declared in project.yml,
    /// the committed plist and the built bundle.
    @Test func theAppsTypesAndSchemesAreDeclaredInProjectYml() throws {
        let properties = try Self.appProperties(try Self.projectText())
        let exported = [PackageController.typeIdentifier, StyleDrag.typeIdentifier, GradientRampDrag.typeIdentifier,
                        "com.villagecompute.wiretuner.colorref", "com.villagecompute.wiretuner.objects",
                        SymbolLibraryDrag.rowsType.identifier, SymbolPackage.pasteboardType, SymbolTransferFeatures.libraryType.identifier]
        let plist = try Self.committedPlist()
        let declared = (plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
        let bundled = (Bundle.main.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
        for identifier in exported {
            #expect(properties.contains("UTTypeIdentifier: \(identifier)\n"), "\(identifier) is not in project.yml")
            #expect(declared.contains(identifier), "\(identifier) is not in Info.plist")
            #expect(bundled.contains(identifier), "\(identifier) is not in the built app")
        }
        let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        for scheme in ["wiretuner", "wiretuner-share"] {
            #expect(schemes.contains(scheme))
        }
        #expect(properties.contains("CFBundleURLSchemes: [wiretuner, wiretuner-share]"))
    }
}
