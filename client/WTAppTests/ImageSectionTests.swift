import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// IMG-016: the Object panel's image section, the gray ramp sheet and Image Info.
@Suite(.serialized) @MainActor struct ImageSectionTests {
    /// An image of `mode` (with alpha when asked) placed at 144 ppi, 300 × 150 pixels.
    static func place(_ document: DocumentHandle, mode: Wiretuner_Doc_V1_ColorMode = .grayscale, alpha: Bool = true) async throws -> OpID {
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(repeating: 0xCD, count: 32)
        pixels.format = "public.png"
        pixels.pixelWidth = 300
        pixels.pixelHeight = 150
        pixels.mode = mode
        pixels.bitsPerChannel = 8
        pixels.hasAlpha_p = alpha
        let node = try #require(await document.perform(PlaceImage(pixels, name: "scan.png", dpiX: 144, dpiY: 144)).value?.createdObjects.first)
        await document.settle()
        return node
    }

    static func model(_ world: TypeWorld, _ nodes: [OpID]) throws -> ImageSectionModel {
        try #require(ImageSectionModel(ObjectPanelModel(document: world.document, selection: Selection(nodes.map { SelectionID($0) }))))
    }

    static func run(_ world: TypeWorld, _ command: (any WTModel.Command)?) async throws -> String? {
        let command = try #require(command)
        _ = await world.document.perform(command).value
        await world.settle()
        return world.document.undoTitle
    }

