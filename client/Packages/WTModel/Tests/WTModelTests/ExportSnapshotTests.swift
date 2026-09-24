import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// IO-014's model half: the export snapshot (`ExportSnapshot`).
@Suite struct ExportSnapshotTests {
    /// A rectangle at `x` with the given common facts.
    static func rect(at x: Double, y: Double = 0, name: String = "", note: String = "", alt: String = "", url: String = "", decorative: Bool = false)
        -> Wiretuner_Doc_V1_NodeProps {
        var props = ShapeFixture.rect()
        props.rect.common.transform = PathEditing.proto(AffineTransform.translation(x: x, y: y))
        props.rect.common.name = name
        props.rect.common.note = note
        props.rect.common.alt = alt
        props.rect.common.url = url
        props.rect.common.decorative = decorative
        return props
    }

    static func create(_ props: Wiretuner_Doc_V1_NodeProps, on parent: OpID, at position: UInt8 = 0x80, _ replica: inout Replica) throws -> OpID {
        try replica.perform(OpsCommand("Create", ops: [Ops.create(parent: parent, position: [position], props: props)]))!.createdNodes[0]
    }

    static let pages = [ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 100, height: 100), name: "Cover", bleed: 9),
                        ExportSnapshot.Page(bounds: Rect(x: 200, y: 0, width: 100, height: 100))]

    static func capture(_ state: EngineState, _ request: ExportSnapshot.Request, blobs: [Data: Data] = [:]) -> ExportSnapshot {
        ExportSnapshot.capture(state, request: request, builder: DocumentDisplayListBuilder(canvas: "export"), blob: { blobs[$0] })
    }

    @Test func pagesRegroupTheOutputListByLayerWithNestedIDsAndFacts() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Back", "Front"], on: &a)
        let first = try Self.create(Self.rect(at: 0, name: "Logo", note: "Check the colour", alt: "The logo", url: "https://example.com", decorative: true), on: layers[0], &a)
        let second = try Self.create(Self.rect(at: 20, name: "   "), on: layers[1], &a)
        let third = try Self.create(Self.rect(at: 210), on: layers[0], at: 0x90, &a)
        let inner = try Self.create(Self.rect(at: 230, name: "Inner"), on: layers[1], at: 0x90, &a)
        let other = try Self.create(Self.rect(at: 250), on: layers[1], at: 0xA0, &a)
        let group = try a.perform(GroupObjects([inner, other]))!.createdNodes[0]
        let hidden = try LayerFixture.layers(["Hidden"], on: &a)[0]
        let unseen = try Self.create(Self.rect(at: 40), on: hidden, &a)
        try a.perform(SetLayerFlag([hidden], .visible, false))
        var raster = Wiretuner_Doc_V1_NodeProps()
        raster.settings.rasterEffects.resolutionPpi = 150
        try a.perform(OpsCommand("Raster", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 90, 1])], values: raster)]))

        let snapshot = Self.capture(a.state, ExportSnapshot.Request(name: "Catalog", pages: Self.pages, scope: .pages([0, 1, 7]), pageColor: .white))
        let scene = snapshot.scene
        #expect(scene.name == "Catalog" && scene.pages.count == 2 && scene.rasterResolution == 150)
        #expect(snapshot.packageContents == nil && snapshot.missing.isEmpty && scene.animation == nil && scene.text.isEmpty && scene.package == nil)
        let cover = scene.pages[0]
        #expect(cover.name == "Cover" && cover.bounds == Self.pages[0].bounds && cover.bleed == 9 && cover.background == .white)
        #expect(cover.displayList.nodeIDs == [NodeID(layers[0]), NodeID(layers[1])])
        #expect(cover.nodeID(at: [0, 0]) == NodeID(first) && cover.nodeID(at: [1, 0]) == NodeID(second))
        #expect(scene.nodes[NodeID(layers[0])]?.isLayer == true && scene.nodes[NodeID(layers[0])]?.name == "Back")
        #expect(scene.nodes[NodeID(first)] == ExportNodeInfo(name: "Logo", alt: "The logo", decorative: true, url: "https://example.com", note: "Check the colour"))
        #expect(scene.nodes[NodeID(second)] == nil, "a blank name is no fact")
        let back = scene.pages[1]
        #expect(back.displayList.nodeIDs == [NodeID(layers[0]), NodeID(layers[1])])
        #expect(back.nodeID(at: [0, 0]) == NodeID(third) && back.nodeID(at: [1, 0]) == NodeID(group))
        #expect(back.nodeID(at: [1, 0, 0]) == NodeID(inner) && back.nodeID(at: [1, 0, 1]) == NodeID(other))
        #expect(scene.nodes[NodeID(inner)]?.name == "Inner")
        #expect(!scene.pages.contains { $0.displayList.nodeIDs.contains(NodeID(unseen)) })

        // Without the page boundary each page is its artwork's bounds; hidden layers on request.
        let trimmed = Self.capture(a.state, ExportSnapshot.Request(name: "T", pages: Self.pages, scope: .pages([0]), includePageBoundary: false, includeHidden: true))
        let bounds = try #require(trimmed.scene.pages.first?.bounds)
        #expect(bounds.minX < 1 && bounds.maxX > 49 && bounds.maxX < 60 && bounds.height < 20)
        #expect(trimmed.scene.pages[0].displayList.nodeIDs.contains(NodeID(hidden)))
        // A page with nothing on it keeps its rectangle.
        let empty = Self.capture(a.state, ExportSnapshot.Request(name: "E", pages: [ExportSnapshot.Page(bounds: Rect(x: 900, y: 900, width: 10, height: 10))],
                                                              scope: .pages([0]), includePageBoundary: false))
        #expect(empty.scene.pages[0].bounds == Rect(x: 900, y: 900, width: 10, height: 10) && empty.scene.pages[0].displayList.count == 0)
    }

    @Test func areaAndSelectionScopes() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Only"], on: &a)[0]
        let left = try Self.create(Self.rect(at: 0), on: layer, &a)
        let inner = try Self.create(Self.rect(at: 50), on: layer, at: 0x90, &a)
        let outer = try Self.create(Self.rect(at: 70), on: layer, at: 0xA0, &a)
        let group = try a.perform(GroupObjects([inner, outer]))!.createdNodes[0]

        let area = Self.capture(a.state, ExportSnapshot.Request(name: "A", pages: Self.pages, scope: .area(Rect(x: 45, y: -5, width: 20, height: 20))))
        #expect(area.scene.pages.count == 1 && area.scene.pages[0].bounds == Rect(x: 45, y: -5, width: 20, height: 20))
        #expect(area.scene.pages[0].nodeID(at: [0, 0]) == NodeID(group) && area.scene.pages[0].name == nil)

        // Selecting an object inside a group exports the group it is drawn in, cropped to it.
        let selection = Self.capture(a.state, ExportSnapshot.Request(name: "S", pages: Self.pages, scope: .selection([NodeID(inner)])))
        let page = try #require(selection.scene.pages.first)
        #expect(page.nodeID(at: [0, 0]) == NodeID(group) && page.displayList.items.count == 1)
        #expect(page.bounds.minX >= 49 && page.bounds.maxX <= 82 && page.background == nil)
        let top = Self.capture(a.state, ExportSnapshot.Request(name: "S", pages: Self.pages, scope: .selection([NodeID(left)])))
        #expect(top.scene.pages.first?.nodeID(at: [0, 0]) == NodeID(left))
        #expect(Self.capture(a.state, ExportSnapshot.Request(name: "S", pages: Self.pages, scope: .selection([]))).scene.pages.isEmpty)
    }

    @Test func placedPreviewsAndEPSProgramsComeFromTheBlobCache() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["L"], on: &a)[0]
        let jpeg = try Self.jpeg()
        let previewHash = Data(repeating: 0x11, count: 32)
        var eps = Wiretuner_Doc_V1_NodeProps()
        eps.placedFile.content = PlacedFileTests.content(preview: Array(previewHash), name: "art.eps")
        eps.placedFile.content.blobSha256 = Data(repeating: 0x33, count: 32)
        eps.placedFile.common.transform = PathEditing.proto(AffineTransform.translation(x: 10, y: 20))
        eps.placedFile.common.name = "Art"
        let placed = try Self.create(eps, on: layer, &a)
        var broken = Wiretuner_Doc_V1_NodeProps()
        broken.placedFile.content = PlacedFileTests.content(preview: Array(repeating: 0x22, count: 32), name: "broken.eps")
        broken.placedFile.content.format = .unspecified
        broken.placedFile.common.transform = PathEditing.proto(AffineTransform.translation(x: 300, y: 0))
        let other = try Self.create(broken, on: layer, at: 0x90, &a)
        let program = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 40 30\n".utf8)
        let blobs = [previewHash: jpeg, Data(repeating: 0x33, count: 32): program, Data(repeating: 0x22, count: 32): Data("not an image".utf8),
                     Data(repeating: 0xAB, count: 32): program]
        let everything = [ExportSnapshot.Page(bounds: Rect(x: -500, y: -500, width: 2000, height: 2000))]

        let snapshot = Self.capture(a.state, ExportSnapshot.Request(name: "P", pages: everything, scope: .pages([0])), blobs: blobs)
        let assetID = String(repeating: "11", count: 32)
        #expect(snapshot.scene.assets[assetID]?.jpegData == jpeg && snapshot.scene.assets[assetID]?.image.width == 4)
        #expect(snapshot.missing == ["broken.eps"])
        #expect(snapshot.scene.nodes[NodeID(placed)]?.name == "Art")
        let postScript = try #require(snapshot.scene.placedPostScript[NodeID(placed)])
        #expect(postScript.data == program && postScript.transform == .translation(x: 10, y: 20) && postScript.bounds == postScript.boundingBox)
        #expect(snapshot.scene.placedPostScript[NodeID(other)] == nil, "only EPS programs pass through")
        // Without the blobs the placed file draws its gray box: no program, no preview.
        let offline = Self.capture(a.state, ExportSnapshot.Request(name: "P", pages: everything, scope: .pages([0])))
        #expect(offline.scene.placedPostScript.isEmpty && offline.missing == ["art.eps", "broken.eps"] && offline.scene.assets.isEmpty)
        #expect(ExportCapture.bytes(hex: "0g") == nil && ExportCapture.bytes(hex: "abc") == nil && ExportCapture.bytes(hex: "0aff") == Data([0x0A, 0xFF]))
        #expect(ExportCapture.asset(Data([0xFF, 0xD8, 0xFF])) == nil)
        let png = try #require(ExportCapture.asset(Self.png()))
        #expect(png.jpegData == nil && png.image.width == 4)
    }

    @Test func documentInfoAnimationTextAndPackage() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["L"], on: &a)[0]
        #expect(ExportSnapshot.documentInfo(a.state).isEmpty && ExportSnapshot.rasterResolution(a.state) == 72)
        var info = Wiretuner_Doc_V1_NodeProps()
        info.settings.info.title = "Spring Catalog"
        info.settings.info.creators = ["Pat", "Sam"]
        info.settings.info.headline = "Spring"
        info.settings.info.description_p = "Every product"
        info.settings.info.language = "en-US"
        info.settings.info.copyrightStatus = .copyrighted
        try a.perform(OpsCommand("Info", ops: [Ops.set(WellKnown.settings, [1, 2, 3, 10, 21, 35].map { RegisterPath([2, 130, $0]) }, values: info)]))
        let written = ExportSnapshot.documentInfo(a.state)
        #expect(written.title == "Spring Catalog" && written.author == "Pat" && written.subject == "Spring" && written.description == "Every product")
        #expect(written.language == "en-US" && written.metadata?.copyrightStatus == .copyrighted && written.metadata?.creators == ["Pat", "Sam"])
        info.settings.info = Wiretuner_Doc_V1_DocumentInfo()
        info.settings.info.copyrightStatus = .publicDomain
        try a.perform(OpsCommand("Info", ops: [Ops.set(WellKnown.settings, [1, 2, 3, 10, 21, 35].map { RegisterPath([2, 130, $0]) }, values: info)]))
        let cleared = ExportSnapshot.documentInfo(a.state)
        #expect(cleared.title == nil && cleared.author == nil && cleared.metadata?.copyrightStatus == .publicDomain)
        info.settings.info.copyrightStatus = .unspecified
        info.settings.info.title = "Untitled"
        try a.perform(OpsCommand("Info", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 130, 1]), RegisterPath([2, 130, 21])], values: info)]))
        #expect(ExportSnapshot.documentInfo(a.state).metadata?.copyrightStatus == .unknown)

        let box = try Self.create(Self.rect(at: 0), on: layer, &a)
        _ = try a.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "Hello\nWorld", layer: layer))
        _ = try a.perform(CreateTextBlock(.point(Point(x: 220, y: 10)), text: "Back", layer: layer))
        _ = try a.perform(CreateTextBlock(.point(Point(x: 900, y: 10)), text: "Off the pages", layer: layer))
        var indent = Wiretuner_Doc_V1_ParagraphProps()
        indent.leftIndent = 12
        let indented = try a.perform(CreateTextBlock(.point(Point(x: 30, y: 30)), text: "Indented", paragraph: indent, layer: layer))!.createdNodes[0]
        // Text inside a group is found; text on a hidden layer only with hidden layers included.
        let grouped = try a.perform(CreateTextBlock(.point(Point(x: 240, y: 40)), text: "Grouped", layer: layer))!.createdNodes[0]
        let partner = try Self.create(Self.rect(at: 260), on: layer, at: 0xF0, &a)
        _ = try a.perform(GroupObjects([grouped, partner]))
        let hiddenLayer = try LayerFixture.layers(["Hidden"], on: &a)[0]
        let secret = try a.perform(CreateTextBlock(.point(Point(x: 50, y: 50)), text: "Secret", layer: hiddenLayer))!.createdNodes[0]
        try a.perform(SetLayerFlag([hiddenLayer], .visible, false))
        try a.perform(SetAnimationSettings(source: .layers, fps: 24))
        var background = Wiretuner_Doc_V1_NodeProps()
        background.settings.animation.background = .transparent
        try a.perform(OpsCommand("Background", ops: [Ops.set(WellKnown.settings, [AnimationFields.background], values: background)]))

        let package = DocumentPackage.Info(documentID: "doc-1", title: "Spring Catalog")
        let snapshot = Self.capture(a.state, ExportSnapshot.Request(name: "Spring", pages: Self.pages, scope: .pages([0, 1]), animation: true, text: true,
                                                                 package: package))
        let text = snapshot.scene.text
        #expect(text.map(\.page) == [0, 1, 0, 1] && text.map(\.stackingOrder) == [0, 0, 1, 1] && text[3].node == NodeID(grouped))
        let withHidden = Self.capture(a.state, ExportSnapshot.Request(name: "H", pages: Self.pages, scope: .pages([0]), includeHidden: true, text: true))
        #expect(withHidden.scene.text.map(\.node).contains(NodeID(secret)))
        guard case .paragraph(let hello)? = text[0].story?.elements.first, case .paragraph(let world)? = text[0].story?.elements.last else {
            Issue.record("paragraphs")
            return
        }
        #expect(hello.runs.map(\.text) == ["Hello"] && world.runs.map(\.text) == ["World"] && text[0].story?.elements.count == 2)
        guard case .paragraph(let indentedParagraph)? = text[2].story?.elements.first else {
            Issue.record("indent")
            return
        }
        #expect(text[2].node == NodeID(indented) && indentedParagraph.style.leftIndent == 12)
        let animation = try #require(snapshot.scene.animation)
        #expect(animation.fps == 24 && animation.background == .transparent && animation.area == Self.pages[0].bounds && !animation.frames.isEmpty)
        #expect(snapshot.scene.package == nil && snapshot.packageContents?.manifest.title == "Spring Catalog")
        let resolved = try snapshot.resolved()
        let data = try #require(resolved.package)
        #expect(try PackageReader.manifest(of: data).originDocumentID == "doc-1")

        // A selection's text is the selected objects' text; a document without animation has none.
        let selected = Self.capture(a.state, ExportSnapshot.Request(name: "S", pages: Self.pages, scope: .selection([NodeID(indented), NodeID(box)]), text: true))
        #expect(selected.scene.text.map(\.node) == [NodeID(indented)])
        var still = Replica(0xB)
        _ = try LayerFixture.layers(["L"], on: &still)
        let none = Self.capture(still.state, ExportSnapshot.Request(name: "N", pages: [], scope: .pages([]), animation: true, package: package))
        #expect(none.scene.animation == nil && none.packageContents?.firstPage.pages.first?.bounds == Rect(x: 0, y: 0, width: 612, height: 792))
        try still.perform(SetAnimationSettings(source: .layers))
        #expect(Self.capture(still.state, ExportSnapshot.Request(name: "N", pages: Self.pages, scope: .pages([0]), animation: true)).scene.animation?.background == .pageColor)
        #expect(ExportSnapshot.animation(a.state, request: ExportSnapshot.Request(name: "N", pages: [], scope: .pages([])),
                                         displayList: DisplayList(canvas: "c", items: []), area: nil)?.area == Rect(x: 0, y: 0, width: 1, height: 1))
        #expect(try ExportSnapshot(scene: ExportScene(pages: []), packageContents: nil, missing: []).resolved().package == nil)
    }

    /// A 4 × 4 JPEG.
    static func jpeg() throws -> Data {
        try encoded(UTType.jpeg)
    }

    /// A 4 × 4 PNG.
    static func png() throws -> Data {
        try encoded(UTType.png)
    }

    static func encoded(_ type: UTType) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
