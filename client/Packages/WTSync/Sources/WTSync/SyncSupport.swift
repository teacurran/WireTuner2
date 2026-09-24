import Foundation
import Synchronization
import SwiftProtobuf
import WTCRDT
import WTModel
import WTProto

/// A wake-up: `fire` wakes every waiter, or the next `wait` when nobody is waiting.  Cancelling
/// a waiting task wakes it too.  A latching signal stays fired: every later `wait` returns at once.
final class Signal: Sendable {
    private struct State {
        var pending = false
        var latched = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let latching: Bool
    private let state = Mutex(State())

    init(latching: Bool = false) {
        self.latching = latching
    }

    func fire() {
        let latching = latching
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.latched = latching
            guard !state.waiters.isEmpty else {
                state.pending = true
                return []
            }
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state -> Bool in
                    if state.latched || state.pending || Task.isCancelled {
                        state.pending = false
                        return true
                    }
                    state.waiters[id] = continuation
                    return false
                }
                if now {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// Whether a latching signal has fired.
    var isFired: Bool { state.withLock { $0.latched } }

    /// Waits for `fire` or `timeout`, whichever comes first.
    func wait(timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// Fans values out to every open `AsyncStream`.
final class Broadcast<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    /// A new stream, first yielding `initial` when given.
    func stream(initial: Element? = nil) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            if let initial {
                continuation.yield(initial)
            }
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ element: Element) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(element)
        }
    }
}

/// Packing a backlog into `PushChanges` frames (docs/spec/offline.adoc, "Reconnecting with a
/// backlog"; SYNC-005): consecutive changes, at most `maxBytes` encoded per frame (1 MiB) and
/// `maxChanges` per frame (sync.proto's bound, 256).  A change larger than `maxBytes` travels
/// alone: the server accepts a one-change frame up to the 4 MiB change limit.
enum BulkFrames {
    static func pack(_ changes: [Wiretuner_Doc_V1_Change], documentID: String, maxBytes: Int = 1 << 20,
                     maxChanges: Int = 256) -> [Wiretuner_Sync_V1_PushChangesRequest] {
        let header = Wiretuner_Sync_V1_PushChangesRequest.with { $0.documentID = documentID }
        let headerBytes = encodedSize(header)
        var frames: [Wiretuner_Sync_V1_PushChangesRequest] = []
        var frame = header
        var bytes = headerBytes
        for change in changes {
            let size = encodedSize(change)
            let cost = 1 + varintSize(size) + size
            if !frame.changes.isEmpty && (bytes + cost > maxBytes || frame.changes.count == maxChanges) {
                frames.append(frame)
                frame = header
                bytes = headerBytes
            }
            frame.changes.append(change)
            bytes += cost
        }
        if !frame.changes.isEmpty {
            frames.append(frame)
        }
        return frames
    }

    static func varintSize(_ value: Int) -> Int {
        var value = UInt64(value)
        var size = 1
        while value >= 0x80 {
            value >>= 7
            size += 1
        }
        return size
    }
}

/// A snapshot downloaded through `FetchSnapshot` (docs/spec/sync-protocol.adoc, "Catch-up";
/// SYNC-004): its frames assembled, checked and decoded by WTCRDT's `SnapshotTransfer`.
enum SnapshotDownload {
    /// Why the frames do not make a snapshot.
    struct Failure: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    /// The state the frames carry and the server sequence it is at.  The server's header says
    /// `uncompressed_size = 0` until the snapshotter records it (SRV-007): the size is then read
    /// from the zstd frame header, which carries the content size.
    static func state(_ frames: [Wiretuner_Doc_V1_SnapshotFrame], schema: Schema) throws -> (state: EngineState, serverSeq: UInt64) {
        guard case .header(var header)? = frames.first?.frame else { throw Failure(description: "the first frame is not a header") }
        var frames = frames
        if header.uncompressedSize == 0 && header.compression == .zstd {
            var payload: [UInt8] = []
            for case .chunk(let chunk)? in frames.dropFirst().map(\.frame) {
                payload.append(contentsOf: chunk.prefix(18 - min(18, payload.count)))
                if payload.count >= 18 { break }
            }
            guard let size = contentSize(payload) else { throw Failure(description: "the zstd frame does not say its content size") }
            header.uncompressedSize = size
            frames[0] = .with { $0.header = header }
        }
        return (try SnapshotTransfer.state(frames, schema: schema), header.serverSeq)
    }

    /// The content size a zstd frame header declares (RFC 8878, 3.1.1.1), or nil.
    static func contentSize(_ bytes: [UInt8]) -> UInt64? {
        guard bytes.count >= 6, bytes[0] == 0x28, bytes[1] == 0xB5, bytes[2] == 0x2F, bytes[3] == 0xFD else { return nil }
        let descriptor = bytes[4]
        let singleSegment = descriptor & 0x20 != 0
        let fieldSize = [singleSegment ? 1 : 0, 2, 4, 8][Int(descriptor >> 6)]
        let start = 5 + (singleSegment ? 0 : 1) + [0, 1, 2, 4][Int(descriptor & 3)]
        guard fieldSize > 0, bytes.count >= start + fieldSize else { return nil }
        var value: UInt64 = 0
        for index in (0..<fieldSize).reversed() {
            value = value << 8 | UInt64(bytes[start + index])
        }
        return fieldSize == 2 ? value + 256 : value
    }
}

