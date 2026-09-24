import Foundation
import Synchronization
import Testing
import WTCRDT
import WTInterchange
@testable import WTModel
import WTProto

/// An in-memory file system for the link tests: files with modification dates, directories by
/// path prefix.
final class MemoryFileSystem: LinkFileSystem, Sendable {
    private let files: Mutex<[String: Date]>

    init(_ files: [String: Date]) {
        self.files = Mutex(files)
    }

    func modificationDate(atPath path: String) -> Date? {
        files.withLock { $0[path] }
    }

    func entries(atPath path: String) -> [(name: String, isDirectory: Bool)]? {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let all = files.withLock { Array($0.keys) }
        var result: [String: Bool] = [:]
        for file in all where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count)
            let parts = rest.split(separator: "/", maxSplits: 1)
            result[String(parts[0])] = (result[String(parts[0])] ?? false) || parts.count > 1
        }
        return result.isEmpty ? nil : result.map { ($0.key, $0.value) }
    }
}

/// DOC-022: link commands, per-device status, the missing-link search and the merge cases
/// (linking-embedding.adoc).
@Suite struct LinkCommandTests {
    static let device = "mac-a"
    static let modified = Date(timeIntervalSince1970: 1_700_000_000)

    static func blob(_ text: String) -> ImportedBlob {
        ImportedBlob(data: Data(text.utf8), uti: "public.png")
    }

    /// An asset linked to `path` on `device`, holding `blob("v1")`.
    @discardableResult
    static func asset(_ replica: inout Replica, path: String = "/Users/a/art/photo.png", device: String = device,
                      kind: Wiretuner_Doc_V1_LinkKind = .localFile) throws -> OpID {
        let blob = Self.blob("v1")
        let props = AssetFields.values {
            $0.common.name = "photo.png"
            $0.sha256 = blob.sha256
            $0.byteSize = UInt64(blob.data.count)
            $0.mediaType = blob.mediaType
            $0.link.kind = kind
            $0.link.displayName = (path as NSString).lastPathComponent
            $0.link.path = path
            $0.link.device = device
            $0.link.sourceModifiedMs = Int64(modified.timeIntervalSince1970 * 1000)
        }
        let key = try PathEditing.keys(between: nil, and: nil, count: 1)
        return try replica.perform(OpsCommand("Import", ops: [Ops.create(parent: WellKnown.assets, position: key[0], props: props)]))!.createdNodes[0]
    }

    @Test func readsTheLinkRecord() throws {
        var a = Replica(0xA)
        let id = try Self.asset(&a)
        let link = try #require(AssetLink.read(id, in: a.state))
        #expect(link.kind == .localFile && link.path == "/Users/a/art/photo.png" && link.device == Self.device)
        #expect(link.fileName == "photo.png" && link.sourceModified == Self.modified && link.byteSize == 2 && link.mediaType == "image/png")
        #expect(AssetLink.all(in: a.state).map(\.id) == [id])
        #expect(AssetLink.read(OpID(counter: 99, replica: 9), in: a.state) == nil)
        var bare = Wiretuner_Doc_V1_AssetProps()
        bare.link.path = "/x/y.tif"
        let unnamed = AssetLink(id: id, props: bare)
        #expect(unnamed.kind == .embedded && unnamed.fileName == "y.tif" && unnamed.sourceModified == nil)
        bare.link.kind = .library
        #expect(AssetLink(id: id, props: bare).kind == .library)
    }

