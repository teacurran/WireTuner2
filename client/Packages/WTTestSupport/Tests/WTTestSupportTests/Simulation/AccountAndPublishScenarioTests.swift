import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

/// Multi-client scenarios for the client-sync pieces beside the document (BASIC-023 preferences
/// sync, WEB-013 web links) and for the units-per-em rows of the review (FONT-007), through the
/// simulator.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct AccountAndPublishScenarioTests {
    /// A preference sync for `client`'s account over its link, stamped with its simulated clock.
    static func preferences(_ client: SimClient, _ service: SimAccountService, in sim: Simulation) throws -> PreferenceSync {
        let clock = client.clock
        return try PreferenceSync(transport: service.transport(account: client.user.id, link: client.link),
                                  url: sim.directory.appending(components: client.name, "preferences.sqlite"), device: client.device,
                                  now: { Int64(clock().timeIntervalSince1970 * 1000) }, token: { "t" })
    }

    static func int(_ value: Int64) -> Wiretuner_Account_V1_PreferenceValue {
        var out = Wiretuner_Account_V1_PreferenceValue()
        out.intValue = value
        return out
    }

    /// BASIC-023: two devices of one person change the same key while one is offline; after
    /// reconnect both show the newer value -- whichever side made it.
    @Test func twoDevicesChangeOneKeyWhileOneIsOffline() async throws {
        let sim = try await Simulation(name: "preferences-offline", seed: Simulation.seed(2301))
        defer { Task { await sim.shutdown() } }
        let priya = SimUser(id: "u-priya", name: "Priya")
        let studio = try await sim.addClient("studio", user: priya)
        let laptop = try await sim.addClient("laptop", user: priya, device: "laptop")
        try await sim.settle()
        let service = SimAccountService()
        let atStudio = try Self.preferences(studio, service, in: sim)
        let atLaptop = try Self.preferences(laptop, service, in: sim)

        // The laptop's offline change is older: the studio's newer one wins on both.
        laptop.goOffline()
        try await atLaptop.enqueue(["general.pick_distance": Self.int(3)])
        await #expect(throws: SyncCallError.self) { try await atLaptop.push() }
        sim.advance(by: .seconds(60))
        try await atStudio.enqueue(["general.pick_distance": Self.int(7)])
        try await atStudio.push()
        laptop.goOnline()
        #expect(try await atLaptop.refresh()?["general.pick_distance"]?.intValue == 7)
        #expect(try await atStudio.refresh()?["general.pick_distance"]?.intValue == 7)

        // Now the offline change is the newer one: it is sent on reconnect and wins on both.
        studio.goOffline()
        try await atStudio.enqueue(["general.smart_guides": Self.int(0)])
        laptop.goOffline()
        sim.advance(by: .seconds(60))
        try await atLaptop.enqueue(["general.smart_guides": Self.int(1)])
        studio.goOnline()
        try await atStudio.refresh()
        laptop.goOnline()
        #expect(try await atLaptop.refresh()?["general.smart_guides"]?.intValue == 1)
        #expect(try await atStudio.refresh()?["general.smart_guides"]?.intValue == 1)
        #expect(service.preferences(of: priya.id)["general.smart_guides"]?.device == laptop.device)
        try await sim.expectConverged()
    }

    /// WEB-013: a publish uploads its blobs and registers the bundle; a second client's
    /// *Published links* sheet updates from the document event; republishing sends no blob bytes;
    /// offline, publishing fails at once and the sheet shows the cached list read-only.
    @Test func aSecondClientsPublishedLinksFollowTheDocumentEvent() async throws {
        let sim = try await Simulation(name: "publish-links", seed: Simulation.seed(2302))
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana")
        let ben = try await sim.addClient("ben")
        try await sim.settle()
        let server = try #require(sim.server)
        let service = SimPublishService(server: server)
        let anaLink = service.transports(link: ana.link)
        let benLink = service.transports(link: ben.link)
        let uploader = PublishUploader(documentID: sim.documentID, blobs: anaLink, publishes: anaLink, token: { "t" })
        let links = PublishedLinks(documentID: sim.documentID, transport: benLink, token: { "t" })
        #expect(await links.refresh().publishes.isEmpty)

        let files = [PublishBundleFile(path: "index.html", data: Data("<html>hi</html>".utf8), mediaType: "text/html; charset=utf-8"),
                     PublishBundleFile(path: "images/a.png", data: Data(repeating: 7, count: 300_000), mediaType: "image/png")]
        var job = await uploader.job(files, serverSeq: await server.head(sim.documentID), settingName: "Setting 1")
        let publish = try await uploader.run(&job)
        let event = try await Self.publishesChanged(ben, after: 0)
        await links.handle(event)
        let listing = await links.refresh()
        #expect(listing.isCurrent && listing.publishes.map(\.publishID) == [publish.publishID])
        #expect(await links.currentURL == "https://pub.sim/d/\(sim.documentID)/")
        let bytes = service.uploadedBytes

        // Republishing the same bundle: no blob bytes, a new current publish.
        var again = await uploader.job(files, serverSeq: 1, settingName: "Setting 1")
        try await uploader.run(&again)
        #expect(service.uploadedBytes == bytes && service.publishes(of: sim.documentID).count == 2)
        await links.handle(try await Self.publishesChanged(ben, after: 1))

        // Ben changes access, downloads the files, unpublishes.
        try await links.setAccess(.anyoneWithLink, of: publish.publishID)
        #expect(service.publishes(of: sim.documentID).first { $0.publishID == publish.publishID }?.access == .anyoneWithLink)
        #expect(try await links.files(of: publish.publishID, blobs: benLink).map(\.data) == files.map(\.data))
        try await links.unpublish(publish.publishID)
        #expect(await links.refresh().publishes.count == 1)
        await #expect(throws: SyncCallError.self) { try await benLink.getPublish(.with { $0.publishID = publish.publishID }, token: "t") }

        // Offline: publishing is not queued, the sheet is read-only.
        ben.goOffline()
        ana.goOffline()
        var offline = await uploader.job(files, serverSeq: 1, settingName: "Setting 1")
        await #expect(throws: SyncCallError.self) { try await uploader.run(&offline) }
        let cached = await links.refresh()
        #expect(!cached.isCurrent && cached.publishes.count == 1)
        await #expect(throws: SyncCallError.self) { try await benLink.createPublish(.init(), token: "t") }
        await #expect(throws: SyncCallError.self) { try await benLink.stat(.init(), token: "t") }
        await #expect(throws: SyncCallError.self) { try await benLink.setPublishAccess(.init(), token: "t") }
        await #expect(throws: SyncCallError.self) { try await benLink.deletePublish(.init(), token: "t") }
        var failed = false
        do {
            for try await _ in benLink.download(.init(), token: "t") {}
        } catch {
            failed = true
        }
        #expect(failed)
        ana.goOnline()
        ben.goOnline()
        try await sim.settle()
        try await sim.expectConverged()
    }

    /// The `index`-th `PublishesChanged` document event `client` received (waiting for it).
    static func publishesChanged(_ client: SimClient, after index: Int) async throws -> SyncEvent {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let events = client.events.filter { event in
                if case .document(let frame) = event, case .publishesChanged? = frame.event { return true }
                return false
            }
            if events.count > index { return events[index] }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Simulation.Failure(description: "\(client.name) received no PublishesChanged")
    }

    /// FONT-007: replica A scales the font 1000→2048 while replica B draws two paths offline; after
    /// reconnect B's review lists both under "drawn while the font was rescaled", and *Rescale mine*
    /// makes them identical to A's scaled fixture within 0.01 units on every client.
    @Test func aScaleWhileAnotherDrawsOfflineIsRescaledFromTheReview() async throws {
        let sim = try await Simulation(name: "font-rescale", seed: Simulation.seed(2303))
        defer { Task { await sim.shutdown() } }
        let a = try await sim.addClient("a")
        let b = try await sim.addClient("b")
        await a.perform(NewTypeface(family: "Marlowe", style: "Regular", upm: 1_000, set: nil))
        await a.perform(AddGlyphs([NewGlyph(scalar: 0x41), NewGlyph(scalar: 0x42)]))
        try await sim.settle()
        let index = GlyphIndex(a.state)
        let glyphA = try #require(index.glyph(named: "A")?.id)
        let glyphB = try #require(index.glyph(named: "B")?.id)
        let fixture = try await Self.box(on: glyphA, by: a)
        try await sim.settle()

        b.goOffline()
        await a.perform(SetUnitsPerEm(2_048, scale: true))
        let one = try await Self.box(on: glyphA, by: b)
        let two = try await Self.box(on: glyphB, by: b)
        b.goOnline()
        try await sim.settle()
        let reviews: [ReviewModel] = b.events.compactMap { event in
            switch event {
            case .reviewNeeded(let review), .merged(let review): review
            default: nil
            }
        }
        let review = try #require(reviews.last)
        #expect(review.rescaleRows.map(\.node) == [one, two])
        #expect(review.rescaleRows.allSatisfy { $0.reason == .drawnWhileRescaled && abs($0.factor - 2.048) < 1e-12 })
        let rescale = try #require(FontRescaleReview.rescaleAll(review.rescaleRows))
        await b.perform(rescale)
        try await sim.settle()
        try await sim.expectConverged()
        for client in [a, b] {
            let scaled = try #require(Objects.bounds(of: fixture, in: client.state))
            for node in [one, two] {
                let bounds = try #require(Objects.bounds(of: node, in: client.state))
                #expect(abs(bounds.minX - scaled.minX) < 0.01 && abs(bounds.minY - scaled.minY) < 0.01)
                #expect(abs(bounds.width - scaled.width) < 0.01 && abs(bounds.height - scaled.height) < 0.01)
            }
        }
    }

    /// A 100 × 500 rectangle at (0, −500) on `glyph`'s canvas, drawn by `client`.
    static func box(on glyph: OpID, by client: SimClient) async throws -> OpID {
        let create = CreateShape(.rectangle(CornerRadii()), size: Size(width: 100, height: 500), transform: .translation(x: 0, y: -500))
        let node = try Workload.created(await client.perform(create), by: client, "a box")[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.common.canvas.id = glyph.proto
        await client.perform(OpsCommand("Place", ops: [Ops.set(node, [RegisterPath([NodeKind.rect.rawValue, 1, 5])], values: props)]))
        return node
    }
}
