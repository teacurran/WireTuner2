import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A one-page PDF with a filled square, as drawing applications put on the pasteboard.
@MainActor
func squarePDF() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 50, height: 40)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// The import pointer (IMG-005): click and marquee placement, the counter, kbd:[Return] and
/// kbd:[Esc]; and pasting images, PDF data and files.
@Suite(.serialized) @MainActor struct ImportPointerTests {
    static let returnKey = TestEvents.key("\r", keyCode: 36)

    func transform(_ world: ImportWorld, _ node: OpID) -> Wiretuner_Doc_V1_Transform {
        let props = world.state.props(node)
        if case .image(let image)? = props.kind { return image.common.transform }
        return props.group.common.transform
    }

    @Test func thePointerCountsTheFilesAndWorksOutClicksAndMarquees() throws {
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.svg")
        var pointer = ImportPointer(files: [a, b])
        #expect(pointer.counter == "1 of 2" && pointer.label == "1 of 2  a.png" && pointer.remaining == [a, b])
        #expect(pointer.marquee == nil && !pointer.isDragging)
        let unpressed = pointer.release(at: .zero, view: .zero)
        #expect(unpressed == nil, "nothing pressed")
        // A press that barely moves is a click: the top-left corner at the press.
        pointer.begin(at: Point(x: 10, y: 20), view: Point(x: 10, y: 20), modifiers: [])
        #expect(pointer.isDragging)
        let released = pointer.release(at: Point(x: 11, y: 21), view: Point(x: 11, y: 21))
        let click = try #require(released)
        #expect(click.file == a && click.placement == .at(Point(x: 10, y: 20)))
        #expect(pointer.counter == "2 of 2" && pointer.label == "2 of 2  b.svg" && pointer.next == b)
        // A drag fits the marquee; Shift fills its width; Option draws it from the centre.
        pointer.begin(at: Point(x: 50, y: 50), view: Point(x: 50, y: 50), modifiers: [.shift, .option])
        pointer.pointer = Point(x: 70, y: 60)
        #expect(pointer.marquee == Rect(x: 30, y: 40, width: 40, height: 20))
        let dragged = pointer.release(at: Point(x: 70, y: 60), view: Point(x: 70, y: 60))
        let drag = try #require(dragged)
        #expect(drag.file == b && drag.placement == .fit(Rect(x: 30, y: 40, width: 40, height: 20), fillWidth: true))
        #expect(pointer.isFinished && pointer.counter == nil && pointer.label == "")
        #expect(ImportPointer.marquee(from: Point(x: 5, y: 5), to: Point(x: 1, y: 9), fromCenter: false) == Rect(x: 1, y: 5, width: 4, height: 4))
        // A drag along one axis has no area: a click at the press.
        var flat = ImportPointer(files: [a])
        flat.begin(at: .zero, view: .zero, modifiers: [])
        let flatRelease = flat.release(at: Point(x: 30, y: 0), view: Point(x: 30, y: 0))
        #expect(flatRelease?.placement == .at(.zero))
        #expect(ImportPointer(files: [a]).counter == nil && ImportPointer(files: [a]).label == "a.png")
        var rest = ImportPointer(files: [a, b])
        let taken = rest.takeRemaining()
        #expect(taken == [a, b] && rest.isFinished)
        var stopped = ImportPointer(files: [a, b])
        stopped.stop()
        #expect(stopped.isFinished && stopped.remaining.isEmpty)
    }

