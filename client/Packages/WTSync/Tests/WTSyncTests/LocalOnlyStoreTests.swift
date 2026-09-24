import Foundation
import GRDB
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// Local-only fields in the local store (crdt-model.adoc, "Local-only fields"; offline.adoc,
/// `view`): the outbox holds a change without them, the `view` table keeps what they wrote in the
/// same transaction, and every load or replacement of the state restores them.
@Suite struct LocalOnlyStoreTests {
    let scratch = Scratch()
    static let zoom = RegisterPath([2, 40, 1])

    static func zoomTo(_ magnification: Double) -> OpsCommand {
        OpsCommand("Zoom", ops: [Ops.set(WellKnown.settings, [zoom, RegisterPath([2, 7])], values: SettingsFields.values {
            $0.view.magnification = magnification
            $0.guidesLocked = true
        })])
    }

    static func magnification(_ store: LocalStore) async -> Double {
        await store.read { $0.props(WellKnown.settings).settings.view.magnification }
    }

    @Test func localOnlyWritesStayOutOfTheOutboxAndSurviveARelaunch() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        let update = try await store.perform(Self.zoomTo(4), recording: Fixture.recording())
        #expect(update.change?.ops[0].set.paths.count == 2)   // the façade sees what was applied
        let outbox = try await store.outbox()
        #expect(outbox.count == 1 && outbox[0].ops[0].set.paths.map(RegisterPath.init) == [RegisterPath([2, 7])])
        #expect(!outbox[0].ops[0].set.values.settings.hasView)
        #expect(try await store.pendingUpload().allSatisfy { !LocalOnly.carries($0, schema: .generated) })
        #expect(await Self.magnification(store) == 4)

        // A crash image holds the value: it was written with the change.
        let copy = try scratch.crashImage(of: "doc", to: "crash")
        let recovered = try await LocalStore.open(documentID: "D1", at: copy, options: options())
        #expect(await Self.magnification(recovered) == 4)
        try await recovered.close()

        _ = try await store.undo(recording: Fixture.recording())
        #expect(await Self.magnification(store) == 0)
        _ = try await store.redo(recording: Fixture.recording())
        try await store.close()
        let reopened = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        #expect(await Self.magnification(reopened) == 4)
        #expect(try await reopened.outbox().allSatisfy { !LocalOnly.carries($0, schema: .generated) })
        try await reopened.close()
    }

    @Test func replacingTheStateKeepsTheLocalOnlyValues() async throws {
        let store = try await LocalStore.open(documentID: "D1", at: scratch.url(), options: options())
        _ = try await store.perform(Self.zoomTo(3), recording: Fixture.recording())
        // A snapshot from the server (bootstrap, catch-up) holds no local-only value.
        var server = EngineState()
        server.apply(Fixture.change(9, seq: 1, start: 1, [Fixture.createLayer("S")]), serverSeq: 1)
        try await store.installSnapshot(server, serverSeq: 1)
        #expect(await Self.magnification(store) == 3)
        // Neither does the empty state salvage or a discard starts from.
        try await store.beginSalvage(reason: .expired)
        #expect(await Self.magnification(store) == 3)
        try await store.discardLocalChanges()
        #expect(await Self.magnification(store) == 3)
        try await store.close()
    }

    @Test func rowsRoundTripAndRefuseWhatDoesNotDecode() throws {
        let set = Write(node: WellKnown.settings, path: Self.zoom, value: [0x09, 0, 0, 0, 0, 0, 0, 0, 0x40], op: OpID(counter: 7, replica: 42))
        let unset = Write(node: OpID(counter: 3, replica: 42), path: RegisterPath([2, 60]).element(OpID(counter: 2, replica: 42)).child(3),
                          value: nil, op: OpID(counter: 8, replica: 42))
        #expect(try LocalOnlyRows.decode(LocalOnlyRows.encode(set)) == set)
        #expect(try LocalOnlyRows.decode(LocalOnlyRows.encode(unset)) == unset)
        #expect(LocalOnlyRows.key(unset.node, unset.path) == "crdt.local/3:42/2.60.<2:42>.3")
        #expect(LocalOnlyRows.decode(Data([1, 2, 3])) == nil)
        var truncated = try LocalOnlyRows.encode(set)
        truncated.removeLast(12)
        #expect(LocalOnlyRows.decode(truncated) == nil)
        let queue = try DatabaseQueue()
        try StoreSchema.migrator.migrate(queue)
        try queue.write { db in
            try LocalOnlyRows.keep([set, unset], db)
            try db.execute(sql: "INSERT INTO view (key, value) VALUES ('crdt.local/0:0/bad', x'00'), ('other', x'00')")
        }
        #expect(try queue.read { try LocalOnlyRows.all($0) }.count == 2)
    }
}
