import AppKit
import Foundation
import Testing
@testable import WireTuner

/// Dragging clusters (D-077, magnetic panels): the whole cluster moves, Option pulls one group
/// out, releasing near an edge joins it, Escape puts everything back.  Driven through
/// `PanelClusterDrag` directly (tests have no mouse).
@Suite @MainActor struct PanelClusterDragTests {
    private func controller() -> PanelLayoutController {
        let registry = PanelRegistry()
        for id in ["object", "layers", "swatches"] {
            registry.registerIfAbsent(PanelDescriptor(id: PanelID(rawValue: id), title: id.capitalized, defaultGroup: id.capitalized, menuOrder: 0) { NSView() })
        }
        let layout = PanelLayoutController(registry: registry)
        layout.load()
        return layout
    }

    private let window = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func draggingOneGroupMovesItsWholeCluster() throws {
        let layout = controller()
        layout.update { layout in
            layout.detach(group: "layers", frame: LayoutRect(x: 400, y: 300, width: 260, height: 400))
            layout.detach(group: "swatches", frame: LayoutRect(x: 0, y: 0, width: 260, height: 200))
            layout.attach(cluster: "swatches", to: .stack(cluster: "layers", column: 0, index: 1))
        }
        let start = try #require(layout.layout.cluster("layers")?.frame)
        let drag = try #require(PanelClusterDrag(group: "swatches", layout: layout, pointer: CGPoint(x: 500, y: 390), groupFrame: CGRect(x: 400, y: 300, width: 260, height: 200),
                                                 clusterFrame: start.cgRect, detach: false))
        #expect(drag.clusterID == "layers" && !drag.detached && drag.groupCount == 2)
        drag.scene = PanelSnapScene(window: window)
        var placed: [CGRect] = []
        drag.place = { _, frame in placed.append(frame) }
        drag.move(to: CGPoint(x: 560, y: 350))
        drag.finish(at: CGPoint(x: 600, y: 340))
        let moved = try #require(layout.layout.cluster("layers"))
        #expect(moved.groups.map(\.id) == ["layers", "swatches"], "both groups moved together")
        #expect(start == LayoutRect(x: 400, y: 100, width: 260, height: 600), "Swatches stacked under Layers")
        #expect(moved.frame == LayoutRect(x: 500, y: 50, width: 260, height: 600))
        #expect(placed == [CGRect(x: 460, y: 60, width: 260, height: 600), CGRect(x: 500, y: 50, width: 260, height: 600)])
        #expect(drag.isFinished)
        drag.move(to: .zero)
        #expect(placed.count == 2, "a finished drag ignores the mouse")
    }

    @Test func optionPullsJustThatGroupOutOfADockedCluster() throws {
        let layout = controller()
        #expect(layout.layout.dockedCluster(.right)?.groups.map(\.id) == ["object", "layers", "swatches"])
        let drag = try #require(PanelClusterDrag(group: "layers", layout: layout, pointer: CGPoint(x: 1000, y: 590), groupFrame: CGRect(x: 920, y: 400, width: 280, height: 28),
                                                 clusterFrame: CGRect(x: 920, y: 0, width: 280, height: 800), detach: true))
        #expect(drag.detached && drag.clusterID == "layers" && drag.groupCount == 1)
        // A collapsed group keeps a usable height, its top under the pointer.
        #expect(drag.origin == CGRect(x: 920, y: 428 - 160, width: 280, height: 160))
        #expect(layout.layout.dockedCluster(.right)?.groups.map(\.id) == ["object", "swatches"], "the rest stay docked")
        drag.scene = PanelSnapScene(window: window)
        drag.finish(at: CGPoint(x: 600, y: 590))
        #expect(layout.layout.cluster("layers")?.frame == LayoutRect(x: 520, y: 268, width: 280, height: 160))
        #expect(layout.layout.dockedCluster(.right)?.groups.count == 2)
    }

    @Test func aPlainDragUndocksTheClusterAndReleasingAtAnEdgeDocksIt() throws {
        let layout = controller()
        let drag = try #require(PanelClusterDrag(group: "layers", layout: layout, pointer: CGPoint(x: 1000, y: 590), groupFrame: CGRect(x: 920, y: 400, width: 280, height: 200),
                                                 clusterFrame: CGRect(x: 920, y: 0, width: 280, height: 800), detach: false))
        #expect(drag.clusterID == "right" && layout.layout.dockedCluster(.right) == nil && layout.layout.cluster("right")?.groups.count == 3)
        drag.scene = PanelSnapScene(window: window)
        var clicks = 0
        var guides: [PanelSnap.Guide?] = []
        drag.click = { clicks += 1 }
        drag.preview = { guides.append($0) }
        // Out into the canvas: floating, no preview.
        drag.move(to: CGPoint(x: 500, y: 590))
        #expect(drag.snap.target == nil && guides.last! == nil && clicks == 0)
        // To the left edge, 8 points off: it clicks there and the area shows.
        drag.move(to: CGPoint(x: 88, y: 590))
        #expect(drag.snap.target == .dock(.left) && clicks == 1)
        #expect(guides.last! == .area(CGRect(x: 0, y: 0, width: 280, height: 800)))
        drag.move(to: CGPoint(x: 86, y: 580))
        #expect(clicks == 1, "moving within the same snap does not click again")
        var settled: CGRect?
        drag.settle = { _, frame, done in
            settled = frame
            done()
        }
        drag.finish(at: CGPoint(x: 86, y: 580))
        #expect(settled == CGRect(x: 0, y: 0, width: 280, height: 800))
        #expect(guides.last! == nil, "the preview goes on release")
        #expect(layout.layout.dockedCluster(.left)?.groups.map(\.id) == ["object", "layers", "swatches"])
    }

    @Test func escapePutsEverythingBack() throws {
        let layout = controller()
        let before = layout.layout
        let drag = try #require(PanelClusterDrag(group: "object", layout: layout, pointer: CGPoint(x: 1000, y: 790), groupFrame: CGRect(x: 920, y: 600, width: 280, height: 200),
                                                 clusterFrame: CGRect(x: 920, y: 0, width: 280, height: 800), detach: true))
        #expect(layout.layout != before)
        var placed: CGRect?
        drag.place = { _, frame in placed = frame }
        drag.move(to: CGPoint(x: 300, y: 300))
        drag.cancel()
        #expect(layout.layout == before && drag.wasCancelled && placed == drag.origin)
        drag.finish(at: .zero)
        #expect(layout.layout == before, "nothing more happens after Escape")
        #expect(PanelClusterDrag(group: "nope", layout: layout, pointer: .zero, groupFrame: .zero, clusterFrame: nil, detach: false) == nil)
    }

    @Test func releasedBesideAFloatingClusterItBecomesAColumnOfIt() throws {
        let layout = controller()
        layout.update { $0.detach(group: "swatches", frame: LayoutRect(x: 200, y: 200, width: 260, height: 400)) }
        let drag = try #require(PanelClusterDrag(group: "layers", layout: layout, pointer: CGPoint(x: 1000, y: 590), groupFrame: CGRect(x: 920, y: 400, width: 280, height: 200),
                                                 clusterFrame: nil, detach: true))
        drag.scene = PanelSnapScene(window: window, clusters: [PanelSnapScene.Cluster(id: "swatches", edge: nil, frame: CGRect(x: 200, y: 200, width: 260, height: 400),
                                                                                      columns: [PanelSnapScene.Column(frame: CGRect(x: 200, y: 200, width: 260, height: 400), groupFrames: [CGRect(x: 200, y: 200, width: 260, height: 400)])])])
        // Its left edge to 6 points right of Swatches' right edge.
        drag.finish(at: CGPoint(x: 1000 - (920 - 466), y: 590))
        #expect(layout.layout.cluster("swatches")?.columns.map { $0.groups.map(\.id) } == [["swatches"], ["layers"]])
        #expect(layout.layout.cluster("layers") == nil)
    }
}

