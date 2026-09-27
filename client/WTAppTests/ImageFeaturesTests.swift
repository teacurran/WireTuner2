import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// An import world with a placed 20 × 10 PNG and the image features over its blob cache.
@MainActor
struct ImageWorld {
    let world = ImportWorld()
    let features: ImageFeatures

    init() {
        features = ImageFeatures(preferences: world.environment.preferences)
        let blobs = world.files.blobs
        features.blobDirectory = { blobs }
    }

    var window: DocumentWindowController { world.window }
    var document: DocumentHandle { world.document }
    var preferences: PreferenceStore { world.environment.preferences }

    /// Places the PNG at `point`; returns its node.
    func placeImage(at point: Point = Point(x: 100, y: 100)) async -> OpID? {
        _ = await world.imports.place([world.files.png()], on: world.window, at: point)
        await document.settle()
        return world.objects.last
    }

    func close() {
        features.detach(window)
        world.window.close()
        world.files.remove()
    }
}

@Suite(.serialized) @MainActor struct ImageFeaturesTests {
    // MARK: Pixels and marks (IMG-004 glue, IMG-006, IMG-017)

    /// COLOR-012's rest: the Eyedropper samples a placed bitmap's own pixel through the window's
    /// image store; without it the image reads as its placeholder.
    @Test func theEyedropperSamplesABitmapsPixel() async throws {
        let world = ImageWorld()
        defer { world.close() }
        let node = try #require(await world.placeImage())
        let store = try #require(world.features.attach(world.window).store)
        let hash = ImageNodes.assetID(world.document.state.props(node).image.pixels)
        let bounds = try #require(world.document.object(for: SelectionID(node))?.bounds)
        let inside = bounds.center
        // The first sample starts the decode of the level it needs; the store answers once it is in.
        var red = EyedropperSampling.pixel(at: inside, in: world.document.displayList, imageStore: store)
        // Red through the colour management the canvas applies (the working space), so a little green.
        func isRed(_ color: RenderColor) -> Bool { color.red > 0.9 && color.green < 0.3 && color.blue < 0.1 }
        for _ in 0..<300 where !isRed(red) {
            try await Task.sleep(for: .milliseconds(10))
            red = EyedropperSampling.pixel(at: inside, in: world.document.displayList, imageStore: store)
        }
        #expect(store.state(of: hash) == .ready)
        #expect(isRed(red), "the bitmap's own red: \(red)")
        let placeholder = EyedropperSampling.pixel(at: inside, in: world.document.displayList)
        #expect(!isRed(placeholder), "without the store: the placeholder")
    }

    @Test func theWindowDrawsImagesFromItsStoreAndMarksThem() async throws {
        let world = ImageWorld()
        defer { world.close() }
        let node = try #require(await world.placeImage())
        let images = world.features.attach(world.window)
        #expect(world.features.attach(world.window) === images && images.store != nil)
        let mark = try #require(images.marks.first)
        #expect(mark.node == node && mark.name == "photo.png" && abs(mark.ppi - 72) < 0.5)
        // 72 ppi is below the 150 ppi warning; lowering the warning clears it.
        #expect(images.isLowResolution(mark))
        world.preferences.set(50, for: PreferenceCatalog.Document.lowResolutionWarning)
        #expect(!images.isLowResolution(mark))
        world.preferences.set(150, for: PreferenceCatalog.Document.lowResolutionWarning)
        // Badges: uploading, waiting for network, a collaborator's pixels on their way.
        #expect(images.badge(mark) == nil)
        let offline = TestBox(false)
        images.status.pending = { [mark.assetID] }
        images.status.isOffline = { offline.value }
        await images.contentDidChange().value
        #expect(images.badge(mark) == .uploading)
        let context = bitmap()
        images.draw(in: context)
        offline.value = true
        #expect(images.badge(mark) == .waitingForNetwork)
        images.draw(in: context)
        images.status.pending = { [] }
        images.status.isCached = { _ in false }
        images.status.author = { _ in "Priya" }
        await images.contentDidChange().value
        #expect(images.badge(mark) == .remote("Priya"))
        images.draw(in: context)
        images.status.author = { _ in nil }
        #expect(images.badge(mark) == .remote("someone"))
        // Gray boxes: no store, the marks name the images.
        images.status.isCached = { _ in true }
        world.preferences.set("gray", for: PreferenceCatalog.Redraw.imageDisplay)
        #expect(images.store == nil && images.display == .gray)
        images.draw(in: context)
        images.layer.draw(in: context)
        world.preferences.set("high", for: PreferenceCatalog.Redraw.imageDisplay)
        #expect(images.store != nil)
        images.imageReady(mark.assetID)
        #expect(images.readies == 1)
        // Scrolling keeps the layer the canvas's size.
        world.window.canvas.setViewport(world.window.canvas.navigation.zoom(world.window.viewport, to: 3))
        #expect(images.layer.frame == world.window.canvas.bounds)
        // An image inside a group is still marked, through the group's transform.
        _ = await world.document.perform(GroupObjects([node])).value
        await world.document.settle()
        #expect(images.marks.count == 1 && images.marks.first?.node == node)
        // The Trace tool reads the image's own pixels.
        world.features.install(tools: ToolRegistry())
        let url = try #require(world.features.cachedURL(mark.assetID))
        let sampled = try #require(TraceFeatures.imageBitmap(node, url: url, state: world.document.state))
        #expect(sampled.bitmap.width == 20 && sampled.bitmap.height == 10)
        let clipped = TraceFeatures.clipped(sampled.bitmap, transform: sampled.transform, to: Rect(x: mark.frame.minX, y: mark.frame.minY, width: 5, height: 5))
        #expect(clipped.pixels.last == 255 && world.features.trace.isCached(mark.assetID))
        #expect(TraceFeatures.imageBitmap(node, url: URL(filePath: "/nonexistent.png"), state: world.document.state) == nil)
        let host = RecordingHost(viewport: world.window.viewport)
        let toolContext = ToolContext(document: world.document, host: host)
        #expect(world.features.trace.sample(mark.frame, in: toolContext, clip: false)?.bitmap.width == 20)
        withExtendedLifetime(host) {}
        #expect(world.features.cachedURL("missing") == nil)
        world.features.detach(world.window)
        world.features.detach(world.window)
    }

