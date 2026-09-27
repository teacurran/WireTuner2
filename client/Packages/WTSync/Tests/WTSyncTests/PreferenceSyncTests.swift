import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Testing
import WTCRDT
import WTProto
@testable import WTSync

/// The account's preferences as the server keeps them: per key the entry with the greater
/// `updated_at_ms`, receipt order on ties (preferences.adoc, "Merge semantics").
final class FakePreferenceServer: PreferencesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Wiretuner_Account_V1_PreferenceValue] = [:]
    var offline = false
    private(set) var sets: [[String: Wiretuner_Account_V1_PreferenceValue]] = []
    private(set) var gets = 0

    struct Offline: Error {}

    var map: [String: Wiretuner_Account_V1_PreferenceValue] { lock.withLock { values } }

    func getPreferences(_ request: Wiretuner_Account_V1_GetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_GetPreferencesResponse {
        try lock.withLock {
            if offline { throw Offline() }
            gets += 1
            var response = Wiretuner_Account_V1_GetPreferencesResponse()
            response.preferences.values = values
            return response
        }
    }

    func setPreferences(_ request: Wiretuner_Account_V1_SetPreferencesRequest, token: String) async throws
        -> Wiretuner_Account_V1_SetPreferencesResponse {
        try lock.withLock {
            if offline { throw Offline() }
            sets.append(request.changes.values)
            for (id, value) in request.changes.values {
                values[id] = ShortcutSetSync.merge(values[id], value, now: value.updatedAtMs)
            }
            var response = Wiretuner_Account_V1_SetPreferencesResponse()
            response.preferences.values = values
            return response
        }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
    var now: Int64 { lock.withLock { ms } }
    func advance(_ by: Int64) { lock.withLock { ms += by } }
}

extension Wiretuner_Account_V1_PreferenceValue {
    static func int(_ value: Int64) -> Self {
        var out = Self()
        out.intValue = value
        return out
    }

    static func bool(_ value: Bool) -> Self {
        var out = Self()
        out.boolValue = value
        return out
    }
}

@Suite struct PreferenceSyncTests {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(component: "prefsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func device(_ server: FakePreferenceServer, _ name: String, clock: Clock, in directory: URL, enabled: Bool = true) throws -> PreferenceSync {
        try PreferenceSync(transport: server, url: directory.appending(component: "\(name).sqlite"), device: name, enabled: enabled,
                           now: { clock.now }, token: { "t" })
    }

    @Test func twoDevicesChangeOneKeyWhileOneIsOfflineAndBothEndWithTheNewer() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakePreferenceServer()
        let clock = Clock(1_000)
        let studio = try Self.device(server, "studio", clock: clock, in: dir)
        let laptop = try Self.device(server, "laptop", clock: clock, in: dir)
        let updates = await laptop.updates()

        // The laptop is offline: its change queues.
        server.offline = true
        try await laptop.enqueue(["general.pick_distance": .int(5)])
        await #expect(throws: FakePreferenceServer.Offline.self) { try await laptop.push() }
        #expect(try await laptop.pending()["general.pick_distance"]?.updatedAtMs == 1_000)
        server.offline = false
        // Later the studio changes the same key, online.
        clock.advance(500)
        try await studio.enqueue(["general.pick_distance": .int(9)])
        let pushed = try #require(try await studio.push())
        #expect(pushed["general.pick_distance"]?.intValue == 9 && pushed["general.pick_distance"]?.device == "studio")
        #expect(try await studio.pending().isEmpty)

        // The laptop reconnects: its older queued value is superseded, not sent.
        let applied = try #require(try await laptop.refresh())
        #expect(applied["general.pick_distance"]?.intValue == 9)
        #expect(try await laptop.pending().isEmpty && server.sets.count == 1)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?["general.pick_distance"]?.intValue == 9)
        #expect(await laptop.accountMap["general.pick_distance"]?.intValue == 9)
        #expect(try await studio.refresh()?["general.pick_distance"]?.intValue == 9)
    }

    @Test func aQueuedNewerEntrySurvivesAFetchAndIsSent() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakePreferenceServer()
        let clock = Clock(1_000)
        let studio = try Self.device(server, "studio", clock: clock, in: dir)
        let laptop = try Self.device(server, "laptop", clock: clock, in: dir)
        try await studio.enqueue(["general.smart_guides": .bool(true)])
        try await studio.push()
        clock.advance(10)
        try await laptop.enqueue(["general.smart_guides": .bool(false)])
        let applied = try #require(try await laptop.refresh())
        #expect(applied["general.smart_guides"]?.boolValue == false)
        #expect(server.map["general.smart_guides"]?.boolValue == false && server.map["general.smart_guides"]?.device == "laptop")
        #expect(try await laptop.pending().isEmpty)
        // Nothing queued: a push sends nothing.
        #expect(try await laptop.push() == nil)
    }

    @Test func withSyncOffNothingIsPushedOrApplied() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakePreferenceServer()
        let clock = Clock(1_000)
        let other = try Self.device(server, "other", clock: clock, in: dir)
        try await other.enqueue(["sync.undo_levels": .int(50)])
        try await other.push()
        let mac = try Self.device(server, "mac", clock: clock, in: dir, enabled: false)
        #expect(await !mac.isEnabled)
        try await mac.enqueue(["sync.undo_levels": .int(10)])
        #expect(try await mac.pending().isEmpty)
        #expect(try await mac.push() == nil)
        #expect(try await mac.refresh() == nil)
        #expect(server.gets == 0 && server.map["sync.undo_levels"]?.intValue == 50)

        // Turning it on fetches the account's map; off again forgets the queue.
        let updates = await mac.updates()
        try await mac.setEnabled(true)
        try await mac.setEnabled(true)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?["sync.undo_levels"]?.intValue == 50)
        server.offline = true
        try await mac.enqueue(["sync.undo_levels": .int(10)])
        try await mac.setEnabled(false)
        #expect(try await mac.pending().isEmpty)
    }

    @Test func theOutboxSurvivesRelaunch() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakePreferenceServer()
        server.offline = true
        let clock = Clock(7)
        do {
            let mac = try Self.device(server, "mac", clock: clock, in: dir)
            try await mac.enqueue(["general.pick_distance": .int(4)])
            try await mac.enqueue([:])
        }
        let again = try Self.device(server, "mac", clock: clock, in: dir)
        #expect(try await again.pending()["general.pick_distance"]?.intValue == 4)
        server.offline = false
        try await again.push()
        #expect(server.map["general.pick_distance"]?.updatedAtMs == 7)
    }

    @Test func teamFloorOfFortyRaisesAUsersTwentyToForty() {
        var map: PreferenceSync.Entries = ["sync.ask_overlap_count": .int(20), "sync.auto_merge_below": .int(300),
                                          "sync.ask_overlap_share": .int(40), "sync.always_ask": .bool(true),
                                          "sync.suggest_review_after_hours": .int(2)]
        let user = PreferenceSync.reconcilePreferences(map)
        #expect(user.askOverlapCount == 20 && user.autoMergeBelow == 300 && user.askOverlapShare == 0.4 && user.alwaysAsk)
        #expect(user.suggestReviewAfter == .seconds(7200))
        let team = ReconcilePreferences(askOverlapCount: 40)
        let floored = PreferenceSync.reconcilePreferences(map, team: team)
        #expect(floored.askOverlapCount == 40 && floored.autoMergeBelow == 300 && floored.suggestReviewAfter == .seconds(12 * 3600))
        // In the decision: 30 overlapping objects ask for the whole document under the user's 20,
        // and only per object under the team's 40.
        let divergence = Divergence(localOps: 60, remoteOps: 60, localObjects: 1_000, remoteObjects: 1_000, remoteOpsByReplica: [:],
                                    gap: .seconds(3600), remoteComplete: true,
                                    entries: (0..<30).map { ReviewEntry(node: OpID(counter: UInt64($0 + 1), replica: 3), kinds: [.bothEdited]) })
        map["sync.always_ask"] = .bool(false)
        #expect(divergence.decision(PreferenceSync.reconcilePreferences(map)) == .wholeDocument)
        #expect(divergence.decision(PreferenceSync.reconcilePreferences(map, team: team)) == .perObject)
        // Unset and wrongly typed entries read as defaults.
        #expect(PreferenceSync.reconcilePreferences(["sync.ask_overlap_count": .bool(true)]) == .standard)
    }

    @Test func theDefaultStoreIsInApplicationSupport() throws {
        #expect(try PreferenceSync.defaultURL().path.hasSuffix("WireTuner/Preferences.sqlite"))
    }

    typealias Method = Wiretuner_Account_V1_AccountService.Method

    @Test func theGRPCTransportCallsAccountService() async throws {
        let fake = FakePreferenceServer()
        let recorded = FakeGRPCService.Calls()
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func unary<Output: Sendable>(_ metadata: Metadata, _ body: () async throws -> Output) async throws -> StreamingServerResponse<Output> {
            recorded.metadata.withLock { $0.append(metadata) }
            do {
                return StreamingServerResponse(single: ServerResponse(message: try await body()))
            } catch is FakePreferenceServer.Offline {
                throw FakeGRPCService.status(SyncCallError(code: 14, reason: nil, message: "down", retryAfter: nil))
            }
        }
        router.registerHandler(forMethod: Method.GetPreferences.descriptor, deserializer: ProtobufDeserializer<Method.GetPreferences.Input>(),
                               serializer: ProtobufSerializer<Method.GetPreferences.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.getPreferences(single.message, token: "") }
        }
        router.registerHandler(forMethod: Method.SetPreferences.descriptor, deserializer: ProtobufDeserializer<Method.SetPreferences.Input>(),
                               serializer: ProtobufSerializer<Method.SetPreferences.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary(single.metadata) { try await fake.setPreferences(single.message, token: "") }
        }
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: router)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCPreferencesTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            var set = Wiretuner_Account_V1_SetPreferencesRequest()
            set.changes.values = ["a.b": .int(1)]
            let answered = try await transport.setPreferences(set, token: "tok")
            #expect(answered.preferences.values["a.b"]?.intValue == 1)
            let fetched = try await transport.getPreferences(Wiretuner_Account_V1_GetPreferencesRequest(), token: "tok")
            #expect(fetched.preferences.values.count == 1)
            fake.offline = true
            await #expect(throws: SyncCallError.self) {
                try await transport.getPreferences(Wiretuner_Account_V1_GetPreferencesRequest(), token: "tok")
            }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.count == 3 && calls.allSatisfy { Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
        #expect(calls.allSatisfy { Array($0[stringValues: "wt-device"]) == ["device-1"] })
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() throws {
        _ = try GRPCPreferencesTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        _ = try GRPCPreferencesTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
    }
}
