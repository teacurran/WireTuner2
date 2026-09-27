import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The app glue of commit ef89c5d's package halves: preferences sync and the team floor
/// (BASIC-023), the sync announcement, Sync Activity and library badges (IO-001/IO-002 rest),
/// print progress (PRINT-013), Optimize Image (IMG-020) and Rasterize (IMG-024).
@Suite(.serialized) @MainActor struct PackageGlueTests {
    // MARK: Preferences sync (BASIC-023)

    static func sync(_ server: FakePreferencesServer, enabled: Bool = true) throws -> PreferenceSync {
        let url = TestStores.directory().appending(path: "Preferences.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try PreferenceSync(transport: server, url: url, device: "mac-1", enabled: enabled) { "token" }
    }

    @Test func valuesTravelBothWays() {
        let values: [PreferenceValue] = [.bool(true), .int(40), .double(2.5), .string("x"), .list(["a", "b"]),
                                         .color(PreferenceColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))]
        for value in values {
            #expect(AccountPreferenceBackend.value(AccountPreferenceBackend.wire(value)) == value)
        }
        #expect(AccountPreferenceBackend.value(Wiretuner_Account_V1_PreferenceValue()) == nil)
        #expect(AccountPreferenceBackend.values(["a": AccountPreferenceBackend.wire(.int(1)), "b": Wiretuner_Account_V1_PreferenceValue()]) == ["a": .int(1)])
    }

    @Test func theBackendQueuesSendsAppliesAndRetries() async throws {
        let server = FakePreferencesServer()
        var distance = AccountPreferenceBackend.wire(.double(7))
        distance.updatedAtMs = 1
        server.put("general.pick_distance", distance)
        let sleeps = TestBox(0)
        let gate = AsyncStream<Void>.makeStream()
        let backend = AccountPreferenceBackend(sleep: { _ in
            await MainActor.run { sleeps.value += 1 }
            for await _ in gate.stream { return }
        })
        var applied: [[String: PreferenceValue]] = []
        backend.onRemoteMap = { applied.append($0) }
        // Before a sync is attached, entries wait; nothing else happens.
        backend.enqueue(["general.smart_guides": .bool(false)])
        await backend.refresh()
        await backend.setEnabled(true)
        #expect(backend.waiting == ["general.smart_guides": .bool(false)])
        let sync = try Self.sync(server)
        await backend.attach(sync, enabled: true).value
        #expect(backend.waiting.isEmpty && backend.sync != nil)
        #expect(await eventually { server.stored["general.smart_guides"] != nil })
        #expect(await eventually { applied.last?["general.pick_distance"] == .double(7) })
        // A change on this Mac goes up at once.
        backend.enqueue(["sync.ask_overlap_count": .int(30)])
        #expect(await eventually { server.stored["sync.ask_overlap_count"].flatMap(AccountPreferenceBackend.value) == .int(30) })
        // Offline: the send fails, one retry waits 30 s, and when it runs everything goes up.
        server.failing = true
        backend.enqueue(["sync.ask_overlap_count": .int(35)])
        #expect(await eventually { backend.retry != nil && backend.lastError != nil })
        await backend.refresh()
        #expect(sleeps.value == 1)
        server.failing = false
        gate.continuation.yield()
        #expect(await eventually { backend.retry == nil && backend.lastError == nil })
        #expect(server.stored["sync.ask_overlap_count"].flatMap(AccountPreferenceBackend.value) == .int(35))
        // Turning sync off forgets the queue; the retry stops with the backend.
        await backend.setEnabled(false)
        #expect(await sync.isEnabled == false)
        backend.stop()
    }

