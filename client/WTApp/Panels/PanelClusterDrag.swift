import AppKit

/// The document window's part in magnetic panels (D-077): where clusters dock and what is
/// already there.  `DocumentWindowController` is one.
@MainActor
protocol PanelHost: AnyObject {
    /// The content area beside the top strip (the canvas area), in screen points: its left and
    /// right edges are where clusters dock.
    var panelArea: CGRect { get }
    /// The window's docks: the two side docks and the two strips.
    var panelDocks: [PanelDockController] { get }
    /// The window floating clusters ride along with.
    var panelWindow: NSWindow? { get }
}

extension LayoutRect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension PanelSnapScene {
    /// What a cluster dragged near `host` can click to: the window's edges, its docked clusters
    /// and strips, and every floating cluster in `floating` -- never the cluster `excluding`.
    @MainActor
    static func make(host: PanelHost?, floating: [FloatingPanelWindow], excluding: PanelCluster.ID) -> PanelSnapScene {
        var scene = PanelSnapScene()
        if let host {
            let area = host.panelArea
            scene.window = area.isEmpty ? nil : area
            for dock in host.panelDocks {
                if let cluster = dock.snapCluster(), cluster.id != excluding { scene.clusters.append(cluster) }
                if let strip = dock.snapStrip() { scene.strips[dock.edge] = strip }
                scene.headers += dock.snapHeaders()
            }
        }
        for window in floating where window.clusterID != excluding && window.isVisible {
            guard let view = window.clusterView, let geometry = view.snapGeometry(id: window.clusterID, edge: nil) else { continue }
            scene.clusters.append(geometry)
            scene.headers += view.snapHeaders()
        }
        return scene
    }
}

/// One drag of a cluster by a group's title bar or gripper (D-077, magnetic panels; panels.adoc,
/// "Docking and floating").  Beginning it takes the cluster off its edge -- or, with Option, takes
/// the group out of its cluster -- so what moves is always a floating cluster; each position is
/// snapped (`PanelSnapping`), the window drawn where it clicks and the preview shown; releasing
/// settles it and applies the join to the layout.  Escape puts everything back.  The mouse loop
/// (`track`) only feeds it positions, so tests drive it directly.
@MainActor
final class PanelClusterDrag {
    let layoutController: PanelLayoutController
    let groupID: PanelGroup.ID
    /// The floating cluster being moved.
    let clusterID: PanelCluster.ID
    /// Whether the group was pulled out of its cluster (Option-drag).
    let detached: Bool
    /// The moving cluster's frame when the drag began, and the pointer then (screen points).
    let origin: CGRect
    let start: CGPoint
    /// How many groups move (a lone group can merge into another's tabs).
    let groupCount: Int
    private let before: PanelLayout
    /// What the cluster can click to.
    var scene = PanelSnapScene()
    private(set) var snap: PanelSnap
    private(set) var isFinished = false
    /// Whether Escape ended it.
    private(set) var wasCancelled = false

    /// Draws the moving cluster's window at a frame (nothing in tests without windows).
    var place: @MainActor (PanelCluster.ID, CGRect) -> Void = { _, _ in }
    /// Shows the join preview; nil hides it.
    var preview: @MainActor (PanelSnap.Guide?) -> Void = { _ in }
    /// A haptic tick as the cluster clicks to something new.
    var click: @MainActor () -> Void = {}
    /// Moves the window to its settled frame, then calls back to apply the layout change.
    var settle: @MainActor (PanelCluster.ID, CGRect, @escaping @MainActor () -> Void) -> Void = { _, _, done in done() }

