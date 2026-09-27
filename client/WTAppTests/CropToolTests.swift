import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// IMG-025: the Crop tool, Remove Crop, and the Object panel's crop fields.
@Suite(.serialized) @MainActor struct CropToolTests {
    /// A 40 × 20 pixel image scaled to 200 × 100 points at the origin, selected, and a Crop tool on it.
    static func world() async throws -> (HandleWorld, OpID, CropTool) {
        let world = HandleWorld()
        let image = try await HandleWorld.place(in: world.document)
        _ = await world.document.perform(TransformObjects([image], matrix: .scale(5), about: .zero, kind: .scale)).value
        await world.settle()
        world.select([image])
        let tool = CropTool()
        tool.activate(in: world.context)
        return (world, image, tool)
    }

    static func handle(_ handle: ImageCropping.Handle, _ world: HandleWorld, _ image: OpID, _ tool: CropTool) -> Point {
        let (natural, transform) = CropTool.frame(of: image, in: world.state)!
        return CropTool.point(handle, crop: tool.crop(of: image, in: world.state), natural: natural, transform: transform)
    }

    static func drag(_ tool: CropTool, _ world: HandleWorld, from: Point, to: Point, _ modifiers: KeyModifiers = []) async {
        tool.mouseDown(world.event(from.x, from.y))
        tool.mouseDragged(world.event((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
        tool.drawOverlay(in: world.bitmap(), viewport: world.context.viewport)
        tool.mouseUp(world.event(to.x, to.y, modifiers))
        await world.settle()
    }

    static func crop(_ world: HandleWorld, _ image: OpID) -> Rect { ImageCropping.crop(of: image, in: world.state)! }

    static func close(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    @Test func eachHandleCropsInOneChangeNamedAfterTheImage() async throws {
        let (world, image, tool) = try await Self.world()
        #expect(tool.target == image && tool.cursor == .crosshair && tool.hasSomethingToCancel)
        tool.drawOverlay(in: world.bitmap(), viewport: world.context.viewport)
        let before = world.document.changeCount
        await Self.drag(tool, world, from: Self.handle(.left, world, image, tool), to: Point(x: 20, y: 50))
        #expect(Self.close(Self.crop(world, image), Rect(x: 0.1, y: 0, width: 0.9, height: 1)))
        #expect(world.document.changeCount == before + 1 && world.document.undoTitle == "Undo Crop photo.png")
        await Self.drag(tool, world, from: Self.handle(.top, world, image, tool), to: Point(x: 100, y: 10))
        await Self.drag(tool, world, from: Self.handle(.right, world, image, tool), to: Point(x: 180, y: 50))
        await Self.drag(tool, world, from: Self.handle(.bottom, world, image, tool), to: Point(x: 100, y: 90))
        #expect(Self.close(Self.crop(world, image), Rect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        for handle in [ImageCropping.Handle.topLeft, .topRight, .bottomRight, .bottomLeft] {
            let at = Self.handle(handle, world, image, tool)
            let inward = Point(x: at.x + (handle.unit.x == 0 ? 10 : -10), y: at.y + (handle.unit.y == 0 ? 5 : -5))
            await Self.drag(tool, world, from: at, to: inward)
        }
        #expect(Self.close(Self.crop(world, image), Rect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)))
        // Never beyond the picture's edge.
        await Self.drag(tool, world, from: Self.handle(.left, world, image, tool), to: Point(x: -100, y: 50))
        #expect(Self.crop(world, image).minX == 0)
        // The bounds are the visible part.
        #expect(Objects.bounds(of: image, in: world.state)?.minX == 0)
    }

    @Test func shiftKeepsProportionsAndOptionIsSymmetric() async throws {
        let (world, image, tool) = try await Self.world()
        await Self.drag(tool, world, from: Self.handle(.bottomRight, world, image, tool), to: Point(x: 150, y: 90), .shift)
        let proportional = Self.crop(world, image)
        #expect(abs(proportional.width - proportional.height) < 1e-6 && abs(proportional.width - 0.9) < 1e-6)
        _ = await world.document.perform(CropImage([image], crop: nil)).value
        await world.settle()
        await Self.drag(tool, world, from: Self.handle(.left, world, image, tool), to: Point(x: 20, y: 50), .option)
        #expect(Self.close(Self.crop(world, image), Rect(x: 0.1, y: 0, width: 0.8, height: 1)))
    }

    @Test func draggingInsideSlidesThePictureBehindTheCrop() async throws {
        let (world, image, tool) = try await Self.world()
        _ = await world.document.perform(CropImage([image], crop: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))).value
        await world.settle()
        let bounds = try #require(Objects.bounds(of: image, in: world.state))
        await Self.drag(tool, world, from: Point(x: 100, y: 50), to: Point(x: 120, y: 50))
        // The picture moved right under a fixed window: the crop moved left over it.
        #expect(Self.close(Self.crop(world, image), Rect(x: 0.15, y: 0.25, width: 0.5, height: 0.5)))
        let after = try #require(Objects.bounds(of: image, in: world.state))
        #expect(abs(after.minX - bounds.minX) < 1e-6 && abs(after.minY - bounds.minY) < 1e-6, "the visible part stays in place")
        #expect(world.document.undoTitle == "Undo Crop photo.png")
        // A press that does not move writes nothing.
        let count = world.document.changeCount
        tool.mouseDown(world.event(100, 50))
        tool.mouseUp(world.event(100, 50))
        await world.settle()
        #expect(world.document.changeCount == count)
    }

    @Test func clicksChooseTheImageAndReturnOrEscFinish() async throws {
        let (world, image, tool) = try await Self.world()
        // A click on the pasteboard drops the target; a click on the image takes it again.
        tool.mouseDown(world.event(500, 500))
        #expect(tool.target == nil && world.selection.selection.ids.isEmpty)
        tool.drawOverlay(in: world.bitmap(), viewport: world.context.viewport)
        tool.mouseDown(world.event(100, 50))
        #expect(tool.target == image && world.selection.selection.ids.map(\.opID) == [image])
        tool.mouseDragged(world.event(0, 0))
        tool.mouseUp(world.event(0, 0))
        // Esc abandons a drag, then finishes.
        var selected: [ToolID] = []
        var context = world.context
        context.selectTool = { selected.append($0) }
        let finishing = CropTool()
        world.select([image])
        finishing.activate(in: context)
        finishing.mouseDown(world.event(100, 50))
        #expect(finishing.drag != nil)
        finishing.cancel()
        #expect(finishing.drag == nil && selected.isEmpty)
        finishing.cancel()
        #expect(selected == [.pointer])
        let key = { (code: UInt16) in
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
        }
        #expect(finishing.keyDown(key(36)) && selected == [.pointer, .pointer])
        #expect(!finishing.keyDown(key(0)))
        finishing.flagsChanged(world.event(0, 0))
        finishing.deactivate()
        #expect(finishing.target == nil && !finishing.hasSomethingToCancel)
        finishing.mouseDown(world.event(0, 0))
        finishing.mouseDragged(world.event(0, 0))
        finishing.mouseUp(world.event(0, 0))
        #expect(!finishing.keyDown(key(36)))
        finishing.cancel()
        finishing.drawOverlay(in: world.bitmap(), viewport: world.context.viewport)
        #expect(CropTool.frame(of: OpID(counter: 999, replica: 9), in: world.state) == nil)
        #expect(!tool.isInside(.zero, node: OpID(counter: 999, replica: 9), state: world.state))
        #expect(tool.handle(at: .zero, node: OpID(counter: 999, replica: 9), context: world.context) == nil)
    }

    @Test func removeCropAndTheObjectMenuCommands() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let image = try await HandleWorld.place(in: world.document)
        world.window.selection.model.set(Selection([SelectionID(image)]))
        let commands = CropFeatures.commands { [weak window = world.window] in window }
        let remove = try #require(commands.first { $0.id == CropFeatures.removeCropID })
        #expect(!remove.validation().isEnabled, "nothing cropped")
        _ = await world.document.perform(CropImage([image], crop: Rect(x: 0, y: 0, width: 0.5, height: 1))).value
        await world.settle()
        #expect(remove.validation().isEnabled)
        if case .perform(let run) = remove.action { run() }
        await world.settle()
        #expect(!ImageCropping.isCropped(image, in: world.state) && world.document.undoTitle == "Undo Remove Crop")
        let crop = try #require(commands.first { $0.id == ContextMenuCatalog.ID.imageCrop })
        #expect(crop.validation().isEnabled)
        if case .perform(let run) = crop.action { run() }
        #expect(world.window.toolManager.activeToolID == CropTool.id)
        let none = CropFeatures.commands { nil }
        #expect(none.allSatisfy { !$0.validation().isEnabled })
        for command in none { if case .perform(let run) = command.action { run() } }
    }

    @Test func thePanelsCropFieldsTakePixelsAndReset() async throws {
        let (world, image, _) = try await Self.world()
        let panel = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(image)]))
        let model = try #require(ImageSectionModel(panel))
        #expect(model.resetCrop() == nil)
        panel.perform(model.setCrop(10, field: 0))
        await world.settle()
        let left = try #require(ImageSectionModel(panel))
        #expect(left.one?.cropPixels == Rect(x: 10, y: 0, width: 30, height: 20) && world.document.undoTitle == "Undo Crop photo.png")
        panel.perform(left.setCrop(5, field: 1))
        await world.settle()
        panel.perform(try #require(ImageSectionModel(panel)).setCrop(20, field: 2))
        await world.settle()
        panel.perform(try #require(ImageSectionModel(panel)).setCrop(10, field: 3))
        await world.settle()
        #expect(ImageSectionModel(panel)?.one?.cropPixels == Rect(x: 10, y: 5, width: 20, height: 10))
        #expect(ImageSectionModel(panel)?.setCrop(1000, field: 0) == nil, "no area inside the picture")
        panel.perform(try #require(ImageSectionModel(panel)).resetCrop())
        await world.settle()
        #expect(!ImageCropping.isCropped(image, in: world.state) && world.document.undoTitle == "Undo Remove Crop")
    }
}
