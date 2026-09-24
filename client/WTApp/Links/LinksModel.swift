import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTSync

/// What the Links window shows for one document and what its actions do (linking-embedding.adoc,
/// "The Links window"; DOC-023): a row per imported file -- name (italic when broken on this Mac,
/// a cloud for a library link), kind, size, page and status -- read from the document on every
/// render, so a remote change updates the rows without losing the selection.  Selecting a row
/// selects the objects placing it and scrolls to them.  *Update*, *Update All*, *Change…*,
/// *Embed* and *Extract…* are one change each (the blob stored first, as import does; the file
/// written by *Extract…* is not undoable).
@MainActor
@Observable
final class LinksModel {
    /// One imported file.
    struct Row: Identifiable, Equatable {
        var id: OpID
        var name: String
        var kind: String
        var size: String
        var page: String
        var status: String
        var isBroken: Bool
        var isLibrary: Bool
        var canUpdate: Bool
    }

    let document: DocumentHandle
    /// This Mac's `wt-device` id.
    let device: String
    var selection: OpID?
    /// The row whose *Info* is shown.
    var info: OpID?
    /// What the last action said ("Couldn't read …").
    private(set) var message: String?

    @ObservationIgnored var fileSystem: any LinkFileSystem = LocalLinkFileSystem()
    @ObservationIgnored var perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>
    /// Stores a blob before the change that references it (the import path's `BlobPlacement`).
    @ObservationIgnored var storeBlob: @MainActor (ImportedBlob) async throws -> Void = { _ in }
    /// The stored copy of a blob on this Mac, nil when it has not arrived.
    @ObservationIgnored var cachedBlob: @MainActor (Data) -> Data? = { _ in nil }
    /// *Change…*: the file to relink to.
    @ObservationIgnored var chooseFile: @MainActor () async -> URL? = { nil }
    /// *Extract…*: where to write the copy, suggested by name.
    @ObservationIgnored var chooseDestination: @MainActor (String) async -> URL? = { _ in nil }
    /// *Extract…* over an existing file: replace it (true) or not.
    @ObservationIgnored var confirmReplace: @MainActor (URL) -> Bool = { _ in false }
    /// Selects the objects placing an asset in the window and scrolls to them.
    @ObservationIgnored var selectObjects: @MainActor ([OpID]) -> Void = { _ in }
    /// The person whose Mac a device id is ("Priya"), for *Unavailable* links of another Mac.
    @ObservationIgnored var deviceOwner: @MainActor (String) -> String? = { _ in nil }

    init(document: DocumentHandle, device: String, perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>) {
        self.document = document
        self.device = device
        self.perform = perform
    }

    // MARK: Rows

    var links: [AssetLink] { AssetLink.all(in: document.state) }

    var rows: [Row] {
        let pages = document.pageList
        let state = document.state
        return links.map { link in
            let status = LinkStatus.of(link, device: device, fileSystem: fileSystem)
            let placed = Self.objects(placing: link.id, in: state)
            let corner = placed.compactMap { Objects.bounds(of: $0, in: state) }.first.map { Point(x: $0.minX, y: $0.minY) }
            let page = corner.flatMap(pages.page(containing:)).map { "\($0.number)" } ?? "Pasteboard"
            return Row(id: link.id, name: link.fileName, kind: Self.kind(of: link.mediaType), size: Self.size(link.byteSize), page: page,
                       status: statusText(status), isBroken: status.isBroken, isLibrary: link.kind == .library,
                       canUpdate: status == .modified || status == .linked)
        }
    }

    /// The status column: *Embedded*, *Linked*, *Linked (modified)*, *Unavailable* ("on Priya's
    /// Mac" for another Mac's link), *Library*.
    func statusText(_ status: LinkStatus) -> String {
        switch status {
        case .embedded: return "Embedded"
        case .linked: return "Linked"
        case .modified: return "Linked (modified)"
        case .library: return "Library"
        case .unavailable(let device):
            guard let device else { return "Unavailable" }
            return deviceOwner(device).map { "Unavailable (on \($0)’s Mac)" } ?? "Unavailable (another Mac)"
        }
    }

    /// "TIFF", "PNG", "PDF", "SVG animation" ... from a media type.
    static func kind(of mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "image/svg+xml": return "SVG animation"
        case "application/postscript": return "EPS"
        case "": return "File"
        default:
            let type = UTType(mimeType: mediaType)
            return type?.preferredFilenameExtension?.uppercased() ?? mediaType
        }
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The live objects placing the asset (images and placed files naming it as `source`).
    static func objects(placing asset: OpID, in state: EngineState) -> [OpID] {
        state.store.nodes.filter { node in
            guard state.store.isCreated(node), state.isLive(node) else { return false }
            switch state.props(node).kind {
            case .image(let image)?: return image.hasSource && OpID(image.source.id) == asset
            case .placedFile(let file)?: return file.hasSource && OpID(file.source.id) == asset
            default: return false
            }
        }
    }

    // MARK: Selection and info

    /// A row selected: its objects are selected in the window.
    func select(_ id: OpID?) {
        selection = id
        guard let id else { return }
        selectObjects(Self.objects(placing: id, in: document.state))
    }

    /// *Info*: name, source, modified date, kind and size of the selected row.
    func infoLines(_ id: OpID) -> [(String, String)] {
        guard let link = AssetLink.read(id, in: document.state) else { return [] }
        var lines = [("Name", link.fileName), ("Kind", Self.kind(of: link.mediaType)), ("Size", Self.size(link.byteSize))]
        switch link.kind {
        case .localFile: lines.append(("Source", link.path))
        case .library: lines.append(("Library document", link.libraryDocument))
        case .embedded: lines.append(("Source", "Embedded"))
        }
        if let modified = link.sourceModified { lines.append(("Modified", modified.formatted(date: .abbreviated, time: .shortened))) }
        return lines
    }

