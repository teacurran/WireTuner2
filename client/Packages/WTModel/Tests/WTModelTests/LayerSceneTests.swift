import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-005's model half: the scene is built through `LayerScene` with each layer's rules.
@Suite struct LayerSceneTests {
    @Test func layersBecomeSpansWithTheirRules() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Top", "Hidden"], on: &a)
        let base = try LayerFixture.object(LayerFixture.rect(on: ids[0]), on: &a)
        let top = try LayerFixture.object(LayerFixture.rect(on: ids[1], x: 20), on: &a)
        let hidden = try LayerFixture.object(LayerFixture.rect(on: ids[2], x: 40), on: &a)
        try a.perform(SetLayerFlag([ids[0]], .printing, false))
        try a.perform(SetLayerFlag([ids[1]], .keyline, true))
        try a.perform(SetLayerFlag([ids[1]], .locked, true))
        try a.perform(SetLayerFlag([ids[2]], .visible, false))
        var highlight = Wiretuner_Doc_V1_Color()
        highlight.rgb.r = 1
        try a.perform(SetLayerHighlight(ids[1], color: highlight))
        try a.perform(LayerFixture.guides())
        let guides = try #require(LayerOrder(a.state).guides)
        let guide = try LayerFixture.object(OpsCommand("Guide", ops: [Ops.create(parent: guides, position: [0x80], props: ShapeFixture.rect())]), on: &a)
        let page = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.white)))
        var builder = DocumentDisplayListBuilder(canvas: "c", background: [page])
        builder.guideColor = Color(red: 0, green: 0, blue: 1)
        let scene = builder.rebuild(a.state)
        let spans = scene.displayList.layers
        // The Guides layer (not printing) and the background layer stack below the printing one.
        #expect(spans.map(\.layer.id) == [guides, ids[0], ids[1]].map(NodeID.init))
        #expect(spans[0].layer.isGuides && spans[0].layer.highlight == Color(red: 0, green: 0, blue: 1) && spans[0].layer.opacity == 1)
        #expect(spans[1].layer.printing == false && spans[1].layer.opacity == 0.5 && spans[1].range == 2..<3)
        #expect(spans[2].layer.keyline && spans[2].layer.locked && spans[2].layer.highlight == Color(red: 1, green: 0, blue: 0))
        #expect(scene.displayList.nodeIDs == [nil, NodeID(guide), NodeID(base), NodeID(top)])
        #expect(scene.object(top)?.itemPath == [3] && scene.object(hidden) == nil)
        // Print and export: printing, non-Guides layers; hidden ones only when asked.
        let output = builder.outputDisplayList(a.state)
        #expect(output.nodeIDs == [NodeID(top)] && output.layers.map(\.layer.keyline) == [false])
        let withHidden = builder.outputDisplayList(a.state, includeHidden: true)
        #expect(withHidden.nodeIDs == [NodeID(top), NodeID(hidden)])
        #expect(builder.scene == scene, "the output list leaves the scene alone")
    }

    @Test func aLayerFlagTouchesOnlyThatLayersObjects() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Base", "Top"], on: &a)
        let base = try LayerFixture.object(LayerFixture.rect(on: ids[0]), on: &a)
        let top = try LayerFixture.object(LayerFixture.rect(on: ids[1], x: 20), on: &a)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let change = try #require(try a.perform(SetLayerFlag([ids[1]], .keyline, true)))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(top)) && !summary.touchedNodes.contains(NodeID(base)))
        #expect(scene.displayList.layerSpan(of: NodeID(ids[1]))?.layer.keyline == true)
        #expect(scene.displayList.bounds(ofLayer: NodeID(ids[1])) == scene.object(top)?.bounds)
    }
}

/// PRINT-007's model half: colours from spot swatches carry their ink.
@Suite struct SpotInkTests {
    static func swatch(_ name: String, spot: Bool = true, parent: OpID? = nil, percent: Double = 0, role: Wiretuner_Doc_V1_SwatchRole = .unspecified) -> Wiretuner_Doc_V1_Op {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.swatch.common.name = name
        props.swatch.spot = spot
        props.swatch.value.cmyk.m = 1
        props.swatch.role = role
        if let parent {
            props.swatch.parent.id = parent.proto
            props.swatch.tintPercent = percent
        }
        return Ops.create(parent: WellKnown.swatches, position: [0x80], props: props)
    }

