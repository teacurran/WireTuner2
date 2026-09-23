// Where the renderers get placed images' pixels (IMG-004, IMG-018).  The app tells the store
// where each blob lives in its cache (and how a download is going); the renderers ask for an
// asset at the scale they draw it and get the treated level at once when it is in memory, or
// nil (a placeholder) while it is decoded off the calling thread.  When a decode finishes the
// store calls `onReady` with the asset, so whoever owns the canvas invalidates the image's
// bounds (REND-004) and the next frame draws it.

import CoreGraphics
import Foundation

/// Decoded, treated image levels by asset (the blob's hex SHA-256).
public final class ImageStore: @unchecked Sendable {
    /// Where an asset stands, as a placeholder shows it.
    public enum State: Hashable, Sendable {
        /// The blob is not in the local cache.
        case missing
        /// The blob is downloading; `progress` 0...1.
        case downloading(progress: Double)
        /// The blob is local and its pixels are being decoded.
        case decoding
        /// At least one level is decoded.
        case ready
        /// The blob could not be decoded.
        case failed
    }

    private struct Asset {
        var state: State = .missing
        var pyramid: ImagePyramid?
    }

    /// The local file of an asset's blob, or nil while it is not cached.
    public let blobURL: @Sendable (String) -> URL?
    /// Where pyramid levels are cached on disk; nil keeps them in memory only.
    public let cacheDirectory: URL?
    public let cache: ImageMemoryCache
    public let pyramidThreshold: Int
    public let tiledThreshold: Int
    /// Called (on a background thread) when an asset finishes decoding, ready or failed.
    public var onReady: (@Sendable (String) -> Void)? {
        get { lock.withLock { readyHandler } }
        set { lock.withLock { readyHandler = newValue } }
    }

    private let lock = NSLock()
    private var readyHandler: (@Sendable (String) -> Void)?
    private var assets: [String: Asset] = [:]
    private var pending: Set<ImageCacheKey> = []
    private var opening: Set<String> = []
    private let queue = DispatchQueue(label: "WTRender.ImageStore", qos: .userInitiated, attributes: .concurrent)
    private let group = DispatchGroup()

    public init(
        blobURL: @escaping @Sendable (String) -> URL?,
        cacheDirectory: URL? = nil,
        memoryBudget: Int = 512 << 20,
        pyramidThreshold: Int = ImagePyramid.defaultPyramidThreshold,
        tiledThreshold: Int = ImagePyramid.defaultTiledThreshold
    ) {
        self.blobURL = blobURL
        self.cacheDirectory = cacheDirectory
        cache = ImageMemoryCache(budget: memoryBudget)
        self.pyramidThreshold = pyramidThreshold
        self.tiledThreshold = tiledThreshold
    }

    public func state(of assetID: String) -> State {
        lock.withLock { assets[assetID]?.state ?? .missing }
    }

    /// The asset's pyramid once its header has been read.
    public func pyramid(for assetID: String) -> ImagePyramid? {
        lock.withLock { assets[assetID]?.pyramid }
    }

    /// Records download progress for a blob that is not local yet.
    public func setDownloading(assetID: String, progress: Double) {
        lock.withLock {
            let state = assets[assetID]?.state ?? .missing
            if state == .missing || state.isDownloading {
                assets[assetID, default: Asset()].state = .downloading(progress: min(max(progress, 0), 1))
            }
        }
    }

    /// The blob reached the local cache: its header is read and its coarsest level decoded in
    /// the background, then `onReady` fires.  A failed asset is retried.
    public func blobArrived(assetID: String) {
        let start = lock.withLock { () -> Bool in
            let state = assets[assetID]?.state ?? .missing
            guard state == .missing || state == .failed || state.isDownloading, !opening.contains(assetID) else {
                return false
            }
            assets[assetID, default: Asset()].state = .decoding
            opening.insert(assetID)
            return true
        }
        if start {
            schedule { self.open(assetID, then: nil) }
        }
    }

    /// Forgets everything decoded for the asset (its blob was replaced or evicted).
    public func forget(assetID: String) {
        lock.withLock {
            assets[assetID] = nil
        }
        cache.removeAll(hash: assetID)
    }

    /// The asset treated by `treatment` at the level for `scale` (device pixels per image
    /// pixel), if it is decoded.  Otherwise the decode starts in the background (when the blob
    /// is local) and the result is a coarser or finer level already in memory, or nil.  A tiled
    /// asset (above the tiled threshold) is drawn from its finest reduced level here; its full
    /// resolution comes through `fullResolutionTile`.
    public func image(for assetID: String, treatment: ImageTreatment, scale: Double) -> CGImage? {
        enum Next {
            case done(CGImage?)
            case decode(ImageCacheKey, fallback: CGImage?)
            case open
        }
        let next = lock.withLock { () -> Next in
            if let pyramid = assets[assetID]?.pyramid {
                let key = ImageCacheKey(hash: assetID, level: ImageStore.levelIndex(in: pyramid, scale: scale), treatment: treatment)
                if let image = cache.image(for: key) {
                    return .done(image)
                }
                let fallback = cache.anyLevel(hash: assetID, treatment: treatment)?.image
                guard pending.insert(key).inserted else {
                    return .done(fallback)
                }
                return .decode(key, fallback: fallback)
            }
            let state = assets[assetID]?.state ?? .missing
            guard state != .failed, !opening.contains(assetID), blobURL(assetID) != nil else {
                return .done(nil)
            }
            assets[assetID, default: Asset()].state = .decoding
            opening.insert(assetID)
            return .open
        }
        switch next {
        case .done(let image):
            return image
        case .decode(let key, let fallback):
            schedule { self.decode(key) }
            return fallback
        case .open:
            schedule { self.open(assetID, then: (treatment, scale)) }
            return nil
        }
    }