    @Test func statusPerDevice() throws {
        var a = Replica(0xA)
        let linked = try #require(AssetLink.read(try Self.asset(&a), in: a.state))
        let other = try #require(AssetLink.read(try Self.asset(&a, device: "mac-b"), in: a.state))
        let embedded = try #require(AssetLink.read(try Self.asset(&a, kind: .embedded), in: a.state))
        let library = try #require(AssetLink.read(try Self.asset(&a, kind: .library), in: a.state))
        let same = MemoryFileSystem(["/Users/a/art/photo.png": Self.modified])
        let newer = MemoryFileSystem(["/Users/a/art/photo.png": Self.modified.addingTimeInterval(60)])
        let missing = MemoryFileSystem([:])
        #expect(LinkStatus.of(linked, device: Self.device, fileSystem: same) == .linked)
        #expect(LinkStatus.of(linked, device: Self.device, fileSystem: newer) == .modified)
        #expect(LinkStatus.of(linked, device: Self.device, fileSystem: missing) == .unavailable(device: nil))
        #expect(LinkStatus.of(other, device: Self.device, fileSystem: same) == .unavailable(device: "mac-b"))
        #expect(LinkStatus.of(embedded, device: Self.device, fileSystem: same) == .embedded)
        #expect(LinkStatus.of(library, device: Self.device, fileSystem: same) == .library)
        #expect(LinkStatus.unavailable(device: nil).isBroken && !LinkStatus.linked.isBroken)
    }

    @Test func commandsAreOneChangeEach() throws {
        var a = Replica(0xA)
        let id = try Self.asset(&a)
        let v2 = Self.blob("v2")
        let later = Self.modified.addingTimeInterval(120)
        let update = try #require(try a.perform(UpdateLink(id, blob: v2, modified: later)))
        #expect(update.label == "Update link" && update.ops.count == 1)
        var link = try #require(AssetLink.read(id, in: a.state))
        #expect(link.sha256 == v2.sha256 && link.sourceModified == later && link.path == "/Users/a/art/photo.png")
        let v3 = ImportedBlob(data: Data("v3!".utf8), uti: "public.jpeg")
        let relink = try #require(try a.perform(RelinkAsset(id, to: LinkTarget(path: "/Users/a/new/other.jpg", device: Self.device, modified: later), blob: v3)))
        #expect(relink.label == "Relink" && relink.ops.count == 1)
        link = try #require(AssetLink.read(id, in: a.state))
        #expect(link.sha256 == v3.sha256 && link.byteSize == 3 && link.mediaType == "image/jpeg" && link.displayName == "other.jpg")
        let embed = try #require(try a.perform(EmbedAsset([id])))
        #expect(embed.label == "Embed")
        link = try #require(AssetLink.read(id, in: a.state))
        #expect(link.kind == .embedded && link.displayName == "other.jpg" && link.path.isEmpty)
        #expect(try a.perform(EmbedAsset([id])) == nil)
        #expect(throws: LinkEditError.notLinked(id)) { try a.perform(UpdateLink(id, blob: v2, modified: later)) }
        let extract = try #require(try a.perform(ExtractAsset(id, to: LinkTarget(path: "/Users/a/out/other.jpg", device: Self.device))))
        #expect(extract.label == "Extract" && AssetLink.read(id, in: a.state)?.kind == .localFile)
        a.undo()
        #expect(AssetLink.read(id, in: a.state)?.kind == .embedded)
        #expect(throws: LinkEditError.notAnAsset(.zero)) { try a.perform(EmbedAsset([.zero])) }
        #expect(throws: LinkEditError.notAnAsset(.zero)) { try a.perform(RelinkAsset(.zero, to: LinkTarget(path: "/x", device: ""), blob: v2)) }
        #expect(throws: LinkEditError.notAnAsset(.zero)) { try a.perform(ExtractAsset(.zero, to: LinkTarget(path: "/x", device: ""))) }
    }