    static func reference(_ swatch: OpID) -> Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.swatch.id = swatch.proto
        var cached = Wiretuner_Doc_V1_Color()
        cached.cmyk.m = 1
        ref.swatch.cached = try! cached.serializedData()
        return ref
    }

    @Test func swatchesResolveToTheirInks() throws {
        var a = Replica(0xA)
        let pms = try a.perform(OpsCommand("s", ops: [Self.swatch("PMS 185")]))!.createdNodes[0]
        let tint = try a.perform(OpsCommand("s", ops: [Self.swatch("", spot: false, parent: pms, percent: 50)]))!.createdNodes[0]
        let tintOfTint = try a.perform(OpsCommand("s", ops: [Self.swatch("", parent: tint, percent: 0)]))!.createdNodes[0]
        let process = try a.perform(OpsCommand("s", ops: [Self.swatch("Process", spot: false)]))!.createdNodes[0]
        let registration = try a.perform(OpsCommand("s", ops: [Self.swatch("Registration", spot: false, role: .registration)]))!.createdNodes[0]
        let dangling = try a.perform(OpsCommand("s", ops: [Self.swatch("", parent: OpID(counter: 999, replica: 9), percent: 50)]))!.createdNodes[0]
        // A loop of two tints reads as process.
        let loopA = try a.perform(OpsCommand("s", ops: [Self.swatch("", parent: OpID(counter: 1, replica: 1), percent: 50)]))!.createdNodes[0]
        let loopB = try a.perform(OpsCommand("s", ops: [Self.swatch("", parent: loopA, percent: 50)]))!.createdNodes[0]
        var rebase = Wiretuner_Doc_V1_NodeProps()
        rebase.swatch.parent.id = loopB.proto
        try a.perform(OpsCommand("r", ops: [Ops.set(loopA, [RegisterPath([70, 4])], values: rebase)]))
        let resolver = ColorResolver(a.state)
        func ink(_ swatch: OpID) -> SpotInk? { resolver.color(ofSwatch: swatch)?.spot }
        #expect(ink(pms) == SpotInk(swatch: NodeID(pms), name: "PMS 185"))
        #expect(ink(tint) == SpotInk(swatch: NodeID(pms), name: "PMS 185", tint: 0.5))
        #expect(ink(tintOfTint) == SpotInk(swatch: NodeID(pms), name: "PMS 185", tint: 0.5))
        #expect(ink(process) == nil && ink(dangling) == nil && ink(loopA) == nil && ink(loopB) == nil)
        #expect(resolver.color(ofSwatch: registration) == .registration)
        ColorResolver.$current.withValue(resolver) {
            #expect(Appearances.color(Self.reference(pms))?.spot == SpotInk(swatch: NodeID(pms), name: "PMS 185"))
            #expect(Appearances.color(Self.reference(process))?.spot == nil)
            #expect(Appearances.color(Self.reference(registration)) == .registration)
            var tintRef = Wiretuner_Doc_V1_ColorRef()
            tintRef.tint.base = Self.reference(pms).swatch
            tintRef.tint.percent = 25
            #expect(Appearances.color(tintRef)?.spot?.tint == 0.25)
            tintRef.tint.base = Self.reference(registration).swatch
            #expect(Appearances.color(tintRef)?.spot == SpotInk.registration.tinted(0.25))
        }
        #expect(Appearances.color(Self.reference(pms))?.spot == nil, "outside a build swatches resolve to their cached colours")
    }

    @Test func aSpotFillRendersWithItsInkAndASwatchEditRepaintsItsUsers() throws {
        var a = Replica(0xA)
        let pms = try a.perform(OpsCommand("s", ops: [Self.swatch("PMS 185")]))!.createdNodes[0]
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.basic.color = Self.reference(pms)
        appearance.fills = [fill]
        let spot = try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), appearance: appearance))!.createdObjects[0]
        let plain = try a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .translation(x: 20, y: 0)))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        func fillColor(_ scene: DocumentScene) -> Color? {
            guard case .path(let item)? = scene.object(spot)?.item, case .fill(let paint)? = item.appearance.items.first else { return nil }
            return paint.paint.color
        }
        #expect(fillColor(scene)?.spot?.name == "PMS 185")
        var rename = Wiretuner_Doc_V1_NodeProps()
        rename.swatch.common.name = "PMS 186"
        let change = try #require(try a.perform(OpsCommand("Rename", ops: [Ops.set(pms, [RegisterPath([70, 1, 1])], values: rename)])))
        let (after, summary) = builder.apply(change, state: a.state, origin: .remote)
        #expect(fillColor(after)?.spot?.name == "PMS 186")
        #expect(summary.touchedNodes.contains(NodeID(spot)) && !summary.touchedNodes.contains(NodeID(plain)))
    }
}

