import AppKit
import WTCRDT
import WTModel
import WTRender
import WTSync

/// Custom colour profiles as shared blobs in the app (color-management.adoc, "Offline behavior";
/// the WTApp glue CMS-008 left): one `ProfileBlobs` over the app's blob cache, installed at launch
/// so the registry reads cached custom profiles; the Color Settings sheet's *Other…* (and an
/// installed profile) loads through it -- cached and queued for upload on the document's blob queue
/// -- and every open document asks its queue for the custom profiles its colour settings name that
/// are not here yet, when it opens and whenever it changes.
@MainActor
final class ProfileBlobGlue {
    /// The app's glue; nil until launch sets it (tests make their own).
    static var shared: ProfileBlobGlue?

    let profiles: ProfileBlobs
    /// A document's blob queue: its sync session's; nil offline or unsaved.
    let queue: @MainActor (DocumentHandle) -> BlobQueue?
    /// The profiles already asked for, per document (asking again is harmless, but quiet).
    private(set) var requested: [String: Set<String>] = [:]
    private var tokens: [String: DocumentHandle.ObservationToken] = [:]

    init(profiles: ProfileBlobs, queue: @escaping @MainActor (DocumentHandle) -> BlobQueue?) {
        self.profiles = profiles
        self.queue = queue
        profiles.install()
    }

    /// The loader the Color Settings sheet uses for `document`: through the blob cache and the
    /// document's queue, or -- without a queue -- registered in this process.
    func loader(for document: DocumentHandle?) -> @MainActor (URL) async throws -> WTColor.ProfileRef {
        let profiles = profiles
        let queue = document.flatMap(queue)
        return { url in
            guard let queue else {
                guard let ref = profiles.registry.register(iccData: try Data(contentsOf: url)) else { throw ProfileBlobs.Failure.notAProfile }
                return ref
            }
            return try await profiles.load(fileAt: url, queue: queue)
        }
    }

    /// The custom profiles `document`'s colour settings name that are neither here nor asked for.
    func missing(in document: DocumentHandle) -> [WTColor.ProfileRef] {
        let asked = requested[document.id] ?? []
        return ColorSettings(document.state, registry: profiles.registry, isAvailable: profiles.isAvailable).pendingProfiles.filter { !asked.contains($0.hexHash) }
    }

    /// Asks `document`'s queue for its missing profiles; nil when there is nothing to ask or no queue.
    @discardableResult
    func requestMissing(_ document: DocumentHandle) -> Task<Void, Never>? {
        let missing = missing(in: document)
        guard !missing.isEmpty, let queue = queue(document) else { return nil }
        requested[document.id, default: []].formUnion(missing.map(\.hexHash))
        let profiles = profiles, state = document.state
        return Task { _ = await profiles.requestMissing(in: state, queue: queue) }
    }

    /// A document opened: its missing profiles are asked for now and after every change.
    func watch(_ document: DocumentHandle) {
        requestMissing(document)
        guard tokens[document.id] == nil else { return }
        tokens[document.id] = document.observe { [weak self, weak document] _ in
            if let document { self?.requestMissing(document) }
        }
    }
}

extension AppDelegate {
    /// Launch: the app's profile blobs over the shared cache and each document's sync queue.
    func installProfileBlobs() {
        guard let directory = try? BlobCache.defaultDirectory() else { return }
        let documents = documents!
        ProfileBlobGlue.shared = ProfileBlobGlue(profiles: ProfileBlobs(cache: BlobCache(directory: directory))) {
            documents.windowControllers[$0.id]?.session?.client?.blobs
        }
    }
}
