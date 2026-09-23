import Foundation
import Testing
@testable import WTCRDT
import WTProto

/// Snapshots (CRDT-009): a lossless round trip, the same behaviour afterwards, and the chunked,
/// zstd-compressed transfer.  The conformance vectors check every vector's snapshot bytes in both
/// engines.
@Suite struct SnapshotTests {
    static let n = Scenario.nodeText
    static let t = Scenario.textPath

    /// Everything a snapshot holds: moves (and a node without a parent), deleted flags, an unset
    /// register, a well-known node's register, moved and deleted elements, set histories judged by
    /// server sequence numbers, text with tombstones, marks and paragraph registers.
    static func rich() -> EngineState {
        var engine = InverseTests.base()
        engine.apply(Scenario.change(9, 1, 13, base: 2, [
            #"move { node { counter: 2 replica: 7 } parent { counter: 1 replica: 7 } position: "\x80" }"#,
            "set_deleted { node { counter: 2 replica: 7 } deleted: true }",
            "set { \(n) paths { segments { field: 1000 } segments { field: 2 } } }",
            #"element_move { \#(n) element { \#(InverseTests.stop3) } position: "\x90" }"#,
            "element_delete { \(n) elements { segments { field: 1000 } segments { field: 8 } segments { element { counter: 4 replica: 7 } } } deleted: true }",
            #"set_remove { \#(n) set { segments { field: 1000 } segments { field: 3 } } values { test { tags: "t" } } }"#,
            #"set_add { \#(n) set { segments { field: 1000 } segments { field: 3 } } values { test { tags: "u" } } }"#,
            "text_delete { \(n) \(t) ranges { first { counter: 8 replica: 7 } count: 1 } }",
            #"create { parent { counter: 77 replica: 7 } position: "\x80" props { test { label: "orphan" } } }"#,
            #"set { node { counter: 0 } paths { segments { field: 1 } segments { field: 1 } segments { field: 1 } } values { document { common { name: "Doc" } } } }"#,
            "set_deleted { \(n) }",
            "element_delete { \(n) elements { \(InverseTests.stop3) } }",
            #"element_insert { \#(n) sequence { segments { field: 1000 } segments { field: 8 } } positions: "\xA0" }"#,
        ]), serverSeq: 3)
        engine.acknowledge(replica: 5, seq: 1, serverSeq: 4)
        return engine
    }

    @Test func roundTripsLosslesslyAndMergesTheSameAfterwards() throws {
        var original = Self.rich()
        let bytes = Snapshot.encode(original, serverSeq: 3)
        var decoded = try Snapshot.decode(bytes, schema: Scenario.schema)
        #expect(decoded.stateHash == original.stateHash)
        #expect(Snapshot.encode(decoded, serverSeq: 3) == bytes)
        #expect(decoded.clock == original.clock)
        #expect(decoded.store.moveLog == original.store.moveLog)
        #expect(decoded.store.replicas.map(\.state) == original.store.replicas.map(\.state))
        #expect(View.of(decoded) == View.of(original))
        // A late move before the logged ones, a remove judged by the server-seq map, typing next to
        // a tombstone, a mark and a paragraph edit: both states take them alike.
        let late = Scenario.change(4, 1, 12, base: 3, [
            #"move { node { counter: 2 replica: 7 } parent { counter: 4 } position: "\x70" }"#,
            #"set_remove { \#(Self.n) set { segments { field: 1000 } segments { field: 3 } } values { test { tags: "u" } } }"#,
            Scenario.insert("Z", left: OpID(counter: 8, replica: 7), right: OpID(counter: 9, replica: 7)),
            Scenario.mark(nil, true, nil, false, "size: 9"),
            "set { \(Self.n) paths { segments { field: 1000 } segments { field: 9 } segments { element { counter: 7 replica: 7 } } segments { field: 6 } segments { field: 4 } } values { test { text { chars { paragraph { left_indent: 3 } } } } } }",
        ])
        original.apply(late, serverSeq: 5)
        decoded.apply(late, serverSeq: 5)
        #expect(decoded.stateHash == original.stateHash)
        #expect(Snapshot.encode(decoded, serverSeq: 5) == Snapshot.encode(original, serverSeq: 5))
    }

    @Test func anEmptyStateRoundTrips() throws {
        let bytes = Snapshot.encode(EngineState())
        #expect(try Snapshot.decode(bytes).stateHash == EngineState().stateHash)
    }