    @Test func updateAllIsOneChange() throws {
        var a = Replica(0xA)
        let first = try Self.asset(&a)
        let second = try Self.asset(&a, path: "/Users/a/art/logo.png")
        let change = try #require(try a.perform(UpdateAllLinks([
            UpdateLink(first, blob: Self.blob("f2"), modified: Self.modified.addingTimeInterval(1)),
            UpdateLink(second, blob: Self.blob("s2"), modified: Self.modified.addingTimeInterval(2)),
        ])))
        #expect(change.label == "Update all links" && change.ops.count == 2)
    }

    @Test func autoRelinkFindsAMovedFileTenLevelsDeepAndWritesOnlyThisMacsLinks() async throws {
        var a = Replica(0xA)
        let mine = try Self.asset(&a)
        let theirs = try Self.asset(&a, path: "/Users/b/photo.png", device: "mac-b")
        let beside = try Self.asset(&a, path: "/Users/a/old/logo.png")
        let deep = "/Volumes/Work/" + (1...10).map { "d\($0)" }.joined(separator: "/") + "/photo.png"
        let tooDeep = "/Volumes/Work/" + (1...11).map { "e\($0)" }.joined(separator: "/") + "/logo2.png"
        let fileSystem = MemoryFileSystem([deep: Self.modified, tooDeep: Self.modified, "/Users/a/old/logo.png.bak": Self.modified,
                                           "/Users/a/old/sub/logo.png": Self.modified])
        _ = beside
        let links = AssetLink.all(in: a.state)
        let found = await LinkSearch.autoRelink(links, device: Self.device, searchFolder: "/Volumes/Work", fileSystem: fileSystem,
                                                bookmark: { Data($0.utf8) })
        #expect(found.map(\.asset) == [mine])
        #expect(found.first?.path == deep && found.first?.bookmark == Data(deep.utf8))
        let change = try #require(try a.perform(RepairLinks(found)))
        #expect(change.label == "Relink missing files" && change.ops.count == 1)
        let repaired = try #require(AssetLink.read(mine, in: a.state))
        #expect(repaired.path == deep && repaired.sourceModified == Self.modified && repaired.sha256 == Self.blob("v1").sha256)
        #expect(AssetLink.read(theirs, in: a.state)?.path == "/Users/b/photo.png")
        // The bookmark is the asset's local-only register: read here, never in what is sent.
        #expect(repaired.bookmark == Data(deep.utf8))
        #expect(change.ops.contains { $0.set.paths.contains { RegisterPath($0) == AssetFields.bookmark } })
        #expect(!a.sent.last!.ops.contains { $0.set.paths.contains { RegisterPath($0) == AssetFields.bookmark } })
        #expect(a.sent.last!.ops.allSatisfy { $0.set.values.asset.bookmark.isEmpty })
        #expect(try a.perform(RepairLinks(found)) == nil)
    }

    @Test func autoRelinkLooksBesideTheOldPathFirstAndStopsAtTheBounds() async throws {
        var a = Replica(0xA)
        let moved = try Self.asset(&a, path: "/Users/a/art/old-name.png")
        var raw = try #require(AssetLink.read(moved, in: a.state))
        raw.displayName = "photo.png"
        let beside = MemoryFileSystem(["/Users/a/art/photo.png": Self.modified])
        let links = [raw]
        let found = await LinkSearch.autoRelink(links, device: Self.device, searchFolder: nil, fileSystem: beside, bookmark: { _ in nil })
        #expect(found == [FoundLink(asset: moved, path: "/Users/a/art/photo.png")])
        // Nothing broken: nothing searched.
        let fine = MemoryFileSystem(["/Users/a/art/old-name.png": Self.modified])
        #expect(await LinkSearch.autoRelink(AssetLink.all(in: a.state), device: Self.device, searchFolder: "/", fileSystem: fine).isEmpty)
        // Missing everywhere, no search folder: nothing.
        #expect(await LinkSearch.autoRelink(AssetLink.all(in: a.state), device: Self.device, searchFolder: nil, fileSystem: MemoryFileSystem([:])).isEmpty)
        // The entry bound stops a huge tree.
        var files: [String: Date] = [:]
        for index in 0..<(LinkSearch.maximumEntries + 10) { files["/big/f\(index).txt"] = Self.modified }
        files["/big/zzz/old-name.png"] = Self.modified
        let big = MemoryFileSystem(files)
        #expect(await LinkSearch.autoRelink(AssetLink.all(in: a.state), device: Self.device, searchFolder: "/big", fileSystem: big).isEmpty)
    }

    @Test func localFileSystemAndExtract() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("copy.png")
        let written = try LinkFiles.extract(Data("abc".utf8), to: file, replace: false)
        #expect(written != nil)
        #expect(throws: (any Error).self) { try LinkFiles.extract(Data("abc".utf8), to: file, replace: false) }
        #expect(try LinkFiles.extract(Data("abcd".utf8), to: file, replace: true) != nil)
        let local = LocalLinkFileSystem()
        #expect(local.modificationDate(atPath: file.path) != nil)
        #expect(local.modificationDate(atPath: directory.path) == nil)
        #expect(local.modificationDate(atPath: directory.appendingPathComponent("none").path) == nil)
        let entries = try #require(local.entries(atPath: directory.path))
        #expect(Set(entries.map(\.name)) == ["copy.png", "sub"] && entries.first { $0.name == "sub" }?.isDirectory == true)
        #expect(local.entries(atPath: directory.appendingPathComponent("none").path) == nil)
        #expect(LinkSearch.securityScopedBookmark(file.path) != nil)
    }

    @Test func reviewRule() {
        var local = Wiretuner_Doc_V1_LinkSource()
        local.kind = .localFile
        local.path = "/a"
        var moved = local
        moved.path = "/b"
        var embedded = Wiretuner_Doc_V1_LinkSource()
        embedded.kind = .embedded
        #expect(LinkReview.action(embedded, before: local) == .embed)
        #expect(LinkReview.action(moved, before: local) == .relink(path: "/b"))
        #expect(LinkReview.action(local, before: local) == .update)
        #expect(LinkReview.action(local, before: nil) == .relink(path: "/a"))
        #expect(LinkReview.isListed(losing: embedded, winning: moved) && !LinkReview.isListed(losing: local, winning: local))
    }

    @Test func mergeUpdateVersusUpdateKeepsAConsistentTriple() throws {
        var pair = Pair()
        let id = try Self.asset(&pair.a)
        pair.sync()
        let tiff = ImportedBlob(data: Data("tiff-bytes".utf8), uti: "public.tiff")
        let a = try #require(try pair.a.perform(UpdateLink(id, blob: tiff, modified: Self.modified.addingTimeInterval(5))))
        let png = Self.blob("png")
        let b = try #require(try pair.b.perform(UpdateLink(id, blob: png, modified: Self.modified.addingTimeInterval(9))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let link = try #require(AssetLink.read(id, in: pair.a.state))
        let winner = PageFixture.later(a, b) ? tiff : png
        #expect(link.sha256 == winner.sha256 && link.byteSize == UInt64(winner.data.count) && link.mediaType == winner.mediaType)
    }

    @Test func mergeEmbedVersusRelinkLaterWinsAndTheLoserIsListed() throws {
        var pair = Pair()
        let id = try Self.asset(&pair.a)
        pair.sync()
        let a = try #require(try pair.a.perform(EmbedAsset([id])))
        let b = try #require(try pair.b.perform(RelinkAsset(id, to: LinkTarget(path: "/Users/b/p.png", device: "mac-b"), blob: Self.blob("b"))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let link = try #require(AssetLink.read(id, in: pair.a.state))
        #expect(link.kind == (PageFixture.later(a, b) ? .embedded : .localFile))
        #expect(!pair.a.state.store.losingWrites(id, AssetFields.link).isEmpty)
    }

    @Test func mergeObjectDeleteVersusAssetUpdate() throws {
        var pair = Pair()
        let id = try Self.asset(&pair.a)
        let object = try PageFixture.rect(&pair.a, at: .init(x: 0, y: 0))
        pair.sync()
        try pair.a.perform(DeleteNodes([object]))
        try pair.b.perform(UpdateLink(id, blob: Self.blob("v2"), modified: Self.modified.addingTimeInterval(1)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(object) && AssetLink.read(id, in: pair.a.state)?.sha256 == Self.blob("v2").sha256)
    }
}
