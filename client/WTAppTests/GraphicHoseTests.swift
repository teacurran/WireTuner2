import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-039's Graphic Hose tool and DRAW-040's sheet over DRAW-038's sets and library.
@Suite(.serialized) @MainActor struct GraphicHoseTests {
    /// A clipboard held in memory.
    final class Clipboard: ObjectPasteboard {
        var bytes: [UInt8]?
        func write(_ payload: [UInt8]) { bytes = payload }
        func read() -> [UInt8]? { bytes }
    }

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Hose")
        let selection: SelectionController
        let editing: ObjectEditing
        let active: ActiveSelection
        let directory = FileManager.default.temporaryDirectory.appending(path: "WireTunerTests-hoses-\(UUID().uuidString)")
        let model: GraphicHoseModel
        let host = RecordingHost()
        let clipboard = Clipboard()

        init() {
            selection = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: selection, pasteboard: clipboard)
            active = ActiveSelection(model: selection.model, document: document, editing: editing)
            model = GraphicHoseModel(selection: active, library: HoseLibrary(directory: directory))
            model.seed = { 7 }
        }

        func close() {
            try? FileManager.default.removeItem(at: directory)
        }

        var state: EngineState { document.state }

        /// Copies rectangles of the given widths to the clipboard, one object each call.
        func copy(width: Double) async {
            let rect = await document.addRectangles([Rect(x: 0, y: 0, width: width, height: width)])[0].opID
            clipboard.write(ClipboardPayload(copying: [rect], from: state, document: document.id).encoded())
        }

        func set(_ name: String) -> HoseSet? { HoseSets.list(in: state).first { $0.name == name } }

        func tool() -> GraphicHoseTool {
            let tool = GraphicHoseTool(model: model)
            tool.activate(in: ToolContext(document: document, host: host, selection: selection))
            return tool
        }

        func event(_ x: Double, _ y: Double, time: Double) -> CanvasEvent {
            CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), timestamp: time)
        }

        /// A stroke from (0, 0) to (`length`, 0) over a second; waits for it to be written.
        func spray(_ tool: GraphicHoseTool, length: Double = 300) async {
            tool.mouseDown(event(0, 0, time: 0))
            for step in 1...10 { tool.mouseDragged(event(length * Double(step) / 10, 0, time: Double(step) / 10)) }
            tool.mouseUp(event(length, 0, time: 1))
            await tool.writing?.value
            await document.settle()
        }

        var sprayed: [OpID] {
            state.liveChildren(WellKnown.layers).flatMap { state.liveChildren($0) }
        }
    }

    static func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func documentSetsAreMadeFilledRenamedDuplicatedAndDeleted() async throws {
        let f = Fixture()
        defer { f.close() }
        await f.document.settle()
        #expect(f.model.choice == nil && f.model.choiceName.isEmpty && f.model.shown == nil && f.model.contents.isEmpty && f.model.contentsPreview() == nil)
        #expect(f.model.delete() == nil && f.model.removeObject() == nil && f.model.edit { SetHoseOptions($0, []) } == nil)
        f.model.beginNaming(.rename)
        #expect(f.model.naming == nil, "nothing to rename")
        f.model.beginNaming(.new)
        #expect(f.model.nameText == "Hose")
        f.model.nameText = "Leaves"
        await f.model.commitNaming()?.value
        let leaves = try #require(f.set("Leaves"))
        #expect(f.model.choice == .document(leaves.id) && f.model.choiceName == "Leaves" && f.document.undoTitle == "Undo New hose set")
        // Paste In three objects, remove one.
        #expect(f.model.pasteIn(from: f.clipboard) == nil && f.model.failure != nil, "nothing copied")
        for width in [10.0, 20, 30] {
            await f.copy(width: width)
            await f.model.pasteIn(from: f.clipboard)?.value
        }
        #expect(f.set("Leaves")?.objects.count == 3 && f.model.contents == ["Object-1", "Object-2", "Object-3"])
        f.model.contentsIndex = 2
        #expect(f.model.contentsPreview() != nil)
        await f.model.removeObject()?.value
        #expect(f.set("Leaves")?.objects.count == 2 && f.model.contentsIndex == 1)
        // Rename, duplicate in the document and into the library.
        f.model.beginNaming(.rename)
        #expect(f.model.nameText == "Leaves")
        f.model.nameText = "Foliage"
        await f.model.commitNaming()?.value
        #expect(f.set("Foliage") != nil && f.document.undoTitle == "Undo Rename hose set")
        f.model.beginNaming(.duplicate)
        #expect(f.model.nameText == "Foliage copy")
        await f.model.commitNaming()?.value
        #expect(f.set("Foliage copy")?.objects.count == 2)
        f.model.choose(.document(try #require(f.set("Foliage")).id))
        f.model.beginNaming(.duplicate)
        f.model.location = .library
        f.model.nameText = "Foliage kept"
        await f.model.commitNaming()?.value
        #expect(f.model.entries.map(\.name) == ["Foliage kept"] && f.model.choiceName == "Foliage kept")
        // Refused names.
        f.model.choose(.document(try #require(f.set("Foliage")).id))
        f.model.beginNaming(.rename)
        f.model.nameText = "Foliage copy"
        await f.model.commitNaming()?.value
        #expect(f.model.failure != nil && f.set("Foliage") != nil)
        f.model.beginNaming(.new)
        f.model.nameText = "  "
        #expect(f.model.commitNaming() == nil && f.model.failure == "A hose needs a name")
        f.model.beginNaming(.new)
        f.model.cancelNaming()
        #expect(f.model.naming == nil && f.model.commitNaming() == nil)
        // Delete.
        await f.model.delete()?.value
        #expect(f.set("Foliage") == nil && f.document.undoTitle == "Undo Delete hose set")
    }

    @Test func edgeCasesOfTheSheetModel() async throws {
        let f = Fixture()
        defer { f.close() }
        _ = await f.document.perform(CreateHoseSet(name: "Solo")).value
        await f.document.settle()
        let solo = try #require(f.set("Solo"))
        // A set removed by a collaborator while its name prompt is open: nothing to rename.
        f.model.beginNaming(.rename)
        _ = await f.document.receiveRemote(DeleteHoseSet(solo.id))
        #expect(f.model.choice == nil && f.model.commitNaming() == nil)
        // Paste In with no hose chosen writes nothing.
        await f.copy(width: 8)
        #expect(f.model.pasteIn() == nil)
        // No document: New writes nothing.
        let lone = GraphicHoseModel(selection: ActiveSelection(), library: HoseLibrary(directory: f.directory))
        lone.beginNaming(.new)
        #expect(lone.commitNaming() == nil)
        // The front document changes: the model follows the new one.
        _ = f.model.document
        let other = DocumentHandle.memory(title: "Other")
        f.active.document = other
        #expect(f.model.document === other)
        f.active.document = f.document
        #expect(f.model.document === f.document && f.model.revision >= 0)
        // The Contents preview: past the end, and an object the preview leaves out (text).
        _ = await f.document.perform(CreateHoseSet(name: "Words")).value
        await f.document.settle()
        let text = try #require(await f.document.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "Hi")).value?.createdObjects.first)
        f.clipboard.write(ClipboardPayload(copying: [text], from: f.state, document: f.document.id).encoded())
        await f.model.pasteIn()?.value
        #expect(f.model.contents.count == 1 && f.model.contentsPreview() == nil)
        f.model.contentsIndex = 5
        #expect(f.model.contentsPreview() == nil)
        // A stroke whose set is gone by the time it is written, and one whose changes are not
        // applied (a recording sink): nothing is selected.
        await f.copy(width: 8)
        await f.model.pasteIn()?.value
        guard case .success(let source) = f.model.source() else { Issue.record("a source"); return }
        let placement = HosePlacement(index: 0, center: Point(x: 5, y: 5), scale: 1, rotation: 0)
        await GraphicHoseTool.spray([placement], from: source, layer: nil, document: f.document, sink: RecordingSink(), selection: f.selection).value
        #expect(f.selection.selection.ids.isEmpty)
        _ = await f.document.perform(DeleteHoseSet(source.set.id)).value
        await GraphicHoseTool.spray([placement], from: source, layer: nil, document: f.document, sink: f.document, selection: f.selection).value
        #expect(f.selection.selection.ids.isEmpty)
    }

    @Test func everyOptionIsWrittenToItsRegister() async throws {
        let f = Fixture()
        defer { f.close() }
        _ = await f.document.perform(CreateHoseSet(name: "Stars")).value
        await f.document.settle()
        let options: [HoseOption] = [.order(.random), .spacing(.grid), .gridSize(48), .spacingAmount(120), .scale(.random), .scalePercent(150),
                                     .rotation(.incremental), .angle(.pi / 4)]
        for option in options { await f.model.setOption(option)?.value }
        let stored = try #require(f.set("Stars")).stored
        #expect(stored.order == .random && stored.spacing == .grid && stored.gridSize == 48 && stored.spacingAmount == 120)
        #expect(stored.scale == .random && stored.scalePercent == 150 && stored.rotation == .incremental && abs(stored.angle - .pi / 4) < 1e-9)
        // The Options view's bindings read the set and write one option each.
        let model = f.model
        #expect(HoseOptionsView.order(model).wrappedValue == .random && HoseOptionsView.spacing(model).wrappedValue == .grid)
        #expect(HoseOptionsView.scale(model).wrappedValue == .random && HoseOptionsView.rotation(model).wrappedValue == .incremental)
        #expect(HoseOptionsView.gridSize(model).wrappedValue == 48 && abs(HoseOptionsView.angle(model).wrappedValue - 45) < 1e-9)
        HoseOptionsView.order(model).wrappedValue = .backAndForth
        HoseOptionsView.spacing(model).wrappedValue = .random
        HoseOptionsView.scale(model).wrappedValue = .uniform
        HoseOptionsView.rotation(model).wrappedValue = .random
        HoseOptionsView.spacingAmount(model).wrappedValue = 500
        HoseOptionsView.scalePercent(model).wrappedValue = 0
        HoseOptionsView.gridSize(model).wrappedValue = 20
        HoseOptionsView.angle(model).wrappedValue = 90
        await f.document.settle()
        #expect(await eventually { f.set("Stars")?.stored.angle ?? 0 > 1.5 })
        let edited = try #require(f.set("Stars")).stored
        #expect(edited.order == .backAndForth && edited.spacing == .random && edited.scale == .uniform && edited.rotation == .random)
        #expect(edited.spacingAmount == 200 && edited.scalePercent == 1 && edited.gridSize == 20, "clamped to the ranges")
        #expect(HoseOptionsView.order(model).wrappedValue == .backAndForth && HoseOptionsView.spacing(model).wrappedValue == .random)
        #expect(HoseOptionsView.rotation(model).wrappedValue == .random && HoseOptionsView.scale(model).wrappedValue == .uniform)
        HoseOptionsView.order(model).wrappedValue = .loop
        HoseOptionsView.spacing(model).wrappedValue = .variable
        HoseOptionsView.rotation(model).wrappedValue = .uniform
        await f.document.settle()
        #expect(await eventually { HoseOptionsView.rotation(model).wrappedValue == .uniform })
        #expect(HoseOptionsView.order(model).wrappedValue == .loop && HoseOptionsView.spacing(model).wrappedValue == .variable)
        // A remote change shows while the sheet is open.
        let revision = f.model.revision
        _ = await f.document.receiveRemote(SetHoseOptions(try #require(f.set("Stars")).id, [.scalePercent(80)]))
        #expect(f.model.revision > revision && HoseOptionsView.scalePercent(model).wrappedValue == 80)
    }

    @Test func libraryHosesAreListedEditedAndCopiedIn() async throws {
        let f = Fixture()
        defer { f.close() }
        await f.document.settle()
        await f.model.restoreDefaults().value
        #expect(f.model.entries.map(\.name) == ["Dots", "Leaves", "Stars"])
        #expect(f.model.choiceName == "Dots", "no document set: the first library hose")
        let dots = try #require(f.model.shown)
        #expect(dots.bundle != nil && !dots.set.objects.isEmpty && f.model.contentsPreview() != nil)
        // Paste In, options and Remove rewrite the bundle.
        await f.copy(width: 12)
        await f.model.pasteIn(from: f.clipboard)?.value
        #expect(f.model.shown?.set.objects.count == dots.set.objects.count + 1)
        await f.model.setOption(.scalePercent(50))?.value
        #expect(f.model.shown?.set.stored.scalePercent == 50)
        f.model.contentsIndex = dots.set.objects.count
        await f.model.removeObject()?.value
        #expect(f.model.shown?.set.objects.count == dots.set.objects.count)
        // Rename, duplicate in the library and into the document.
        f.model.beginNaming(.rename)
        #expect(f.model.location == .library)
        f.model.nameText = "Spots"
        await f.model.commitNaming()?.value
        #expect(f.model.entries.map(\.name) == ["Leaves", "Spots", "Stars"] && f.model.choiceName == "Spots")
        f.model.beginNaming(.duplicate)
        f.model.location = .library
        await f.model.commitNaming()?.value
        #expect(f.model.entries.map(\.name).contains("Spots copy"))
        f.model.beginNaming(.duplicate)
        f.model.location = .document
        f.model.nameText = "Spots here"
        await f.model.commitNaming()?.value
        let here = try #require(f.set("Spots here"))
        #expect(here.libraryID == nil && f.model.choice == .document(here.id))
        // A new library hose, then delete it.
        f.model.beginNaming(.new)
        f.model.location = .library
        f.model.nameText = "Empty"
        await f.model.commitNaming()?.value
        #expect(f.model.choiceName == "Empty" && f.model.shown?.set.objects.isEmpty == true)
        await f.model.delete()?.value
        #expect(!f.model.entries.map(\.name).contains("Empty"))
        // A dropped `.wthose` joins the library; anything else is refused.
        let outside = f.directory.deletingLastPathComponent().appending(path: "Dropped-\(UUID().uuidString).wthose")
        defer { try? FileManager.default.removeItem(at: outside) }
        try HoseDefaults.bundles[1].write(to: outside)
        #expect(f.model.importBundles([URL(fileURLWithPath: "/tmp/notes.txt")]) == nil)
        let count = f.model.entries.count
        await f.model.importBundles([outside])?.value
        #expect(f.model.entries.count == count + 1, "saved under its set's name")
        await f.model.importBundles([f.directory.appending(path: "Missing.wthose")])?.value
        #expect(f.model.failure != nil)
        // The library watcher reports what changes on disk.
        await HoseFeatures.start(f.model).value
        try HoseScratch.renamed(HoseDefaults.bundles[2], to: "Watched").write(to: f.directory.appending(path: "Watched.wthose"))
        #expect(await eventually { f.model.entries.contains { $0.name == "Watched" } })
        await f.model.library.stopWatching()
    }

    @Test func pasteInStopsAtTenObjects() async throws {
        let f = Fixture()
        defer { f.close() }
        _ = await f.document.perform(CreateHoseSet(name: "Full")).value
        await f.copy(width: 5)
        for _ in 0 ..< HoseFields.maximumObjects { await f.model.pasteIn(from: f.clipboard)?.value }
        #expect(f.set("Full")?.objects.count == 10)
        #expect(f.model.pasteIn(from: f.clipboard) == nil && f.model.failure == "A hose holds at most ten objects")
        #expect(f.model.pasteIn() == nil, "no window clipboard")
    }

    @Test func theToolSpraysADocumentSetAsOneSelectedStroke() async throws {
        let f = Fixture()
        defer { f.close() }
        let tool = f.tool()
        #expect(f.host.messages.last == GraphicHoseTool.status && tool.cursor == .crosshair && !tool.hasSomethingToCancel)
        // No hose, then an empty one: the HUD says why.
        tool.mouseDown(f.event(0, 0, time: 0))
        #expect(f.host.messages.last == HoseSourceError.noHose.message && tool.sprayer == nil)
        _ = await f.document.perform(CreateHoseSet(name: "Dots")).value
        await f.document.settle()
        tool.mouseDown(f.event(0, 0, time: 0))
        #expect(f.host.messages.last == HoseSourceError.empty.message)
        await f.copy(width: 10)
        await f.model.pasteIn(from: f.clipboard)?.value
        let before = f.sprayed.count
        await f.spray(tool)
        let sprayed = f.sprayed.count - before
        #expect(sprayed > 1 && f.document.undoTitle == "Undo Spray \(sprayed) objects")
        #expect(f.selection.selection.ids.count == sprayed, "selected as a set")
        // A click places one object.
        tool.mouseDown(f.event(50, 50, time: 2))
        tool.mouseUp(f.event(50, 50, time: 2.1))
        await tool.writing?.value
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Spray object")
        // Arrow keys while spraying; the overlay; Esc.
        #expect(!tool.keyDown(Self.key(123)))
        tool.mouseDown(f.event(0, 0, time: 3))
        #expect(tool.hasSomethingToCancel)
        for code: UInt16 in [123, 124, 125, 126] { #expect(tool.keyDown(Self.key(code))) }
        #expect(!tool.keyDown(Self.key(0)))
        #expect(tool.sprayer?.spacingMultiplier == 1 && tool.sprayer?.scaleMultiplier == 1, "each pair cancels out")
        tool.mouseDragged(f.event(200, 0, time: 3.5))
        tool.flagsChanged(f.event(200, 0, time: 3.5))
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        tool.drawOverlay(in: context, viewport: f.host.viewport)
        tool.cancel()
        tool.drawOverlay(in: context, viewport: f.host.viewport)
        tool.mouseDragged(f.event(300, 0, time: 4))
        tool.mouseUp(f.event(300, 0, time: 4))
        #expect(tool.sprayer == nil)
        tool.deactivate()
        #expect(tool.context == nil)
        // Without a document.
        let lone = GraphicHoseModel(selection: ActiveSelection(), library: HoseLibrary(directory: f.directory))
        guard case .failure(.noDocument) = lone.source() else { Issue.record("a source without a document"); return }
        #expect(HoseSourceError.noDocument.message.contains("document"))
    }

    @Test func sprayingALibraryHoseCopiesItInOnceInTheSameUndoStep() async throws {
        let f = Fixture()
        defer { f.close() }
        await f.document.settle()
        await f.model.restoreDefaults().value
        f.model.choose(.library(try #require(f.model.entries.first { $0.name == "Stars" }).url))
        let tool = f.tool()
        await f.spray(tool)
        let stars = HoseSets.list(in: f.state)
        #expect(stars.count == 1 && stars[0].libraryID != nil && f.document.undoTitle.hasPrefix("Undo Spray"))
        let first = f.sprayed.count
        await f.spray(tool, length: 200)
        #expect(HoseSets.list(in: f.state).count == 1, "the copy is reused")
        #expect(f.model.shown?.bundle == nil, "the library hose shows the document's copy")
        // One undo takes back the stroke; the first stroke's undo takes the copy with it.
        _ = await f.document.undo().value
        await f.document.settle()
        #expect(f.sprayed.count == first && HoseSets.list(in: f.state).count == 1)
        _ = await f.document.undo().value
        await f.document.settle()
        #expect(f.sprayed.isEmpty && HoseSets.list(in: f.state).isEmpty)
    }

    @Test func theSheetRendersAndItsControlsAct() async throws {
        let f = Fixture()
        defer { f.close() }
        _ = await f.document.perform(CreateHoseSet(name: "Dots")).value
        await f.copy(width: 10)
        await f.model.pasteIn(from: f.clipboard)?.value
        var dismissed = 0
        PanelRendering.host(GraphicHoseSheet(model: f.model) { dismissed += 1 })
        f.model.beginNaming(.new)
        PanelRendering.host(GraphicHoseSheet(model: f.model) {})
        f.model.beginNaming(.rename)
        PanelRendering.host(HoseNamingView(model: f.model))
        f.model.cancelNaming()
        f.model.page = .options
        PanelRendering.host(GraphicHoseSheet(model: f.model) {})
        await f.model.setOption(.spacing(.grid))?.value
        PanelRendering.host(HoseOptionsView(model: f.model))
        #expect(GraphicHoseModel.Page.allCases.map(\.title) == ["Hose", "Options"])
        #expect(GraphicHoseModel.Location.allCases.map(\.title) == ["In this document", "In my library"])
        let empty = GraphicHoseModel(selection: ActiveSelection(), library: HoseLibrary(directory: f.directory))
        PanelRendering.host(GraphicHoseSheet(model: empty) {})
        PanelRendering.host(HoseOptionsView(model: empty))
        #expect(HoseOptionsView.options(empty) == HoseSprayOptions())
        // The closures.
        let set = try #require(f.set("Dots"))
        GraphicHoseSheet.choosing(.document(set.id), f.model)()
        GraphicHoseSheet.naming(.duplicate, f.model)()
        #expect(f.model.naming == .duplicate && f.model.choice == .document(set.id))
        f.model.cancelNaming()
        let contents = HoseSetView.contents(f.model)
        contents.wrappedValue = 0
        #expect(contents.wrappedValue == 0)
        #expect(!GraphicHoseSheet.dropping(f.model)([]))
        #expect(GraphicHoseSheet.dropping(f.model)([NSItemProvider(object: "text" as NSString)]))
        _ = await eventually(.milliseconds(200)) { false }
        HoseSetView.pasting(f.model)()
        await f.document.settle()
        #expect(await eventually { f.set("Dots")?.objects.count == 2 })
        await f.model.setOption(.spacing(.random))?.value
        PanelRendering.host(HoseOptionsView(model: f.model))
        let outside = f.directory.deletingLastPathComponent().appending(path: "Sheet-\(UUID().uuidString).wthose")
        defer { try? FileManager.default.removeItem(at: outside) }
        try HoseDefaults.bundles[0].write(to: outside)
        #expect(GraphicHoseSheet.dropping(f.model)([NSItemProvider(contentsOf: outside)!]))
        #expect(await eventually { f.model.entries.contains { $0.name == HoseDefaults.bundles[0].name } })
        // The tool's descriptor and sheet.
        let descriptor = HoseFeatures.descriptor(model: f.model)
        #expect(descriptor.id == GraphicHoseTool.id)
        #expect(descriptor.make() is GraphicHoseTool)
        let controller = try #require(descriptor.options?())
        #expect(controller.title == "Graphic Hose")
        let window = TestWindow.make(contentViewController: controller)
        (controller as? NSHostingController<GraphicHoseSheet>)?.rootView.dismiss()
        window.close()
        #expect(dismissed == 0)
    }
}