    /// Starts dragging `group`'s cluster (or, when `detach`, `group` alone) with the pointer at
    /// `pointer`.  `groupFrame` and `clusterFrame` are where the group and its cluster are on
    /// screen.  Nil when the group is not in the layout.
    init?(group: PanelGroup.ID, layout: PanelLayoutController, pointer: CGPoint, groupFrame: CGRect, clusterFrame: CGRect?, detach: Bool) {
        let before = layout.layout
        guard before.group(group) != nil else { return nil }
        let current = before.cluster(containing: group)
        var moving: PanelCluster.ID?
        var pulledOut = false
        layout.update { layout in
            if let current, !(detach && current.groups.count > 1) {
                if current.edge != nil { layout.undock(cluster: current.id, frame: LayoutRect(clusterFrame ?? groupFrame)) }
                moving = current.id
            } else {
                // A strip's group, or Option: the group alone.  A collapsed group keeps a usable
                // height for when it is expanded; its top stays under the pointer.
                let height = max(groupFrame.height, 160)
                let frame = CGRect(x: groupFrame.minX, y: groupFrame.maxY - height, width: groupFrame.width, height: height)
                moving = layout.detach(group: group, frame: LayoutRect(frame))
                pulledOut = true
            }
        }
        guard let moving, let cluster = layout.layout.cluster(moving), let frame = cluster.frame else { return nil }
        self.layoutController = layout
        self.groupID = group
        self.clusterID = moving
        self.detached = pulledOut
        self.origin = frame.cgRect
        self.start = pointer
        self.groupCount = cluster.groups.count
        self.before = before
        snap = PanelSnap(target: nil, frame: frame.cgRect, guide: nil)
    }

    /// The pointer moved to `pointer`: the cluster follows, clicking to what is in range.
    func move(to pointer: CGPoint) {
        guard !isFinished else { return }
        let moving = origin.offsetBy(dx: pointer.x - start.x, dy: pointer.y - start.y)
        let next = PanelSnapping.snap(moving: moving, pointer: pointer, groupCount: groupCount, scene: scene)
        if next.target != nil, next.target != snap.target { click() }
        snap = next
        place(clusterID, next.frame)
        preview(next.guide)
    }

    /// The button came up at `pointer`: the cluster settles where it clicked (or where it is)
    /// and the layout takes the change.
    func finish(at pointer: CGPoint) {
        guard !isFinished else { return }
        move(to: pointer)
        isFinished = true
        preview(nil)
        let result = snap
        let id = clusterID
        let layout = layoutController
        settle(id, result.frame) {
            layout.update { layout in
                if let target = result.target {
                    layout.attach(cluster: id, to: target)
                } else {
                    layout.setFrame(LayoutRect(result.frame), cluster: id)
                }
            }
        }
    }

    /// Escape: everything goes back to where it was before the drag.
    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        wasCancelled = true
        preview(nil)
        place(clusterID, origin)
        let before = before
        layoutController.update { $0 = before }
    }

    /// Feeds the mouse to `drag` until the button comes up (or Escape is pressed).  A button
    /// already up before any drag event (a synthetic mouse-down) cancels; a button that came up
    /// unseen after dragging finishes where the pointer is.
    static func track(_ drag: PanelClusterDrag, buttonIsDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        var dragged = false
        while !drag.isFinished {
            guard let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true) else {
                if !buttonIsDown() {
                    if dragged { drag.finish(at: NSEvent.mouseLocation) } else { drag.cancel() }
                }
                continue
            }
            switch event.type {
            case .leftMouseDragged:
                dragged = true
                drag.move(to: NSEvent.mouseLocation)
            case .leftMouseUp: drag.finish(at: NSEvent.mouseLocation)
            case .keyDown where event.keyCode == 53: drag.cancel()
            default: break
            }
        }
    }
}

/// The preview of a join while a cluster is dragged: an accent line along the edges that will
/// meet, the area a cluster will take at a window edge, or a lit header.  A borderless window
/// that ignores the mouse, above the document window and its floating clusters.
@MainActor
final class PanelSnapPreview {
    private(set) var window: NSPanel?
    private(set) var guide: PanelSnap.Guide?

