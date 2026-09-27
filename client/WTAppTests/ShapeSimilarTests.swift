import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// IMG-030's app half: the bundled model, the *Shape* item, and the model-absent variant.
@Suite(.serialized) @MainActor struct ShapeSimilarTests {
    final class TestBundleMarker {}

    @Test func theAppCarriesTheModelAndABundleWithoutItHasNoClassifier() async throws {
        #expect(ShapeClassifierResource.url(in: .main) != nil, "the app bundle carries the model")
        let bare = Bundle(for: TestBundleMarker.self)
        #expect(ShapeClassifierResource.url(in: bare) == nil)
        #expect(await ShapeClassifierResource.load(from: bare) == nil, "no model: no classifier")
        // Loading and classifying opens no socket (the sandbox audit's rule): nothing leaves the Mac.
        let before = SocketMonitor.openSockets().filter { $0.family == .internet }
        let classification = try #require(await ShapeClassifierResource.load())
        let square = Contour(polygon: [Point(x: 0, y: 0), Point(x: 30, y: 0), Point(x: 30, y: 30), Point(x: 0, y: 30)])
        #expect(classification.classifier.classify(try #require(ShapeFeatures([square]))) == .rectangle)
        #expect(SocketMonitor.openSockets().filter { $0.family == .internet }.isSubset(of: before))
    }

    @Test func shapeSelectsEveryCircleOnThePageAndReportsTheCount() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = SelectSimilarCommands(window: { world.window })
        features.shiftDown = { false }
        #expect(await features.runShape(in: world.window, adding: false) == nil, "nothing selected")
        let loaded: ShapeClassification = try #require(await ShapeClassifierResource.load())
        features.classifier = loaded
        features.install(commands: world.commands)
        let shape = SelectSimilarCommands.id(.shape)
        #expect(world.commands.command(shape)?.title == "Shape")
        let origin = world.document.activePage.origin
        var circles: [OpID] = []
        for (index, size) in [16.0, 60.0, 140.0].enumerated() {
            let transform = AffineTransform.rotation(radians: Double(index)).concatenating(.translation(x: origin.x + 40 + Double(index) * 160, y: origin.y + 100))
            circles.append(try #require(await world.document.perform(CreateShape(.ellipse, size: Size(width: size, height: size), transform: transform,
                                                                                 appearance: TestAppearance.filled)).value?.createdObjects.first))
        }
        let squares = await world.document.addRectangles([Rect(x: origin.x + 40, y: origin.y + 400, width: 50, height: 50),
                                                          Rect(x: origin.x + 200, y: origin.y + 400, width: 90, height: 30)])
        world.select([circles[1]])
        let outcome = try #require(await features.runShape(in: world.window, adding: false))
        #expect(Set(outcome.selection) == Set(circles) && Set(world.window.selection.model.ids.map(\.opID)) == Set(circles))
        #expect(world.window.statusBar.message.stringValue == "3 objects selected")
        // The menu item runs the same thing off the main actor.
        world.select([squares[0].opID])
        #expect(world.commands.perform(shape))
        for _ in 0..<400 where Set(world.window.selection.model.ids) != Set(squares) { await Task.yield() }
        #expect(Set(world.window.selection.model.ids) == Set(squares))
    }

    @Test func theGlueAddsShapeOnceTheModelLoads() async throws {
        let world = GlueWorld()
        defer { world.close() }
        for loaded in [false, true] {
            let commands = CommandRegistry()
            let glue = DocumentGlueFeatures(preferences: world.preferences) { world.window }
            let classification = loaded ? await ShapeClassifierResource.load() : nil
            glue.loadShapeClassifier = { classification }
            let changed = TestBox(0)
            glue.onMenuChange = { changed.value += 1 }
            glue.install(commands: commands, panels: PanelRegistry(), extensions: ExtensionRegistry(), documents: nil)
            await glue.shapeLoading?.value
            #expect((commands.command(SelectSimilarCommands.id(.shape)) != nil) == loaded)
            #expect(changed.value == (loaded ? 1 : 0))
            glue.profileScan.timer?.invalidate()
        }
    }
}