/// PRINT-009's model half: effective object screens.
@Suite struct HalftoneTests {
    @Test func objectScreensInheritTheirDefaultParts() throws {
        var a = Replica(0xA)
        let own = try a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        let partial = try a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        let inherited = try a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        let unset = try a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        func screen(_ node: OpID, shape: Wiretuner_Doc_V1_HalftoneShape, angle: Double, frequency: Double) throws {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.ellipse.common.halftone.shape = shape
            props.ellipse.common.halftone.angle = angle
            props.ellipse.common.halftone.frequency = frequency
            try a.perform(OpsCommand("Halftone", ops: [Ops.set(node, [RegisterPath([22, 1, 11])], values: props)]))
        }
        try screen(own, shape: .line, angle: 15, frequency: 40)
        try screen(partial, shape: .unspecified, angle: 30, frequency: 900)
        try screen(inherited, shape: .unspecified, angle: 0, frequency: 0)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let plate = HalftoneScreen(shape: .diamond, angle: 45, frequency: 85)
        let screens = Halftones.objectScreens(scene, in: a.state, plate: plate)
        #expect(screens[NodeID(own)] == HalftoneScreen(shape: .line, angle: 15, frequency: 40))
        #expect(screens[NodeID(partial)] == nil, "shape and frequency both inherited")
        #expect(screens[NodeID(inherited)] == nil && screens[NodeID(unset)] == nil)
        #expect(Halftones.objectScreens(scene, in: a.state, plate: plate, ignoreObjectHalftones: true).isEmpty)
        var cross = Wiretuner_Doc_V1_Halftone()
        cross.shape = .cross
        cross.angle = 75
        #expect(Halftones.screen(cross, plate: plate) == HalftoneScreen(shape: .cross, angle: 75, frequency: 85))
        var fine = Wiretuner_Doc_V1_Halftone()
        fine.frequency = 150
        #expect(Halftones.screen(fine, plate: plate) == HalftoneScreen(shape: .diamond, angle: 0, frequency: 150))
    }
}

/// WEB-014's frame fields and settings, and the frame list WEB-016 draws.
@Suite struct AnimationModelTests {
    @Test func settingsReadDefaultsAndCommandsWriteThem() throws {
        var a = Replica(0xA)
        var info = AnimationInfo(a.state)
        #expect(info.source == .none && info.fps == 12 && info.loop && info.autoplay && info.layers.isEmpty)
        try a.perform(SetAnimationSettings(fps: 24))
        info = AnimationInfo(a.state)
        #expect(info.fps == 24 && info.loop, "the first write keeps looping on")
        let change = try #require(try a.perform(SetAnimationSettings(source: .layers, loop: false, autoplay: false)))
        #expect(change.label == "Animation Settings")
        info = AnimationInfo(a.state)
        #expect(info.source == .layers && !info.loop && !info.autoplay)
        a.undo()
        #expect(AnimationInfo(a.state).loop)
        #expect(try a.perform(SetAnimationSettings()) == nil)
        #expect(throws: ObjectEditError.invalidValue("fps")) { try a.perform(SetAnimationSettings(fps: 0)) }
    }

    @Test func frameListsFollowTheLayers() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["Background", "One", "Two", "Excluded", "Hidden"], on: &a)
        let objects = try ids.map { try LayerFixture.object(LayerFixture.rect(on: $0), on: &a) }
        try a.perform(SetLayerFlag([ids[0]], .printing, false))
        try a.perform(SetLayerFlag([ids[4]], .visible, false))
        let hold = try #require(try a.perform(SetLayerFrame([ids[2]], hold: 3)))
        #expect(hold.label == "Frame Hold")
        let exclude = try #require(try a.perform(SetLayerFrame([ids[3]], excluded: true)))
        #expect(exclude.label == "Exclude from Animation")
        #expect(SetLayerFrame([ids[3]], excluded: false).label == "Include in Animation")
        try a.perform(SetAnimationSettings(source: .layers, fps: 10))
        let info = AnimationInfo(a.state)
        let frames = info.frames()
        #expect(frames.map(\.layers) == [[ids[0], ids[1]], [ids[0], ids[2]]].map { $0.map(NodeID.init) })
        #expect(frames.map(\.hold) == [1, 3])
        #expect(info.visibleNodes(of: frames[1], in: a.state) == [objects[0], objects[2]])
        #expect(info.timeline().totalPeriods == 4)
        let pages = [Rect(x: 0, y: 0, width: 100, height: 100), Rect(x: 200, y: 0, width: 100, height: 100)]
        try a.perform(SetAnimationSettings(source: .pagesAndLayers))
        #expect(AnimationInfo(a.state).frames(pages: pages).count == 4)
        #expect(try a.perform(SetLayerFrame([ids[1]])) == nil)
        #expect(throws: ObjectEditError.invalidValue("hold")) { try a.perform(SetLayerFrame([ids[1]], hold: 0)) }
        #expect(throws: LayerError.notALayer(objects[0])) { try a.perform(SetLayerFrame([objects[0]], hold: 2)) }
    }
}

enum ShapeFixture {
    /// A 10 × 10 rectangle's props.
    static func rect() -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.size.width = 10
        props.rect.size.height = 10
        props.rect.appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        return props
    }
}
