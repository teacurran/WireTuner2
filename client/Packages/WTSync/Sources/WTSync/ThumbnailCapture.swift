import Foundation
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The library thumbnail (DOC-032; creating-opening.adoc, "Client"; offline.adoc, `blobs_pending`):
/// at the local snapshot cadence -- when the document window closes, and every snapshot interval --
/// if the document changed since the last capture, the first page is rendered off the main actor
/// and queued on the blob queue with `tag = THUMBNAIL`, replacing any pending thumbnail, so it
/// uploads first and a backlog never holds more than one.  The thumbnail is not document state:
/// capturing never writes a change.
public actor ThumbnailCapture {
    /// Renders a document state as PNG bytes; nil when there is nothing to draw.
    public typealias Renderer = @Sendable (EngineState) async throws -> Data?

    /// What the document is at: a change applied locally or remotely moves it.
    struct Marker: Equatable {
        var nextSeq: UInt64
        var serverSeq: UInt64
    }

    let store: LocalStore
    let queue: BlobQueue
    let interval: Duration
    let render: Renderer
    private var captured: Marker?
    private var timer: Task<Void, Never>?
    /// The capture running or run most recently: the next waits for it, so a close during a
    /// timer's capture does not render the same state a second time.
    private var running: Task<String?, any Error>?
    /// How many timer intervals have passed and how many captures were asked for (tests wait on
    /// them instead of on the wall clock).
    private(set) var ticks = 0
    private(set) var requests = 0

    /// A capture for `store`'s document queueing on `queue`; `interval` is the snapshot interval
    /// (offline.adoc: five minutes).  The document as opened counts as captured.
    public init(store: LocalStore, queue: BlobQueue, interval: Duration = .seconds(300), render: @escaping Renderer = ThumbnailCapture.firstPage) async {
        self.store = store
        self.queue = queue
        self.interval = interval
        self.render = render
        captured = await Self.marker(of: store)
    }

    private static func marker(of store: LocalStore) async -> Marker {
        Marker(nextSeq: await store.nextSeq, serverSeq: await store.lastServerSeq)
    }

    /// Whether the document changed since the last capture.
    public var hasChanges: Bool {
        get async { await Self.marker(of: store) != captured }
    }

    /// Captures and queues the thumbnail if the document changed since the last capture; returns
    /// the queued blob's hash, or nil when nothing changed or nothing was drawn.
    @discardableResult
    public func captureIfChanged() async throws -> String? {
        requests += 1
        let previous = running
        let task = Task {
            _ = try? await previous?.value
            return try await captureOnce()
        }
        running = task
        return try await task.value
    }

    private func captureOnce() async throws -> String? {
        let marker = await Self.marker(of: store)
        guard marker != captured else { return nil }
        let state = await store.read { $0 }
        let render = render
        let png = try await Task.detached(priority: .utility) { try await render(state) }.value
        captured = marker
        guard let png else { return nil }
        return try await queue.add(png, mediaType: "image/png", tag: .thumbnail)
    }

    /// Starts capturing every `interval` while the document is open (idempotent).
    public func start() {
        guard timer == nil else { return }
        let interval = interval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.captureIfChanged()
                await self.tick()
            }
        }
    }

    private func tick() {
        ticks += 1
    }

    /// The window is closing: stops the timer and captures once more if the document changed.
    @discardableResult
    public func close() async throws -> String? {
        timer?.cancel()
        timer = nil
        return try await captureIfChanged()
    }

    /// The default renderer: the first page (the only page of an unpaged document) of the print
    /// and export display list at `ThumbnailRenderer.libraryEdge` pixels on its long edge.
    public static let firstPage: Renderer = { state in
        let page = PageList(state).pages[0].rect
        var builder = DocumentDisplayListBuilder(canvas: "thumbnail")
        return ThumbnailRenderer.png(builder.outputDisplayList(state), page: page)
    }
}
