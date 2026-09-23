import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// The in-process server's protocol rules, called directly (docs/spec/sync-protocol.adoc).
@Suite struct SimServerTests {
    static let doc = "D1"
    static let alice = SimUser(id: "alice", name: "Alice")
    static let bob = SimUser(id: "bob", name: "Bob")

    /// A server with document D1 owned by Alice, Bob an editor, and a token for each.
    static func server(_ configure: (inout SimServer.Options) -> Void = { _ in }) async -> (SimServer, String, String) {
        var options = SimServer.Options()
        configure(&options)
        let server = SimServer(clock: SimClock(scale: 0.001), options: options)
        await server.add(alice)
        await server.add(bob)
        await server.createDocument(doc, owner: alice.id)
        await server.setRole(.editor, for: bob.id, on: doc)
        return (server, await server.issueToken(for: alice.id, lifetime: .seconds(3_600)), await server.issueToken(for: bob.id, lifetime: .seconds(3_600)))
    }

    static func change(_ replica: UInt64, seq: UInt64, start: UInt64? = nil, name: String = "L", base: UInt64 = 0) -> Wiretuner_Doc_V1_Change {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = name
        var change = Wiretuner_Doc_V1_Change()
        change.replica = replica
        change.seq = seq
        change.startCounter = start ?? seq
        change.baseServerSeq = base
        change.label = "\(replica)#\(seq)"
        change.ops = [Ops.create(parent: OpID.wellKnown(4), position: [0x80], props: props)]
        return change
    }

    static func push(_ server: SimServer, _ change: Wiretuner_Doc_V1_Change, token: String, device: String = "d1") async throws -> UInt64 {
        try await server.pushChange(.with { $0.documentID = doc; $0.change = change }, token: token, device: device).serverSeq
    }

    static func reason(_ body: () async throws -> Void) async -> Wiretuner_Sync_V1_ErrorReason? {
        do {
            try await body()
            return nil
        } catch let error as SyncCallError {
            return error.reason ?? .unspecified
        } catch {
            return nil
        }
    }

    static func frames(_ stream: AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>, count: Int) async throws -> [Wiretuner_Sync_V1_ServerFrame] {
        var frames: [Wiretuner_Sync_V1_ServerFrame] = []
        for try await frame in stream {
            frames.append(frame)
            if frames.count == count { break }
        }
        return frames
    }

