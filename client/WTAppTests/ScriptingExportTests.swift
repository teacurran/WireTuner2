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

        /// DATA-011: `wt.document.export` writes the menu export's bytes (a save panel's file, or
        /// a `wt.ui.saveFile` writer's) and `print` goes to the print path; failures throw in the
        /// script.
        @Test func aScriptsExportWritesTheMenuExportsBytesAndPrintGoesToThePrintPath() async throws {
            let world = ExportWorld()
            defer { world.close() }
            world.controller.registry = ExportRegistry.standard
            _ = await world.threePages()
            let window = world.window
            var settings = ExportSettings()
            settings.format = .svg
            world.saveName = "menu.svg"
            guard case .exported? = await world.controller.present(settings, for: window) else {
                Issue.record("menu export")
                return
            }
            let menu = try Data(contentsOf: world.output.appending(path: "menu.svg"))
            let ui = ScriptUI(window: window, data: nil)
            ui.exportDocument = ScriptingHost.exporting(through: world.controller) { _ in window }
            var saves: [String] = []
            var answers = [world.output.appending(path: "panel.svg"), world.output.appending(path: "writer.svg")]
            ui.chooseSave = { panel, _ in
                saves.append(panel.nameFieldStringValue)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
            var printed: [(String?, String)] = []
            ui.printDocument = { _, preset, label in
                printed.append((preset, label))
                return preset == "Missing" ? "There is no print preset “Missing”" : nil
            }
            let host = WindowScriptHost(ui: ui)
            let target = DocumentScriptTarget(try #require(world.document.model), name: world.document.title)
            let result = await ScriptRunner().runDetached("""
            console.log(wt.document.export({ format: "svg" }));
            const writer = wt.ui.saveFile({ suggestedName: "chosen.svg" });
            console.log(wt.document.export({ format: "SVG", to: writer }));
            console.log(wt.document.export({ format: "pdf", fileName: "Proof.pdf" }));
            console.log(wt.document.print("Proof"), wt.document.print());
            for (const bad of [{ format: "bogus" }, { to: { write: function () {} } }]) {
              try { wt.document.export(bad); } catch (error) { console.log(String(error.message || error)); }
            }
            try { wt.document.print("Missing"); } catch (error) { console.log(String(error.message || error)); }
            """, name: "Export", target: target, host: host)
            #expect(result.error == nil, "\(String(describing: result.error))")
            #expect(result.console.map(\.text) == ["true", "true", "false", "true true", "Unknown export format “bogus”",
                                                  "wt.document.export: “to” must be a writer from wt.ui.saveFile", "There is no print preset “Missing”"])
            #expect(saves == ["\(world.document.title).svg", "chosen.svg", "Proof.pdf"], "the save panel names the file; the last is cancelled")
            #expect(try Data(contentsOf: world.output.appending(path: "panel.svg")) == menu, "the menu export's bytes")
            #expect(try Data(contentsOf: world.output.appending(path: "writer.svg")) == menu)
            #expect(printed.map(\.0) == ["Proof", nil, "Missing"] && printed.allSatisfy { $0.1 == "Script: apply print preset" })
            // Without the window both refuse.
            let orphan = ScriptUI(window: nil, data: nil)
            await #expect(throws: ScriptCallFailed("wt.document.export needs the document's window")) { _ = try await orphan.export([:]) }
            #expect(throws: ScriptCallFailed("wt.document.print needs the document's window")) { _ = try orphan.print(nil) }
        }
    }
}
