import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// IMG-003: image node commands, and the image as the scene draws it (IMG-004 in the scene).
@Suite struct ImageCommandsTests {
    static func pixels(width: Int32 = 300, height: Int32 = 150, mode: Wiretuner_Doc_V1_ColorMode = .rgb, fill: UInt8 = 0xAB,
                       alpha: Bool = false) -> Wiretuner_Doc_V1_PixelSource {
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(repeating: fill, count: 32)
        pixels.format = "public.png"
        pixels.pixelWidth = width
        pixels.pixelHeight = height
        pixels.mode = mode
        pixels.bitsPerChannel = 8
        pixels.hasAlpha_p = alpha
        return pixels
    }

    /// An image placed on `replica` at 144 ppi, moved to (10, 20).
    static func place(_ replica: inout Replica, _ pixels: Wiretuner_Doc_V1_PixelSource = pixels()) throws -> OpID {
        try replica.perform(PlaceImage(pixels, name: "photo.png", dpiX: 144, dpiY: 144, transform: .translation(x: 10, y: 20)))!.createdObjects[0]
    }

    @Test func placingCreatesOneNodeOnTheDrawingLayerWithDisplayAlphaOn() throws {
        var replica = Replica(3)
        let change = try #require(try replica.perform(PlaceImage(Self.pixels(alpha: true), name: "photo.png", dpiX: 144, dpiY: 144,
                                                                 transform: .translation(x: 10, y: 20))))
        #expect(change.label == "Place photo.png")
        let node = change.createdObjects[0]
        let image = replica.state.props(node).image
        #expect(image.common.name == "photo.png" && image.sourceName == "photo.png" && image.displayAlpha && image.dpiX == 144)
        #expect(!image.hasSource && replica.state.nodeKind(node) == .image && Objects.isObject(node, in: replica.state))
        #expect(Objects.bounds(of: node, in: replica.state) == Rect(x: 10, y: 20, width: 150, height: 75))
        #expect(PlaceImage(Self.pixels()).label == "Place Image")
        let asset = OpID(counter: 99, replica: 3)
        let linked = try #require(try replica.perform(PlaceImage(Self.pixels(), source: asset)))
        #expect(OpID(replica.state.props(linked.createdObjects[0]).image.source.id) == asset)
        replica.undo()
        #expect(!replica.state.isLive(linked.createdObjects[0]))
    }

    @Test func invalidValuesAreRefusedByTheSchemaRules() throws {
        var replica = Replica(3)
        var bad = Self.pixels()
        bad.blobSha256 = Data([1, 2])
        #expect(throws: ImageEditError.invalidValue("pixels.blob_sha256")) { try replica.perform(PlaceImage(bad)) }
        bad = Self.pixels()
        bad.format = String(repeating: "x", count: 129)
        #expect(throws: ImageEditError.invalidValue("pixels.format")) { try replica.perform(PlaceImage(bad)) }
        bad = Self.pixels(width: 0)
        #expect(throws: ImageEditError.invalidValue("pixels.size")) { try replica.perform(PlaceImage(bad)) }
        bad = Self.pixels()
        bad.bitsPerChannel = 4
        #expect(throws: ImageEditError.invalidValue("pixels.bits_per_channel")) { try replica.perform(PlaceImage(bad)) }
        bad = Self.pixels(mode: .unspecified)
        #expect(throws: ImageEditError.invalidValue("pixels.mode")) { try replica.perform(PlaceImage(bad)) }
        #expect(throws: ImageEditError.invalidValue("dpi")) { try replica.perform(PlaceImage(Self.pixels(), dpiX: 0)) }
        #expect(throws: ImageEditError.invalidValue("dpi")) { try replica.perform(PlaceImage(Self.pixels(), dpiY: .infinity)) }
        let node = try Self.place(&replica)
        #expect(throws: ImageEditError.invalidValue("dpi")) { try replica.perform(SetImageResolution([node], dpiX: -1, dpiY: nil)) }
        #expect(throws: ImageEditError.invalidValue("dpi")) { try replica.perform(SetImageResolution([node], dpiX: nil, dpiY: 0)) }
        #expect(throws: ImageEditError.invalidValue("crop")) { try replica.perform(SetImageSetting([node], .crop(Rect(x: 0.5, y: 0, width: 0.6, height: 1)))) }
        #expect(throws: ImageEditError.invalidValue("crop")) { try replica.perform(SetImageSetting([node], .crop(Rect(x: 0, y: 0, width: 0, height: 1)))) }
        #expect(throws: ImageEditError.invalidValue("ramp")) {
            try replica.perform(SetImageSetting([node], .ramp(GrayRamp(preset: .custom, lightness: 101, contrast: 0))))
        }
        #expect(throws: ImageEditError.invalidValue("ramp")) {
            try replica.perform(SetImageSetting([node], .ramp(GrayRamp(preset: .custom, lightness: 0, contrast: -101))))
        }
        #expect(throws: ImageEditError.invalidValue("pixels.size")) { try replica.perform(ReplaceImagePixels(node, pixels: Self.pixels(height: 0))) }
    }

    @Test func commandsRefuseNodesThatAreNotEditableImages() throws {
        var replica = Replica(3)
        let node = try Self.place(&replica)
        let layer = try #require(Objects.parent(of: node, in: replica.state))
        #expect(throws: ImageEditError.notAnImage(layer)) { try replica.perform(SetImageSetting([layer], .displayAlpha(false))) }
        try replica.perform(OpsCommand("Lock", ops: [Ops.set(node, [CommonFields.locked(.image)], values: NodeValues.common(kind: .image) { $0.locked = true })]))
        #expect(throws: ImageEditError.notAnImage(node)) { try replica.perform(ReplaceImagePixels(node, pixels: Self.pixels())) }
        #expect(try replica.perform(SetImageResolution([], dpiX: nil, dpiY: nil)) == nil)
    }

    @Test func replacingPixelsKeepsThePlacedBoundsAndRecomputesTheResolution() throws {
        var replica = Replica(3)
        let node = try Self.place(&replica)
        let before = Objects.bounds(of: node, in: replica.state)
        let change = try #require(try replica.perform(ReplaceImagePixels(node, pixels: Self.pixels(width: 600, height: 400, fill: 0xCD), name: "edited.png")))
        #expect(change.label == "Replace Pixels" && change.ops.count == 1 && change.ops[0].set.paths.count == 4)
        let image = replica.state.props(node).image
        #expect(image.dpiX == 288 && image.dpiY == 384 && image.sourceName == "edited.png")
        #expect(Objects.bounds(of: node, in: replica.state) == before)
        replica.undo()
        #expect(replica.state.props(node).image.pixels == Self.pixels() && replica.state.props(node).image.dpiX == 144)
        // Without a name the source name stays; an image with no pixels yet takes 72 ppi.
        let bare = try #require(try replica.perform(OpsCommand("Bare", ops: [Ops.create(parent: Objects.parent(of: node, in: replica.state)!, position: [0x10],
                                                                                        props: ImageFields.values { $0.sourceName = "x" })]))).createdNodes[0]
        let filled = try #require(try replica.perform(ReplaceImagePixels(bare, pixels: Self.pixels())))
        #expect(filled.ops[0].set.paths.count == 3 && replica.state.props(bare).image.dpiX == 72 && replica.state.props(bare).image.sourceName == "x")
    }

    @Test func eachSettingIsOneChangeWithALabelAndUndoes() throws {
        var replica = Replica(3)
        let node = try Self.place(&replica, Self.pixels(mode: .grayscale))
        let other = try Self.place(&replica, Self.pixels(mode: .bilevel))
        let tint = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
        let steps: [(SetImageSetting.Setting, String, (Wiretuner_Doc_V1_ImageProps) -> Bool)] = [
            (.displayAlpha(true), "Display Alpha Channel", { $0.displayAlpha }),
            (.displayAlpha(false), "Hide Alpha Channel", { !$0.displayAlpha }),
            (.transparentBackground(true), "Transparent", { $0.transparentBackground }),
            (.transparentBackground(false), "Opaque Background", { !$0.transparentBackground }),
            (.ramp(GrayRamp(preset: .custom, lightness: 20, contrast: -30)), "Edit Ramp", { $0.ramp.preset == .custom && $0.ramp.lightness == 20 && $0.ramp.contrast == -30 }),
            (.ramp(nil), "Reset Ramp", { !$0.hasRamp }),
            (.tint(tint), "Tint", { $0.tint == tint }),
            (.tint(nil), "Remove Tint", { !$0.hasTint }),
            (.crop(Rect(x: 0.25, y: 0, width: 0.5, height: 1)), "Crop", { $0.crop.x == 0.25 && $0.crop.width == 0.5 }),
            (.crop(nil), "Remove Crop", { !$0.hasCrop }),
        ]
        for (setting, label, check) in steps {
            let change = try #require(try replica.perform(SetImageSetting([node], setting)))
            #expect(change.label == label && change.ops.count == 1)
            #expect(check(replica.state.props(node).image))
        }
        #expect(SetImageSetting([node, other], .displayAlpha(true)).label == "Display Alpha Channel (2 images)")
        let resolution = try #require(try replica.perform(SetImageResolution([node, other], dpiX: 300, dpiY: 300)))
        #expect(resolution.label == "Set Resolution (2 images)" && resolution.ops.count == 2)
        #expect(replica.state.props(other).image.dpiY == 300)
        try replica.perform(SetImageResolution([node], dpiX: 150, dpiY: nil))
        #expect(replica.state.props(node).image.dpiX == 150 && replica.state.props(node).image.dpiY == 300)
        replica.undo()
        replica.undo()
        #expect(replica.state.props(node).image.dpiX == 144 && replica.state.props(other).image.dpiX == 144)
        replica.undo()
        #expect(replica.state.props(node).image.hasCrop)
    }

    @Test func replacingPixelsOnOneReplicaWhileCroppingOnTheOtherKeepsBoth() throws {
        var pair = Pair()
        let node = try Self.place(&pair.a)
        pair.sync()
        try pair.a.perform(ReplaceImagePixels(node, pixels: Self.pixels(width: 600, height: 300, fill: 0x11)))
        try pair.b.perform(SetImageSetting([node], .crop(Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))))
        pair.sync()
        for replica in [pair.a, pair.b] {
            let image = replica.state.props(node).image
            #expect(image.pixels.blobSha256 == Data(repeating: 0x11, count: 32) && image.crop.x == 0.1 && image.crop.y == 0.2)
            #expect(abs(image.crop.width - 0.5) < 1e-12 && abs(image.crop.height - 0.5) < 1e-12)
        }
        #expect(pair.a.state.props(node) == pair.b.state.props(node))
    }

    @Test func itemsReadModesRampsTintsProfilesAndTheNormalizations() {
        #expect(ImageMode.allCases.map { ImageNodes.mode(ImageNodes.stored($0)) } == ImageMode.allCases)
        #expect(ImageNodes.mode(.unspecified) == .rgb)
        for preset in GrayRamp.Preset.allCases {
            let ramp = GrayRamp(preset: preset, lightness: 5, contrast: -5)
            #expect(ImageNodes.ramp(ImageNodes.stored(ramp)) == ramp)
        }
        #expect(ImageNodes.ramp(Wiretuner_Doc_V1_GrayRamp()) == .normal)
        var props = Wiretuner_Doc_V1_ImageProps()
        props.pixels = Self.pixels(width: 100, height: 50, mode: .grayscale, alpha: true)
        props.common.name = "named"
        props.displayAlpha = true
        props.transparentBackground = true
        props.tint = ColorResolver.inline(Color(red: 0, green: 0, blue: 1))
        props.crop.x = 0.5
        props.crop.width = 0.5
        props.crop.height = 1
        props.color.intent = .perceptual
        props.color.sourceProfile.bundledID = "srgb"
        var item = ImageNodes.item(props, transform: .translation(x: 1, y: 2))
        #expect(item.rect == Rect(x: 0, y: 0, width: 100, height: 50) && item.transform == .translation(x: 1, y: 2))
        #expect(item.mode == .grayscale && item.hasAlpha && item.displayAlpha && item.transparentBackground)
        #expect(item.tint == Color(red: 0, green: 0, blue: 1) && item.crop == Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(item.intent == .perceptual && item.sourceProfile == WTColor.ProfileRegistry.shared.bundled("srgb") && item.name == "named")
        #expect(item.assetID == String(repeating: "ab", count: 32))
        props.sourceName = "file.png"
        props.color.embeddedProfile.bundledID = "display-p3"
        props.color.useEmbedded = true
        item = ImageNodes.item(props, transform: .identity)
        #expect(item.name == "file.png" && item.sourceProfile == WTColor.ProfileRegistry.shared.bundled("display-p3"))
        // Embedded without a profile falls back to the source profile; neither reads as none.
        props.color.clearEmbeddedProfile()
        #expect(ImageNodes.item(props, transform: .identity).sourceProfile == WTColor.ProfileRegistry.shared.bundled("srgb"))
        props.color = Wiretuner_Doc_V1_ImageColorSettings()
        props.clearTint()
        props.clearCrop()
        item = ImageNodes.item(props, transform: .identity)
        #expect(item.sourceProfile == nil && item.intent == nil && item.tint == nil && item.crop == nil)
        #expect(ImageNodes.item(Wiretuner_Doc_V1_ImageProps(), transform: .identity).assetID.isEmpty)
    }

    @Test func theSceneDrawsImagesThroughTheImagePathAndMovesThem() throws {
        var replica = Replica(3)
        let node = try Self.place(&replica, Self.pixels(mode: .grayscale))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        var scene = builder.rebuild(replica.state)
        var object = try #require(scene.object(node))
        guard case .image(let image) = object.item else { Issue.record("image item"); return }
        #expect(object.kind == .image && image.rect == Rect(x: 0, y: 0, width: 150, height: 75) && image.name == "photo.png")
        #expect(object.bounds == Rect(x: 10, y: 20, width: 150, height: 75))
        #expect(scene.displayList.bounds(ofImageAsset: image.assetID) == [Rect(x: 10, y: 20, width: 150, height: 75)])
        #expect(scene.displayList.itemBounds == scene.displayList.items.map(\.bounds))
        let move = try #require(try replica.perform(MoveObjects([node], by: Vector(dx: 5, dy: 0))))
        (scene, _) = builder.apply(move, state: replica.state, origin: .local)
        object = try #require(scene.object(node))
        #expect(object.bounds == Rect(x: 15, y: 20, width: 150, height: 75))
        // A tint through a swatch redraws when the swatch changes.
        try replica.perform(DocumentTemplate())
        let swatch = try #require(ColorResolver(replica.state).swatch(role: .black))
        let tint = try #require(try replica.perform(SetImageSetting([node], .tint(ColorResolver(replica.state).reference(to: swatch)))))
        (scene, _) = builder.apply(tint, state: replica.state, origin: .local)
        #expect(builder.dependencies.dependents(of: [NodeID(swatch)]).contains(NodeID(node)))
        guard case .image(let tinted) = try #require(scene.object(node)).item else { Issue.record("tinted"); return }
        #expect(tinted.tint != nil)
    }
}
