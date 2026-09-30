import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The point items of the context menu on selected points and of menu:Modify[Points] (ctx;
/// editing-paths.adoc, "Changing points"; context-menus.adoc, "Selected points").
@Suite(.serialized) @MainActor struct PointTypeCommandsTests {
    /// A window with an open three-point path and a closed triangle, the point commands and the
    /// standard ones registered against it.
    @MainActor final class Fixture {
        let environment = TestEnvironment()
        let controller: DocumentWindowController
        var open = SelectionID(NodeID(counter: 0, replica: 0))
        var closed = SelectionID(NodeID(counter: 0, replica: 0))

        init() {
            StandardCommands.register(into: environment.commands)
            PanelCommands.sync(into: environment.commands, panels: environment.panels, layout: environment.layout)
            controller = DocumentWindowController(document: .memory(title: "Points"), environment: environment.document)
            let controller = controller
            for command in PointTypeCommands.commands(window: { controller }) { environment.commands.replace(command) }
        }

        static func make() async throws -> Fixture {
            let fixture = Fixture()
            let document = fixture.controller.documentHandle
            fixture.open = try #require(await document.addPath([Point(x: 7500, y: 7500), Point(x: 7560, y: 7500), Point(x: 7560, y: 7560)]))
            fixture.closed = try #require(await document.addPath([Point(x: 7700, y: 7500), Point(x: 7760, y: 7500), Point(x: 7730, y: 7540)], closed: true))
            return fixture
        }

        var document: DocumentHandle { controller.documentHandle }
        var registry: CommandRegistry { environment.commands }

        func point(_ id: SelectionID, _ index: Int) -> PointReference {
            let contour = document.path(id)!.contours[0]
            return PointReference(node: id.node, contour: contour.id, point: contour.drawn[index].id)
        }

        func select(_ points: [SelectionID: [PointReference]]) {
            controller.selection.model.set(Selection().applying(Array(points.keys).sorted(), sub: points.mapValues { .points(Set($0)) }, mode: .replace))
        }

        func validation(_ id: CommandID) -> CommandValidation? { registry.command(id)?.validation() }

        func run(_ id: CommandID) async {
            _ = registry.perform(id) { _ in true }
            await document.settle()
        }

        func close() { controller.close() }
    }

    @Test func theTargetOfSelectedPointsHasThePointItemsFirst() async throws {
        let f = try await Fixture.make()
        defer { f.close() }
        #expect(ContextMenuTarget.points([.path]).contexts == [.path, .points])
        #expect(ContextMenuTarget.points([.path, .path]).contexts == [.path, .multiple, .points])
        #expect(ContextMenuCatalog.entries(for: .points([.path])).prefix(3) == ContextMenuCatalog.pointEntries[...])

        f.select([f.open: [f.point(f.open, 1)]])
        f.controller.canvas.setViewport(f.controller.viewport.scrolled(byViewDelta: f.controller.viewport.toView(Point(x: 7530, y: 7500)) - f.controller.viewport.viewCenter))
        let menu = f.controller.contextMenu(at: f.controller.viewport.toView(Point(x: 7530, y: 7500)))
        #expect(f.controller.contextTarget == .points([.path]))
        #expect(menu.items.prefix(3).map(\.title) == ["Point Type", "Retract Handles", "Automatic"])
        #expect(menu.items[0].submenu?.items.map(\.title) == ["Corner", "Curve", "Connector"])
        #expect(menu.items.contains { $0.title == "Path" }, "the path's own items follow")

        // The same path without points selected: the object menu.
        f.controller.selection.model.set(Selection([f.open]))
        _ = f.controller.contextMenu(at: f.controller.viewport.toView(Point(x: 7530, y: 7500)))
        #expect(f.controller.contextTarget == .objects([.path]))
    }

    @Test func theTypeItemsAreCheckedOrDashedAndActOnEveryPoint() async throws {
        let f = try await Fixture.make()
        defer { f.close() }
        let corner = PointTypeCommands.ID.kind(.corner), curve = PointTypeCommands.ID.kind(.curve)
        let connector = PointTypeCommands.ID.kind(.connector)
        #expect(f.validation(corner)?.isEnabled == false && f.validation(corner)?.reason == PointTypeCommands.noPoints)
        #expect(f.validation(PointTypeCommands.ID.retract)?.isEnabled == false)
        #expect(f.validation(PointTypeCommands.ID.automatic)?.isEnabled == false)

        f.select([f.open: [f.point(f.open, 0), f.point(f.open, 1)], f.closed: [f.point(f.closed, 2)]])
        #expect(f.validation(corner) == CommandValidation(isChecked: true))
        #expect(f.validation(curve) == CommandValidation())

        let changes = f.document.changeCount
        await f.run(curve)
        #expect(f.document.changeCount == changes + 1 && f.document.undoTitle == "Undo Set Point Type")
        #expect(f.validation(curve)?.isChecked == true && f.validation(corner)?.isChecked == false)

        // Mixed: one point back to corner.
        f.select([f.open: [f.point(f.open, 1)]])
        await f.run(corner)
        f.select([f.open: [f.point(f.open, 0), f.point(f.open, 1)], f.closed: [f.point(f.closed, 2)]])
        #expect(f.validation(corner) == CommandValidation(isMixed: true))
        #expect(f.validation(curve) == CommandValidation(isMixed: true))
        #expect(f.validation(connector) == CommandValidation())
        #expect(f.validation(curve)?.controlState == .mixed && CommandValidation(isChecked: true).controlState == .on)
        #expect(CommandValidation().controlState == .off)

        // Automatic: off, then on for all, then mixed, and on again from mixed.
        #expect(f.validation(PointTypeCommands.ID.automatic) == CommandValidation())
        await f.run(PointTypeCommands.ID.automatic)
        #expect(f.document.undoTitle == "Undo Automatic" && f.validation(PointTypeCommands.ID.automatic)?.isChecked == true)
        f.select([f.closed: [f.point(f.closed, 2)]])
        await f.run(PointTypeCommands.ID.automatic)
        #expect(f.validation(PointTypeCommands.ID.automatic)?.isChecked == false)
        f.select([f.open: [f.point(f.open, 0), f.point(f.open, 1)], f.closed: [f.point(f.closed, 2)]])
        #expect(f.validation(PointTypeCommands.ID.automatic) == CommandValidation(isMixed: true))
        await f.run(PointTypeCommands.ID.automatic)
        #expect(f.validation(PointTypeCommands.ID.automatic)?.isChecked == true)
        await f.run(PointTypeCommands.ID.automatic)

        await f.run(PointTypeCommands.ID.retract)
        #expect(f.document.undoTitle == "Undo Retract Handles")
        let drawn = try #require(f.document.path(f.open)?.contours.first?.drawn)
        #expect(drawn.prefix(2).allSatisfy { $0.inHandle == .zero && $0.outHandle == .zero })
    }

    @Test func theMenuBarHasThePointsSubmenuInModify() async throws {
        let f = try await Fixture.make()
        defer { f.close() }
        let commands = PointTypeCommands.commands(window: { nil })
        #expect(commands.map(\.title) == ["Corner", "Curve", "Connector", "Retract Handles", "Automatic"])
        #expect(commands.allSatisfy { $0.menuPath?.components == ["Modify", "Points"] && $0.contexts == [.points] })
        #expect(commands.allSatisfy { $0.validation().reason == ViewCommands.noDocument })
        for command in commands { if case let .perform(action) = command.action { action() } }
        let tree = MenuTreeBuilder.build(registry: f.registry, shortcuts: ShortcutSet.builtInDefault(commands: f.registry.commands))
        let modify = tree.menus.first { $0.title == "Modify" }
        guard case let .submenu(_, items)? = modify, case let .submenu(_, points)? = items.first(where: { $0.title == "Points" }) else {
            Issue.record("Modify ▸ Points")
            return
        }
        #expect(points.map(\.title) == ["Corner", "Curve", "Connector", nil, "Retract Handles", "Automatic"])
        #expect(ContextMenuResolver.hasSelectedPoints(.empty, document: f.document) == false)
    }

    @Test func aLiveShapesPointsConvertItInTheSameChange() async throws {
        let f = try await Fixture.make()
        defer { f.close() }
        let ids = await f.document.addRectangles([Rect(x: 7900, y: 7500, width: 40, height: 40)])
        let contour = try #require(f.document.object(for: ids[0])?.path?.contours.first)
        f.select([ids[0]: contour.drawn.prefix(2).map { PointReference(node: ids[0].node, contour: contour.id, point: $0.id) }])
        #expect(ContextMenuResolver.hasSelectedPoints(f.controller.selection.model.selection, document: f.document))
        let changes = f.document.changeCount
        await f.run(PointTypeCommands.ID.kind(.curve))
        #expect(f.document.changeCount == changes + 1, "the conversion and the type are one change")
        #expect(f.document.object(for: ids[0]) == nil, "the rectangle became a path")
        #expect(f.document.selectableIDs().contains { f.document.object(for: $0)?.kind == .path && f.document.path($0)?.contours.first?.drawn.contains { $0.kind == .curve } == true })
    }
}
