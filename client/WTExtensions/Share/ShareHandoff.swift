import Foundation
import UniformTypeIdentifiers

/// The hand-off between the `WireTunerShare` extension and the app (IMG-026; importing.adoc, "From
/// another app's Share menu" and "Client").  The extension copies the shared items into the app
/// group container's `Inbox/<uuid>/` -- numbered so they place in the order they were shared -- and
/// opens `wiretuner-share://inbox/<uuid>?app=<name>[&option=1]`; the app's `ShareInbox` drains the
/// folder.  Compiled into the extension and into the app (which parses the URL and is where the
/// tests run), so the two agree on the scheme, the group and the layout.  Foundation only: the
/// extension links neither WTModel nor WTSync and opens no socket.
enum ShareHandoff {
    static let scheme = "wiretuner-share"
    /// The app group: the bundle's `WTAppGroup` (`$(TeamIdentifierPrefix)com.villagecompute.wiretuner`,
    /// the signing team's prefix before the name; none when signed ad hoc), which is exactly what
    /// the app's and the extension's entitlements hold.
    static let appGroup = groupIdentifier(Bundle.main.infoDictionary)

    static func groupIdentifier(_ info: [String: Any]?) -> String {
        (info?["WTAppGroup"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "com.villagecompute.wiretuner"
    }
    /// The most items one share takes (the activation rule's limit too).
    static let maximumItems = 20
    /// What the extension accepts: images (SVG among them) and PDFs, as data or as files.
    static let acceptedTypes: [UTType] = [.svg, .pdf, .image]

    /// The app group's `Inbox` folder; nil when the group container is not available (an
    /// unsigned build).
    static func inboxRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "Inbox")
    }

    /// The hand-off URL for inbox folder `id`, shared from `app`, with kbd:[Option] held or not.
    static func url(inbox id: UUID, app: String, option: Bool) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "inbox"
        components.path = "/" + id.uuidString
        components.queryItems = [URLQueryItem(name: "app", value: app)] + (option ? [URLQueryItem(name: "option", value: "1")] : [])
        return components.url!
    }

    /// A hand-off URL's inbox id, source app and whether kbd:[Option] was held; nil for any other
    /// URL.
    static func parse(_ url: URL) -> (id: String, app: String, option: Bool)? {
        guard url.scheme == scheme, url.host() == "inbox" else { return nil }
        let id = url.lastPathComponent
        guard UUID(uuidString: id) != nil else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = query.first { $0.name == "app" }?.value.flatMap { $0.isEmpty ? nil : $0 } ?? "another app"
        let option = query.first { $0.name == "option" }?.value == "1"
        return (id, app, option)
    }

    /// The accepted type among `identifiers` (an item's registered types), most specific first;
    /// nil when the item offers none.
    static func acceptedType(of identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        for accepted in acceptedTypes {
            if let type = types.first(where: { $0.conforms(to: accepted) }) { return type }
        }
        return nil
    }

    /// The accepted type of the file at `url`, from its extension; nil for any other file.
    static func acceptedType(ofFile url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension).flatMap { type in acceptedTypes.contains { type.conforms(to: $0) } ? type : nil }
    }

    /// The inbox file name of item `index`: its number (so the folder sorts in share order), then
    /// its own name made safe, with the type's extension.
    static func fileName(index: Int, suggested: String?, type: UTType) -> String {
        let fallback = "Shared Item"
        let base = (suggested.map { ($0 as NSString).deletingPathExtension } ?? fallback)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.hasPrefix(".") ? fallback : base
        let ext = type.preferredFilenameExtension ?? "data"
        return String(format: "%02d", index + 1) + " " + name + "." + ext
    }
}

/// Copies shared items into a fresh inbox folder.
struct ShareInboxWriter: Sendable {
    /// The `Inbox` folder.
    let root: URL

    enum WriteError: Error, Equatable {
        /// No item was an image, a PDF or a file of those.
        case nothingAccepted
    }

    /// One shared item: data a provider hands over, or a file already on disk (a Finder share).
    struct Item: Sendable {
        var suggestedName: String?
        /// Copies the item's bytes to `destination`; returns their type and, for a file, its name.
        var copy: @Sendable (_ destination: URL) async throws -> (type: UTType, name: String?)
    }

    /// The items of `providers` the extension accepts, in order, at most `ShareHandoff.maximumItems`.
    static func items(_ providers: [NSItemProvider]) -> [Item] {
        providers.compactMap { provider -> Item? in
            if let type = ShareHandoff.acceptedType(of: provider.registeredTypeIdentifiers) {
                let box = ProviderBox(provider)
                return Item(suggestedName: provider.suggestedName) { destination in
                    let name = try await box.copy(type, to: destination)
                    return (type, name)
                }
            }
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
            let box = ProviderBox(provider)
            return Item(suggestedName: provider.suggestedName) { destination in try await box.copyFile(to: destination) }
        }.prefix(ShareHandoff.maximumItems).map { $0 }
    }

    /// Writes `items` into `Inbox/<id>/` and returns the id.  Items that fail to copy are left out;
    /// when none is written the folder is removed and the write throws.
    func write(_ items: [Item], id: UUID = UUID()) async throws -> UUID {
        let folder = root.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = 0
        for (index, item) in items.prefix(ShareHandoff.maximumItems).enumerated() {
            let staging = folder.appending(path: ".item-\(index)")
            do {
                let (type, name) = try await item.copy(staging)
                try FileManager.default.moveItem(at: staging, to: folder.appending(path: ShareHandoff.fileName(index: index, suggested: item.suggestedName ?? name, type: type)))
                written += 1
            } catch {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw WriteError.nothingAccepted
        }
        return id
    }
}

/// An item provider handed across the copy's suspension point.  Providers are not `Sendable`;
/// each is only read, once, by the one copy made for it.
private final class ProviderBox: @unchecked Sendable {
    let provider: NSItemProvider

    init(_ provider: NSItemProvider) {
        self.provider = provider
    }

    /// The provider's file of `type`, copied to `destination` inside the loading callback (the
    /// file it hands over is removed when the callback returns).
    /// Returns the handed-over file's name.
    func copy(_ type: UTType, to destination: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                continuation.resume(with: Result {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    try FileManager.default.copyItem(at: url, to: destination)
                    return url.lastPathComponent
                })
            }
        }
    }

    /// A shared file URL of an accepted type, copied to `destination`: its type and name.
    func copyFile(to destination: URL) async throws -> (type: UTType, name: String?) {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                continuation.resume(with: Result {
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, let type = ShareHandoff.acceptedType(ofFile: url) else { throw error ?? CocoaError(.fileReadUnsupportedScheme) }
                    try FileManager.default.copyItem(at: url, to: destination)
                    return (type, url.lastPathComponent)
                })
            }
        }
    }
}
