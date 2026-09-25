import Foundation
import WTCRDT
import WTInterchange
import WTProto

// DOC-022: linked and embedded files (linking-embedding.adoc, "Command effects", "Merge
// semantics" and "Client").  An imported file is an `asset` node under `assets` (0:9) holding
// its blob's hash and its link record; the commands rewrite those registers, one change each.
// A command that brings new content carries the blob: the caller stores it in the blob queue
// (SYNC-008) before performing, as an import does, so the change is sent first and the blob
// follows.

/// Register paths of `AssetProps` (`NodeProps.asset` = 5).
public enum AssetFields {
    public static let kind: UInt32 = 5
    public static let name = RegisterPath([5, 1, 1])
    public static let sha256 = RegisterPath([5, 2])
    public static let byteSize = RegisterPath([5, 3])
    public static let mediaType = RegisterPath([5, 4])
    /// ATOMIC: kind, path, device and modification time describe one source.
    public static let link = RegisterPath([5, 5])
    /// The security-scoped bookmark of a local file on this Mac: `local_only`, never on the wire
    /// (crdt-model.adoc, "Local-only fields").
    public static let bookmark = RegisterPath([5, 6])

    public static func values(_ build: (inout Wiretuner_Doc_V1_AssetProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.asset)
        return props
    }
}

/// An asset's link record as read.
public struct AssetLink: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case embedded, localFile, library
    }

    public var id: OpID
    /// The display name (`CommonProps.name`).
    public var name: String
    public var sha256: Data
    public var byteSize: UInt64
    public var mediaType: String
    public var kind: Kind
    /// The source's name as the Links window shows it.
    public var displayName: String
    /// POSIX path on `device`, for a local file.
    public var path: String
    /// The wt-device id of the Mac that owns `path`.
    public var device: String
    public var libraryDocument: String
    /// The source's modification time when the blob was last read from it.
    public var sourceModified: Date?
    /// This Mac's security-scoped bookmark of the file (`bookmark`, local-only); nil when none.
    public var bookmark: Data?

    public init(id: OpID, props: Wiretuner_Doc_V1_AssetProps) {
        self.id = id
        name = props.common.name
        sha256 = props.sha256
        byteSize = props.byteSize
        mediaType = props.mediaType
        switch props.link.kind {
        case .localFile: kind = .localFile
        case .library: kind = .library
        default: kind = .embedded
        }
        displayName = props.link.displayName
        path = props.link.path
        device = props.link.device
        libraryDocument = props.link.libraryDocument
        sourceModified = props.link.sourceModifiedMs == 0 ? nil : Date(timeIntervalSince1970: Double(props.link.sourceModifiedMs) / 1000)
        bookmark = props.bookmark.isEmpty ? nil : props.bookmark
    }

    /// The file name the link searches for.
    public var fileName: String {
        displayName.isEmpty ? (path as NSString).lastPathComponent : displayName
    }

    /// Every asset of `state`, in the assets collection's order.
    public static func all(in state: EngineState) -> [AssetLink] {
        state.liveChildren(WellKnown.assets).filter { state.store.kind($0) == AssetFields.kind }.map { AssetLink(id: $0, props: state.props($0).asset) }
    }

    /// The asset `id` names, if live.
    public static func read(_ id: OpID, in state: EngineState) -> AssetLink? {
        guard state.isLive(id), state.store.kind(id) == AssetFields.kind else { return nil }
        return AssetLink(id: id, props: state.props(id).asset)
    }
}

/// How a file system answers the link questions (injectable for tests).
public protocol LinkFileSystem: Sendable {
    /// The modification date of the regular file at `path`; nil when there is none.
    func modificationDate(atPath path: String) -> Date?
    /// The names of the entries of the directory at `path` and whether each is a directory; nil
    /// when it cannot be read.
    func entries(atPath path: String) -> [(name: String, isDirectory: Bool)]?
}

/// The real file system.
public struct LocalLinkFileSystem: LinkFileSystem {
    public init() {}

    public func modificationDate(atPath path: String) -> Date? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public func entries(atPath path: String) -> [(name: String, isDirectory: Bool)]? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: [.skipsHiddenFiles]) else { return nil }
        return contents.map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
    }
}