/// Clusters in a real document window: docked ones are part of it, floating ones are not.
@Suite @MainActor struct MagneticPanelWindowTests {
    private func window(_ environment: TestEnvironment, tools: Bool = false) -> DocumentWindowController {
        if tools {
            environment.panels.groupDefaults[PanelCatalog.Group.tools] = PanelCatalog.groupDefaults[PanelCatalog.Group.tools]
            environment.panels.registerIfAbsent(ToolsPanel.descriptor(model: ToolPaletteModel()))
            environment.layout.addRegisteredPanels()
        }
        let controller = DocumentWindowController(document: .memory(id: UUID().uuidString, title: "Magnetic"), environment: environment.document)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func aDockedClusterIsFlushAndMovesAndResizesWithTheWindow() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        let dock = controller.dock.view
        #expect(abs(dock.frame.maxX - content.bounds.maxX) < 0.5, "flush with the window edge")
        #expect(abs(controller.dock.clusterView.frame.width - dock.bounds.width) < 0.5 && controller.dock.clusterView.frame.minX == 0)
        let height = dock.frame.height
        #expect(abs(dock.frame.minY - content.bounds.minY) < 0.5 && abs(height - controller.rulerHost.frame.height) < 0.5, "the height of the content area")
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1500, height: 900))
        content.layoutSubtreeIfNeeded()
        #expect(abs(dock.frame.maxX - 1500) < 0.5 && abs(dock.frame.height - controller.rulerHost.frame.height) < 0.5 && dock.frame.height > height)
        // In screen points it is at the window's edge, which is what snapping sees.
        let area = controller.panelArea
        let snapped = try #require(controller.dock.snapCluster())
        #expect(abs(snapped.frame.maxX - area.maxX) < 0.5 && snapped.edge == .right && snapped.columns.count == 1)
        #expect(controller.panelDocks.count == 4 && controller.panelWindow === window)
        #expect(controller.dock.snapHeaders().map(\.group) == controller.dock.groupViews.map(\.group.id))
        #expect(controller.topDock.snapStrip() == nil && controller.topDock.snapCluster() == nil, "an empty strip is no target")
    }

    @Test func theSafeAreaExcludesDockedClustersButNotFloatingOnes() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        let docked = controller.canvas.safeInsets.right
        #expect(docked > 250, "the docked cluster and its handle are left out")
        environment.layout.update { $0.undock(cluster: "right", frame: LayoutRect(x: 600, y: 100, width: 280, height: 500)) }
        content.layoutSubtreeIfNeeded()
        #expect(controller.dock.view.isHidden && controller.rightHandle.isHidden)
        #expect(abs(controller.canvas.safeInsets.right - Double(RulerHostView.scrollerWidth)) < 0.5, "a floating cluster covers nothing")
        environment.layout.update { $0.attach(cluster: "right", to: .dock(.right)) }
        content.layoutSubtreeIfNeeded()
        #expect(abs(controller.canvas.safeInsets.right - docked) < 0.5 && !controller.rightHandle.isHidden)
    }

    @Test func dragsInTheWindowUseItsEdgesAndClusters() throws {
        let environment = TestEnvironment()
        let controller = window(environment)
        let floating = FloatingPanelsController(panels: environment.panels, layout: environment.layout, interaction: controller.panelInteraction)
        floating.parentWindow = { controller.window }
        defer {
            for window in floating.windows.values { window.close() }
            controller.close()
        }
        controller.window?.orderFront(nil)
        PanelInteraction.settleDuration = 0
        defer { PanelInteraction.settleDuration = 0.14 }
        let interaction = controller.panelInteraction
        let layers = try #require(controller.dock.groupViews.first { $0.group.id == "layers" })
        var scene: PanelSnapScene?
        interaction.runClusterDrag = { drag in
            scene = drag.scene
            // Out to the middle of the canvas, then released there.
            let start = drag.start
            drag.move(to: CGPoint(x: start.x - 500, y: start.y - 50))
            drag.finish(at: CGPoint(x: start.x - 500, y: start.y - 50))
        }
        let option = NSEvent.mouseEvent(with: .leftMouseDown, location: layers.convert(NSPoint(x: 60, y: 10), to: nil), modifierFlags: [.option], timestamp: 0,
                                        windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        layers.onDragGroup?(option)
        let drag = try #require(interaction.clusterDrag)
        #expect(drag.detached && drag.clusterID == "layers")
        let seen = try #require(scene)
        #expect(seen.window == controller.panelArea)
        #expect(seen.clusters.map(\.id) == ["right"] && seen.clusters[0].edge == .right, "the docked rest, not the dragged group")
        #expect(seen.headers.contains { $0.group == "properties" } && !seen.headers.contains { $0.group == "layers" })
        let window = try #require(floating.windows["layers"])
        #expect(window.clusterView?.attachment == .floating && window.groupViews.map(\.group.id) == ["layers"])
        let stored = environment.layout.layout.cluster("layers")?.frame?.cgRect
        #expect(!window.isTracking && stored == drag.snap.frame, "released where it was dropped")
        // The window rounds to whole points.
        #expect(abs((stored?.minX ?? 0) - window.frame.minX) < 1 && abs((stored?.maxY ?? 0) - window.frame.maxY) < 1, "\(String(describing: stored)) vs \(window.frame)")
        // Escape during a plain drag of the floating group puts it back.
        interaction.runClusterDrag = { drag in
            drag.move(to: CGPoint(x: drag.start.x + 40, y: drag.start.y))
            drag.cancel()
        }
        let before = environment.layout.layout
        let plain = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 60, y: 10), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        PanelInteraction.optionIsDown = { false }
        defer { PanelInteraction.optionIsDown = { NSEvent.modifierFlags.contains(.option) } }
        try #require(window.groupViews.first).onDragGroup?(plain)
        #expect(environment.layout.layout == before && !window.isTracking)
        #expect(PanelInteraction.host(of: window) === controller && PanelInteraction.host(of: controller.window) === controller && PanelInteraction.host(of: nil) == nil)
    }

    @Test func theToolsPanelWearsTheSharedChrome() throws {
        let environment = TestEnvironment()
        let controller = window(environment, tools: true)
        defer { controller.close() }
        let tools = try #require(controller.leftDock.groupViews.first)
        let object = try #require(controller.dock.groupViews.first)
        #expect(tools.group.panels == ["tools"])
        // The same cluster chrome as the right-hand panels, docked flush at its edge.
        #expect(controller.leftDock.clusterView.attachment == .docked(.left) && controller.dock.clusterView.attachment == .docked(.right))
        #expect(controller.leftDock.frost?.squareEdge == .left && controller.leftDock.frost?.level == .chrome && controller.leftDock.frost?.strokesOutline == true)
        #expect(tools.superview is DockColumnView && tools.superview?.superview?.superview === controller.leftDock.clusterView)
        #expect(controller.leftDock.view.frame.minX == 0)
        // The same title styling and card as every group.
        #expect(tools.titleLabel.font == object.titleLabel.font && tools.titleLabel.textColor == object.titleLabel.textColor)
        #expect(!tools.bodyCard.isHidden && tools.bodyCard.isTranslucent == object.bodyCard.isTranslucent)
        #expect(tools.titleLabel.stringValue == "Tools" && !tools.titleLabel.isHidden)
        // Narrow, its title bar keeps the name and the Options button, not the gripper and triangle.
        #expect(tools.isCompact && tools.gripper.isHidden && tools.disclosure.isHidden && !tools.optionsButton.isHidden)
        #expect(!object.isCompact && !object.gripper.isHidden && !object.disclosure.isHidden)
        #expect(tools.titleLabel.frame.width > 20, "the name has room")
        #expect(tools.gripper.toolTip == PanelGroupView.dragToolTip && tools.titleBar.toolTip == PanelGroupView.dragToolTip)
    }
}