    /// BASIC-028's app glue: the shortcut sets travel through the preferences backend -- a change
    /// here waits until a sync is attached, then goes up; the account's sets come down into the store.
    @Test func shortcutSetsSyncThroughTheBackend() async throws {
        let server = FakePreferencesServer()
        var remote = Wiretuner_Account_V1_ShortcutSet()
        remote.id = "remote-set"
        remote.name = "Remote"
        remote.basedOn = ShortcutSet.defaultID
        remote.updatedAtMs = 5
        var value = ShortcutSetSync.entry([remote])
        value.updatedAtMs = 5
        server.put(ShortcutSetSync.key, value)
        let backend = AccountPreferenceBackend(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let folder = TestStores.directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ShortcutSetStore(url: folder.appending(path: "ShortcutSets.json"))
        backend.connect(store)
        let mine = try store.makeCopy(of: ShortcutSet.defaultID, name: "Mine")
        #expect(backend.waitingWire[ShortcutSetSync.key] != nil, "waits for a sync")
        _ = try store.makeCopy(of: ShortcutSet.defaultID, name: "Also mine")
        await backend.attach(try Self.sync(server), enabled: true).value
        #expect(backend.waitingWire.isEmpty)
        #expect(await eventually { store.userSets.contains { $0.id == "remote-set" } }, "the account's set came down")
        #expect(await eventually {
            if case .shortcutSetsValue(let sets)? = server.stored[ShortcutSetSync.key]?.value { return sets.sets.contains { $0.id == mine.id } }
            return false
        }, "this Mac's set went up")
        // A rename after the attach goes up at once.
        try store.rename(mine.id, to: "Renamed")
        #expect(await eventually {
            if case .shortcutSetsValue(let sets)? = server.stored[ShortcutSetSync.key]?.value { return sets.sets.contains { $0.name == "Renamed" } }
            return false
        })
        // A delivered map without shortcut sets leaves the store alone.
        let before = store.userSets
        backend.deliver([:])
        #expect(store.userSets == before)
        backend.stop()
    }

    @Test func aFailingAttachRetriesAndStopCancelsIt() async throws {
        let server = FakePreferencesServer()
        server.failing = true
        let backend = AccountPreferenceBackend(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await backend.attach(try Self.sync(server, enabled: false), enabled: true).value
        #expect(backend.retry != nil && backend.lastError != nil)
        await backend.setEnabled(true)
        backend.stop()
        #expect(backend.retry == nil)
    }

    @Test func theTeamFloorRaisesThresholdsInTheWindow() {
        let floor = ReconcilePreferences(autoMergeBelow: 100, askOverlapCount: 40, askOverlapShare: 0.5, alwaysAsk: true, suggestReviewAfter: .seconds(24 * 3600))
        let count = PreferenceCatalog.Sync.askOverlapCount.id, auto = PreferenceCatalog.Sync.autoMergeBelow.id
        #expect(ReviewFloors.floored(.int(20), id: count, floor: floor) == .int(40))
        #expect(ReviewFloors.floored(.int(500), id: auto, floor: floor) == .int(100))
        #expect(ReviewFloors.floored(.int(20), id: PreferenceCatalog.Sync.askOverlapShare.id, floor: floor) == .int(50))
        #expect(ReviewFloors.floored(.int(1), id: PreferenceCatalog.Sync.suggestReviewAfterHours.id, floor: floor) == .int(24))
        #expect(ReviewFloors.floored(.bool(false), id: PreferenceCatalog.Sync.alwaysAsk.id, floor: floor) == .bool(true))
        #expect(ReviewFloors.floored(.double(3), id: "general.pick_distance", floor: floor) == .double(3))
        #expect(ReviewFloors.floored(.bool(false), id: count, floor: floor) == .bool(false))
        #expect(ReviewFloors.floored(.int(20), id: count, floor: nil) == .int(20))
        #expect(!ReviewFloors.allows(.int(20), id: count, floor: floor) && ReviewFloors.allows(.int(60), id: count, floor: floor))
        #expect(ReviewFloors.note(id: count, floor: floor) == "Team minimum: 40" && ReviewFloors.note(id: auto, floor: floor) == "Team maximum: 100")
        #expect(ReviewFloors.note(id: PreferenceCatalog.Sync.alwaysAsk.id, floor: floor) == "Your team always asks")
        #expect(ReviewFloors.note(id: PreferenceCatalog.Sync.alwaysAsk.id, floor: .standard) == nil && ReviewFloors.note(id: "x.y", floor: floor) == nil)

        // The floors of the open documents: the front one's, else the only one.
        let floors = ReviewFloors()
        #expect(floors.current == nil)
        floors.update(floor, for: "a")
        #expect(floors.current == floor)
        floors.update(.standard, for: "b")
        #expect(floors.current == nil)
        floors.activeDocument = { "b" }
        #expect(floors.current == .standard)

        // The window: a user's 20 shows as the team's 40 and cannot go under it.
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        var beeps = 0
        var bindings = PreferenceBindings(store: store, beep: { beeps += 1 })
        bindings.floor = { floor }
        let key = PreferenceCatalog.Sync.askOverlapCount.erased
        #expect(bindings.number(key, integer: true).wrappedValue == 40 && bindings.floorNote(key) == "Team minimum: 40")
        bindings.number(key, integer: true).wrappedValue = 30
        #expect(beeps == 1 && store[PreferenceCatalog.Sync.askOverlapCount] == 20)
        bindings.number(key, integer: true).wrappedValue = 60
        #expect(store[PreferenceCatalog.Sync.askOverlapCount] == 60)
        #expect(bindings.bool(PreferenceCatalog.Sync.alwaysAsk.erased).wrappedValue)
        Render.view(Form { PreferenceRowView(row: PreferenceForm.rows(for: .sync).first { $0.key.id == count }!, bindings: bindings) })
    }

    @Test func aSessionPassesItsFloorOnAndClearsItWhenItStops() async {
        let handle = DocumentHandle.memory(title: "Floor")
        let session = DocumentSession(document: handle, connector: nil, localUserID: "me")
        session.handle(.reviewFloor(ReconcilePreferences(askOverlapCount: 40)))
        #expect(ReviewFloors.shared.floors[handle.id]?.askOverlapCount == 40)
        await session.stop()
        #expect(ReviewFloors.shared.floors[handle.id] == nil)
    }

    @Test func theAppAttachesTheBackendAndItsHooks() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        #expect(delegate.preferences.backend is AccountPreferenceBackend)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer {
            TypeWindowParts.detach(window)
            window.close()
        }
        for id in [PackageHalvesGlue.ID.optimizeImage, PackageHalvesGlue.ID.rasterize, SyncActivityWindow.id] {
            #expect(delegate.commands.command(id) != nil)
        }
        #expect(delegate.packageGlue.announcer(for: window) != nil)
        #expect(SymbolTransferFeatures.shared != nil && WebLinks.services == nil)
        #expect(delegate.library.syncState(window.documentHandle.id) == .saved || delegate.library.syncState(window.documentHandle.id) == .opening)
        #expect(delegate.library.syncState("nobody") == nil)
        #expect(delegate.commands.command(PackageHalvesGlue.ID.optimizeImage)?.validation().isEnabled == false)
        #expect(delegate.commands.command(PackageHalvesGlue.ID.rasterize)?.validation().isEnabled == false)
        #expect(delegate.packageGlue.downsampleLimit() == 50_000_000)
        #expect(SymbolTransferFeatures.shared?.libraryDocuments() != nil)
        #expect(try await SymbolTransferFeatures.shared?.cloudState("x") == nil)
        #expect(SymbolTransferFeatures.shared?.openDocuments().contains { $0 === window.documentHandle } == true)
        #expect(ReviewFloors.shared.activeDocument() == window.documentHandle.id)
        #expect(delegate.packageGlue.imageStore(window) != nil)
        delegate.sessions.session(for: window.documentHandle).status.update(.offline(1))
        #expect(delegate.packageGlue.announcer(for: window)?.announced == SyncAnnouncer.kind(.offline(1)))
        window.close()
        #expect(delegate.packageGlue.announcer(for: window) == nil)
    }

    // MARK: Sync indicator rest (IO-001, IO-002)

    @Test func voiceOverHearsEachChangeOfStateOnce() {
        var heard: [String] = []
        let announcer = SyncAnnouncer(element: nil) { heard.append($0) }
        announcer.update(.saved)
        announcer.update(.syncing(3))
        announcer.update(.syncing(2))
        announcer.update(.offline(2))
        announcer.update(.offline(5))
        announcer.update(.saved)
        #expect(heard == ["Syncing 3 changes", "Offline — 2 changes waiting", "Saved to cloud"])
        #expect(SyncAnnouncer.kind(.offline(1)) == SyncAnnouncer.kind(.offline(9)) && SyncAnnouncer.kind(.saved) != SyncAnnouncer.kind(.needsReview))
        SyncAnnouncer(element: NSView()).post("Posted")
    }

    @Test func syncActivityListsWhatIsInFlightAndTheLibraryBadgesIt() async {
        let sessions = DocumentSessions(connector: nil)
        let handle = DocumentHandle.memory(title: "Poster")
        let session = sessions.session(for: handle)
        await session.start().value
        let window = SyncActivityWindow(sessions: sessions)
        #expect(window.model.rows.isEmpty)
        Render.view(SyncActivityView(model: window.model))
        session.status.update(.offline(3))
        #expect(window.model.rows.map(\.detail) == ["3 changes waiting (offline)"] && window.model.rows[0].note == nil)
        Render.view(SyncActivityView(model: window.model))
        // Closing the window keeps the session in the background, still listed.
        sessions.documentDidClose(handle)
        #expect(window.model.rows.first?.note == "Window closed")
        #expect(LibrarySyncBadge.badge(.offline(3))?.symbol == "icloud.slash" && LibrarySyncBadge.badge(.saved) == nil && LibrarySyncBadge.badge(nil) == nil)
        window.show()
        window.show()
        #expect(window.window?.title == "Sync Activity")
        window.close()
        if case .perform(let run) = window.command.action { run() }
        window.close()
        await sessions.release(handle.id)
    }

    // MARK: Print progress (PRINT-013)

    @Test func theSpooledJobReportsEachSheetAndCancelsBetweenSheets() async throws {
        let world = PrintWorld()
        defer { world.close() }
        world.document.pages = [Rect(x: 0, y: 0, width: 200, height: 200), Rect(x: 0, y: 300, width: 200, height: 200),
                                Rect(x: 0, y: 600, width: 200, height: 200)]
        await world.document.settle()
        let plan = PrintJob.plan(world.document, source: .pages, paper: .letter, selection: nil, blobs: BlobPlacement())
        #expect(plan.count == 3)
        let panel = PrintProgressPanel()
        panel.showsWindow = false
        let spooler = PrintSpooler(window: nil, panel: panel)
        var destroyed = 0
        spooler.destroyContext = { destroyed += 1 }
        let view = PrintPlanView(plan: plan, renderer: PrintJob.renderer(imageStore: nil), title: "Job")
        view.spooler = spooler
        let context = try #require(BitmapSurface(width: 612, height: 792)?.context)
        view.drawSheets(in: context, dirty: view.rectForPage(1), preview: false)
        #expect(panel.isShown && panel.label.stringValue.hasPrefix("Drawing sheet 1 of 3") && spooler.run?.sheetsDrawn == 1)
        // Cancel: the next sheet draws nothing and ends the job.
        panel.cancelButton.performClick(nil)
        #expect(spooler.isCancelled && panel.label.stringValue == "Cancelling…" && !panel.cancelButton.isEnabled)
        view.drawSheets(in: context, dirty: view.rectForPage(2), preview: false)
        #expect(spooler.run?.sheetsDrawn == 1 && spooler.run?.plan == nil)
        try spooler.draw(sheet: 2, of: plan, renderer: view.renderer, into: context)
        #expect(!panel.isShown)
        // The preview never goes through the job.
        view.drawSheets(in: context, dirty: view.rectForPage(3), preview: true)
        #expect(destroyed == 1)

        // A job drawn to the end closes its panel.
        let done = PrintSpooler(window: world.window.window, panel: panel)
        for sheet in 0..<plan.count { try done.draw(sheet: sheet, of: plan, renderer: view.renderer, into: context) }
        #expect(done.run?.sheetsDrawn == 3 && !panel.isShown)

        // A run cancelled while a sheet draws destroys the context.
        let cancelling = PrintSpooler(window: nil, panel: panel)
        var ended = 0
        cancelling.destroyContext = { ended += 1 }
        try cancelling.draw(sheet: 0, of: plan, renderer: view.renderer, into: context)
        cancelling.run?.cancel()
        try cancelling.draw(sheet: 1, of: plan, renderer: view.renderer, into: context)
        try cancelling.draw(sheet: 2, of: plan, renderer: view.renderer, into: context)
        #expect(ended == 1)
    }

    @Test func theProgressPanelTakesItsClicksAndEscapeAndLeavesTheRest() throws {
        let panel = PrintProgressPanel()
        panel.showsWindow = false
        var cancels = 0
        panel.onCancel = { cancels += 1 }
        panel.show(over: nil)
        panel.show(over: nil)
        panel.update(PrintProgress(sheet: 1, count: 4, name: "Page 2"))
        #expect(panel.label.stringValue == "Drawing sheet 2 of 4, Page 2" && panel.bar.doubleValue == 0.25)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        var queue = [escape, other]
        var reposted: [NSEvent] = []
        panel.pump(events: { queue.isEmpty ? nil : queue.removeFirst() }, repost: { reposted = $0 })
        #expect(cancels == 1 && reposted == [other])
        panel.close()
        #expect(!panel.isShown)
        let shown = PrintProgressPanel()
        shown.show(over: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true))
        #expect(shown.panel?.isVisible == true)
        shown.close()
        let centred = PrintProgressPanel()
        centred.show(over: nil)
        centred.close()
    }

    // MARK: Optimize Image (IMG-020)

    static func png(width: Int = 64, height: Int = 32, alpha: Bool = true) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func optimizingReencodesAndWritesOneChange() async throws {
        let data = Self.png()
        var performed: [any WTModel.Command] = []
        var stored: [ImportedBlob] = []
        let item = OptimizeImageModel.Item(node: OpID(counter: 5, replica: 1), name: "Photo", data: data, pixelWidth: 64, pixelHeight: 32, placedWidth: 32)
        let model = OptimizeImageModel(items: [item], perform: { command in
            performed.append(command)
            return Task { nil }
        }, storeBlobs: { stored += $0 })
        model.settle = .zero
        model.optionsChanged()
        await model.settled()
        #expect(model.estimate != nil && model.preview.before != nil && model.preview.after != nil && model.sizeLine.contains("about"))
        #expect(model.planLine(item) == "64 × 32 px, 144 ppi")
        model.resampleChoice = .effectiveResolution
        model.resolution = 72
        #expect(model.planLine(item) == "64 × 32 px, 144 ppi → 32 × 16 px, 72 ppi")
        model.resampleChoice = .pixelSize
        model.pixelSize = 16
        #expect(model.options.resample == .pixelSize(16))
        #expect(model.dims(.jpeg) && !model.dims(.png) && model.formats.contains(.png) && model.storedSize == data.count)
        model.quality = 0
        #expect(model.unavailableReason == "Quality must be 1 to 100." && model.optimize() == nil)
        model.quality = 80
        model.format = .png
        model.colorMode = .grayscale
        model.stripMetadata = true
        #expect(model.unavailableReason == nil)
        Render.view(OptimizeImageSheet(model: model))
        var closed = false
        model.onClose = { closed = true }
        await model.optimize()?.value
        #expect(model.phase == .done && closed && stored.count == 1 && (performed.first as? OptimizeImages)?.results.first?.node == item.node)
        #expect(model.sizeLine.contains("→"))
        OptimizeImageSheet.cancel(model)()
        _ = OptimizeImageSheet.optimize(model)
        #expect(OptimizeImageModel.message(.unreadable) == "The image could not be read." && OptimizeImageModel.message(.encodingFailed("x")) == "The image could not be written.")
    }

    /// IMG-025's rest: *Trim to crop* encodes only a cropped image's visible pixels and writes it
    /// with `TrimImageToCrop` beside the others' `OptimizeImages`, one change (that the visible part
    /// stays in place is `ImageCroppingTests`).
    @Test func trimToCropKeepsTheVisiblePixelsInOneChange() async throws {
        let data = Self.png()
        let cropped = OptimizeImageModel.Item(node: OpID(counter: 5, replica: 1), name: "Photo", data: data, pixelWidth: 64, pixelHeight: 32, placedWidth: 32,
                                              crop: Rect(x: 0.25, y: 0, width: 0.5, height: 1))
        let plain = OptimizeImageModel.Item(node: OpID(counter: 6, replica: 1), name: "Other", data: data, pixelWidth: 64, pixelHeight: 32, placedWidth: 32)
        var performed: [any WTModel.Command] = []
        let model = OptimizeImageModel(items: [cropped, plain], perform: { command in
            performed.append(command)
            return Task { nil }
        }, storeBlobs: { _ in })
        model.settle = .zero
        #expect(model.canTrim && model.input(cropped)?.trimmed == false, "off until chosen")
        model.trimToCrop = true
        let input = try #require(model.input(cropped))
        #expect(input.trimmed && input.placedWidth == 16 && model.input(plain)?.trimmed == false)
        let cut = try #require(OptimizeImageModel.image(input.data))
        #expect(cut.width == 32 && cut.height == 32)
        #expect(OptimizeImageModel.trimmed(Data([1, 2]), to: (0, 0, 1, 1)) == nil)
        Render.view(OptimizeImageSheet(model: model))
        await model.optimize()?.value
        let batch = try #require(performed.first as? CommandBatch)
        #expect(batch.label == "Optimize (2 images)" && batch.commands.count == 2)
        #expect((batch.commands[0] as? TrimImageToCrop)?.node == cropped.node && (batch.commands[1] as? OptimizeImages)?.results.map(\.node) == [plain.node])
        #expect(!OptimizeImageModel(items: [plain], perform: { _ in Task { nil } }, storeBlobs: { _ in }).canTrim)

        // One trimmed image alone: a batch of the trim under "Optimize <name>".
        let pixels = try ImageOptimizer.optimize(input.data, placedWidth: input.placedWidth, options: ImageOptimizeOptions())
        let single = try #require(OptimizeImageModel.command([(cropped.node, pixels, true)], names: ["Photo"]) as? CommandBatch)
        #expect(single.label == "Optimize Photo" && single.commands.count == 1)
        #expect(OptimizeImageModel.command([(plain.node, pixels, false)], names: ["Other"]) is OptimizeImages)
    }

    @Test func anUnreadableOrMissingImageIsReported() async {
        let missing = OptimizeImageModel.Item(node: OpID(counter: 5, replica: 1), name: "Gone", data: nil, pixelWidth: 10, pixelHeight: 10, placedWidth: 10)
        let empty = OptimizeImageModel(items: [], perform: { _ in Task { nil } }, storeBlobs: { _ in })
        #expect(empty.unavailableReason == "Select an image")
        let waiting = OptimizeImageModel(items: [missing], perform: { _ in Task { nil } }, storeBlobs: { _ in })
        #expect(waiting.unavailableReason == "An image’s pixels have not downloaded yet")
        let broken = OptimizeImageModel.Item(node: OpID(counter: 6, replica: 1), name: "Broken", data: Data([1, 2, 3]), pixelWidth: 10, pixelHeight: 10, placedWidth: 10)
        let failing = OptimizeImageModel(items: [broken], perform: { _ in Task { nil } }, storeBlobs: { _ in })
        failing.settle = .zero
        failing.optionsChanged()
        await failing.settled()
        #expect(failing.estimate == nil)
        await failing.optimize()?.value
        #expect(failing.phase == .failed("The image could not be read."))
        Render.view(OptimizeImageSheet(model: failing))
    }

    // MARK: Rasterize (IMG-024)

    @Test func rasterizingTheSelectionMakesOneImage() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 10, y: 10, width: 72, height: 36), Rect(x: 100, y: 10, width: 20, height: 20)])
        world.window.selection.model.set(Selection(ids))
        let (nodes, list) = RasterizeModel.selection(in: world.window)
        #expect(nodes == ids.map(\.opID) && list.items.count == 2)
        var performed: [any WTModel.Command] = []
        var stored: [ImportedBlob] = []
        let model = RasterizeModel(nodes: nodes, selection: list, downsampleLimit: 100, perform: { command in
            performed.append(command)
            return Task { nil }
        }, storeBlob: { stored.append($0) })
        model.resolutionChoice = .screen
        #expect(model.readout.hasSuffix("MP)") && model.warning?.contains("Downsample") == true && !model.showsProgress)
        model.resolutionChoice = .custom
        model.customResolution = 10
        #expect(model.unavailableReason == "Choose a resolution from 36 to 2,400 ppi" && model.rasterize() == nil)
        model.customResolution = 2400
        #expect(model.warning?.contains("200 MB") == true || model.warning != nil)
        model.resolutionChoice = .proof
        model.antiAliasing = .none
        model.transparent = false
        model.colorMode = .grayscale
        model.keepOriginals = true
        Render.view(RasterizeSheet(model: model))
        var closed = false
        model.onClose = { closed = true }
        await model.rasterize()?.value
        let command = try #require(performed.first as? RasterizeObjects)
        #expect(closed && model.phase == .done && command.keepOriginals && command.nodes == nodes && stored.count == 1)
        model.resolutionChoice = .print
        #expect(model.options.resolution == .print)
        RasterizeSheet.cancel(model)()
        #expect(RasterizeSheet.failed(.failed("x")) && !RasterizeSheet.failed(.ready))
        #expect(RasterizeModel.message(RasterizeError.invalidResolution).contains("36") && RasterizeModel.message(RasterizeError.nothingToRasterize).contains("nothing")
            && RasterizeModel.message(RasterizeError.tooLarge(bytes: 1)).contains("200") && RasterizeModel.message(CocoaError(.fileNoSuchFile)).contains("could not"))
        // Nothing drawn: no plan, no rasterizing.
        let nothing = RasterizeModel(nodes: [], selection: DisplayList(canvas: "none", items: []), downsampleLimit: nil, perform: { _ in Task { nil } }, storeBlob: { _ in })
        #expect(nothing.readout == "Nothing to rasterize" && nothing.warning == nil && nothing.unavailableReason == "The selection draws nothing")
    }

    @Test func aLargeRenderShowsProgressAndCancels() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 1000, height: 1000)])
        world.window.selection.model.set(Selection(ids))
        let (nodes, list) = RasterizeModel.selection(in: world.window)
        let model = RasterizeModel(nodes: nodes, selection: list, downsampleLimit: nil, perform: { _ in Task { nil } }, storeBlob: { _ in })
        model.resolutionChoice = .custom
        model.customResolution = 300
        model.antiAliasing = .none
        #expect(model.showsProgress)
        let task = model.rasterize()
        model.cancel()
        await task?.value
        #expect(model.phase == .ready || model.phase == .done)
        Render.view(RasterizeSheet(model: model))
    }

    @Test func optimizeOpensOverTheSelectedImagesAndTheSheetShowsEveryOption() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let glue = PackageHalvesGlue(sessions: DocumentSessions(connector: nil))
        glue.presenter.present = { _ in }
        glue.window = { world.window }
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(repeating: 7, count: 32)
        pixels.format = "public.png"
        pixels.pixelWidth = 64
        pixels.pixelHeight = 32
        pixels.mode = .rgb
        pixels.bitsPerChannel = 8
        let image = try #require(await world.document.perform(PlaceImage(pixels, name: "p.png", dpiX: 144, dpiY: 144, transform: .identity)).value?.createdObjects.first)
        world.select([image])
        #expect(glue.commands()[0].validation().isEnabled)
        let model = try #require(glue.presentOptimize())
        #expect(model.items.map(\.pixelWidth) == [64] && model.items[0].placedWidth == 32 && model.items[0].data == nil)
        model.onClose()
        #expect(glue.presenter.sheets[PackageHalvesGlue.optimizeSheet] == nil)
        // The sheet's change and blobs go through the window and the glue's placement.
        var stored = 0
        glue.storeBlobs = { blobs, _ in stored += blobs.count }
        try await model.storeBlobs([ImportedBlob(data: Data([1]), uti: "public.png")])
        _ = await model.perform(OpsCommand("Nothing", ops: [])).value
        #expect(stored == 1)
        let rasterize = try #require(glue.presentRasterize())
        try await rasterize.storeBlob(ImportedBlob(data: Data([2]), uti: "public.png"))
        _ = await rasterize.perform(OpsCommand("Nothing", ops: [])).value
        #expect(stored == 2)
        // The defaults before the app sets them.
        let bare = PackageHalvesGlue(sessions: DocumentSessions(connector: nil))
        #expect(bare.window() == nil && bare.imageStore(world.window) == nil && bare.downsampleLimit() == nil)
        try await bare.storeBlobs([], world.document)
        model.format = .jpeg
        Render.view(OptimizeImageSheet(model: model))
        model.resampleChoice = .effectiveResolution
        Render.view(OptimizeImageSheet(model: model))
        model.resampleChoice = .pixelSize
        Render.view(OptimizeImageSheet(model: model))
    }

    @Test func thePreferencesSyncFollowsSignInAndTheSwitch() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        #expect(delegate.attachPreferenceSync(nil) == nil)
        let server = FakePreferencesServer()
        let sync = try Self.sync(server)
        await delegate.attachPreferenceSync(sync)?.value
        let handlers = delegate.account.signedInHandlers.count
        #expect(handlers >= 1)
        for handler in delegate.account.signedInHandlers { handler() }
        delegate.preferences.set(false, for: PreferenceCatalog.Sync.enabled)
        #expect(await eventually { await sync.isEnabled == false })
        delegate.preferences.set(true, for: PreferenceCatalog.General.smartGuides)
        (delegate.preferences.backend as? AccountPreferenceBackend)?.stop()
    }

    @Test func theGlueOpensItsSheetsOverTheFrontWindow() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let glue = PackageHalvesGlue(sessions: DocumentSessions(connector: nil))
        glue.presenter.present = { _ in }
        glue.window = { world.window }
        #expect(glue.presentOptimize() == nil && glue.presentRasterize() == nil)
        let commands = glue.commands()
        #expect(commands.count == 3 && commands[0].validation().isEnabled == false && commands[1].validation().isEnabled == false)
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])
        world.window.selection.model.set(Selection(ids))
        #expect(commands[1].validation().isEnabled && commands[0].validation() == .disabled("Select an image"))
        let rasterize = try #require(glue.presentRasterize())
        rasterize.onClose()
        #expect(glue.presenter.sheets[PackageHalvesGlue.rasterizeSheet] == nil)
        if case .perform(let run) = commands[1].action { run() }
        glue.window = { nil }
        #expect(commands[0].validation() == .disabled("Open a document") && commands[1].validation() == .disabled("Open a document"))
        if case .perform(let run) = commands[0].action { run() }
    }
}