/// A link's status on this Mac (the Links window's *Status* column and italics; computed per
/// device, never stored).
public enum LinkStatus: Hashable, Sendable {
    case embedded
    /// Linked and up to date.
    case linked
    /// *Linked (modified)*: the source is newer than the copy.
    case modified
    /// *Unavailable*: the source is not where the link says on this Mac -- missing here, or a
    /// path on another Mac (`device` names it, for "Priya's Mac").
    case unavailable(device: String?)
    /// A library document (cloud icon).
    case library

    /// Whether the row shows in italics (broken on this Mac).
    public var isBroken: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// The status of `link` on the Mac `device`.
    public static func of(_ link: AssetLink, device: String, fileSystem: any LinkFileSystem = LocalLinkFileSystem()) -> LinkStatus {
        switch link.kind {
        case .embedded: return .embedded
        case .library: return .library
        case .localFile:
            guard link.device.isEmpty || link.device == device else { return .unavailable(device: link.device) }
            guard !link.path.isEmpty, let modified = fileSystem.modificationDate(atPath: link.path) else { return .unavailable(device: nil) }
            // Millisecond precision, as stored.
            let stored = link.sourceModified.map { ($0.timeIntervalSince1970 * 1000).rounded(.down) } ?? 0
            return (modified.timeIntervalSince1970 * 1000).rounded(.down) > stored ? .modified : .linked
        }
    }
}

/// Where a relink or extract points: a file on this Mac.
public struct LinkTarget: Hashable, Sendable {
    public var path: String
    public var device: String
    public var modified: Date?

    public init(path: String, device: String, modified: Date? = nil) {
        self.path = path
        self.device = device
        self.modified = modified
    }

    func source(displayName: String? = nil) -> Wiretuner_Doc_V1_LinkSource {
        var link = Wiretuner_Doc_V1_LinkSource()
        link.kind = .localFile
        link.displayName = String((displayName ?? (path as NSString).lastPathComponent).prefix(256))
        link.path = String(path.prefix(4096))
        link.device = String(device.prefix(64))
        if let modified { link.sourceModifiedMs = Int64((modified.timeIntervalSince1970 * 1000).rounded(.down)) }
        return link
    }
}

/// Why a link command could not build its change.
public enum LinkEditError: Error, Equatable, Sendable {
    case notAnAsset(OpID)
    /// Update needs a linked source.
    case notLinked(OpID)
}

enum LinkEditing {
    static func asset(_ id: OpID, in state: EngineState) throws -> AssetLink {
        guard let asset = AssetLink.read(id, in: state) else { throw LinkEditError.notAnAsset(id) }
        return asset
    }

    /// The `SetFields` of new content and `link` in one op: hash, size and media type from
    /// `blob` always together, so concurrent updates keep a consistent triple.
    static func content(_ id: OpID, blob: ImportedBlob, link: Wiretuner_Doc_V1_LinkSource) -> Wiretuner_Doc_V1_Op {
        Ops.set(id, [AssetFields.sha256, AssetFields.byteSize, AssetFields.mediaType, AssetFields.link], values: AssetFields.values {
            $0.sha256 = blob.sha256
            $0.byteSize = UInt64(blob.data.count)
            $0.mediaType = String(blob.mediaType.prefix(128))
            $0.link = link
        })
    }

    static func link(_ id: OpID, _ link: Wiretuner_Doc_V1_LinkSource) -> Wiretuner_Doc_V1_Op {
        Ops.set(id, [AssetFields.link], values: AssetFields.values { $0.link = link })
    }
}

/// *Update*: the source re-read -- new hash, size and media type, and the link with the source's
/// new modification time -- one change "Update link".  The old blob stays referenced by history.
public struct UpdateLink: Command {
    public var asset: OpID
    /// The re-read content; the caller queues it before performing.
    public var blob: ImportedBlob
    public var modified: Date
    public var label: String { "Update link" }