/// How docked and floating clusters are drawn: square corners and a hairline on the attached side,
/// rounded all round when floating.  Rendered into bitmaps (the frost; the glass does not render).
@Suite @MainActor struct PanelClusterRenderingTests {
    private func render(_ attachment: PanelClusterView.Attachment, size: CGSize = CGSize(width: 200, height: 300)) -> (PanelClusterView, TestBitmap) {
        let view = PanelClusterView(attachment: attachment, translucent: true)
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        return (view, TestBitmap(of: view))
    }

    /// The opacity at a corner, 1 point in from both edges.
    private func corner(_ bitmap: TestBitmap, right: Bool, bottom: Bool) -> CGFloat {
        let x = right ? Int(bitmap.size.width * bitmap.scale) - 2 : 1
        let y = bottom ? Int(bitmap.size.height * bitmap.scale) - 2 : 1
        return bitmap.alpha(x, y)
    }

    @Test func aClusterDockedRightIsSquareAtTheWindowEdgeAndRoundedOnTheCanvasSide() {
        let (view, bitmap) = render(.docked(.right))
        #expect(corner(bitmap, right: true, bottom: false) > 0.4 && corner(bitmap, right: true, bottom: true) > 0.4, "square at the window edge")
        #expect(corner(bitmap, right: false, bottom: false) < 0.05 && corner(bitmap, right: false, bottom: true) < 0.05, "rounded toward the canvas")
        // A hairline along the canvas side, none along the window edge.
        let middle = Int(bitmap.size.height)
        let inside = bitmap.rgb(40, middle)
        let hairline = bitmap.rgb(0, middle)
        let edge = bitmap.rgb(Int(bitmap.size.width * 2) - 1, middle)
        #expect(abs(hairline.r - inside.r) + abs(hairline.g - inside.g) + abs(hairline.b - inside.b) > 0.05)
        #expect(abs(edge.r - inside.r) + abs(edge.g - inside.g) + abs(edge.b - inside.b) < 0.02)
        // The shadow falls on the canvas; the glass runs past the window edge to hide its corners.
        #expect(view.chrome.shadow != nil && view.chrome.layer?.shadowPath != nil)
        #expect(view.chrome.glassFrame(in: view.bounds) == CGRect(x: 0, y: 0, width: 200 + PanelClusterView.dockedCornerRadius, height: 300))
        #expect(view.accessibilityLabel() == "Panels, docked at the right edge")
    }

