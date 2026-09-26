import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// Transparency, Expand Stroke and Inset Path with their sheets (OBJ-026, OBJ-029, OBJ-030).
@Suite(.serialized) @MainActor struct PathOperationSheetsTests {
    static func features(_ world: GlueWorld, shift: Bool = false) -> (PathOperationFeatures, ExtensionRegistry) {
        let features = PathOperationFeatures(target: world.target, store: world.preferences, sheets: world.sheets())
        features.shiftDown = { shift }
        let extensions = ExtensionRegistry()
        features.install(commands: world.commands, extensions: extensions)
        return (features, extensions)
    }

    @Test func theFeaturesAreWiredIntoTheApp() throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        #expect(delegate.modelGlue.pathOperations != nil)
        for id in [ContextMenuCatalog.ID.transparency, ContextMenuCatalog.ID.expandStroke, ContextMenuCatalog.ID.insetPath] {
            #expect(delegate.commands.command(id)?.validation().reason != WireTuner.Command.placeholderReason, "\(id)")
        }
        for id in ["transparency", "expandStroke", "insetPath"] {
            #expect(delegate.toolbars.extensions.descriptor(for: id)?.isStub == false, "\(id)")
        }
    }

    @Test func transparencyMixesTheOverlapFromItsSheet() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, extensions) = Self.features(world)
        let id = ContextMenuCatalog.ID.transparency
        #expect(world.commands.command(id)?.validation().reason == PathOperationFeatures.needsTwoFilled)
        let rects = await world.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 20, y: 0, width: 40, height: 40)])
        world.select(rects.map(\.opID))
        #expect(world.commands.command(id)?.validation().isEnabled == true)
        #expect(world.commands.perform(id))
        let model = try #require(features.transparency)
        #expect(world.presented.value.last?.identifier?.rawValue == PathOperationFeatures.Sheet.transparency)
        #expect(model.percent == 50 && model.overlaps && model.mixed != nil)
        Render.view(TransparencySheet(model: model))
        TransparencySheet.text(model).wrappedValue = "140"
        #expect(model.percent == 100)
        TransparencySheet.text(model).wrappedValue = "x"
        model.percent = 30
        let change = await model.confirm()?.value
        #expect(change?.createdObjects.count == 1 && world.document.undoTitle == "Undo Transparency" && features.transparency == nil)
        #expect(world.preferences[PathOperationFeatures.percent] == 30)
        #expect(rects.allSatisfy { world.state.isLive($0.opID) })
        #expect(await world.waitForSelection(.path) == change?.createdObjects.first)
        // Cancel writes nothing; the toolbar button opens the sheet too.
        world.select(rects.map(\.opID))
        #expect(extensions.perform("transparency"))
        try #require(features.transparency).cancel()
        #expect(features.transparency == nil)
        // Paths that do not overlap: the sheet says so and OK writes nothing.
        let far = await world.document.addRectangles([Rect(x: 300, y: 0, width: 10, height: 10)])
        world.select([rects[0].opID, far[0].opID])
        let apart = try #require(features.showTransparency())
        #expect(!apart.overlaps)
        Render.view(TransparencySheet(model: apart))
        #expect(apart.confirm() == nil)
        apart.cancel()
    }

    @Test func expandStrokeReplacesThePathOrKeepsItWithShift() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, extensions) = Self.features(world)
        let id = ContextMenuCatalog.ID.expandStroke
        #expect(world.commands.command(id)?.validation().reason == PathOperationFeatures.needsPath)
        let line = try #require(await world.document.addPath([Point(x: 10, y: 10), Point(x: 110, y: 10)]))
        world.select([line.opID])
        #expect(world.commands.command(id)?.validation().title == "Expand Stroke…")
        #expect(world.commands.perform(id))
        let model = try #require(features.expandStroke)
        #expect(model.width == 1 && model.cap == .butt && model.join == .miter)
        Render.view(ExpandStrokeSheet(model: model))
        model.setWidth(1000)
        #expect(model.width == 500)
        model.setWidth(8)
        model.setMiterLimit(0)
        #expect(model.miterLimit == 1)
        model.cap = .round
        let change = await model.confirm().value
        #expect(world.document.undoTitle == "Undo Expand Stroke" && features.expandStroke == nil)
        #expect(!world.state.isLive(line.opID) && change?.createdObjects.count == 1)
        // With Shift the original stays.
        let other = try #require(await world.document.addPath([Point(x: 10, y: 50), Point(x: 110, y: 50)]))
        world.select([other.opID])
        let (keeping, keepingExtensions) = Self.features(world, shift: true)
        #expect(keeping.expandStrokeValidation.title == "Expand Stroke (keep original)…")
        #expect(keepingExtensions.perform("expandStroke"))
        _ = try await #require(keeping.expandStroke).confirm().value
        #expect(world.state.isLive(other.opID))
        _ = features.showExpandStroke()
        try #require(features.expandStroke).cancel()
        #expect(features.expandStroke == nil)
        _ = extensions
        for title in [WTGeometry.LineCap.butt, .round, .square].map(StrokeControlTitles.title) + [WTGeometry.LineJoin.miter, .round, .bevel].map(StrokeControlTitles.title) {
            #expect(!title.isEmpty)
        }
    }

    @Test func insetPathMakesStepsAndReportsACollapse() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, extensions) = Self.features(world)
        let id = ContextMenuCatalog.ID.insetPath
        let open = try #require(await world.document.addPath([Point(x: 10, y: 10), Point(x: 110, y: 10)]))
        world.select([open.opID])
        #expect(world.commands.command(id)?.validation().reason == PathOperationFeatures.needsClosed)
        let square = try #require(await world.document.addRectangles([Rect(x: 0, y: 0, width: 100, height: 100)]).first)
        world.select([square.opID])
        #expect(world.commands.perform(id))
        let model = try #require(features.insetPath)
        #expect(model.steps == 1 && model.distance == 4)
        Render.view(InsetPathSheet(model: model))
        model.setSteps(3.4)
        model.setDistance(10)
        model.setMiterLimit(-2)
        model.spacing = .farther
        #expect(model.steps == 3 && model.miterLimit == 1 && !model.collapses)
        #expect(InsetSpacing.allCases.map(InsetPathModel.title) == ["Uniform", "Farther", "Nearer"])
        let change = await model.confirm()?.value
        let group = try #require(change?.createdObjects.first)
        #expect(world.state.nodeKind(group) == .group && world.state.liveChildren(group).count == 3)
        #expect(world.document.undoTitle == "Undo Inset Path" && !world.state.isLive(square.opID))
        #expect(world.preferences[PathOperationFeatures.insetSteps] == 3 && world.preferences[PathOperationFeatures.insetDistance] == 10)
        // An inset larger than the half-width collapses: the sheet says so and OK writes nothing.
        let small = try #require(await world.document.addRectangles([Rect(x: 200, y: 0, width: 10, height: 10)]).first)
        world.select([small.opID])
        #expect(extensions.perform("insetPath"))
        let collapsing = try #require(features.insetPath)
        collapsing.setDistance(20)
        #expect(collapsing.collapses)
        Render.view(InsetPathSheet(model: collapsing))
        #expect(collapsing.confirm() == nil && world.state.isLive(small.opID))
        collapsing.cancel()
        #expect(features.insetPath == nil)
    }

    @Test func withoutADocumentEverythingIsDisabled() {
        let world = GlueWorld()
        defer { world.close() }
        let features = PathOperationFeatures(target: { nil }, store: world.preferences)
        #expect(features.commands().allSatisfy { !$0.validation().isEnabled })
        for command in features.commands() { if case .perform(let run) = command.action { run() } }
        #expect(features.showTransparency() == nil && features.showExpandStroke() == nil && features.showInsetPath() == nil)
        #expect(features.extensionDescriptors(existing: ExtensionRegistry(descriptors: [])).isEmpty)
        for descriptor in features.extensionDescriptors(existing: ExtensionRegistry()) { _ = descriptor.run?(nil) }
        #expect(features.transparency == nil)
    }
}
