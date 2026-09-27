import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender
@testable import WireTuner

/// DOC-026: the scripting dictionary's objects and commands over a document (scripting.adoc,
/// "AppleScript").  Cocoa scripting's key-value coding and command objects are driven directly --
/// the Apple event transport (`osascript`) needs an Automation grant a test host cannot have.
/// The scripting dictionary and the App Intents share `ScriptingHost.shared`: their suites run
/// one at a time.
@Suite(.serialized) @MainActor struct ScriptingSurfaces {}

extension ScriptingSurfaces {
    @Suite @MainActor struct ScriptingDictionaryTests {
        static let sdef = Bundle.main.url(forResource: "WireTuner", withExtension: "sdef")

        func document(_ title: String = "Brochure") -> (DocumentHandle, WTScriptDocument) {
            let handle = DocumentHandle.memory(title: title)
            ScriptingHost.shared.role = { _ in .owner }
            return (handle, WTScriptDocument(handle: handle))
        }

        /// A command object for the dictionary's `suite`/`code` verb.
        static func command<T: NSScriptCommand>(_ type: T.Type, _ suite: String, _ code: String) throws -> T {
            let description = try #require(NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(suite), andAppleEventCode: FourCharCode(code)))
            return T(commandDescription: description)
        }

        @Test func theDictionaryNamesClassesAndKeysThatExist() throws {
            let url = try #require(Self.sdef, "the sdef is a bundle resource")
            #expect(Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String == "WireTuner.sdef")
            let xml = try XMLDocument(contentsOf: url, options: [])
            for element in try xml.nodes(forXPath: "//class") {
                guard let element = element as? XMLElement,
                      let cocoa = (try element.nodes(forXPath: "cocoa/@class").first?.stringValue) else { continue }
                let type: AnyClass = try #require(NSClassFromString(cocoa), "\(cocoa)")
                for key in try element.nodes(forXPath: "property/cocoa/@key | element/cocoa/@key").compactMap(\.stringValue) where cocoa != "NSApplication" {
                    #expect(class_respondsToSelector(type, NSSelectorFromString(key)), "\(cocoa).\(key)")
                }
            }
            for name in try xml.nodes(forXPath: "//command/cocoa/@class").compactMap(\.stringValue) {
                #expect(NSClassFromString(name) != nil, "\(name)")
            }
            #expect(NSScriptClassDescription(for: WTScriptDocument.self) != nil)
        }

        @Test func documentsPagesAndSetsRunLabelledCommands() async throws {
            let (handle, document) = document()
            await handle.settle()
            #expect(document.name == "Brochure" && document.uniqueID == handle.id)
            let pages = document.scriptPages
            #expect(pages.count == 1 && pages[0].scriptIndex == 1 && pages[0].scriptPageSize == [612, 792])
            pages[0].scriptPageSize = [500, 400]
            await handle.settle()
            #expect(document.scriptPages[0].scriptPageSize == [500, 400])
            #expect(handle.undoTitle == "Undo Script: set page size" || handle.state.store.nodes.count > 0)
            pages[0].scriptName = "Cover"
            await handle.settle()
            #expect(document.scriptPages[0].scriptName == "Cover")
            #expect(pages[0].objectSpecifier != nil && document.objectSpecifier != nil)

            // make new page with properties {page size: {200, 100}}
            let page = WTScriptPage()
            page.scriptPageSize = [200, 100]
            document.insertPage(page, at: 1)
            await handle.settle()
            #expect(document.scriptPages.count == 2 && document.scriptPages[1].scriptPageSize == [200, 100])
            document.removePage(at: 1)
            await handle.settle()
            #expect(document.scriptPages.count == 1)
            ScriptRun.clear()
            document.removePage(at: 7)
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.noSuchObject)
        }

