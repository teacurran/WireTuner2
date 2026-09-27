import Foundation
import WTProto

/// One space's blob storage (`AccountService.Me`'s `storage`; saving.adoc, "Storage"; IO-008).
struct StorageUsage: Equatable, Sendable {
    var spaceID: String
    var usedBytes: UInt64
    var limitBytes: UInt64

    /// Used over the limit, 0...; zero without a limit.
    var fraction: Double { limitBytes == 0 ? 0 : Double(usedBytes) / Double(limitBytes) }
    /// At or past 90% of the limit: *Storage almost full*.
    var isAlmostFull: Bool { fraction >= Self.warningFraction }
    /// *Storage almost full* from 90%.
    static let warningFraction = 0.9
    var isFull: Bool { limitBytes > 0 && usedBytes >= limitBytes }
}

extension StorageUsage {
    init(_ usage: Wiretuner_Account_V1_StorageUsage) {
        self.init(spaceID: usage.spaceID, usedBytes: usage.usedBytes, limitBytes: usage.limitBytes)
    }
}

/// The storage quota messaging of the document windows (saving.adoc, "Storage"; IO-009, the app's
/// part): the account's usage per space read from `AccountService.Me`, *Storage almost full* in a
/// window's sync popover when its document's space is at 90% or more, and -- while a window is
/// *Storage full* -- the usage read again every few minutes, the waiting images retried as soon as
/// the space has room, so freeing space resumes uploads without anyone clicking anything.
@MainActor
final class StorageMonitor {
    static let pollInterval: Duration = .seconds(300)

    /// Reads the usage (`Me`); throws offline.
    var fetch: @MainActor () async throws -> [StorageUsage] = { [] }
    /// The open document windows.
    var windows: @MainActor () -> [DocumentWindowController] = { [] }
    /// The space a document is in (the library's record), nil when unknown.
    var space: @MainActor (DocumentHandle) -> String? = { _ in nil }
    /// Every read of the usage (the library window's banner follows it).
    var onUsage: @MainActor ([StorageUsage]) -> Void = { _ in }
    private(set) var usage: [StorageUsage] = []
    private var polling: Task<Void, Never>?

    init() {}

    /// "Storage almost full — 9.3 GB of 10 GB used", or nil below 90%.
    static func note(_ usage: StorageUsage?) -> String? {
        guard let usage, usage.isAlmostFull else { return nil }
        let used = ByteCountFormatter.string(fromByteCount: Int64(clamping: usage.usedBytes), countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(clamping: usage.limitBytes), countStyle: .file)
        return "Storage almost full — \(used) of \(limit) used"
    }

    func usage(for window: DocumentWindowController) -> StorageUsage? {
        guard let space = space(window.documentHandle) else { return nil }
        return usage.first { $0.spaceID == space }
    }

    /// Reads the usage again and updates every window: its note, and a retry of the waiting images
    /// when it is *Storage full* and its space now has room.
    @discardableResult
    func refresh() async -> Bool {
        guard let usage = try? await fetch() else { return false }
        self.usage = usage
        onUsage(usage)
        for window in windows() {
            let current = self.usage(for: window)
            window.collaboration.sync.storageNote = Self.note(current)
            if case .storageFull = window.syncStatus.state, let current, !current.isFull {
                window.syncStatus.perform(.retryNow)
            }
        }
        return true
    }

    /// Whether some window waits on the quota.
    var anyWindowFull: Bool {
        windows().contains { if case .storageFull = $0.syncStatus.state { true } else { false } }
    }

    /// Polls while a window is *Storage full*; stops by itself when none is.
    func startPolling(interval: Duration = StorageMonitor.pollInterval) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                if !self.anyWindowFull { break }
            }
            self?.polling = nil
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// A window opened or its sync state changed: its note now, and polling while it is full.
    func windowDidChange(_ window: DocumentWindowController) {
        window.collaboration.sync.storageNote = Self.note(usage(for: window))
        if case .storageFull = window.syncStatus.state { startPolling() }
    }
}

extension AppDelegate {
    /// The storage messaging over the account and the library's record of each document's space.
    func installStorageMonitor() {
        let account = account
        let library = library
        let documents = documents!
        storage.fetch = {
            let token = try await account.auth.validAccessToken()
            return try await account.client.me(accessToken: token).storage
        }
        storage.windows = { documents.allWindowControllers }
        storage.space = { document in library.cache.documents[document.id]?.spaceID }
        // The library window's banner (IO-009): the notes by space, read again when it shows.
        storage.onUsage = { usage in
            library.storageNotes = Dictionary(usage.compactMap { item in StorageMonitor.note(item).map { (item.spaceID, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        let storage = storage
        library.refreshStorage = { Task { await storage.refresh() } }
    }
}