    public init(_ asset: OpID, blob: ImportedBlob, modified: Date) {
        self.asset = asset
        self.blob = blob
        self.modified = modified
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try LinkEditing.asset(asset, in: state)
        guard current.kind == .localFile else { throw LinkEditError.notLinked(asset) }
        var link = state.props(asset).asset.link
        link.sourceModifiedMs = Int64((modified.timeIntervalSince1970 * 1000).rounded(.down))
        builder.append(LinkEditing.content(asset, blob: blob, link: link))
    }
}

/// *Update All*: every modified link updated in one change, "Update all links".
public struct UpdateAllLinks: Command {
    public var updates: [UpdateLink]
    public var label: String { "Update all links" }

    public init(_ updates: [UpdateLink]) {
        self.updates = updates
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for update in updates {
            try update.execute(&builder, state: state)
        }
    }
}

/// *Change…* (relink): the asset's content replaced from another file and its link pointed at
/// it, one change "Relink".
public struct RelinkAsset: Command {
    public var asset: OpID
    public var target: LinkTarget
    public var blob: ImportedBlob
    public var label: String { "Relink" }

    public init(_ asset: OpID, to target: LinkTarget, blob: ImportedBlob) {
        self.asset = asset
        self.target = target
        self.blob = blob
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try LinkEditing.asset(asset, in: state)
        builder.append(LinkEditing.content(asset, blob: blob, link: target.source()))
    }
}

/// *Embed*: the link broken, the copy kept -- `link` = EMBEDDED (the display name kept), one
/// change "Embed".
public struct EmbedAsset: Command {
    public var assets: [OpID]
    public var label: String { "Embed" }

    public init(_ assets: [OpID]) {
        self.assets = assets
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for asset in assets {
            let current = try LinkEditing.asset(asset, in: state)
            guard current.kind != .embedded else { continue }
            var link = Wiretuner_Doc_V1_LinkSource()
            link.kind = .embedded
            link.displayName = String(current.displayName.prefix(256))
            builder.append(LinkEditing.link(asset, link))
        }
    }
}

/// *Extract…*: after the caller has written the stored copy to `target` (`LinkFiles.extract`;
/// the file write is not undoable), the asset relinked to it, one change "Extract".
public struct ExtractAsset: Command {
    public var asset: OpID
    public var target: LinkTarget
    public var label: String { "Extract" }

    public init(_ asset: OpID, to target: LinkTarget) {
        self.asset = asset
        self.target = target
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try LinkEditing.asset(asset, in: state)
        builder.append(LinkEditing.link(asset, target.source()))
    }
}

/// One link the missing-link search repaired: where the file is now and its security-scoped
/// bookmark, which `RepairLinks` writes to the asset's `local_only` `bookmark` -- meaningful only on
/// this Mac, so it never leaves it.
public struct FoundLink: Hashable, Sendable {
    public var asset: OpID
    public var path: String
    public var bookmark: Data?

    public init(asset: OpID, path: String, bookmark: Data? = nil) {
        self.asset = asset
        self.path = path
        self.bookmark = bookmark
    }
}

/// Writes the repaired paths of this Mac's links (the link register with only `path` changed)
/// and, beside each, its bookmark (local-only: the outbox never carries it), one change "Relink
/// missing files".
public struct RepairLinks: Command {
    public var found: [FoundLink]
    public var label: String { "Relink missing files" }

    public init(_ found: [FoundLink]) {
        self.found = found
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for item in found {
            _ = try LinkEditing.asset(item.asset, in: state)
            var link = state.props(item.asset).asset.link
            guard link.kind == .localFile, link.path != item.path else { continue }
            link.path = String(item.path.prefix(4096))
            guard let bookmark = item.bookmark else {
                builder.append(LinkEditing.link(item.asset, link))
                continue
            }
            builder.append(Ops.set(item.asset, [AssetFields.link, AssetFields.bookmark], values: AssetFields.values {
                $0.link = link
                $0.bookmark = bookmark
            }))
        }
    }
}

/// The missing-link search on open (linking-embedding.adoc, "Broken links when opening"): for
/// each of this Mac's broken links, the file is looked for in the folder it was in, then in the
/// *Search for missing links in* folder and up to ten levels of its subfolders (at most 20,000
/// entries visited).  Runs off the main actor; another Mac's links are never repaired.
public enum LinkSearch {
    public static let maximumDepth = 10
    public static let maximumEntries = 20_000

