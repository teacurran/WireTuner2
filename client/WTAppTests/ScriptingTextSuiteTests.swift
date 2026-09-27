import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender
@testable import WireTuner

/// DOC-026's rest: the Text suite, units, grid, guides, `make new layer` and printing with a
/// named print preset, driven through the dictionary's objects (the Apple event transport needs
/// an Automation grant a test host cannot have), and the dictionary checked against the classes
/// and commands the app implements without `osascript`.
extension ScriptingSurfaces {
    @Suite @MainActor struct ScriptingTextSuiteTests {
        static let sdef = Bundle.main.url(forResource: "WireTuner", withExtension: "sdef")

        func document() async -> (DocumentHandle, WTScriptDocument) {
            let handle = DocumentHandle.memory(title: "Brochure")
            ScriptingHost.shared.role = { _ in .owner }
            ScriptRun.clear()
            await handle.settle()
            return (handle, WTScriptDocument(handle: handle))
        }

        // MARK: The dictionary against the app

        @Test func theDictionaryIsValidAndMatchesTheImplementedClassesAndCommands() throws {
            let url = try #require(Self.sdef)
            // Valid against the system's sdef DTD (the `sdp` and Script Editor parse).
            let xml = try XMLDocument(contentsOf: url, options: [.documentValidate])
            try xml.validate()

            let registry = NSScriptSuiteRegistry.shared()
            var named: Set<String> = []
            for node in try xml.nodes(forXPath: "//class") {
                let element = try #require(node as? XMLElement)
                let code = try #require(element.attribute(forName: "code")?.stringValue)
                let cocoa = try #require(try element.nodes(forXPath: "cocoa/@class").first?.stringValue)
                named.insert(cocoa)
                #expect(registry.classDescription(withAppleEventCode: FourCharCode(code)) != nil, "\(cocoa) is registered")
                guard cocoa != "NSApplication", let type = NSClassFromString(cocoa) else { continue }
                // Every writable element can be made and deleted.
                for writable in try element.nodes(forXPath: "element[not(@access='r')]/cocoa/@key").compactMap(\.stringValue) {
                    let key = writable.prefix(1).uppercased() + writable.dropFirst()
                    #expect(class_respondsToSelector(type, NSSelectorFromString("insertIn\(key):")), "\(cocoa) makes \(writable)")
                    #expect(class_respondsToSelector(type, NSSelectorFromString("removeObjectFrom\(key)AtIndex:")), "\(cocoa) deletes \(writable)")
                }
                // Every writable property has a setter.
                for writable in try element.nodes(forXPath: "property[not(@access='r')]/cocoa/@key").compactMap(\.stringValue) {
                    let setter = "set" + writable.prefix(1).uppercased() + writable.dropFirst() + ":"
                    #expect(class_respondsToSelector(type, NSSelectorFromString(setter)), "\(cocoa).\(setter)")
                }
            }
            var commands: Set<String> = []
            for node in try xml.nodes(forXPath: "//command") {
                let element = try #require(node as? XMLElement)
                let code = try #require(element.attribute(forName: "code")?.stringValue)
                commands.insert(try #require(try element.nodes(forXPath: "cocoa/@class").first?.stringValue))
                #expect(registry.commandDescription(withAppleEventClass: FourCharCode(String(code.prefix(4))),
                                                    andAppleEventCode: FourCharCode(String(code.suffix(4)))) != nil, "\(code) is registered")
            }
            // Every scripting class and command the app implements is in the dictionary.
            for name in Self.implementedScriptingClasses() {
                let type: AnyClass = try #require(NSClassFromString(name))
                if isSubclass(type, of: NSScriptCommand.self) {
                    #expect(commands.contains(name), "\(name) is a dictionary command")
                } else {
                    #expect(named.contains(name), "\(name) is a dictionary class")
                }
            }
            #expect(named.isSuperset(of: ["WTScriptParagraph", "WTScriptWord", "WTScriptCharacter", "WTScriptGuide", "WTScriptTextRange"]))
        }

        /// The `WTScript…` classes of the app's image, less the abstract node base: read by name,
        /// so no class outside the app is touched.
        static func implementedScriptingClasses() -> [String] {
            guard let image = class_getImageName(WTScriptDocument.self) else { return [] }
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
            defer { free(UnsafeMutableRawPointer(mutating: names)) }
            return (0..<Int(count)).map { String(cString: names[$0]) }.filter { $0.hasPrefix("WTScript") && $0 != "WTScriptNode" }.sorted()
        }

        func isSubclass(_ type: AnyClass, of base: AnyClass) -> Bool {
            var current: AnyClass? = type
            while let candidate = current {
                if candidate == base { return true }
                current = class_getSuperclass(candidate)
            }
            return false
        }

        // MARK: Text suite