    @Test func aClusterDockedLeftIsItsMirror() {
        let (view, bitmap) = render(.docked(.left))
        #expect(corner(bitmap, right: false, bottom: false) > 0.4 && corner(bitmap, right: false, bottom: true) > 0.4)
        #expect(corner(bitmap, right: true, bottom: false) < 0.05 && corner(bitmap, right: true, bottom: true) < 0.05)
        #expect(view.chrome.glassFrame(in: view.bounds).minX == -PanelClusterView.dockedCornerRadius)
    }

    @Test func aFloatingClusterIsRoundedAllRound() {
        let (view, bitmap) = render(.floating)
        for (right, bottom) in [(false, false), (true, false), (false, true), (true, true)] {
            #expect(corner(bitmap, right: right, bottom: bottom) < 0.05)
        }
        #expect(bitmap.alpha(Int(bitmap.size.width), Int(bitmap.size.height)) > 0.4, "frosted inside")
        // The window casts the shadow, not the view.
        #expect(view.chrome.shadow == nil && view.chrome.glassFrame(in: view.bounds) == view.bounds)
        #expect(view.accessibilityLabel() == "Floating panels" && view.chrome.cornerRadius == PanelClusterView.floatingCornerRadius)
        // Switching the attachment redraws it docked.
        view.show(columns: [], widths: [], attachment: .docked(.right), clusterID: "c")
        let docked = TestBitmap(of: view)
        #expect(corner(docked, right: true, bottom: false) > 0.4 && view.accessibilityIdentifier() == "panel-cluster.c")
    }

