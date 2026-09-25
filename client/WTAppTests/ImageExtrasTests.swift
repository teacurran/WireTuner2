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

/// CMS-013's Image colour rows in the Object panel.
@Suite(.serialized) @MainActor struct ImageExtrasTests {
    static func pixels(mode: Wiretuner_Doc_V1_ColorMode = .rgb, fill: UInt8 = 0xAB) -> Wiretuner_Doc_V1_PixelSource {
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(repeating: fill, count: 32)
        pixels.format = "public.png"
        pixels.pixelWidth = 40
        pixels.pixelHeight = 20
        pixels.mode = mode
        pixels.bitsPerChannel = 8
        return pixels
    }

    static func place(_ document: DocumentHandle, mode: Wiretuner_Doc_V1_ColorMode = .rgb) async throws -> OpID {
        let node = try #require(await document.perform(PlaceImage(pixels(mode: mode), name: "photo.png", dpiX: 72, dpiY: 72)).value?.createdObjects.first)
        await document.settle()
        return node
    }

    static func embed(_ profile: WTColor.ProfileRef, on node: OpID, _ document: DocumentHandle) async {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.image.color.embeddedProfile = ColorSettings.stored(profile)
        _ = await document.perform(OpsCommand("Embed", ops: [Ops.set(node, [RegisterPath([170, 11, 4])], values: props)])).value
    }

    @Test func theRowsReadTheImagesAndEveryChoiceIsOneChange() async throws {
        let document = DocumentHandle.memory(title: "Images")
        let a = try await Self.place(document), b = try await Self.place(document)
        let registry = WTColor.ProfileRegistry.shared
        func model(_ ids: [OpID] = [a, b]) -> ImageColorSectionModel? {
            ImageColorSectionModel(ObjectPanelModel(document: document, selection: Selection(ids.map(SelectionID.init))))
        }
        var section = try #require(model())
        #expect(section.type == "RGB, no embedded profile" && section.selection == "default" && section.intent == "Document" && section.space == .rgb)
        #expect(!section.choices(installed: []).contains { $0.id == "embedded" })
        ImageColorSection.source(section, choices: section.choices(installed: [])).wrappedValue = "bundled:display-p3"
        await document.settle()
        #expect(document.undoTitle == "Undo Assign Image Profile (2 images)")
        section = try #require(model())
        #expect(section.selection == "bundled:display-p3")
        ImageColorSection.intent(section).wrappedValue = "Perceptual"
        await document.settle()
        #expect(try #require(model()).intent == "Perceptual" && document.undoTitle == "Undo Change Image Intent (2 images)")
        // One image embeds a profile: Mixed type; both do: Embedded is offered and chosen.
        await Self.embed(registry.sRGB, on: a, document)
        #expect(try #require(model()).type == "Mixed")
        await Self.embed(registry.sRGB, on: b, document)
        section = try #require(model())
        let embedded = try #require(section.choices(installed: []).first)
        #expect(embedded.title == "Embedded: \(registry.sRGB.name)")
        ImageColorSection.source(section, choices: section.choices(installed: [])).wrappedValue = "embedded"
        await document.settle()
        #expect(try #require(model()).selection == "embedded")
        // A remote assignment to one image makes the menu Mixed.
        await document.receiveRemote(SetImageSourceProfile([b], .documentDefault))
        #expect(try #require(model()).selection == ImageColorSectionModel.mixed)
        PanelRendering.host(ImageColorSectionView(model: try #require(model())))
        ImageColorSection.intent(try #require(model())).wrappedValue = "Unknown"
        ImageColorSection.source(section, choices: []).wrappedValue = "nothing"
        // Other…: a chosen file loads and applies.
        let p3 = registry.displayP3
        let chose = ImageColorSection.chooseFile, load = ImageColorSection.loadProfile
        defer { ImageColorSection.chooseFile = chose; ImageColorSection.loadProfile = load }
        ImageColorSection.chooseFile = { URL(fileURLWithPath: "/tmp/profile.icc") }
        ImageColorSection.loadProfile = { _ in { _ in p3 } }
        ImageColorSection.source(try #require(model()), choices: []).wrappedValue = ImageColorSectionModel.other
        for _ in 0..<20 where try #require(model()).selection != "bundled:display-p3" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try #require(model()).selection == "bundled:display-p3")
        // An installed profile of the model loads through the same path; a failing load changes nothing.
        let installed = InstalledProfileFile(name: "Camera RGB", url: URL(fileURLWithPath: "/tmp/camera.icc"), space: .rgb)
        let withInstalled = try #require(model()).choices(installed: [installed])
        #expect(withInstalled.contains { $0.title == "Camera RGB" })
        // Without the shared blob glue a file registers in this process; an unreadable one throws.
        let glue = ProfileBlobGlue.shared
        ProfileBlobGlue.shared = nil
        let local = load(document)
        ProfileBlobGlue.shared = glue
        let srgb = try await local(URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"))
        #expect(srgb.hexHash.isEmpty == false)
        await #expect(throws: (any Error).self) { _ = try await local(URL(fileURLWithPath: "/nonexistent/profile.icc")) }
        ImageColorSection.loadProfile = { _ in { _ in throw CocoaError(.fileReadCorruptFile) } }
        let failing = try #require(model())
        await failing.assign(file: installed.url).value
        ImageColorSection.source(try #require(model()), choices: withInstalled).wrappedValue = "file:/tmp/camera.icc"
        // Images of different models offer only the model-free choices; other objects hide the rows.
        let gray = try await Self.place(document, mode: .grayscale)
        let mixed = try #require(model([a, gray]))
        #expect(mixed.space == nil && mixed.choices(installed: [installed]).count == 1)
        #expect(ImageColorSectionModel.modelName(.cmyk) == "CMYK" && ImageColorSectionModel.modelName(.bilevel) == "Bitmap" && ImageColorSectionModel.modelName(.indexed) == "Indexed")
        let rect = try #require(await document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)]).first)
        #expect(ImageColorSectionModel(ObjectPanelModel(document: document, selection: Selection([rect, SelectionID(a)]))) == nil)
        let registry2 = InspectorRegistry()
        ImageColorSection.register(into: registry2)
        #expect(registry2.views(for: ObjectPanelModel(document: document, selection: Selection([SelectionID(a)]))).map(\.id).contains("imageColor"))
        // The default loader refuses a file that is not there.
        await #expect(throws: (any Error).self) { _ = try await load(document)(URL(fileURLWithPath: "/nonexistent.icc")) }
    }
}