    @Test func theAppStatusReadsTheCacheTheStoreAndTheSession() async throws {
        let world = ImageWorld()
        defer { world.close() }
        let status = ImageFeatures.status(for: world.window) { world.world.files.blobs }
        #expect(!status.isCached("0000") && !status.isOffline() && status.author(OpID(counter: 1, replica: 2)) == nil)
        #expect(await status.pending().isEmpty)
        let broken = ImageFeatures.status(for: world.window) { throw BranchError.noStore }
        #expect(!broken.isCached("0000"))
        (world.window.syncStatus as? StubSyncStatus)?.state = .offline(0)
        #expect(status.isOffline())
        world.features.blobDirectory = { throw BranchError.noStore }
        #expect(world.features.cachedURL("x") == nil)
        world.features.blobDirectory = { throw BranchError.noStore }
        #expect(world.features.makeStore() == nil)
        let images = WindowImages(window: world.window, preferences: world.preferences) { nil }
        images.applyDisplay()
        #expect(images.store == nil)
        images.window = nil
        images.install()
        images.applyDisplay()
        images.imageReady("x")
        images.draw(in: bitmap())
    }

    // MARK: Trace tool (IMG-023)

    @Test func theTraceToolTracesAMarqueeAboveTheImage() async throws {
        let registry = ToolRegistry()
        let environment = TestEnvironment()
        let trace = TraceFeatures(preferences: environment.preferences)
        trace.install(tools: registry)
        let descriptor = try #require(registry.descriptor(for: TraceTool.id))
        #expect(descriptor.shortcut == KeyEquivalent("8") && descriptor.options != nil)
        let setup = SetupWindow(tools: [descriptor])
        defer { setup.close() }
        let page = setup.page.rect
        let ids = await setup.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 60, height: 40)])
        setup.window.toolManager.select(TraceTool.id)
        let tool = try #require(setup.window.toolManager.activeTool as? TraceTool)
        #expect(tool.cursor == .crosshair && !tool.hasSomethingToCancel)
        var shown = 0
        trace.showProgress = { _, _ in shown += 1 }
        // A marquee over the rectangle: traced, placed above it as one group.
        let from = Point(x: page.minX + 10, y: page.minY + 10), to = Point(x: page.minX + 90, y: page.minY + 70)
        tool.mouseDown(setup.event(from))
        tool.mouseDragged(setup.event(to, .shift))
        #expect(tool.marquee != nil && tool.hasSomethingToCancel)
        tool.drawOverlay(in: bitmap(), viewport: setup.window.viewport)
        tool.flagsChanged(setup.event(to))
        tool.mouseUp(setup.event(to))
        #expect(await eventually { setup.document.undoTitle == "Undo Trace" })
        #expect(shown == 1 && trace.progress == nil)
        let layer = try #require(setup.document.state.store.placement(ids[0].opID)?.parent)
        let children = setup.document.state.liveChildren(layer)
        #expect(children.count == 2 && children[0] == ids[0].opID)
        #expect(setup.document.state.props(children[1]).group.common.name.hasPrefix("Trace of"))
        // Marquee geometry.
        #expect(TraceTool.marquee(from: Point(x: 0, y: 0), to: Point(x: 10, y: -4), modifiers: .shift) == Rect(x: 0, y: -10, width: 10, height: 10))
        #expect(TraceTool.marquee(from: Point(x: 5, y: 5), to: Point(x: 7, y: 8), modifiers: .option) == Rect(x: 3, y: 2, width: 4, height: 6))
        #expect(trace.trace(Rect(x: 0, y: 0, width: 0, height: 5), in: tool.context!) == nil)
        tool.cancel()
        setup.window.toolManager.select(.pointer)
        #expect(tool.context == nil)
    }

    @Test func theWandPicksAddsInvertsAndTracesAnAreaOfColor() async throws {
        let registry = ToolRegistry()
        let environment = TestEnvironment()
        let trace = TraceFeatures(preferences: environment.preferences)
        trace.install(tools: registry)
        trace.settings.resolution = 1
        let setup = SetupWindow(tools: [try #require(registry.descriptor(for: TraceTool.id))])
        defer { setup.close() }
        let page = setup.page.rect
        await setup.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 30, height: 30)])
        setup.window.toolManager.select(TraceTool.id)
        let tool = try #require(setup.window.toolManager.activeTool as? TraceTool)
        trace.showProgress = { _, _ in }
        let inside = Point(x: page.minX + 30, y: page.minY + 30)
        tool.mouseDown(setup.event(inside))
        tool.mouseUp(setup.event(inside))
        let picked = try #require(tool.wand?.selection.count)
        #expect(picked > 0)
        // Option takes the same area away; Shift adds it back; Tab inverts.
        tool.pick(at: inside, modifiers: .option)
        #expect(tool.wand?.selection.isEmpty == true)
        tool.pick(at: inside, modifiers: .shift)
        #expect(tool.wand?.selection.count == picked)
        tool.drawOverlay(in: bitmap(), viewport: setup.window.viewport)
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        #expect(tool.keyDown(tab))
        #expect(tool.keyDown(tab) && tool.wand?.selection.count == picked)
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(!tool.keyDown(other))
        // E: the selection's edge as one unfilled path.
        let edge = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        #expect(tool.keyDown(edge) && tool.wand == nil)
        #expect(await eventually { setup.document.undoTitle == "Undo Trace" })
        // Return: the area traced.
        tool.pick(at: inside, modifiers: [])
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let before = setup.document.changeCount
        #expect(tool.keyDown(enter))
        #expect(await eventually { setup.document.changeCount > before })
        #expect(!tool.keyDown(enter))
        // An empty selection traces nothing; a cancelled trace says so.
        let context = try #require(tool.context)
        let empty = WandSelection(width: 2, height: 2)
        let blank = try #require(Trace.Bitmap(width: 2, height: 2, pixels: [UInt8](repeating: 255, count: 16)))
        #expect(trace.traceSelection(blank, selection: empty, transform: .identity, area: page, edgeOnly: false, in: context) == nil)
        let task = trace.trace(Rect(x: page.minX, y: page.minY, width: 200, height: 200), in: context)
        trace.cancelTrace()
        await task?.value
        #expect(trace.message == "The trace was cancelled" || setup.document.changeCount > before)
        await trace.place(Trace.Result(paths: []), source: nil, name: nil, in: context).value
        #expect(trace.message == "Nothing was traced")
        // A placeholder image cannot be traced.
        trace.isCached = { _ in false }
        let image = ImageWorld()
        defer { image.close() }
        _ = await image.placeImage(at: Point(x: page.minX + 100, y: page.minY + 100))
        let imageHost = RecordingHost(viewport: image.window.viewport)
        let imageContext = ToolContext(document: image.document, host: imageHost)
        let placed = try #require(image.features.attach(image.window).marks.first)
        let frame = placed.frame
        #expect(trace.trace(frame, in: imageContext) == nil && trace.message?.contains("cannot be traced") == true)
        #expect(trace.sampleArea(at: frame.center, in: imageContext) == nil)
        trace.isCached = { _ in true }
        #expect(trace.sampleArea(at: frame.center, in: imageContext) == frame)
        #expect(trace.sampleArea(at: Point(x: -9_000, y: -9_000), in: imageContext) != nil)
        withExtendedLifetime(imageHost) {}
    }

    @Test func aClickInsideTheSelectionOpensTheWandOptions() async throws {
        let registry = ToolRegistry()
        let environment = TestEnvironment()
        let trace = TraceFeatures(preferences: environment.preferences)
        trace.install(tools: registry)
        trace.settings.resolution = 1
        let setup = SetupWindow(tools: [try #require(registry.descriptor(for: TraceTool.id))])
        defer { setup.close() }
        let page = setup.page.rect
        await setup.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 30, height: 30)])
        setup.window.toolManager.select(TraceTool.id)
        let tool = try #require(setup.window.toolManager.activeTool as? TraceTool)
        trace.showProgress = { _, _ in }
        var shown: [Point] = []
        trace.showWandOptions = { _, point, _ in shown.append(point) }
        let inside = Point(x: page.minX + 30, y: page.minY + 30)
        tool.pick(at: inside, modifiers: [])
        #expect(shown.isEmpty && tool.wand?.selection.isEmpty == false)
        // A plain click inside the selection opens the popover and keeps the selection.
        tool.pick(at: inside, modifiers: [])
        #expect(shown.count == 1 && tool.wand != nil)
        // Convert selection edge: one unfilled path.
        let before = setup.document.changeCount
        #expect(tool.perform(.edge) != nil && tool.wand == nil)
        #expect(await eventually { setup.document.changeCount > before })
        #expect(tool.perform(.trace) == nil, "nothing selected")
        // Trace selection from the view's button.
        tool.pick(at: inside, modifiers: [])
        var closed = false
        Render.view(WandOptionsView(tool: tool) {})
        WandOptionsView.trace(tool, .trace) { closed = true }()
        #expect(closed && tool.wand == nil)
        #expect(TraceTool.WandAction.allCases.map(\.title) == ["Trace selection", "Convert selection edge"])
        // The real popover needs a view host; a recording host shows nothing.
        let host = RecordingHost(viewport: setup.window.viewport)
        WandOptionsPopover.show(for: tool, at: inside, in: ToolContext(document: setup.document, host: host))
        withExtendedLifetime(host) {}
    }

    @Test func traceLayersLimitWhatTheToolSees() async throws {
        let environment = TestEnvironment()
        let trace = TraceFeatures(preferences: environment.preferences)
        let setup = SetupWindow(tools: [])
        defer { setup.close() }
        let page = setup.page.rect
        let ids = await setup.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 30, height: 30)])
        let state = setup.document.state
        #expect(trace.settings.layers == .all && TraceLayers.foreground.includes(node: ids[0].opID, in: state))
        #expect(!TraceLayers.background.includes(node: ids[0].opID, in: state))
        #expect(!TraceLayers.foreground.includes(node: OpID(counter: 999, replica: 9), in: state) && TraceLayers.all.includes(node: OpID(counter: 999, replica: 9), in: state))
        let list = setup.document.displayList
        #expect(TraceLayers.all.filter(list, in: state) == list)
        #expect(TraceLayers.background.filter(list, in: state).isEmpty && !TraceLayers.foreground.filter(list, in: state).isEmpty)
        // A background-only trace of the rectangle's area samples nothing but paper.
        trace.settings.layers = .background
        let rect = Rect(x: page.minX + 20, y: page.minY + 20, width: 30, height: 30)
        let host = RecordingHost(viewport: setup.window.viewport)
        defer { withExtendedLifetime(host) {} }
        let sampled = try #require(trace.sample(rect, in: ToolContext(document: setup.document, host: host), clip: true))
        #expect(sampled.bitmap.pixels.allSatisfy { $0 == 255 })
        #expect(trace.marks(in: state).isEmpty)
        #expect(TraceSettings.load(environment.preferences.defaults).layers == .background, "kept in the preferences")
        #expect(TraceLayers.allCases.map(\.title) == ["All", "Foreground", "Background"])
    }

    @Test func wandSelectionsAndSettings() throws {
        var pixels = [UInt8](repeating: 255, count: 4 * 4 * 4)
        for index in [5, 6, 9, 10] { pixels[index * 4] = 0 }
        let bitmap = try #require(Trace.Bitmap(width: 4, height: 4, pixels: pixels))
        var selection = WandSelection(width: 4, height: 4)
        selection.apply(bitmap, x: 1, y: 1, tolerance: 10, subtract: false)
        #expect(selection.count == 4)
        selection.apply(bitmap, x: 9, y: 9, tolerance: 10, subtract: false)
        selection.apply(try #require(Trace.Bitmap(width: 2, height: 2, pixels: [UInt8](repeating: 0, count: 16))), x: 0, y: 0, tolerance: 0, subtract: false)
        #expect(selection.count == 4)
        #expect(selection.contains(x: 1, y: 1) && !selection.contains(x: 0, y: 0) && !selection.contains(x: -1, y: 9))
        selection.invert()
        #expect(selection.count == 12)
        let masked = selection.masked(bitmap)
        #expect(masked.pixels[5 * 4] == 255)
        let suite = TestDefaults()
        var settings = TraceSettings.load(suite.defaults)
        #expect(settings == TraceSettings())
        settings.colors = 8
        settings.centerline = true
        settings.save(suite.defaults)
        #expect(TraceSettings.load(suite.defaults).colors == 8 && settings.options.mode == .centerline)
        let features = TraceFeatures(preferences: PreferenceStore(defaults: suite.defaults))
        #expect(features.settings.colors == 8)
        Render.view(TraceOptionsSheet(features: features) {})
        Render.view(TraceProgressSheet(features: features))
        TraceProgressSheet.cancel(features)()
        let registry = ToolRegistry()
        features.install(tools: registry)
        let options = try #require(registry.descriptor(for: TraceTool.id)?.options?())
        #expect(options.title == "Trace Options")
        _ = registry.descriptor(for: TraceTool.id)?.make()
    }

    // MARK: Share inbox (IMG-026)

    @Test func theShareInboxDrainsIntoTheFrontDocumentOrANewOne() async throws {
        let image = ImageWorld()
        defer { image.close() }
        let root = TestStores.directory()
        let inbox = ShareInbox(root: root)
        let id = UUID().uuidString
        let folder = root.appending(path: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: image.world.files.png()).write(to: folder.appending(path: "a.png"))
        try Data(contentsOf: image.world.files.png("b.png")).write(to: folder.appending(path: "b.png"))
        let url = try #require(URL(string: "wiretuner-share://inbox/\(id)?app=Photos"))
        #expect(ShareInbox.parse(url)?.app == "Photos" && ShareInbox.parse(url)?.option == false)
        #expect(ShareInbox.parse(URL(string: "wiretuner://inbox/\(id)")!) == nil && ShareInbox.parse(URL(string: "wiretuner-share://inbox/nope")!) == nil)
        inbox.window = { image.window }
        let imports = image.world.imports
        inbox.place = { urls, window, app in await ShareInbox.place(urls, on: window, from: app, imports: imports) }
        #expect(await inbox.drain(url) == 2)
        #expect(image.document.undoTitle == "Undo Add from Photos" && !FileManager.default.fileExists(atPath: folder.path))
        // Option (or no window): a new document; an empty or unknown folder places nothing.
        let second = UUID().uuidString
        try FileManager.default.createDirectory(at: root.appending(path: second), withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: root.appending(path: second).appending(path: "c.png"))
        var created = 0
        inbox.newDocument = {
            created += 1
            return image.window
        }
        #expect(await inbox.drain(URL(string: "wiretuner-share://inbox/\(second)?option=1")!) == 0 && created == 1)
        #expect(await inbox.drain(URL(string: "wiretuner-share://inbox/\(UUID().uuidString)")!) == 0)
        #expect(await inbox.drain(URL(string: "wiretuner://other")!) == 0)
        inbox.window = { nil }
        inbox.newDocument = { nil }
        let third = UUID().uuidString
        try FileManager.default.createDirectory(at: root.appending(path: third), withIntermediateDirectories: true)
        try Data(contentsOf: image.world.files.png()).write(to: root.appending(path: third).appending(path: "d.png"))
        #expect(await inbox.drain(URL(string: "wiretuner-share://inbox/\(third)")!) == 0)
        #expect(inbox.opens(URL(string: "wiretuner-share://inbox/\(UUID().uuidString)")!) && !inbox.opens(URL(string: "https://example.com")!))
        // Stale folders go at launch.
        let stale = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: stale.path)
        let fresh = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        inbox.removeStale()
        #expect(!FileManager.default.fileExists(atPath: stale.path) && FileManager.default.fileExists(atPath: fresh.path))
        #expect(ShareInbox.defaultRoot.lastPathComponent == "Inbox")
    }

    // MARK: Import limits (IMG-007)

    @Test func theDownsamplePreferenceReachesTheImporter() {
        let world = ImportWorld()
        defer { world.files.remove() }
        #expect(world.imports.context.downsampleLimit == 50_000_000)
        world.environment.preferences.set(0, for: PreferenceCatalog.Import.downsampleMegapixels)
        #expect(world.imports.context.downsampleLimit == nil)
        world.environment.preferences.set(20, for: PreferenceCatalog.Import.downsampleMegapixels)
        #expect(world.imports.context.downsampleLimit == 20_000_000)
        #expect(PreferenceCatalog.Import.downsampleMegapixels.scope == .synced)
    }
}