    /// The repairs for `links` on the Mac `device`.  `bookmark` makes a file's bookmark (nil
    /// when it cannot).
    public static func autoRelink(_ links: [AssetLink], device: String, searchFolder: String?,
                                  fileSystem: any LinkFileSystem = LocalLinkFileSystem(),
                                  bookmark: @Sendable (String) -> Data? = LinkSearch.securityScopedBookmark) async -> [FoundLink] {
        var broken = links.filter { LinkStatus.of($0, device: device, fileSystem: fileSystem) == .unavailable(device: nil) }
        guard !broken.isEmpty else { return [] }
        var result: [FoundLink] = []
        // The folder the file was in.
        broken.removeAll { link in
            let folder = (link.path as NSString).deletingLastPathComponent
            let candidate = (folder as NSString).appendingPathComponent(link.fileName)
            guard !folder.isEmpty, candidate != link.path, fileSystem.modificationDate(atPath: candidate) != nil else { return false }
            result.append(FoundLink(asset: link.id, path: candidate, bookmark: bookmark(candidate)))
            return true
        }
        guard !broken.isEmpty, let searchFolder, !searchFolder.isEmpty else { return result }
        var wanted = Dictionary(grouping: broken, by: { $0.fileName })
        // Breadth first, so the shallowest match wins.
        var queue: [(path: String, depth: Int)] = [(searchFolder, 0)]
        var visited = 0
        while !queue.isEmpty, !wanted.isEmpty, visited < maximumEntries {
            if Task.isCancelled { break }
            let (folder, depth) = queue.removeFirst()
            guard let entries = fileSystem.entries(atPath: folder) else { continue }
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                visited += 1
                if visited > maximumEntries { break }
                let path = (folder as NSString).appendingPathComponent(entry.name)
                if entry.isDirectory {
                    if depth < maximumDepth { queue.append((path, depth + 1)) }
                } else if let links = wanted.removeValue(forKey: entry.name) {
                    result += links.map { FoundLink(asset: $0.id, path: path, bookmark: bookmark(path)) }
                }
            }
        }
        return result
    }

    /// A security-scoped bookmark of the file at `path`, falling back to a plain one.
    @Sendable public static func securityScopedBookmark(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        #if os(macOS)
        return (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        #else
        // iOS has no `.withSecurityScope`: a bookmark carries the URL's scope implicitly.
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
}

/// The review rule for a lost link write (linking-embedding.adoc, "Merge semantics"): `link` is
/// ATOMIC later-wins, so embed vs. relink or relink vs. relink ends with the later action; the
/// loser is a same-register loss of visible work, listed in the review sheet with *Reapply mine*.
public enum LinkReview {
    /// What the losing and winning writes did.
    public enum Action: Hashable, Sendable {
        case embed, relink(path: String), update
    }

    /// Whether a lost write of `link` is listed (every loss of a link write is visible work).
    public static func isListed(losing: Wiretuner_Doc_V1_LinkSource, winning: Wiretuner_Doc_V1_LinkSource) -> Bool {
        losing != winning
    }

    /// The action a stored link value records, relative to the value before it.
    public static func action(_ link: Wiretuner_Doc_V1_LinkSource, before: Wiretuner_Doc_V1_LinkSource?) -> Action {
        switch link.kind {
        case .localFile:
            if let before, before.kind == .localFile, before.path == link.path, before.device == link.device { return .update }
            return .relink(path: link.path)
        default:
            return .embed
        }
    }
}

/// Writing a stored copy out for *Extract…*.
public enum LinkFiles {
    /// Writes `data` to `url` (replacing a file there when `replace`); returns the file's
    /// modification date for the relink.
    public static func extract(_ data: Data, to url: URL, replace: Bool) throws -> Date? {
        if !replace, FileManager.default.fileExists(atPath: url.path) { throw CocoaError(.fileWriteFileExists) }
        try data.write(to: url, options: .atomic)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