        @Test func paragraphsWordsAndCharactersReadAndSetOneChangeEach() async throws {
            let (handle, document) = await document()
            _ = handle.perform(CreateTextBlock(.point(Point(x: 20, y: 20)), text: "Spring sale\nNow on"))
            await handle.settle()
            let block = try #require(document.scriptTextBlocks.first as? WTScriptTextBlock)
            #expect(block.scriptParagraphs.count == 2 && block.scriptWords.count == 4 && block.scriptCharacters.count == 18)
            let word = block.scriptWords[1]
            #expect(word.scriptContents == "sale" && word.scriptFont == ScriptObjects.defaultFontFamily && word.scriptSize == 12)
            #expect(abs(word.scriptLeading - 14.4) < 1e-9 && word.scriptColor == [0, 0, 0])
            #expect(word.objectSpecifier is NSIndexSpecifier && block.scriptParagraphs[0].objectSpecifier != nil)

            word.scriptSize = 24
            await handle.settle()
            #expect(handle.undoTitle == "Undo Script: set size")
            word.scriptFont = "Futura"
            word.scriptLeading = 30
            word.scriptColor = [65535, 0, 0]
            await handle.settle()
            let again = block.scriptWords[1]
            #expect(again.scriptSize == 24 && again.scriptFont == "Futura" && again.scriptLeading == 30 && again.scriptColor == [65535, 0, 0])
            #expect(block.scriptWords[0].scriptSize == 12, "the other words keep theirs")
            #expect(handle.undoTitle == "Undo Script: set color")

            block.scriptParagraphs[1].scriptContents = "Ends Sunday"
            await handle.settle()
            #expect(block.scriptContents == "Spring sale\nEnds Sunday")
            block.scriptCharacters[0].scriptContents = "s"
            await handle.settle()
            #expect(block.scriptParagraphs[0].scriptContents == "spring sale")

            // The whole text.
            block.scriptSize = 10
            block.scriptFont = "Avenir"
            block.scriptLeading = 12
            block.scriptColor = [0, 0, 65535]
            await handle.settle()
            #expect(block.scriptSize == 10 && block.scriptFont == "Avenir" && block.scriptLeading == 12 && block.scriptColor == [0, 0, 65535])
            #expect(block.scriptWords[1].scriptSize == 10)

            // Refusals carry the documented codes.
            block.scriptWords[0].scriptSize = 0
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)
            ScriptRun.clear()
            block.scriptWords[0].scriptColor = [1, 2]
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)
            let missing = WTScriptWord(block: block, index: 99)
            #expect(missing.scriptContents == "" && missing.scriptSize == 0 && missing.scriptLeading == 0 && missing.scriptFont == "" && missing.scriptColor == [])
            missing.scriptSize = 12
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.noSuchObject)
            #expect(WTScriptTextRange(block: block, index: 0).scriptContents == block.scriptContents)
            let unmade = WTScriptTextBlock()
            #expect(unmade.scriptWords.isEmpty && unmade.scriptSize == 0)
            unmade.scriptSize = 5
        }

        // MARK: Units, grid, layers

        @Test func unitsGridAndMakeNewLayer() async throws {
            let (handle, document) = await document()
            #expect(document.scriptUnits == "points" && document.scriptGridSize == GridSettings.defaultSize)
            document.scriptUnits = "mm"
            document.scriptGridSize = 18
            await handle.settle()
            #expect(document.scriptUnits == "millimeters" && document.scriptGridSize == 18)
            #expect(handle.undoTitle == "Undo Script: set grid size")
            document.scriptUnits = "furlongs"
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)
            let detached = WTScriptDocument()
            detached.scriptUnits = "mm"
            #expect(detached.scriptUnits == "points")

            let layersBefore = document.scriptLayers.count
            let layer = WTScriptLayer()
            layer.scriptName = "Notes"
            #expect(layer.scriptName == "Notes" && layer.uniqueID.isEmpty)
            document.insertLayer(layer, at: 0)
            await handle.settle()
            #expect(await eventually { !layer.uniqueID.isEmpty }, "the made layer is bound to its node")
            #expect(document.scriptLayers.count == layersBefore + 1 && document.scriptLayers.contains { $0.scriptName == "Notes" })
            #expect(!layer.uniqueID.isEmpty && layer.scriptName == "Notes")
            #expect(handle.undoTitle == "Undo Script: make layer")
            detached.insertLayer(WTScriptLayer())
        }

        // MARK: Guides

        @Test func guidesAreMadeMovedAndDeletedOnPagesAndMasters() async throws {
            let (handle, document) = await document()
            let page = try #require(document.scriptPages.first)
            #expect(page.scriptGuides.isEmpty)
            let guide = WTScriptGuide()
            guide.scriptOrientation = "vertical"
            guide.scriptPosition = 72
            #expect(guide.scriptOrientation == "vertical" && guide.scriptPosition == 72 && guide.objectSpecifier == nil)
            page.insertInScriptGuides(guide, at: 0)
            await handle.settle()
            #expect(await eventually { !guide.uniqueID.isEmpty }, "the made guide is bound to its element")
            #expect(page.scriptGuides.count == 1 && !guide.uniqueID.isEmpty && guide.objectSpecifier != nil)
            #expect(guide.scriptOrientation == "vertical" && guide.scriptPosition == 72)
            #expect(handle.undoTitle == "Undo Script: make guide")
            guide.scriptPosition = 90
            await handle.settle()
            #expect(page.scriptGuides[0].scriptPosition == 90)
            guide.scriptOrientation = "horizontal"
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.notModifiable)
            ScriptRun.clear()
            let bad = WTScriptGuide()
            bad.scriptOrientation = "diagonal"
            page.insertInScriptGuides(bad)
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.invalidParameter)
            page.removeFromScriptGuides(at: 0)
            await handle.settle()
            #expect(page.scriptGuides.isEmpty)
            page.removeFromScriptGuides(at: 3)
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.noSuchObject)

            _ = handle.perform(NewMasterPage(from: PageList(handle.state).pages[0].id, name: "A"))
            await handle.settle()
            let master = try #require(document.scriptMasterPages.first)
            let onMaster = WTScriptGuide()
            onMaster.scriptPosition = 36
            master.insertInScriptGuides(onMaster)
            await handle.settle()
            #expect(await eventually { !onMaster.uniqueID.isEmpty })
            #expect(master.scriptGuides.map(\.scriptOrientation) == ["horizontal"] && master.scriptGuides[0].scriptPosition == 36)
            master.insertInScriptGuides(WTScriptGuide(), at: 1)
            master.removeFromScriptGuides(at: 0)
            await handle.settle()
            #expect(master.scriptGuides.isEmpty)
            let stale = WTScriptGuide(owner: page, guide: OpID(counter: 1, replica: 1))
            stale.scriptPosition = 5
            #expect(ScriptRun.lastFailure?.number == ScriptFailure.noSuchObject)
        }

        // MARK: Print presets

        @Test func printingWithANamedPresetAppliesItsSettingsThenPrints() async throws {
            let (handle, _) = await document()
            #expect(ScriptPrinting.domains(printer: nil) == [ScriptPrinting.domain])
            #expect(ScriptPrinting.domains(printer: "HP Color (D365)") == ["\(ScriptPrinting.domain).forprinter.HP_Color__D365_", ScriptPrinting.domain])
            let current = PrintPresets.preset(handle.state)
            let flipped = current.preset.dictionary(includeHiddenLayers: !current.includeHiddenLayers)
            let domains: [[String: Any]] = [
                ["Other": [ScriptPrinting.settingsKey: ["Duplex": "None"]]],
                ["Press": [ScriptPrinting.settingsKey: flipped], "x": [ScriptPrinting.idKey: "Proof", ScriptPrinting.settingsKey: ["Duplex": "None"]]],
            ]
            #expect(ScriptPrinting.settings(named: "Press", in: domains)?.isEmpty == false)
            #expect(ScriptPrinting.settings(named: "Proof", in: domains)?["Duplex"] as? String == "None")
            #expect(ScriptPrinting.settings(named: "Missing", in: domains) == nil)

            let lookup = ScriptPrinting.lookup
            defer { ScriptPrinting.lookup = lookup }
            ScriptPrinting.lookup = { ScriptPrinting.settings(named: $0, in: domains) }
            var shown = 0
            let show: @MainActor () -> String? = {
                shown += 1
                return nil
            }
            #expect(ScriptPrinting.print(handle, preset: "Missing", label: "Script: apply print preset", show: show)?.contains("Missing") == true)
            #expect(ScriptPrinting.print(handle, preset: "Other", label: "Script: apply print preset", show: show) == nil && shown == 1)
            #expect(ScriptPrinting.print(handle, preset: "Press", label: "Script: apply print preset", show: show) == nil)
            await handle.settle()
            #expect(await eventually { shown == 2 })
            #expect(PrintPresets.preset(handle.state).includeHiddenLayers == !current.includeHiddenLayers)
            #expect(handle.undoTitle == "Undo Script: apply print preset")
            // Again: printed once more (applied again only if the document reads it differently).
            #expect(ScriptPrinting.print(handle, preset: "Press", label: "x", show: show) == nil)
            #expect(await eventually { shown == 3 })
            ScriptingHost.shared.role = { _ in .viewer }
            ScriptPrinting.lookup = { _ in current.preset.dictionary(includeHiddenLayers: current.includeHiddenLayers) }
            #expect(ScriptPrinting.print(handle, preset: "Press", label: "x", show: show)?.contains("editor role") == true)
            ScriptingHost.shared.role = { _ in .owner }
            #expect(ScriptPrinting.lookup("anything") != nil)
            ScriptPrinting.lookup = lookup
            #expect(ScriptPrinting.lookup("WireTuner test preset that does not exist") == nil)
        }
    }
}