    @Test func columnsShareTheWidthWithDividersBetween() throws {
        let view = PanelClusterView(attachment: .docked(.right), translucent: true)
        view.frame = NSRect(x: 0, y: 0, width: 545, height: 400)
        let a = PanelGroupView(group: PanelGroup(id: "a", panels: ["a"]), title: { $0.rawValue }, body: { _ in NSView() })
        let b = PanelGroupView(group: PanelGroup(id: "b", panels: ["b"]), title: { $0.rawValue }, body: { _ in NSView() })
        view.show(columns: [[a], [b]], widths: [280, 260], attachment: .docked(.right), clusterID: "right")
        view.layoutSubtreeIfNeeded()
        #expect(view.columnViews.map(\.frame.width) == [280, 260] && view.columnDividers.count == 1)
        #expect(view.columnDividers[0].frame.minX == 280 && view.columnDividers[0].frame.width == CGFloat(PanelCluster.columnDividerWidth))
        #expect(view.columnViews[0].identifierPrefix == "panel-divider.right" && view.columnViews[1].identifierPrefix == "panel-divider.right.column1")
        // Docked right, the column beside the canvas takes up a difference in width.
        #expect(view.frames(for: CGSize(width: 565, height: 400)).columns.map(\.width) == [300, 260])
        var resized: (Int, Double)?
        view.onColumnResize = { resized = ($0, $1) }
        view.columnDividers[0].move(by: 16)
        #expect(resized?.0 == 0 && resized?.1 == 296)
        #expect(view.columnDividers[0].accessibilityPerformDecrement() && resized?.1 == 264)
        #expect(view.groupViews.map(\.group.id) == ["a", "b"])
        // All collapsed, a cluster needs its title bars only.
        let collapsed = PanelCluster(id: "c", columns: [PanelColumn(groups: [PanelGroup(id: "a", panels: ["a"], collapsed: true), PanelGroup(id: "b", panels: ["b"], collapsed: true)], width: 200)])
        #expect(PanelClusterView.collapsedHeight(of: collapsed) == 2 * PanelGroupView.titleHeight + DockColumnView.dividerThickness + 2 * PanelClusterView.verticalInset)
        #expect(PanelClusterView.collapsedHeight(of: PanelCluster(id: "d", columns: [PanelColumn(groups: [PanelGroup(id: "a", panels: ["a"])], width: 200)])) == nil)
    }

    @Test func theSnapPreviewDrawsLinesAndAreas() {
        let preview = PanelSnapPreview()
        defer { preview.close() }
        preview.show(.line(CGRect(x: 100, y: 100, width: 4, height: 200)), over: nil)
        #expect(preview.window?.frame == CGRect(x: 100, y: 100, width: 4, height: 200) && preview.window?.ignoresMouseEvents == true)
        preview.show(.area(CGRect(x: 0, y: 0, width: 280, height: 400)), over: nil)
        let view = PanelSnapPreviewView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        for guide in [PanelSnap.Guide.line(.zero), .area(.zero), .header(.zero)] {
            view.guide = guide
            _ = TestBitmap(of: view)
        }
        preview.show(nil, over: nil)
        #expect(preview.guide == nil && preview.window?.isVisible == false)
    }
}
