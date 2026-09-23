import Foundation
import WTProto

/// Chunked snapshot transfer (docs/spec/crdt-model.adoc, "Snapshots"; `SnapshotFrame` in
/// doc/v1/snapshot.proto): a `SnapshotHeader`, then the zstd-compressed `DocumentSnapshot` in
/// chunks of at most 1 MiB.  wt-crdt's `SnapshotTransfer` is this type in Java.
public enum SnapshotTransfer {
    /// The largest chunk a frame carries.
    public static let chunkSize = 1 << 20

    /// Why frames could not be assembled.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The frames carrying `snapshot` (an encoded `DocumentSnapshot`): the header, then its
    /// compressed bytes in order.  `stateHash` and `nodeCount` fill the header.
    public static func frames(
        _ snapshot: [UInt8], serverSeq: UInt64, stateHash: [UInt8], nodeCount: Int,
        compression: Wiretuner_Doc_V1_SnapshotCompression = .zstd
    ) -> [Wiretuner_Doc_V1_SnapshotFrame] {
        let payload = compression == .zstd ? Zstd.compress(snapshot) : snapshot
        var header = Wiretuner_Doc_V1_SnapshotHeader()
        header.serverSeq = serverSeq
        header.stateHash = Data(stateHash)
        header.compression = compression
        header.compressedSize = UInt64(payload.count)
        header.uncompressedSize = UInt64(snapshot.count)
        header.nodeCount = UInt32(clamping: nodeCount)
        var frames: [Wiretuner_Doc_V1_SnapshotFrame] = []
        var start = 0
        while start < payload.count {
            let end = min(start + chunkSize, payload.count)
            var frame = Wiretuner_Doc_V1_SnapshotFrame()
            frame.chunk = Data(payload[start..<end])
            frames.append(frame)
            start = end
        }
        header.chunkCount = UInt32(frames.count)
        var first = Wiretuner_Doc_V1_SnapshotFrame()
        first.header = header
        return [first] + frames
    }

    /// The frames of `state`'s snapshot at `serverSeq`.
    public static func frames(_ state: EngineState, serverSeq: UInt64) -> [Wiretuner_Doc_V1_SnapshotFrame] {
        let snapshot = Snapshot.encode(state, serverSeq: serverSeq)
        return frames(snapshot, serverSeq: serverSeq, stateHash: Snapshot.stateHash(snapshot)!, nodeCount: state.store.nodes.count)
    }

    /// The `DocumentSnapshot` bytes `frames` carry, checked against the header's counts and sizes.
    public static func assemble(_ frames: [Wiretuner_Doc_V1_SnapshotFrame]) throws(Failure) -> (
        header: Wiretuner_Doc_V1_SnapshotHeader, snapshot: [UInt8]
    ) {
        guard case .header(let header)? = frames.first?.frame else { throw Failure(description: "the first frame is not a header") }
        var payload: [UInt8] = []
        for frame in frames.dropFirst() {
            guard case .chunk(let chunk)? = frame.frame, chunk.count <= chunkSize else {
                throw Failure(description: "a frame after the header is not a chunk of at most 1 MiB")
            }
            payload.append(contentsOf: chunk)
        }
        guard frames.count - 1 == Int(header.chunkCount), UInt64(payload.count) == header.compressedSize else {
            throw Failure(description: "\(frames.count - 1) chunks of \(payload.count) bytes, the header says "
                + "\(header.chunkCount) of \(header.compressedSize)")
        }
        let snapshot: [UInt8]
        switch header.compression {
        case .zstd:
            do {
                snapshot = try Zstd.decompress(payload, size: Int(header.uncompressedSize))
            } catch {
                throw Failure(description: error.description)
            }
        default:
            guard UInt64(payload.count) == header.uncompressedSize else {
                throw Failure(description: "uncompressed payload of \(payload.count) bytes, the header says \(header.uncompressedSize)")
            }
            snapshot = payload
        }
        return (header: header, snapshot: snapshot)
    }

    /// The state `frames` carry: `assemble`, a check that the header names the snapshot's
    /// `state_hash`, then `Snapshot.decode`, which checks the decoded state against it.
    public static func state(_ frames: [Wiretuner_Doc_V1_SnapshotFrame], schema: Schema = .generated) throws -> EngineState {
        let (header, snapshot) = try assemble(frames)
        guard Snapshot.stateHash(snapshot) == Array(header.stateHash) else {
            throw Failure(description: "the header's state_hash does not match the snapshot")
        }
        return try Snapshot.decode(snapshot, schema: schema)
    }
}