    @Test func clicksPlaceAtNaturalSizeAndMarqueesFitThenThePointerPops() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let png = world.files.png()
        world.imports.runPanel = { _, _ in [png, png, png, png] }
        let manager = world.window.toolManager!
        let tool = try #require(await world.imports.runImport(on: world.window))
        #expect(manager.activeToolID == ImportPointerTool.id && manager.isTemporary && tool.hasSomethingToCancel)
        #expect(world.window.statusBar.message.stringValue == ImportPointerTool.statusMessage && tool.cursor == .crosshair)
        manager.pointerMoved(TestEvents.point(5, 5))
        #expect(tool.pointer.pointer == Point(x: 5, y: 5))
        // Click: 20 × 10 px at 72 ppi, its top-left corner at the click.
        manager.mouseDown(TestEvents.point(100, 50))
        manager.mouseUp(TestEvents.point(100, 50))
        await tool.placing?.value
        let first = try #require(world.objects.last)
        #expect(transform(world, first).tx == 100 && transform(world, first).ty == 50 && transform(world, first).a == 1)
        #expect(world.window.selection.selection.ids.map(\.opID) == [first])
        // Drag a 40 × 40 marquee: scaled by 2 to 40 × 20, centred in it.
        manager.mouseDown(TestEvents.point(0, 0))
        manager.mouseDragged(TestEvents.point(40, 40))
        manager.flagsChanged([])
        manager.mouseUp(TestEvents.point(40, 40))
        await tool.placing?.value
        let second = try #require(world.objects.last)
        #expect(transform(world, second).a == 2 && transform(world, second).tx == 0 && transform(world, second).ty == 10)
        // Shift fills the marquee's width from its top-left corner.
        manager.mouseDown(TestEvents.point(0, 0, [.shift]))
        manager.mouseUp(TestEvents.point(60, 5, [.shift]))
        await tool.placing?.value
        let third = try #require(world.objects.last)
        #expect(transform(world, third).a == 3 && transform(world, third).tx == 0 && transform(world, third).ty == 0)
        #expect(tool.pointer.counter == "4 of 4")
        // Keys other than Return reach the shortcuts.
        #expect(!tool.keyDown(TestEvents.key("x", keyCode: 7)))
        // The last file: the pointer pops and the previous tool is back.
        manager.mouseDown(TestEvents.point(200, 200))
        manager.mouseUp(TestEvents.point(200, 200))
        #expect(manager.activeToolID == .pointer && !manager.isTemporary && manager.pushedTool == nil)
        await tool.placing?.value
        #expect(world.objects.count == 4)
        // Released twice (a stray mouse-up), or Esc after the end: nothing more happens.
        tool.mouseUp(TestEvents.point(0, 0))
        tool.cancel()
        #expect(world.objects.count == 4)
    }

    @Test func escapeStopsTheRestAndReturnStacksThemFromThePointer() async throws {
        let world = ImportWorld()
        defer { world.close() }
        _ = world.environment.preferences.set(12, for: PreferenceCatalog.Sync.keepBothOffset)
        let png = world.files.png()
        let svg = world.files.text("shape.svg", ImportFiles.staticSVG)
        let manager = world.window.toolManager!
        // Three files; Esc after the second.
        let three = world.imports.beginPlacing([png, svg, png], on: world.window)
        #expect(three.pointer.label == "1 of 3  photo.png")
        for x in [10.0, 80.0] {
            manager.mouseDown(TestEvents.point(x, 10))
            manager.mouseUp(TestEvents.point(x, 10))
        }
        #expect(three.pointer.label == "3 of 3  photo.png")
        #expect(manager.keyDown(TestEvents.escape))
        await three.placing?.value
        #expect(world.objects.count == 2 && manager.activeToolID == .pointer && !three.hasSomethingToCancel)
        #expect(world.document.undoTitle == "Undo Import shape.svg")

        // Return places every remaining file stacked from the pointer by the Keep both offset.
        let rest = world.imports.beginPlacing([png, png, png], on: world.window)
        manager.mouseDown(TestEvents.point(0, 0))
        manager.mouseUp(TestEvents.point(0, 0))
        manager.pointerMoved(TestEvents.point(200, 100))
        #expect(manager.keyDown(Self.returnKey))
        #expect(manager.activeToolID == .pointer)
        await rest.placing?.value
        let placed = world.objects.suffix(2)
        #expect(placed.map { transform(world, $0).tx } == [200, 212] && placed.map { transform(world, $0).ty } == [100, 112])
        #expect(world.objects.count == 5)

        // Without a pointer position, Return stacks them from the view's centre.
        let viewport = world.window.canvas.viewport
        let centre = viewport.toPasteboard(viewport.viewCenter)
        let centred = world.imports.beginPlacing([png], on: world.window)
        centred.placeRemaining()
        await centred.placing?.value
        #expect(transform(world, world.objects.last!).tx == centre.x && transform(world, world.objects.last!).ty == centre.y)
    }

    @Test func thePushedPointerGivesWayToAChosenToolAndDrawsItsBracketAndMarquee() throws {
        let world = ImportWorld()
        defer { world.close() }
        let png = world.files.png()
        let manager = world.window.toolManager!
        let tool = world.imports.beginPlacing([png, png], on: world.window)
        // Command pushes nothing while the pointer is up; releasing it keeps the pointer too.
        manager.flagsChanged(.command)
        manager.flagsChanged([])
        #expect(manager.activeToolID == ImportPointerTool.id)
        // Space waits too.
        #expect(manager.keyDown(TestEvents.space) && manager.keyUp(TestEvents.spaceUp))
        #expect(manager.activeToolID == ImportPointerTool.id)
        // Popping another tool does nothing.
        manager.pop(RecordingTool(id: "other"))
        #expect(manager.pushedTool === tool)

        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        tool.drawOverlay(in: context, viewport: world.window.canvas.viewport)
        manager.pointerMoved(TestEvents.point(30, 30))
        manager.mouseDown(TestEvents.point(30, 30))
        manager.mouseDragged(TestEvents.point(90, 70))
        world.window.canvas.drawOverlay(in: context)
        #expect(tool.pointer.marquee == Rect(x: 30, y: 30, width: 60, height: 40))

        // Choosing a tool in the Tools panel ends the import.
        manager.select("rectangle")
        #expect(manager.activeToolID == "rectangle" && manager.pushedTool == nil && tool.pointer.isFinished)
        tool.drawOverlay(in: context, viewport: world.window.canvas.viewport)

        // A tool never activated stacks from the pasteboard's origin.
        var stacked: [([URL], Point)] = []
        let loose = ImportPointerTool(files: [png], place: { _, _ in }, placeAll: { stacked.append(($0, $1)) })
        loose.placeRemaining()
        loose.deactivate()
        #expect(loose.pointer.isFinished)
    }

    @Test func theAppWiresPastingAndTheMissingFontsSheet() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        let paste = try #require(window.environment.pasteImport)
        // Paste imports files, images and PDF data, or the richer clipboard formats (SVG, rich and
        // plain text) the Edit menu takes (OBJ-015).
        #expect(paste.canPaste() == (delegate.imports.canPaste(from: .general) || delegate.editMenu.takesPaste(from: .general)))
        paste.paste(window)
        #expect(delegate.toolPalette.coloring != nil && delegate.fonts.team == nil)
        #expect(await eventually { delegate.fonts.index(for: window.documentHandle.id) != nil })
        delegate.fonts.closeDocument(window)
        #expect(await eventually { delegate.fonts.index(for: window.documentHandle.id) == nil })
    }

    @Test func pastingImportsImageDataPDFDataAndFiles() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.paste.\(UUID().uuidString)"))
        let world = ImportWorld(pasteboard: pasteboard)
        defer { world.close() }
        // No objects copied by another test.
        (world.window.objectEditing.pasteboard as? SystemObjectPasteboard)?.pasteboard.clearContents()
        world.window.objectEditing.visibleCenter = { Point(x: 300, y: 200) }
        let png = world.files.png()

        pasteboard.clearContents()
        #expect(!world.imports.canPaste(from: pasteboard))
        #expect(await world.imports.paste(from: pasteboard, on: world.window) == ImportOutcome())
        #expect(!world.window.validate(selector: #selector(DocumentWindowController.paste(_:))))

        // A screenshot: image data, centred in the view, named "Pasted", with no link record.
        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: png), forType: .png)
        #expect(world.imports.canPaste(from: pasteboard) && world.window.validate(selector: #selector(DocumentWindowController.paste(_:))))
        world.window.paste(nil)
        #expect(await eventually { world.objects.count == 1 })
        let image = world.state.props(world.objects[0]).image
        #expect(image.common.name == ImportController.pastedName && image.pixels.pixelWidth == 20 && !image.hasSource)
        #expect(image.common.transform.tx == 290 && image.common.transform.ty == 195)

        // PDF data is converted to paths, preferred over an image beside it.
        pasteboard.clearContents()
        pasteboard.setData(squarePDF(), forType: .pdf)
        pasteboard.setData(try Data(contentsOf: png), forType: .png)
        let pdf = await world.imports.paste(from: pasteboard, on: world.window, at: Point(x: 5, y: 6))
        let group = world.state.props(try #require(pdf.placed.first)).group
        #expect(group.common.name == ImportController.pastedName && group.common.transform.tx == 5)

        // Copied files are placed as a drop places them.
        pasteboard.clearContents()
        pasteboard.writeObjects([png as NSURL])
        #expect(world.imports.canPaste(from: pasteboard))
        #expect(await world.imports.paste(from: pasteboard, on: world.window).placed.count == 1)

        // Image data that does not decode is named in the alert.
        pasteboard.clearContents()
        pasteboard.setData(Data("not a png".utf8), forType: .png)
        let broken = await world.imports.paste(from: pasteboard, on: world.window)
        #expect(broken.placed.isEmpty && broken.failures.count == 1 && world.alerts.count == 1)
        #expect(ImportController.isPastable("public.jpeg") && ImportController.isPastable("com.adobe.pdf") && !ImportController.isPastable("public.utf8-plain-text"))

        // WireTuner objects on the pasteboard are pasted as objects, not imported.
        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: png), forType: .png)
        world.window.selection.model.set(Selection([SelectionID(world.objects[0])]))
        world.window.objectEditing.copy()
        let count = world.objects.count
        world.window.paste(nil)
        #expect(await eventually { world.objects.count == count + 1 })
        #expect(world.state.props(world.objects.last!).image.common.name == ImportController.pastedName)
        (world.window.objectEditing.pasteboard as? SystemObjectPasteboard)?.pasteboard.clearContents()
        // A failure that is not the importer's is named with its reason.
        world.imports.blobs.directory = { throw CocoaError(.fileNoSuchFile) }
        let unstored = await world.imports.place([png], on: world.window, at: .zero)
        #expect(unstored.failures.count == 1 && unstored.failures[0].hasPrefix("“photo.png” could not be imported:"))
        let plain = ImportWorld()
        defer { plain.close() }
        plain.window.paste(nil)
        #expect(!plain.window.validate(selector: #selector(DocumentWindowController.paste(_:))))
    }
}
