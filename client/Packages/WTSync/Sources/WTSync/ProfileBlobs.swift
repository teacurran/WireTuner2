import Foundation
import WTCRDT
import WTModel
import WTProto
import WTRender

/// Custom colour profiles as content-addressed blobs (CMS-008; color-management.adoc, "Offline
/// behavior", color-profiles.adoc): loading an `.icc` file hashes it into the shared blob cache,
/// queues its upload ahead of images, registers it with the profile registry and hands back the
/// `ProfileRef` the document stores; a custom `ProfileRef` whose bytes are not here is downloaded
/// when it is first referenced, rendering meanwhile through the bundled default of its space with
/// `ColorSettings.pending` set, and flips when the blob arrives -- nothing is written.
///
/// One `ProfileBlobs` per registry and cache: the cache is content-addressed and shared by every
/// document, so two documents referencing one profile share one file.
public final class ProfileBlobs: Sendable {
    /// The media type profile blobs are uploaded with; `LocalStore.pendingBlobs` puts them right
    /// after the thumbnail.
    public static let mediaType = "application/vnd.iccprofile"

    /// Why a file was refused.
    public enum Failure: Error, Equatable {
        /// The file is not an ICC profile ColorSync reads, or its space is not RGB, CMYK, gray or
        /// Lab.
        case notAProfile
    }

    public let cache: BlobCache
    public let registry: WTColor.ProfileRegistry

    /// Profiles over `cache`; `install` makes `registry` read custom profiles from it.
    public init(cache: BlobCache, registry: WTColor.ProfileRegistry = .shared) {
        self.cache = cache
        self.registry = registry
    }

    /// Points the registry's `blobLoader` at the cache, so any custom profile whose blob is cached
    /// resolves (the renderer's `WTColor.ProfileRegistry.resolve` stops substituting it).
    public func install() {
        let cache = cache
        registry.blobLoader = { sha256 in
            let hash = BlobCache.hex(sha256)
            return cache.contains(hash) ? try? Data(contentsOf: cache.url(for: hash)) : nil
        }
    }

    /// Whether the bytes of the profile with SHA-256 `sha256` are here: `ColorSettings`'
    /// `isAvailable`.
    public func isAvailable(_ sha256: Data) -> Bool {
        cache.contains(BlobCache.hex(sha256))
    }

    /// *Other…* in the Color Settings sheet: reads the profile at `url`, and unless it is one of
    /// the bundled profiles (recognized by hash), caches it and queues its upload on `queue`
    /// (offline it waits in `blobs_pending`).  Returns the reference to store.
    public func load(fileAt url: URL, queue: BlobQueue) async throws -> WTColor.ProfileRef {
        let data = try Data(contentsOf: url)
        guard let ref = registry.register(iccData: data) else { throw Failure.notAProfile }
        guard !ref.isBundled else { return ref }
        // The cache hashes the same bytes the registry hashed, so the blob is `ref.sha256`.
        try await queue.add(fileAt: url, mediaType: Self.mediaType)
        return ref
    }

    /// The custom profiles `state`'s colour settings name whose bytes are not here, each asked of
    /// `queue` (downloaded once, however often asked; `BlobEvent.available` follows).
    @discardableResult
    public func requestMissing(in state: EngineState, queue: BlobQueue) async -> [WTColor.ProfileRef] {
        let pending = ColorSettings(state, registry: registry, isAvailable: isAvailable).pendingProfiles
        for profile in pending {
            _ = await queue.blob(profile.hexHash)
        }
        return pending
    }

    /// The profiles of `watching` as their blobs arrive in `events` (a blob queue's events): the
    /// renderer is invalidated on each (its colour settings re-read with `isAvailable`), with no
    /// change written.
    public func arrivals(_ events: AsyncStream<BlobEvent>, watching: [WTColor.ProfileRef]) -> AsyncStream<WTColor.ProfileRef> {
        let byHash = Dictionary(watching.map { ($0.hexHash, $0) }) { first, _ in first }
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .available(let hash, _) = event, let profile = byHash[hash] {
                        continuation.yield(profile)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