    @Test func eachControlWritesOneChangeWithItsUndoTitle() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let image = try await Self.place(world.document)
        let model = try Self.model(world, [image])
        #expect(model.kindLabel == "Image (Grayscale)" && model.showsAlpha && model.showsGray && model.one?.file == "scan.png")
        #expect(model.effectivePPI == 144 && !model.warns(below: 144) && model.warns(below: 150))
        #expect(try await Self.run(world, model.setDisplayAlpha(false)) == "Undo Hide Alpha Channel")
        #expect(try Self.model(world, [image]).displayAlpha == .off)
        #expect(try await Self.run(world, model.setTransparent(true)) == "Undo Transparent")
        #expect(try Self.model(world, [image]).transparent == .on)
        #expect(try await Self.run(world, model.setStored(300, horizontal: true, locked: true)) == "Undo Set Resolution")
        #expect(world.state.props(image).image.dpiX == 300 && world.state.props(image).image.dpiY == 300)
        _ = try await Self.run(world, model.setStored(150, horizontal: false, locked: false))
        #expect(world.state.props(image).image.dpiY == 150 && world.state.props(image).image.dpiX == 300)
        _ = try await Self.run(world, model.setStored(200, horizontal: true, locked: false))
        #expect(world.state.props(image).image.dpiX == 200)
        #expect(model.setStored(0, horizontal: true, locked: true) == nil)
        #expect(try await Self.run(world, try Self.model(world, [image]).setScale(50, locked: true)) == "Undo Scale")
        #expect(try Self.model(world, [image]).one?.scaleX == 0.5)
        _ = try await Self.run(world, try Self.model(world, [image]).setScale(100, horizontal: false, locked: false))
        #expect(try Self.model(world, [image]).one?.scaleY == 1 && Self.model(world, [image]).one?.scaleX == 0.5)
        _ = try await Self.run(world, try Self.model(world, [image]).setSize(100, width: true, locked: true))
        #expect(abs(try #require(try Self.model(world, [image]).one?.placedSize.width) - 100) < 1e-6)
        #expect(try Self.model(world, [image]).setScale(0, locked: true) == nil)
        let red = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
        #expect(try await Self.run(world, model.setTint(red)) == "Undo Tint")
        #expect(try Self.model(world, [image]).shared(\.tint) == red)
        #expect(try await Self.run(world, model.setTint(ColorResolver.none)) == "Undo Remove Tint")
        // Undo takes them back one at a time.
        _ = await world.document.undo().value
        await world.settle()
        #expect(try Self.model(world, [image]).shared(\.tint) == red)
    }

    @Test func controlsAreHiddenByModeAndMixedAcrossImages() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let rgb = try await Self.place(world.document, mode: .rgb, alpha: false)
        let gray = try await Self.place(world.document)
        let one = try Self.model(world, [rgb])
        #expect(!one.showsGray && !one.showsAlpha && one.kindLabel == "Image (RGB)")
        let both = try Self.model(world, [rgb, gray])
        #expect(both.one == nil && both.kindLabel == "Images" && !both.showsGray && !both.showsAlpha && both.infoLines().isEmpty)
        _ = try await Self.run(world, SetImageSetting([gray], .transparentBackground(true)))
        #expect(try Self.model(world, [rgb, gray]).transparent == .mixed)
        #expect(both.setCrop(10, field: 0) == nil)
        // A panel over something else has no image section.
        let rect = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        #expect(ImageSectionModel(ObjectPanelModel(document: world.document, selection: Selection([rect, SelectionID(rgb)]))) == nil)
        for model in [one, both, try Self.model(world, [gray])] { PanelRendering.host(ImageSectionView(model: model)) }
        #expect(ImageSectionView.toggle(.on) { _ in }.wrappedValue)
    }

    @Test func theRampSheetAppliesKeepsAndCancels() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let image = try await Self.place(world.document)
        let sheet = RampSheetModel(document: world.document, nodes: [image], ramp: .normal)
        let before = world.document.changeCount
        #expect(sheet.apply() == nil, "nothing changed")
        sheet.choose(.inverted)
        #expect(sheet.levels.first == 255)
        _ = await sheet.apply()?.value
        await world.settle()
        #expect(world.document.changeCount == before + 1 && world.document.undoTitle == "Undo Edit Ramp")
        #expect(ImageNodes.ramp(world.state.props(image).image.ramp).preset == .inverted)
        sheet.adjust(lightness: 20)
        #expect(sheet.ramp == GrayRamp(preset: .custom, lightness: 20, contrast: 0))
        sheet.adjust(contrast: -10)
        RampSheetView.lightness(sheet).wrappedValue = 30
        RampSheetView.contrast(sheet).wrappedValue = 5
        RampSheetView.preset(sheet).wrappedValue = .custom
        #expect(sheet.ramp == GrayRamp(preset: .custom, lightness: 30, contrast: 5) && RampSheetView.lightness(sheet).wrappedValue == 30)
        // Cancel puts back the ramp the image had when the sheet opened.
        _ = await sheet.cancel()?.value
        await world.settle()
        #expect(ImageNodes.ramp(world.state.props(image).image.ramp).effectivePreset == .normal && sheet.ramp == .normal)
        sheet.choose(.darken)
        sheet.reset()
        #expect(sheet.ramp == .normal && RampSheetView.preset(sheet).wrappedValue == .normal)
        PanelRendering.host(RampSheetView(model: sheet, close: {}))
        let state = ImageSectionState()
        ImageSectionView.openRamp(try Self.model(world, [image]), state)()
        #expect(state.ramp?.nodes == [image] && state.ramp?.id != nil)
    }

    @Test func imageInfoListsThePictureAndTheMenuItemShowsIt() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let image = try await Self.place(world.document)
        ImageSection.author = { _, _ in "Priya" }
        defer { ImageSection.author = { _, _ in nil } }
        let lines = try Self.model(world, [image]).infoLines()
        #expect(lines.contains { $0 == ("Format", "public.png") } && lines.contains { $0 == ("Placed by", "Priya") })
        PanelRendering.host(ImageInfoView(lines: lines))
        var shown = 0
        ImageSection.showPopover = { _, _, _ in shown += 1 }
        let command = try #require(ImageSection.commands { world.window }.first)
        #expect(!command.validation().isEnabled, "no image selected")
        #expect(ImageSection.showInfo(in: world.window) == nil)
        world.window.selection.model.set(Selection([SelectionID(image)]))
        #expect(command.validation().isEnabled)
        if case .perform(let run) = command.action { run() }
        #expect(shown == 1)
        _ = ImageSection.commands { nil }.first.map { command in if case .perform(let run) = command.action { run() } }
        // btn:[Links…] runs menu:Edit[Links…].
        var ran: [CommandID] = []
        ImageSection.perform = { ran.append($0) }
        defer { ImageSection.perform = { _ in } }
        ImageSection.perform("edit.links")
        #expect(ran == ["edit.links"])
        let registry = InspectorRegistry()
        ImageSection.register(into: registry)
        #expect(registry.sections.contains { $0.id == "image" })
        #expect(ImageSection.threshold() > 0)
    }

    @Test func theEffectiveValueFollowsARemoteScale() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let image = try await Self.place(world.document)
        #expect(try Self.model(world, [image]).effectivePPI == 144)
        // Another replica scales the image: the panel reads the document on every render.
        let scale = Ops.set(image, [ImageFields.transform], values: ImageFields.values { $0.common.transform.a = 2; $0.common.transform.d = 2 })
        _ = await world.document.receive(remoteChange([scale])).value
        await world.settle()
        #expect(try Self.model(world, [image]).effectivePPI == 72)
    }

    @Test func everyFieldAndButtonOfTheViewWrites() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let image = try await Self.place(world.document)
        let values: [ImageSectionView.Field: Double] = [.stored: 200, .storedVertical: 100, .scale: 50, .width: 60, .height: 40,
                                                        .cropLeft: 10, .cropTop: 10, .cropWidth: 100, .cropHeight: 50]
        let state = ImageSectionState()
        state.resolutionLocked = false
        state.scaleLocked = false
        for field in ImageSectionView.Field.allCases {
            let before = world.document.changeCount
            ImageSectionView.commit(try Self.model(world, [image]), state, field)(values[field]!)
            await world.settle()
            #expect(world.document.changeCount == before + 1, "\(field)")
        }
        ImageSectionView.resettingCrop(try Self.model(world, [image]))()
        await world.settle()
        #expect(!ImageCropping.isCropped(image, in: world.state))
        var ran: [CommandID] = []
        ImageSection.perform = { ran.append($0) }
        defer { ImageSection.perform = { _ in } }
        ImageSectionView.showingLinks()
        ImageSectionView.showingInfo(state)()
        #expect(ran == ["edit.links"] && state.showsInfo)
        ImageSectionView.tintActions(try Self.model(world, [image])).commit(ColorResolver.inline(Color(white: 0.3)))
        await world.settle()
        #expect(world.document.undoTitle == "Undo Tint")
        let sheet = RampSheetModel(document: world.document, nodes: [image], ramp: .normal)
        var closed = 0
        sheet.choose(.inverted)
        RampSheetView.keeping(sheet) { closed += 1 }()
        sheet.choose(.darken)
        RampSheetView.cancelling(sheet) { closed += 1 }()
        await world.settle()
        #expect(closed == 2 && sheet.ramp == .normal)
    }
}
