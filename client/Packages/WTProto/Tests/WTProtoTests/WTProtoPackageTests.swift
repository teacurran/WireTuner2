import Foundation
import GRPCCore
import SwiftProtobuf
import Testing
@testable import WTProto

/// Smoke tests over the generated code: a message round-trips through the binary wire format,
/// a oneof frame keeps its case, and a grpc-swift 2 client stub exists with the method
/// descriptors the sync protocol names (docs/spec/sync-protocol.adoc).
@Suite struct WTProtoPackageTests {
    @Test func welcomeRoundTripsThroughBinary() throws {
        var welcome = Wiretuner_Sync_V1_Welcome()
        welcome.role = .editor
        welcome.mergeTable = Data([0x0a, 0x02, 0x08, 0x01])
        welcome.headSeq = 42
        welcome.lastAcceptedSeq = 7
        welcome.snapshotHint = true
        welcome.featureLevel = 3

        let decoded = try Wiretuner_Sync_V1_Welcome(serializedBytes: try welcome.serializedBytes() as Data)
        #expect(decoded == welcome)
        #expect(decoded.role == .editor)
        #expect(decoded.mergeTable == Data([0x0a, 0x02, 0x08, 0x01]))
        #expect(decoded.headSeq == 42)
        #expect(decoded.lastAcceptedSeq == 7)
    }

    @Test func serverFrameKeepsItsCase() throws {
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 0x1234_5678_9abc_def0
        change.seq = 1
        change.startCounter = 16
        change.label = "Move 3 objects"
        var op = Wiretuner_Doc_V1_Op()
        op.noop = Wiretuner_Doc_V1_Noop()
        change.ops = [op]

        var frame = Wiretuner_Sync_V1_ServerFrame()
        frame.change = Wiretuner_Sync_V1_SequencedChange.with {
            $0.serverSeq = 9
            $0.change = change
        }

        let decoded = try Wiretuner_Sync_V1_ServerFrame(serializedBytes: try frame.serializedBytes() as Data)
        guard case .change(let sequenced)? = decoded.frame else {
            Issue.record("expected the change case, got \(String(describing: decoded.frame))")
            return
        }
        #expect(sequenced.serverSeq == 9)
        #expect(sequenced.change == change)
        #expect(sequenced.change.label == "Move 3 objects")
    }

    @Test func syncServiceDescriptorsMatchTheProtocol() {
        #expect(Wiretuner_Sync_V1_SyncService.descriptor.fullyQualifiedService == "wiretuner.sync.v1.SyncService")
        #expect(Wiretuner_Sync_V1_SyncService.Method.Subscribe.descriptor.fullyQualifiedMethod
            == "wiretuner.sync.v1.SyncService/Subscribe")
        #expect(Wiretuner_Sync_V1_SyncService.Method.PushChangeBatch.descriptor.method == "PushChangeBatch")
        let names = Set(Wiretuner_Sync_V1_SyncService.Method.descriptors.map(\.method))
        #expect(names == [
            "Subscribe", "PushChange", "PushChangeBatch", "PushChanges",
            "UpdatePresence", "Ack", "FetchChanges", "FetchSnapshot",
        ])
    }

    @Test func documentServiceClientIsGenerated() {
        // The client stub is a generic struct over any GRPCCore transport; that it compiles with
        // these descriptors is the check (there is no server to call in a unit test).
        #expect(Wiretuner_Docs_V1_DocumentService.Method.Search.descriptor.fullyQualifiedMethod
            == "wiretuner.docs.v1.DocumentService/Search")
        #expect(Wiretuner_Docs_V1_ShareService.Method.descriptors.contains { $0.method == "OpenLink" })
        #expect(Wiretuner_Docs_V1_BranchService.Method.descriptors.contains { $0.method == "MergeBranch" })
        #expect(Wiretuner_Docs_V1_VersionService.Method.descriptors.contains { $0.method == "RestoreAsCopy" })
        #expect(Wiretuner_Docs_V1_LibraryService.Method.descriptors.contains { $0.method == "ListLibraries" })
    }

    @Test func errorReasonNamesAreTheTableRows() throws {
        // ErrorInfo.reason carries the enum value name without `ERROR_REASON_`; the JSON form
        // shows the full name the wire string is derived from.
        #expect(Wiretuner_Sync_V1_ErrorReason.seqGap.rawValue == 6)
        #expect(Wiretuner_Sync_V1_ErrorReason(rawValue: 17) == .mergeStale)
        let rejected = Wiretuner_Sync_V1_ChangeRejected.with {
            $0.replica = 5
            $0.seq = 3
            $0.reason = .mergeStale
            $0.code = 9
        }
        let json = try rejected.jsonString()
        #expect(json.contains("\"ERROR_REASON_MERGE_STALE\""))
        let decoded = try Wiretuner_Sync_V1_ChangeRejected(jsonString: json)
        #expect(decoded == rejected)
    }
}