        @Test func graphicsLayersSwatchesAndStylesReadAndSet() async throws {
            let (handle, document) = document()
            let rectangle = WTScriptRectangle()
            rectangle.scriptPosition = [100, 120]
            document.insertGraphic(rectangle)
            let text = WTScriptTextBlock()
            text.scriptContents = "Hello"
            document.insertGraphic(text, at: 0)
            await handle.settle()
            let graphics = document.scriptGraphics
            #expect(graphics.count == 2 && graphics[0] is WTScriptRectangle && graphics[1] is WTScriptTextBlock)
            #expect(graphics[0].scriptKind == "rectangle" && graphics[0].scriptBounds.count == 4 && graphics[0].scriptPosition == [100, 120])
            graphics[0].scriptName = "Box"
            graphics[0].scriptNotes = "note"
            graphics[0].scriptPosition = [10, 20]
            graphics[0].scriptLocked = true
            (graphics[1] as? WTScriptTextBlock)?.scriptContents = "World"
            await handle.settle()
            let again = document.scriptGraphics
            #expect(again[0].scriptName == "Box" && again[0].scriptNotes == "note" && again[0].scriptPosition == [10, 20] && again[0].scriptLocked)
            #expect((again[1] as? WTScriptTextBlock)?.scriptContents == "World" && document.scriptTextBlocks.count == 1)
            #expect(again[0].scriptFill.contains("fill") && again[0].scriptStroke.contains("stroke"))

            let layer = try #require(document.scriptLayers.first)
            #expect(again[0].scriptLayer?.uniqueID == layer.uniqueID && layer.scriptGraphics.count == 2)
            layer.scriptName = "Art"
            layer.scriptVisible = false
            layer.scriptLocked = true
            await handle.settle()
            let art = try #require(document.scriptLayers.first)
            #expect(art.scriptName == "Art" && !art.scriptVisible && art.scriptLocked)
            again[1].scriptLayer = art
            let swatch = try #require(document.scriptSwatches.first)
            #expect(!swatch.scriptName.isEmpty && swatch.objectSpecifier != nil)
            swatch.scriptName = swatch.scriptName
            #expect(document.scriptStyles.first?.scriptName.isEmpty == false)

            ScriptRun.clear()
            again[0].scriptPosition = [1]
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)
            document.insertGraphic(WTScriptGroup())
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.notHandled)
            art.scriptLocked = false
            art.scriptVisible = true
            await handle.settle()
            document.removeGraphic(at: 1)
            await handle.settle()
            #expect(document.scriptGraphics.count == 1)
            #expect(WTScriptGraphic.make(document: document, node: OpID(counter: 1, replica: 1)).scriptKind == "unknown")
        }

        @Test func aViewerCannotChangeTheDocument() async throws {
            let (handle, document) = document()
            ScriptingHost.shared.role = { _ in .viewer }
            ScriptRun.clear()
            document.scriptPages[0].scriptPageSize = [300, 300]
            await handle.settle()
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.privilege && document.scriptPages[0].scriptPageSize == [612, 792])
            ScriptingHost.shared.role = { _ in .owner }
        }

        @Test func readOnlyAndModelErrorsMapToAppleCodes() {
            #expect(ScriptFailure(ScriptObjects.ReadOnly(property: "fill", kind: "path")).number == ScriptFailure.notModifiable)
            #expect(ScriptFailure(ScriptObjects.InvalidValue(property: "size")).number == ScriptFailure.invalidParameter)
            #expect(ScriptFailure(ScriptFailure(1001, "offline")) == ScriptFailure(1001, "offline"))
            #expect(ScriptFailure(CocoaError(.featureUnsupported)).number == ScriptFailure.invalidParameter)
        }

        @Test func theSuiteCommandsRunOneChangeEach() async throws {
            let (handle, document) = document()
            let host = ScriptingHost.shared
            host.documents = { [handle] }
            host.open = { $0 == "Brochure" ? handle : nil }
            host.isOnline = { true }
            var pagesShown: [Int] = []
            host.goToPage = { _, index in
                pagesShown.append(index)
                return true
            }
            _ = try await Self.run(WTScriptAddPageCommand.self, "WTnr", "AdPg", direct: document, ["Count": 2, "Size": [300, 200]])
            await handle.settle()
            #expect(document.scriptPages.count == 3 && document.scriptPages[2].scriptPageSize == [300, 200])

            _ = handle.perform(NewMasterPage(from: PageList(handle.state).pages[0].id, name: "A"))
            await handle.settle()
            let master = try #require(document.scriptMasterPages.first)
            #expect(master.scriptName == "A" && master.scriptPageSize == [612, 792])
            _ = try await Self.run(WTScriptApplyMasterCommand.self, "WTnr", "ApMs", direct: master, ["Pages": Array(document.scriptPages.dropFirst())])
            await handle.settle()
            #expect(document.scriptPages[1].scriptMaster?.uniqueID == master.uniqueID)
            _ = try await Self.run(WTScriptReleaseCommand.self, "WTnr", "RlPg", direct: [document.scriptPages[1]])
            await handle.settle()
            #expect(document.scriptPages[1].scriptMaster == nil)
            document.scriptPages[2].scriptMaster = master
            await handle.settle()
            #expect(document.scriptPages[2].scriptMaster != nil)

            _ = try await Self.run(WTScriptGoToPageCommand.self, "WTnr", "GoPg", direct: document.scriptPages[1])
            #expect(pagesShown == [2])

            _ = handle.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "Spring sale, spring prices"))
            await handle.settle()
            let count = try await Self.run(WTScriptFindReplaceCommand.self, "WTnr", "FdRp", direct: document, ["Find": "spring", "Replace": "Fall"])
            await handle.settle()
            #expect(count as? Int == 2)
            #expect(try await Self.run(WTScriptFindReplaceCommand.self, "WTnr", "FdRp", direct: document, ["Find": "zebra"]) as? Int == 0)
            ScriptRun.clear()
            _ = try await Self.run(WTScriptFindReplaceCommand.self, "WTnr", "FdRp", direct: document, [:])
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)

            let opened = try await Self.run(WTScriptOpenCommand.self, "aevt", "odoc", direct: "Brochure")
            #expect((opened as? WTScriptDocument)?.uniqueID == handle.id)
            ScriptRun.clear()
            host.isOnline = { false }
            _ = try await Self.run(WTScriptOpenCommand.self, "aevt", "odoc", direct: "Elsewhere")
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.offline)
            host.openFile = { _ in false }
            _ = try await Self.run(WTScriptOpenCommand.self, "aevt", "odoc", direct: URL(fileURLWithPath: "/nope.wiretuner"))
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.noSuchObject)

            let rectangle = WTScriptRectangle()
            document.insertGraphic(rectangle)
            await handle.settle()
            _ = try await Self.run(WTScriptDuplicateCommand.self, "core", "clon", direct: document.scriptGraphics.filter { $0 is WTScriptRectangle })
            await handle.settle()
            #expect(document.scriptGraphics.filter { $0 is WTScriptRectangle }.count == 2)
            ScriptRun.clear()
            _ = try await Self.run(WTScriptDuplicateCommand.self, "core", "clon", direct: document.scriptPages[0])
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.notHandled)
        }

        @Test func windowVerbsGoToTheHost() async throws {
            let (handle, document) = document()
            let host = ScriptingHost.shared
            var printed: [String?] = []
            host.print = { _, preset, _ in
                printed.append(preset)
                return preset == nil ? nil : "no presets"
            }
            _ = try await Self.run(WTScriptPrintCommand.self, "aevt", "pdoc", direct: document)
            ScriptRun.clear()
            _ = try await Self.run(WTScriptPrintCommand.self, "aevt", "pdoc", direct: document, ["Preset": "Proof"])
            #expect(printed == [nil, "Proof"] && ScriptRun.lastFailure?.number == ScriptFailure.notHandled)

            #expect(WTScriptExportCommand.format("PDF") == .pdf && WTScriptExportCommand.format("jpg") == .jpeg && WTScriptExportCommand.format("nope") == nil)
            ScriptRun.clear()
            _ = try await Self.run(WTScriptExportCommand.self, "WTnr", "Expt", direct: document, ["Format": "nope", "File": URL(fileURLWithPath: "/tmp/x")])
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)

            host.isOnline = { false }
            ScriptRun.clear()
            _ = try await Self.run(WTScriptShareLinkCommand.self, "WTnr", "ShLk", direct: document)
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.offline)
            var closed: [String] = []
            host.close = { closed.append($0.id) }
            _ = document.handleClose(NSCloseCommand())
            #expect(closed == [handle.id])
            #expect(host.document(handle).uniqueID == handle.id)
        }

        /// Runs a command object with `direct` and `arguments` (outside an Apple event nothing is
        /// suspended), returning its result.
        static func run<T: NSScriptCommand>(_ type: T.Type, _ suite: String, _ code: String, direct: Any?, _ arguments: [String: Any] = [:]) async throws -> Any? {
            let command = try command(type, suite, code)
            command.directParameter = direct
            command.arguments = arguments
            return command.performDefaultImplementation()
        }
    }
}

extension FourCharCode {
    /// `"WTnr"` as its code.
    init(_ text: String) {
        self = text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