    @Test func decodingRejectsWhatIsNotASnapshot() throws {
        let bytes = Snapshot.encode(Self.rich(), serverSeq: 3)
        func fails(_ bytes: [UInt8]) -> Bool {
            (try? Snapshot.decode(bytes, schema: Scenario.schema)) == nil
        }
        #expect(fails([0xFF]))
        #expect(fails([0x12, 0x05, 0x01]))
        #expect(fails([0x0B]))
        #expect(fails([0x00]))
        #expect(fails([0x1A, 0x02, 0x0A, 0x80]))
        #expect(fails([0x12, 0x02, 0x22, 0x00]))
        #expect(fails([0x12, 0x04, 0x22, 0x02, 0x0A, 0x00]))
        #expect(fails([0x12, 0x04, 0x0A, 0x02, 0x2A, 0x01]))
        var tampered = bytes
        let hashAt = tampered.indices.first { index in
            index + 34 <= tampered.count && tampered[index] == 0x42 && tampered[index + 1] == 0x20
                && Array(tampered[(index + 2)..<(index + 34)]) == Self.rich().stateHash
        }!
        tampered[hashAt + 2] ^= 0xFF
        #expect(throws: Snapshot.Failure.self) { try Snapshot.decode(tampered, schema: Scenario.schema) }
        let described = (try? Snapshot.decode(tampered, schema: Scenario.schema)).map { _ in "" }
        #expect(described == nil)
    }

    @Test func framesCarryTheSnapshotInChunks() throws {
        let engine = Self.rich()
        let frames = SnapshotTransfer.frames(engine, serverSeq: 3)
        #expect(frames.count == 2)
        #expect(frames[0].header.chunkCount == 1 && frames[0].header.compression == .zstd)
        #expect(frames[0].header.nodeCount == UInt32(engine.store.nodes.count))
        let state = try SnapshotTransfer.state(frames, schema: Scenario.schema)
        #expect(state.stateHash == engine.stateHash)

        // Uncompressed, over several chunks.
        let big = [UInt8](repeating: 7, count: SnapshotTransfer.chunkSize * 2 + 5)
        let plain = SnapshotTransfer.frames(big, serverSeq: 1, stateHash: [UInt8](repeating: 0, count: 32), nodeCount: 0,
                                            compression: .unspecified)
        #expect(plain.count == 4 && plain.last!.chunk.count == 5)
        #expect(try SnapshotTransfer.assemble(plain).snapshot == big)
    }

    @Test func assemblingChecksTheFramesAgainstTheirHeader() throws {
        let frames = SnapshotTransfer.frames(Self.rich(), serverSeq: 3)
        func failure(_ frames: [Wiretuner_Doc_V1_SnapshotFrame]) -> String? {
            do {
                _ = try SnapshotTransfer.state(frames, schema: Scenario.schema)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(failure([]) == "the first frame is not a header")
        #expect(failure(Array(frames.dropFirst())) == "the first frame is not a header")
        #expect(failure(frames + [frames[0]]) == "a frame after the header is not a chunk of at most 1 MiB")
        var oversized = Wiretuner_Doc_V1_SnapshotFrame()
        oversized.chunk = Data(count: SnapshotTransfer.chunkSize + 1)
        #expect(failure([frames[0], oversized]) == "a frame after the header is not a chunk of at most 1 MiB")
        #expect(failure([frames[0]])?.hasPrefix("0 chunks of 0 bytes") == true)
        var corrupt = frames
        corrupt[1].chunk = Data(repeating: 0x55, count: frames[1].chunk.count)
        #expect(failure(corrupt)?.hasPrefix("zstd:") == true)
        var wrongSize = frames
        wrongSize[0].header.compression = .unspecified
        #expect(failure(wrongSize)?.hasPrefix("uncompressed payload of") == true)
        var wrongHash = frames
        wrongHash[0].header.stateHash = Data(count: 32)
        #expect(failure(wrongHash) == "the header's state_hash does not match the snapshot")
        var badSnapshot = SnapshotTransfer.frames([0xFF], serverSeq: 1, stateHash: [], nodeCount: 0)
        badSnapshot[0].header.chunkCount = 1
        #expect(failure(badSnapshot) == "not a DocumentSnapshot" || failure(badSnapshot) != nil)
    }

    @Test func zstdRoundTripsAndReportsBadInput() throws {
        let data = Array("snapshot snapshot snapshot".utf8)
        let compressed = Zstd.compress(data)
        #expect(try Zstd.decompress(compressed, size: data.count) == data)
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(compressed, size: data.count + 1) }
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress([1, 2, 3], size: 3) }
    }
}