    /// As `image(for:treatment:scale:)`, decoding inline when needed: for PDF output and
    /// export, which cannot wait for a frame.  Nil when the blob is not local or undecodable.
    public func imageBlocking(for assetID: String, treatment: ImageTreatment, scale: Double) -> CGImage? {
        guard let pyramid = pyramid(for: assetID) ?? openPyramid(assetID) else {
            return nil
        }
        let key = ImageCacheKey(hash: assetID, level: ImageStore.levelIndex(in: pyramid, scale: scale), treatment: treatment)
        if let image = cache.image(for: key) {
            return image
        }
        return decodeLevel(key, pyramid: pyramid)
    }

    /// The full-resolution pixels of `rect` (image pixels, top-left origin), treated; for a
    /// tiled asset zoomed in past its finest reduced level.  Decoded inline.
    public func fullResolutionTile(for assetID: String, rect: CGRect, treatment: ImageTreatment) -> CGImage? {
        guard let pyramid = pyramid(for: assetID) ?? openPyramid(assetID),
              let tile = pyramid.fullLevelTile(rect: rect)
        else {
            return nil
        }
        return treatment.apply(to: tile)
    }

    /// Blocks until every background decode has finished (tests, teardown).
    public func waitUntilIdle() {
        group.wait()
    }

    // MARK: Work

    /// The level drawn at `scale`: the pyramid's choice, except that a tiled pyramid's full
    /// level is never decoded whole, so its finest reduced level stands in.
    static func levelIndex(in pyramid: ImagePyramid, scale: Double) -> Int {
        let index = pyramid.level(forScale: scale).index
        return pyramid.isTiled && index == 0 && pyramid.levels.count > 1 ? 1 : index
    }

    private func schedule(_ work: @escaping @Sendable () -> Void) {
        queue.async(group: group, execute: work)
    }

    /// Reads the header (recording the pyramid, or failure) without touching `opening`.
    private func openPyramid(_ assetID: String) -> ImagePyramid? {
        let pyramid = blobURL(assetID).flatMap {
            ImagePyramid(url: $0, hash: assetID, cacheDirectory: cacheDirectory, pyramidThreshold: pyramidThreshold, tiledThreshold: tiledThreshold)
        }
        lock.withLock {
            if let pyramid {
                assets[assetID, default: Asset()].pyramid = pyramid
            } else {
                assets[assetID, default: Asset()].state = .failed
            }
        }
        return pyramid
    }

    /// Opens the asset in the background, then decodes the level asked for (or the coarsest).
    private func open(_ assetID: String, then request: (treatment: ImageTreatment, scale: Double)?) {
        let pyramid = openPyramid(assetID)
        let key = pyramid.map { pyramid in
            ImageCacheKey(
                hash: assetID,
                level: request.map { ImageStore.levelIndex(in: pyramid, scale: $0.scale) } ?? pyramid.levels.count - 1,
                treatment: request?.treatment ?? ImageTreatment()
            )
        }
        let decodes = lock.withLock { () -> Bool in
            opening.remove(assetID)
            guard let key else {
                return false
            }
            return pending.insert(key).inserted
        }
        if let key, decodes {
            decode(key)
        } else if key == nil {
            notify(assetID)
        }
    }

    private func decode(_ key: ImageCacheKey) {
        let pyramid = lock.withLock { assets[key.hash]?.pyramid }
        if let pyramid {
            _ = decodeLevel(key, pyramid: pyramid)
        }
        lock.withLock {
            _ = pending.remove(key)
        }
        notify(key.hash)
    }

    /// Decodes and treats one level into the cache, recording the asset's state.
    private func decodeLevel(_ key: ImageCacheKey, pyramid: ImagePyramid) -> CGImage? {
        let image = pyramid.image(level: key.level).flatMap { key.treatment.apply(to: $0) }
        if let image {
            cache.insert(image, for: key)
        }
        lock.withLock {
            // The asset's record exists: its pyramid was recorded before any decode.
            if image != nil {
                assets[key.hash]?.state = .ready
            } else if assets[key.hash]?.state != .ready {
                assets[key.hash]?.state = .failed
            }
        }
        return image
    }

    private func notify(_ assetID: String) {
        onReady?(assetID)
    }
}

extension ImageStore.State {
    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }
        return false
    }
}