    // MARK: Buttons (on the selected row)

    /// The action running for a button, awaited by tests.
    @ObservationIgnored private(set) var running: Task<Void, Never>?

    func showInfo() { info = selection }

    func changeSelected() { run { await $0.change($1) } }

    func updateSelected() { run { await $0.update($1) } }

    func extractSelected() { run { await $0.extract($1) } }

    func embedSelected() {
        if let id = selection { embed(id) }
    }

    func updateAllLinks() {
        running = Task { _ = await updateAll() }
    }

    private func run(_ action: @escaping @MainActor (LinksModel, OpID) async -> Wiretuner_Doc_V1_Change?) {
        guard let id = selection else { return }
        running = Task { _ = await action(self, id) }
    }

    // MARK: Actions

    /// Reads a file as the stored copy: its bytes, type from the extension, and modification date.
    static func blob(at url: URL) throws -> (blob: ImportedBlob, modified: Date) {
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (ImportedBlob(data: data, uti: type), modified ?? Date())
    }

    /// *Update*: re-reads the selected linked file ("Update link").
    @discardableResult
    func update(_ id: OpID) async -> Wiretuner_Doc_V1_Change? {
        guard let link = AssetLink.read(id, in: document.state), link.kind == .localFile else { return nil }
        do {
            let (blob, modified) = try Self.blob(at: URL(fileURLWithPath: link.path))
            try await storeBlob(blob)
            message = nil
            return await perform(UpdateLink(id, blob: blob, modified: modified)).value
        } catch {
            message = "“\(link.fileName)” could not be read: \(error.localizedDescription)"
            return nil
        }
    }

    /// *Update All*: every modified link, one change ("Update all links").
    @discardableResult
    func updateAll() async -> Wiretuner_Doc_V1_Change? {
        var updates: [UpdateLink] = []
        for link in links where LinkStatus.of(link, device: device, fileSystem: fileSystem) == .modified {
            guard let (blob, modified) = try? Self.blob(at: URL(fileURLWithPath: link.path)) else { continue }
            try? await storeBlob(blob)
            updates.append(UpdateLink(link.id, blob: blob, modified: modified))
        }
        guard !updates.isEmpty else { return nil }
        return await perform(UpdateAllLinks(updates)).value
    }

    /// *Change…*: relinks to a chosen file ("Relink").
    @discardableResult
    func change(_ id: OpID) async -> Wiretuner_Doc_V1_Change? {
        guard let url = await chooseFile() else { return nil }
        do {
            let (blob, modified) = try Self.blob(at: url)
            try await storeBlob(blob)
            message = nil
            return await perform(RelinkAsset(id, to: LinkTarget(path: url.path, device: device, modified: modified), blob: blob)).value
        } catch {
            message = "“\(url.lastPathComponent)” could not be read: \(error.localizedDescription)"
            return nil
        }
    }

    /// *Embed* ("Embed").
    @discardableResult
    func embed(_ id: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        perform(EmbedAsset([id]))
    }

    /// *Extract…*: writes the stored copy to a chosen file and relinks to it ("Extract").
    @discardableResult
    func extract(_ id: OpID) async -> Wiretuner_Doc_V1_Change? {
        guard let link = AssetLink.read(id, in: document.state) else { return nil }
        guard let data = cachedBlob(link.sha256) else {
            message = "“\(link.fileName)” has not arrived on this Mac yet"
            return nil
        }
        guard let url = await chooseDestination(link.fileName) else { return nil }
        let replace = FileManager.default.fileExists(atPath: url.path) ? confirmReplace(url) : false
        do {
            let modified = try LinkFiles.extract(data, to: url, replace: replace)
            message = nil
            return await perform(ExtractAsset(id, to: LinkTarget(path: url.path, device: device, modified: modified))).value
        } catch {
            message = "“\(url.lastPathComponent)” could not be written: \(error.localizedDescription)"
            return nil
        }
    }
}

/// The missing-link search when a document opens (linking-embedding.adoc, "Broken links when
/// opening"): with *Search for missing links* on, this Mac's broken links are looked for beside
/// their old path and under the *Missing links folder*; the ones found are relinked in one change
/// ("Relink missing files") that also writes each one's bookmark to the asset's local-only
/// `bookmark`, which never leaves this Mac.
@MainActor
enum MissingLinks {
    /// Searches for `document`'s broken links and repairs them; returns what was found.
    @discardableResult
    static func repair(_ document: DocumentHandle, device: String, searchFolder: String?, fileSystem: any LinkFileSystem = LocalLinkFileSystem(),
                       bookmark: @escaping @Sendable (String) -> Data? = LinkSearch.securityScopedBookmark,
                       perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>) async -> [FoundLink] {
        let links = AssetLink.all(in: document.state)
        let found = await Task.detached {
            await LinkSearch.autoRelink(links, device: device, searchFolder: searchFolder, fileSystem: fileSystem, bookmark: bookmark)
        }.value
        guard !found.isEmpty else { return [] }
        _ = await perform(RepairLinks(found)).value
        return found
    }

    /// The bookmark this Mac keeps for `asset` of `document`.
    static func bookmark(_ asset: OpID, of document: DocumentHandle) async -> Data? {
        AssetLink.read(asset, in: document.state)?.bookmark
    }
}