/// The server's acceptance limits for one change (docs/spec/sync-protocol.adoc, "Server log"):
/// 10,000 ops and 4 MiB encoded.  The sync client splits a change over them before sending it
/// (through salvage, `LocalStore.applySalvage`), and salvage re-issues changes within them.
public struct ChangeLimits: Sendable, Hashable {
    /// The most ops in one change.
    public var ops: Int
    /// The most bytes one encoded change may take.
    public var bytes: Int

    public init(ops: Int = 10_000, bytes: Int = 4 << 20) {
        self.ops = ops
        self.bytes = bytes
    }

    /// The server's limits.
    public static let server = ChangeLimits()

    /// The room `change`'s own fields (replica, seq, counters, base, time, label) take when it is
    /// re-issued: their encoding now, and 64 bytes for the re-issue's wider varints and a label
    /// filled in.  What is left of `bytes` holds the ops.
    static func headerSize(_ change: Wiretuner_Doc_V1_Change) -> Int {
        var bare = change
        bare.ops = []
        return encodedSize(bare) + 64
    }

    /// Whether `change` is within the limits.
    public func admits(_ change: Wiretuner_Doc_V1_Change) -> Bool {
        change.ops.count <= ops && encodedSize(change) <= bytes
    }

    /// The bytes an op adds to an encoded change: its own encoding, its tag and its length.
    static func size(of op: Wiretuner_Doc_V1_Op) -> Int {
        let size = encodedSize(op)
        return size + 1 + BulkFrames.varintBytes(UInt64(size)).count
    }
}

/// A change refused with `VALIDATION_FAILED`, rewritten as one `Noop`: the same replica, seq,
/// start counter and base, so the replica's seqs stay dense; the counters the refused ops took
/// are a Lamport jump for the replica's next change (counters increase, they need not be dense
/// across changes).  One op keeps the replacement inside any limit however many counters the
/// refused change took -- a `Noop` per counter would be refused again for its count.  The label
/// is cut to the 256 characters `Change.label` allows and a negative time is zeroed, so the
/// replacement passes the rules the original may have broken.
func noopChange(_ change: Wiretuner_Doc_V1_Change) -> Wiretuner_Doc_V1_Change {
    var noop = change
    noop.ops = [Ops.noop()]
    if noop.label.unicodeScalars.count > 256 {
        noop.label = String(String.UnicodeScalarView(noop.label.unicodeScalars.prefix(256)))
    }
    noop.wallTimeMs = max(0, noop.wallTimeMs)
    return noop
}

/// Whether `change` is nothing but `Noop`s: a refusal of it cannot be answered by sending less.
func isNoopOnly(_ change: Wiretuner_Doc_V1_Change) -> Bool {
    change.ops.allSatisfy { if case .noop? = $0.op { true } else { false } }
}

/// A backlog going up through `PushChanges`: how many of its coalesced bytes lie at or below
/// each seq, so the acknowledged seq reads as a percentage.
struct Backlog: Sendable {
    let seqs: [UInt64]
    let cumulative: [Int]

    init(_ changes: [Wiretuner_Doc_V1_Change]) {
        var total = 0
        var cumulative: [Int] = []
        for change in changes {
            total += encodedSize(change)
            cumulative.append(total)
        }
        seqs = changes.map(\.seq)
        self.cumulative = cumulative
    }

    /// Whole percent of the bytes acknowledged once every seq up to `acked` is.
    func percent(acked: UInt64) -> Int {
        guard let total = cumulative.last, total > 0 else { return 100 }
        var low = 0
        var high = seqs.count
        while low < high {
            let middle = (low + high) / 2
            if seqs[middle] <= acked {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? 0 : cumulative[low - 1] * 100 / total
    }
}

/// The binary encoding's size of `message`.  Encoding fails only for a proto2 message missing a
/// required field, and the sync and doc packages are proto3.
func encodedSize(_ message: some SwiftProtobuf.Message) -> Int {
    // swiftlint:disable:next force_try
    try! message.serializedData().count
}

/// The collection point (C, T) an `AckResponse` carries (D-067): absent (zero) means no collection.
struct CollectionPoint: Equatable {
    let seq: UInt64
    let timeMs: Int64

    init(seq: UInt64, timeMs: Int64) {
        self.seq = seq
        self.timeMs = timeMs
    }

    init?(_ response: Wiretuner_Sync_V1_AckResponse) {
        guard response.collectSeq > 0 else { return nil }
        self.init(seq: response.collectSeq, timeMs: response.collectTimeMs)
    }
}
