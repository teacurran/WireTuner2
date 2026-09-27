import AppIntents
import AppKit
import Foundation
import Testing
import WTInterchange
import WTModel
@testable import WireTuner

/// DOC-027: *Export Document* writes the same bytes as menu:File[Export…] with the same format
/// (scripting.adoc, "Shortcuts and App Intents").  The menu export runs the sheet (its save panel
/// answered with a file) and the intent runs through `ScriptingHost.exporting`, the closure the app
/// installs, against the same window.
extension ScriptingSurfaces {
    @Suite @MainActor struct ScriptingExportTests {
        /// The PDF writer stamps the time, a fresh XMP id and a file `/ID` that Core Graphics derives
        /// from the time (two exports in different seconds differ there, same length); the rest must
        /// match byte for byte.
        static func masked(_ data: Data) -> Data {
            var text = String(decoding: data, as: UTF8.self)
            for pattern in [#"D:\d{14}(?:Z|[+-]\d\d'\d\d'?)?"#, #"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)?"#,
                            #"uuid:[0-9a-fA-F-]{36}"#, #"/ID\s*\[\s*<[0-9A-Fa-f]*>\s*<[0-9A-Fa-f]*>\s*\]"#] {
                text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            return Data(text.utf8)
        }

        @Test func theExportIntentWritesTheMenuExportsBytes() async throws {
            let world = ExportWorld()
            defer { world.close() }
            // The shared hosts would keep this test's window and document until another test
            // replaced them.
            let hooks = (export: ScriptingHost.shared.export, role: ScriptingHost.shared.role, open: IntentsHost.shared.open, scratch: IntentsHost.shared.scratch)
            defer {
                ScriptingHost.shared.export = hooks.export
                ScriptingHost.shared.role = hooks.role
                IntentsHost.shared.open = hooks.open
                IntentsHost.shared.scratch = hooks.scratch
            }
            world.controller.registry = ExportRegistry.standard
            _ = await world.threePages()
            let handle = world.document
            ScriptingHost.shared.role = { _ in .owner }
            IntentsHost.shared.open = { _ in handle }
            let window = world.window
            ScriptingHost.shared.export = ScriptingHost.exporting(through: world.controller) { _ in window }
            let folder = world.output.appending(path: "intent")
            IntentsHost.shared.scratch = { folder }

            let intent = ExportDocumentIntent()
            intent.document = DocumentEntity(id: handle.id, name: handle.title)
            for format in [ExportFormatEntity.svg, .png, .tiff, .jpeg, .pdf] {
                var settings = ExportSettings()
                settings.format = format.format
                world.saveName = "menu.\(format.format.fileExtension)"
                let outcome = await world.controller.present(settings, for: window)
                guard case .exported? = outcome else { Issue.record("menu export of \(format): \(String(describing: outcome))"); continue }
                intent.format = format
                _ = try await intent.perform()
                let menu = try Data(contentsOf: world.output.appending(path: "menu.\(format.format.fileExtension)"))
                let shortcut = try Data(contentsOf: folder.appending(path: "\(handle.title).\(format.format.fileExtension)"))
                #expect(!menu.isEmpty, "\(format)")
                if format == .pdf {
                    #expect(Self.masked(menu) == Self.masked(shortcut), "PDF but its timestamps")
                } else {
                    #expect(menu == shortcut, "\(format) byte-identical")
                }
            }
            #expect(await ScriptingHost.exporting(through: world.controller) { _ in nil }(handle, .svg, folder.appending(path: "x.svg")) == "The document has no window")
        }
    }
}