    func show(_ guide: PanelSnap.Guide?, over parent: NSWindow?) {
        self.guide = guide
        guard let guide else {
            window?.orderOut(nil)
            return
        }
        let panel = window ?? makeWindow()
        window = panel
        let rect: CGRect
        switch guide {
        case let .line(line): rect = line
        case let .area(area): rect = area
        case let .header(header): rect = header
        }
        (panel.contentView as? PanelSnapPreviewView)?.guide = guide
        panel.setFrame(rect.integral, display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent?.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func close() {
        window?.parent?.removeChildWindow(window!)
        window?.close()
        window = nil
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = PanelSnapPreviewView()
        panel.setAccessibilityElement(false)
        return panel
    }
}

/// Draws a snap preview.
@MainActor
final class PanelSnapPreviewView: NSView {
    var guide: PanelSnap.Guide? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        switch guide {
        case .line?:
            accent.setFill()
            let radius = min(bounds.width, bounds.height) / 2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        case .area?, .header?:
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.16).setFill()
            shape.fill()
            accent.setStroke()
            shape.lineWidth = 3
            shape.stroke()
        case nil:
            break
        }
    }
}

extension PanelInteraction {
    /// The document window a group view belongs to: its own, or -- in a floating cluster -- the
    /// one the cluster rides along with.
    static func host(of window: NSWindow?) -> PanelHost? {
        if let floating = window as? FloatingPanelWindow { return floating.parent?.windowController as? PanelHost }
        return window?.windowController as? PanelHost
    }

    /// Every floating cluster window.
    static var floatingWindows: [FloatingPanelWindow] {
        NSApp.windows.compactMap { $0 as? FloatingPanelWindow }
    }

    /// A drag of `groupView`'s title bar or gripper: its cluster moves (Option: the group alone),
    /// clicking to window edges and other clusters.
    func beginClusterDrag(from groupView: PanelGroupView, event: NSEvent) {
        let window = groupView.window
        func screen(_ view: NSView) -> CGRect {
            guard let window else { return view.convert(view.bounds, to: nil) }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        var cluster: NSView? = groupView.superview
        while let view = cluster, !(view is PanelClusterView) { cluster = view.superview }
        let detach = event.modifierFlags.contains(.option) || Self.optionIsDown()
        let pointer = window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        guard let drag = PanelClusterDrag(group: groupView.group.id, layout: layoutController, pointer: pointer, groupFrame: screen(groupView),
                                          clusterFrame: cluster.map(screen), detach: detach)
        else { return }
        let host = Self.host(of: window)
        drag.scene = PanelSnapScene.make(host: host, floating: Self.floatingWindows, excluding: drag.clusterID)
        let preview = PanelSnapPreview()
        let parent = host?.panelWindow
        drag.place = { id, frame in
            guard let moving = Self.floatingWindows.first(where: { $0.clusterID == id }) else { return }
            moving.isTracking = true
            moving.setFrame(frame, display: true)
            moving.orderFront(nil)
        }
        drag.preview = { guide in preview.show(guide, over: parent) }
        drag.click = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        drag.settle = { id, frame, done in
            let moving = Self.floatingWindows.first { $0.clusterID == id }
            let finish: @MainActor @Sendable () -> Void = {
                moving?.isTracking = false
                preview.close()
                done()
            }
            guard let moving, moving.isVisible, Self.settleDuration > 0, !PanelGlass.reducesMotion, !NSEqualRects(moving.frame, frame) else {
                finish()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.settleDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                moving.animator().setFrame(frame, display: true)
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        }
        clusterDrag = drag
        runClusterDrag(drag)
        if !drag.isFinished { drag.cancel() }
        if drag.wasCancelled {
            for window in Self.floatingWindows { window.isTracking = false }
            preview.close()
        }
    }

    /// How long a released cluster takes to settle into place (0: at once).
    static var settleDuration: TimeInterval = 0.14

    /// Whether Option is held (read as the drag begins, with the mouse-down's own flags).
    static var optionIsDown: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }
}