    @Test func theAcceptanceRuleInTheServersOrder() async throws {
        let (server, alice, bob) = await Self.server { $0.maxOps = 2 }
        #expect(try await Self.push(server, Self.change(7, seq: 1), token: alice) == 1)
        // An identical retry is acked silently with its first server seq; different content is a conflict.
        #expect(try await Self.push(server, Self.change(7, seq: 1), token: alice) == 1)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(7, seq: 1, name: "other"), token: alice) } == .replicaConflict)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(7, seq: 3), token: alice) } == .seqGap)
        // The replica is bound to Alice's device.
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(7, seq: 2), token: alice, device: "d2") } == .replicaConflict)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(7, seq: 2), token: bob) } == .replicaConflict)
        var empty = Self.change(8, seq: 1)
        empty.ops = []
        #expect(await Self.reason { _ = try await Self.push(server, empty, token: bob) } == .validationFailed)
        var large = Self.change(8, seq: 1)
        large.ops += large.ops + large.ops
        #expect(await Self.reason { _ = try await Self.push(server, large, token: bob) } == .validationFailed)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(8, seq: 1, start: 10), token: "sim.nobody.1.1") } == .unspecified)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(8, seq: 1), token: "garbage") } == .unspecified)
        let expired = await server.issueToken(for: "bob", lifetime: .zero)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(8, seq: 1), token: expired) } == .tokenExpired)
        await server.setRole(.viewer, for: "bob", on: Self.doc)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(8, seq: 1), token: bob) } == .roleInsufficient)
        let stats = await server.stats
        #expect(stats.duplicates == 1 && stats.conflicts == 3 && stats.gaps == 1 && stats.validationFailures == 2)
        #expect(stats.tokenRefusals == 3 && stats.roleRefusals == 1)
        #expect(await server.acceptedSeqs(7, in: Self.doc) == [1])
        let known = await server.hasDocument(Self.doc)
        let unknown = await server.hasDocument("D2")
        #expect(known && !unknown)
    }

    @Test func documentsAndAccess() async throws {
        let (server, alice, _) = await Self.server()
        let stranger = SimUser(id: "carol", name: "Carol")
        await server.add(stranger)
        let carol = await server.issueToken(for: stranger.id, lifetime: .seconds(60))
        #expect(await Self.reason {
            _ = try await server.pushChange(.with { $0.documentID = "D9"; $0.change = Self.change(7, seq: 1) }, token: alice, device: "d1")
        } == .documentNotFound)
        #expect(await Self.reason { _ = try await Self.push(server, Self.change(9, seq: 1), token: carol) } == .unspecified)
        let transport = SimServerTransport(server: server, device: "d1")
        await #expect(throws: SyncCallError.self) {
            for try await _ in transport.fetchChanges(.with { $0.documentID = "D9" }, token: alice) {}
        }
        await #expect(throws: SyncCallError.self) {
            for try await _ in transport.fetchSnapshot(.with { $0.documentID = Self.doc }, token: alice) {}
        }
        _ = try await Self.push(server, Self.change(7, seq: 1), token: alice)
        await server.takeSnapshot(Self.doc)
        #expect(await server.snapshotSeq(Self.doc) == 1)
        // A snapshot newer than asked for is not served.
        _ = try await Self.push(server, Self.change(7, seq: 2), token: alice)
        await server.takeSnapshot(Self.doc)
        await #expect(throws: SyncCallError.self) {
            for try await _ in transport.fetchSnapshot(.with { $0.documentID = Self.doc; $0.atOrBeforeServerSeq = 1 }, token: alice) {}
        }
        var frames = 0
        for try await _ in transport.fetchSnapshot(.with { $0.documentID = Self.doc }, token: alice) { frames += 1 }
        #expect(frames >= 2)
        var changes: [UInt64] = []
        for try await response in transport.fetchChanges(.with { $0.documentID = Self.doc; $0.untilServerSeq = 99 }, token: alice) {
            changes += response.changes.map(\.serverSeq)
        }
        #expect(changes == [1, 2])
    }

    @Test func batchesAndBulkUploadsAnswerAPrefix() async throws {
        let (server, alice, _) = await Self.server()
        let transport = SimServerTransport(server: server, device: "d1")
        await #expect(throws: SyncCallError.self) {
            _ = try await transport.pushChangeBatch(.with { $0.documentID = Self.doc }, token: alice)
        }
        let batch = try await transport.pushChangeBatch(.with {
            $0.documentID = Self.doc
            $0.changes = [Self.change(7, seq: 1), Self.change(7, seq: 2), Self.change(7, seq: 4)]
        }, token: alice)
        #expect(batch.serverSeqs == [1, 2] && batch.rejected.reason == .seqGap && batch.rejected.seq == 4)
        await #expect(throws: SyncCallError.self) { _ = try await transport.pushChanges([], token: alice) }
        await #expect(throws: SyncCallError.self) {
            _ = try await transport.pushChanges([.with { $0.documentID = Self.doc }, .with { $0.documentID = "D2" }], token: alice)
        }
        let bulk = try await transport.pushChanges([.with {
            $0.documentID = Self.doc
            $0.changes = [Self.change(7, seq: 3), Self.change(7, seq: 3, name: "x")]
        }], token: alice)
        #expect(bulk.lastAcceptedSeq == 3 && bulk.rejected.reason == .replicaConflict)
    }

    @Test func subscriptionsCarryWelcomeReplayPresenceAndEvents() async throws {
        let (server, alice, bob) = await Self.server { $0.pongAfter = .milliseconds(20) }
        _ = try await Self.push(server, Self.change(7, seq: 1), token: alice)
        let transport = SimServerTransport(server: server, device: "d2")
        let stream = transport.subscribe(.with {
            $0.documentID = Self.doc
            $0.replica = 9
            $0.presence.tool = "pen"
        }, token: bob)
        let opening = try await Self.frames(stream, count: 3)
        #expect(opening[0].welcome.headSeq == 1 && opening[0].welcome.role == .editor && !opening[0].welcome.snapshotHint)
        #expect(opening[1].change.serverSeq == 1 && opening[1].change.author.displayName == "Alice")
        #expect(opening[2].presence.participants.map(\.tool) == ["pen"])
        #expect(await server.subscriberCount == 1)
        try await transport.updatePresence(.with { $0.documentID = Self.doc; $0.replica = 9; $0.presence.tool = "brush" }, token: bob)
        await server.setRole(.viewer, for: Self.bob.id, on: Self.doc)
        var seen: [String] = []
        for try await frame in stream {
            switch frame.frame {
            case .presenceUpdate(let update)?: seen.append("presence \(update.tool) \(update.session) \(update.user.displayName)")
            case .event(let event)?: seen.append("event \(event.roleChanged.role)")
            case .pong?: seen.append("pong")
            default: break
            }
            if seen.contains("pong") && seen.count >= 3 { break }
        }
        #expect(seen.prefix(2) == ["presence brush 9 Bob", "event viewer"])
        // Access removed: the event, then the end of the subscription.
        let again = transport.subscribe(.with { $0.documentID = Self.doc; $0.replica = 9; $0.afterServerSeq = 1 }, token: bob)
        let welcome = try await Self.frames(again, count: 2)
        #expect(welcome[0].welcome.role == .viewer && welcome[1].presence.participants.count <= 1)
        await server.setRole(.unspecified, for: Self.bob.id, on: Self.doc)
        var last: Wiretuner_Sync_V1_ServerFrame?
        for try await frame in again { last = frame }
        #expect({ if case .accessRemoved? = last?.event.event { true } else { false } }())
        await #expect(throws: SyncCallError.self) {
            for try await _ in transport.subscribe(.with { $0.documentID = Self.doc; $0.replica = 9 }, token: bob) {}
        }
        await server.setRole(.editor, for: Self.bob.id, on: "D9")
        await server.shutdown()
    }

    @Test func faultsFailCallsAndStreams() async throws {
        let (server, alice, _) = await Self.server()
        let transport = SimServerTransport(server: server, device: "d1")
        let stream = transport.subscribe(.with { $0.documentID = Self.doc; $0.replica = 7 }, token: alice)
        _ = try await Self.frames(stream, count: 2)
        await server.restartBus(outage: .seconds(20))
        _ = try await Self.push(server, Self.change(7, seq: 1), token: alice)
        try await transport.updatePresence(.with { $0.documentID = Self.doc; $0.replica = 7 }, token: alice)
        await #expect(throws: SyncCallError.self) { for try await _ in stream {} }
        #expect(await server.stats.droppedLiveFrames == 1)
        await server.failOverDatabase(outage: .seconds(10))
        await #expect(throws: SyncCallError.self) { _ = try await Self.push(server, Self.change(7, seq: 2), token: alice) }
        try await Task.sleep(for: .milliseconds(20))
        // During the failover calls fail; the next push commits but loses its reply, and its retry
        // is a duplicate.
        await #expect(throws: SyncCallError.self) { _ = try await Self.push(server, Self.change(7, seq: 2), token: alice) }
        #expect(try await Self.push(server, Self.change(7, seq: 2), token: alice) == 2)
        await server.restart(downFor: .seconds(10))
        await #expect(throws: SyncCallError.self) { _ = try await Self.push(server, Self.change(7, seq: 3), token: alice) }
        let stats = await server.stats
        #expect(stats.lostReplies == 1 && stats.duplicates == 1 && stats.unavailable == 3)
    }

    /// The Stability job and the snapshotter: a replica silent past the window is retired, and
    /// with every live replica acking twice after the head the point reaches it.
    @Test func stabilityRetiresAndCollects() async throws {
        let clock = SimClock(scale: 0.001)
        let server = SimServer(clock: clock)
        await server.add(Self.alice)
        await server.add(Self.bob)
        await server.createDocument(Self.doc, owner: Self.alice.id)
        await server.setRole(.editor, for: Self.bob.id, on: Self.doc)
        let alice = await server.issueToken(for: Self.alice.id, lifetime: .seconds(365 * 86_400))
        let bob = await server.issueToken(for: Self.bob.id, lifetime: .seconds(365 * 86_400))
        _ = try await Self.push(server, Self.change(7, seq: 1), token: alice)
        _ = try await server.pushChange(.with { $0.documentID = Self.doc; $0.change = Self.change(8, seq: 1, start: 5) }, token: bob, device: "d2")
        _ = try await Self.push(server, Self.change(9, seq: 1, start: 9), token: alice, device: "d3")
        var deletion = Self.change(7, seq: 2, start: 20)
        deletion.ops = [Ops.setDeleted(OpID(counter: 1, replica: 7))]
        _ = try await Self.push(server, deletion, token: alice)
        clock.advance(by: .seconds(91 * 86_400))
        _ = try await server.ack(.with { $0.documentID = Self.doc; $0.replica = 7; $0.appliedServerSeq = 4 }, token: alice, device: "d1")
        _ = try await server.ack(.with { $0.documentID = Self.doc; $0.replica = 8; $0.appliedServerSeq = 4 }, token: bob, device: "d2")
        await server.runStabilityJob()
        for _ in 0..<3 {
            _ = try await server.ack(.with { $0.documentID = Self.doc; $0.replica = 7; $0.appliedServerSeq = 4 }, token: alice, device: "d1")
            _ = try await server.ack(.with { $0.documentID = Self.doc; $0.replica = 8; $0.appliedServerSeq = 4 }, token: bob, device: "d2")
        }
        await server.runStabilityJob()
        #expect(await server.isRetired(9, in: Self.doc))
        #expect(await Self.reason {
            _ = try await server.ack(.with { $0.documentID = Self.doc; $0.replica = 9; $0.appliedServerSeq = 4 }, token: alice, device: "d3")
        } == .replicaExpired)
        let point = try #require(await server.collectionPoint(Self.doc))
        #expect(point.seq == 4)
        let answer = try await server.ack(.with { $0.documentID = Self.doc; $0.replica = 7; $0.appliedServerSeq = 4 }, token: alice, device: "d1")
        #expect(answer.stableSeq == 4 && answer.collectSeq == 4)
        #expect(await server.state(Self.doc, collected: true).store.nodes.count < (await server.state(Self.doc)).store.nodes.count)
        await server.takeSnapshot(Self.doc)
        #expect(await server.describe(Self.doc).contains("retired"))
        #expect(await server.describe("D9") == "no document D9")
        await server.publishCollectionPoint(SimCollectionPoint(seq: 2, timeMs: 0), for: Self.doc)
        #expect(await server.collectionPoint(Self.doc)?.seq == 2)
    }

    @Test func forkCopiesTheLogThroughASeqPlusChanges() async throws {
        let (server, alice, _) = await Self.server()
        _ = try await Self.push(server, Self.change(7, seq: 1), token: alice)
        _ = try await Self.push(server, Self.change(7, seq: 2), token: alice)
        try await server.fork(Self.doc, newID: "F1", atServerSeq: 1, changes: [Self.change(11, seq: 1, start: 50)], token: alice)
        #expect(await server.log("F1").map(\.change.label) == ["7#1", "11#1"])
        #expect(await server.stats.forks == 1)
        await #expect(throws: SyncCallError.self) {
            try await server.fork("D9", newID: "F2", atServerSeq: 0, changes: [], token: alice)
        }
    }
}
