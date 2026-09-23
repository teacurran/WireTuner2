import AppKit
import Foundation
import GRPCCore
import SwiftProtobuf
import SwiftUI
import Testing
import WTProto
@testable import WireTuner

@Suite struct LibraryTypeTests {
    @Test func snippetsSplitAtTheServersBoldMarkers() {
        #expect(SearchSnippet.parse("Spring <b>Sale</b> starts") == [
            HighlightSegment(text: "Spring ", isMatch: false), HighlightSegment(text: "Sale", isMatch: true), HighlightSegment(text: " starts", isMatch: false),
        ])
        #expect(SearchSnippet.parse("<b>all</b>") == [HighlightSegment(text: "all", isMatch: true)])
        #expect(SearchSnippet.parse("open <b>end") == [HighlightSegment(text: "open ", isMatch: false), HighlightSegment(text: "end", isMatch: true)])
        #expect(SearchSnippet.parse("").isEmpty)
        #expect(SearchSnippet(field: .text, highlighted: "a <b>b</b>").plainText == "a b")
        let name = SearchSnippet(field: .documentName, highlighted: "<b>Spring</b> flyer")
        let text = SearchSnippet(field: .text, highlighted: "<b>Spring</b> Sale")
        #expect(LibrarySearchHit(documentID: "d", snippets: [name, text]).displaySnippet == text)
        #expect(LibrarySearchHit(documentID: "d", snippets: [name]).displaySnippet == name)
        #expect(LibrarySearchHit(documentID: "d", snippets: []).displaySnippet == nil)
        #expect(LibrarySearchField.allCases.map(\.title).count == Set(LibrarySearchField.allCases.map(\.title)).count)
        let attributed = text.attributed
        #expect(String(attributed.characters) == "Text: Spring Sale")
        #expect(attributed.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func uuidV7HasTimeVersionAndVariant() {
        let id = UUIDv7.make(milliseconds: 0x0189_ABCD_EF01, random: [0xFF, 0x11, 0xFF, 1, 2, 3, 4, 5, 6, 7])
        #expect(id == "0189abcd-ef01-7f11-bf01-020304050607")
        let generated = UUIDv7.make()
        #expect(UUID(uuidString: generated) != nil)
        #expect(Array(generated)[14] == "7")
        #expect(generated != UUIDv7.make())
        #expect(generated.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil)
    }

    @Test func hexRoundTrips() {
        #expect(Data([0, 0xAB, 0xFF]).hexString == "00abff")
        #expect(Data(hexString: "00ABff") == Data([0, 0xAB, 0xFF]))
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
        #expect(LibrarySpace.personal(id: "a") == LibrarySpace(id: "a", name: "Personal", kind: .personal))
        #expect(LibraryDocument.Role.commenter.title == "Commenter")
        #expect(LibraryRow(document: LibraryDocument(id: "x", spaceID: "s", name: "n")).id == "x")
    }
}

@Suite @MainActor struct LibraryProtoTests {
    @Test func documentsFoldersHitsAndTeamsMapFromTheWire() {
        var proto = Wiretuner_Docs_V1_Document()
        proto.id = "d"
        proto.spaceID = "s"
        proto.folderID = "f"
        proto.name = "Spring flyer"
        proto.callerRole = .editor
        proto.updatedAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 10))
        proto.thumbnailBlob = Data(repeating: 0xAB, count: 32)
        proto.thumbnailAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 20))
        proto.trashedAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 30))
        let document = LibraryDocument(proto, sharedWithMe: true)
        #expect(document.folderID == "f" && document.role == .editor && document.isTrashed && document.isSharedWithMe)
        #expect(document.thumbnail == String(repeating: "ab", count: 32))
        #expect(document.updatedAt == Date(timeIntervalSince1970: 10) && document.thumbnailAt == Date(timeIntervalSince1970: 20))
        let bare = LibraryDocument(Wiretuner_Docs_V1_Document())
        #expect(bare.folderID == nil && bare.thumbnail == nil && bare.role == nil && !bare.isTrashed && bare.updatedAt == nil && bare.thumbnailAt == nil)
        #expect([Wiretuner_Account_V1_DocumentRole.owner, .editor, .commenter, .viewer, .unspecified].map(LibraryDocument.Role.init) == [.owner, .editor, .commenter, .viewer, nil])

        var folder = Wiretuner_Docs_V1_Folder()
        folder.id = "f"
        folder.spaceID = "s"
        folder.name = "Clients"
        #expect(LibraryFolder(folder) == LibraryFolder(id: "f", spaceID: "s", parentID: nil, name: "Clients"))
        folder.parentFolderID = "p"
        #expect(LibraryFolder(folder).parentID == "p")

        let fields: [Wiretuner_Docs_V1_SearchField] = [.documentName, .objectName, .text, .note, .swatch, .style, .symbol, .keyword, .page, .unspecified]
        #expect(fields.map(LibrarySearchField.init) == LibrarySearchField.allCases)
        var match = Wiretuner_Docs_V1_SearchMatch()
        match.field = .text
        match.highlighted = "<b>Spring</b> Sale"
        var hit = Wiretuner_Docs_V1_SearchHit()
        hit.documentID = "d"
        hit.matches = [match]
        #expect(LibrarySearchHit(hit) == LibrarySearchHit(documentID: "d", snippets: [SearchSnippet(field: .text, highlighted: "<b>Spring</b> Sale")]))

        var list = Wiretuner_Docs_V1_ListResponse()
        list.documents = [proto]
        list.folders = [folder]
        #expect(LibraryPage(list, sharedWithMe: false).nextCursor == nil)
        list.nextCursor = "c"
        let page = LibraryPage(list, sharedWithMe: false)
        #expect(page.nextCursor == "c" && page.documents.count == 1 && page.folders.count == 1 && !page.documents[0].isSharedWithMe)

        var team = Wiretuner_Account_V1_Team()
        team.id = "t"
        team.name = "Acme"
        #expect(LibrarySpace(team) == LibrarySpace(id: "t", name: "Acme", kind: .team))
    }

    @Test func requestsCarryTheirFields() {
        let folder = LibraryRequests.list(LibraryListRequest(spaceID: "s", scope: .folder("f"), cursor: "c"))
        #expect(folder.spaceID == "s" && folder.scope == .folder && folder.folderID == "f" && folder.cursor == "c" && folder.pageSize == 100)
        let root = LibraryRequests.list(LibraryListRequest(spaceID: nil, scope: .folder(nil), cursor: nil))
        #expect(root.spaceID.isEmpty && root.folderID.isEmpty && root.cursor.isEmpty)
        let shared = LibraryRequests.list(LibraryListRequest(spaceID: "s", scope: .sharedWithMe, cursor: nil))
        #expect(shared.scope == .sharedWithMe && shared.spaceID.isEmpty)

        let create = LibraryRequests.create(LibraryDocument(id: "d", spaceID: "s", folderID: "f", name: "Untitled"))
        #expect(create.documentID == "d" && create.spaceID == "s" && create.folderID == "f" && create.name == "Untitled" && create.kind == .illustrationMultiPage)
        #expect(LibraryRequests.create(LibraryDocument(id: "d", spaceID: "s", name: "U")).folderID.isEmpty)
        let search = LibraryRequests.search(query: "spring", spaceID: "s", cursor: nil)
        #expect(search.query == "spring" && search.spaceID == "s" && search.cursor.isEmpty && search.pageSize == 50)
        #expect(LibraryRequests.search(query: "q", spaceID: "s", cursor: "c").cursor == "c")
        let duplicate = LibraryRequests.duplicate(documentID: "d", newDocumentID: "n", name: "copy")
        #expect(duplicate.documentID == "d" && duplicate.newDocumentID == "n" && duplicate.name == "copy")
        #expect(LibraryRequests.move(documentID: "d", spaceID: "s", folderID: nil).folderID.isEmpty)
        #expect(LibraryRequests.move(documentID: "d", spaceID: "s", folderID: "f").folderID == "f")
        #expect(LibraryRequests.createFolder(spaceID: "s", parentFolderID: nil, name: "n").parentFolderID.isEmpty)
        #expect(LibraryRequests.createFolder(spaceID: "s", parentFolderID: "p", name: "n").parentFolderID == "p")
        let download = LibraryRequests.download(documentID: "d", sha256: Data([1, 2]))
        #expect(download.documentID == "d" && download.sha256 == Data([1, 2]))

        var info = Wiretuner_Blob_V1_DownloadResponse()
        info.info = Wiretuner_Blob_V1_BlobInfo()
        var first = Wiretuner_Blob_V1_DownloadResponse()
        first.chunk = Data([1, 2])
        var second = Wiretuner_Blob_V1_DownloadResponse()
        second.chunk = Data([3])
        #expect(LibraryRequests.content(of: [info, first, second, Wiretuner_Blob_V1_DownloadResponse()]) == Data([1, 2, 3]))
    }

    @Test func responsesMapThroughTheirWrappers() async throws {
        var document = Wiretuner_Docs_V1_Document()
        document.id = "d"
        document.name = "Doc"
        #expect(Wiretuner_Docs_V1_GetResponse.with { $0.document = document }.mapped.id == "d")
        #expect(Wiretuner_Docs_V1_CreateResponse.with { $0.document = document }.mapped.id == "d")
        #expect(Wiretuner_Docs_V1_RenameResponse.with { $0.document = document }.mapped.name == "Doc")
        #expect(Wiretuner_Docs_V1_TrashResponse.with { $0.document = document }.mapped.id == "d")
        #expect(Wiretuner_Docs_V1_DuplicateResponse.with { $0.document = document }.mapped.id == "d")
        #expect(Wiretuner_Docs_V1_MoveToFolderResponse.with { $0.document = document }.mapped.id == "d")
        var folder = Wiretuner_Docs_V1_Folder()
        folder.id = "f"
        #expect(Wiretuner_Docs_V1_CreateFolderResponse.with { $0.folder = folder }.mapped.id == "f")
        #expect(Wiretuner_Docs_V1_RenameFolderResponse.with { $0.folder = folder }.mapped.id == "f")
        let listing = Wiretuner_Docs_V1_ListResponse.with { $0.documents = [document] }
        #expect(!listing.mapped.documents[0].isSharedWithMe)
        #expect(listing.mapped.markedShared.documents[0].isSharedWithMe)
        let teams = Wiretuner_Account_V1_ListTeamsResponse.with { $0.teams = [.with { $0.id = "t"; $0.name = "Acme" }] }
        #expect(teams.mapped == [LibrarySpace(id: "t", name: "Acme", kind: .team)])
        #expect(Wiretuner_Docs_V1_SearchResponse().mapped.nextCursor == nil)
        let search = Wiretuner_Docs_V1_SearchResponse.with { $0.hits = [.with { $0.documentID = "d" }]; $0.nextCursor = "n" }.mapped
        #expect(search.hits.map(\.documentID) == ["d"] && search.nextCursor == "n")
        Wiretuner_Docs_V1_DeleteFolderResponse().mapped
        #expect([Wiretuner_Blob_V1_DownloadResponse.with { $0.chunk = Data([9]) }].mapped == Data([9]))

        typealias Part = StreamingClientResponse<Wiretuner_Blob_V1_DownloadResponse>.Contents.BodyPart
        let parts = AsyncThrowingStream<Part, any Error> { continuation in
            continuation.yield(.message(.with { $0.chunk = Data([7]) }))
            continuation.yield(.trailingMetadata([:]))
            continuation.finish()
        }
        let response = StreamingClientResponse(of: Wiretuner_Blob_V1_DownloadResponse.self, metadata: [:], bodyParts: RPCAsyncSequence(wrapping: parts))
        #expect(LibraryRequests.content(of: try await LibraryRequests.collect(response)) == Data([7]))
    }

    @Test func connectivityFailuresAreToldApartFromRefusals() {
        #expect(LibraryConnectivity.isOffline(LibraryClientError.offline))
        #expect(!LibraryConnectivity.isOffline(LibraryClientError.hashMismatch))
        #expect(LibraryConnectivity.isOffline(AuthError.notSignedIn))
        #expect(LibraryConnectivity.isOffline(AuthError.sessionExpired))
        #expect(!LibraryConnectivity.isOffline(AuthError.cancelled))
        #expect(LibraryConnectivity.isOffline(RPCError(code: .unavailable, message: "")))
        #expect(LibraryConnectivity.isOffline(RPCError(code: .deadlineExceeded, message: "")))
        #expect(!LibraryConnectivity.isOffline(RPCError(code: .permissionDenied, message: "")))
        #expect(LibraryConnectivity.isOffline(URLError(.notConnectedToInternet)))
        #expect(!LibraryConnectivity.isOffline(CocoaError(.fileNoSuchFile)))
        #expect(LibraryModel.message(for: RPCError(code: .permissionDenied, message: "Nope")) == "Nope")
        #expect(LibraryModel.message(for: RPCError(code: .permissionDenied, message: "")) == "permissionDenied")
        #expect(LibraryModel.message(for: AuthError.notSignedIn) == "You are not signed in.")
    }

    @Test func theGRPCClientReachesTheConfiguredAPIAndFailsFastWithoutAServer() async {
        let client = GRPCLibraryClient(api: URL(string: "http://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        #expect(client.endpoint.host == "127.0.0.1" && client.endpoint.port == 1 && !client.endpoint.tls)
        let token = "t"
        await #expect(throws: (any Error).self) { try await client.list(LibraryListRequest(spaceID: "s", scope: .folder(nil), cursor: nil), accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.list(LibraryListRequest(spaceID: nil, scope: .sharedWithMe, cursor: nil), accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.get(documentID: "d", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.search(query: "q", spaceID: "s", cursor: nil, accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.create(LibraryDocument(id: "d", spaceID: "s", name: "n"), accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.rename(documentID: "d", name: "n", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.trash(documentID: "d", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.duplicate(documentID: "d", newDocumentID: "n", name: "c", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.move(documentID: "d", spaceID: "s", folderID: nil, accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.createFolder(spaceID: "s", parentFolderID: nil, name: "n", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.renameFolder(folderID: "f", name: "n", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.deleteFolder(folderID: "f", accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.listTeams(accessToken: token) }
        await #expect(throws: (any Error).self) { try await client.download(documentID: "d", sha256: Data(count: 32), accessToken: token) }
        let tls = GRPCLibraryClient(api: URL(string: "https://127.0.0.1:1")!, clientVersion: "v", deviceID: "d")
        await #expect(throws: (any Error).self) { try await tls.listTeams(accessToken: token) }
    }
}

@Suite @MainActor struct LibraryCacheTests {
    private func document(_ id: String, _ name: String, space: String = "s", folder: String? = nil, shared: Bool = false, pending: Bool = false) -> LibraryDocument {
        LibraryDocument(id: id, spaceID: space, folderID: folder, name: name, isPendingUpload: pending, isSharedWithMe: shared)
    }

    @Test func listsReplaceWhatTheyListedAndKeepPendingUploads() {
        var cache = LibraryCacheFile()
        cache.documents = ["old": document("old", "Old"), "pending": document("pending", "Pending", pending: true), "other": document("other", "Other", folder: "f")]
        cache.folders = ["gone": LibraryFolder(id: "gone", spaceID: "s", parentID: nil, name: "Gone"), "deep": LibraryFolder(id: "deep", spaceID: "s", parentID: "x", name: "Deep")]
        let page = LibraryPage(documents: [document("b", "beta"), document("a", "Alpha")], folders: [LibraryFolder(id: "n", spaceID: "s", parentID: nil, name: "New")], nextCursor: nil)
        cache.apply(page, scope: .folder(nil), spaceID: "s", firstPage: true)
        #expect(Set(cache.documents.keys) == ["pending", "other", "a", "b"])
        #expect(Set(cache.folders.keys) == ["deep", "n"])
        #expect(cache.documents(in: .folder(nil), spaceID: "s").map(\.name) == ["Alpha", "beta", "Pending"])
        cache.apply(LibraryPage(documents: [document("c", "Gamma")], folders: [], nextCursor: nil), scope: .folder(nil), spaceID: "s", firstPage: false)
        #expect(cache.documents["a"] != nil && cache.documents["c"] != nil)
        #expect(cache.folders(in: "s", parent: nil).map(\.name) == ["New"])

        cache.documents["shared"] = document("shared", "Shared", space: "t", shared: true)
        cache.apply(LibraryPage(documents: [], folders: [], nextCursor: nil), scope: .sharedWithMe, spaceID: nil, firstPage: true)
        #expect(cache.documents["shared"] == nil && cache.documents["a"] != nil)
        #expect(LibraryCacheFile.matches(document("x", "X", shared: true), scope: .sharedWithMe, spaceID: nil))
        #expect(!LibraryCacheFile.matches(document("x", "X", shared: true), scope: .folder(nil), spaceID: "s"))
        #expect(LibraryCacheFile.byName(document("1", "Same"), document("2", "Same")))
    }

    @Test func opensBecomeRecentsAndOfflineCopies() {
        var cache = LibraryCacheFile()
        for index in 0..<(LibraryCacheFile.recentsLimit + 3) {
            cache.markOpened(document("d\(index)", "D\(index)"), at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(cache.recents.count == LibraryCacheFile.recentsLimit)
        #expect(cache.recents.first?.documentID == "d\(LibraryCacheFile.recentsLimit + 2)")
        cache.markOpened(document("d10", "D10"), at: Date())
        #expect(cache.recents.first?.documentID == "d10" && cache.recents.count == LibraryCacheFile.recentsLimit)
        #expect(cache.offlineAvailable.contains("d0"))
        cache.documents["d10"]?.isTrashed = true
        #expect(!cache.recentDocuments.contains { $0.id == "d10" })
    }

    @Test func theStoreRoundTripsAndStartsEmptyOnGarbage() throws {
        let directory = TestEnvironment.temporaryDirectory()
        let store = LibraryCacheStore(url: directory.appending(path: LibraryCacheStore.fileName))
        #expect(store.load() == LibraryCacheFile())
        var cache = LibraryCacheFile()
        cache.personalSpaceID = "me"
        cache.markOpened(document("d", "Doc"), at: Date(timeIntervalSince1970: 5))
        try store.save(cache)
        #expect(store.load() == cache)
        try Data(#"{"version": 9}"#.utf8).write(to: store.url)
        #expect(store.load() == LibraryCacheFile())
        #expect(LibraryCacheStore.defaultURL.lastPathComponent == "Library.json")
        #expect(ThumbnailCache.defaultDirectory.lastPathComponent == "Thumbnails")
    }

    @Test func thumbnailsAreCheckedAgainstTheirHash() throws {
        for directory in [TestEnvironment.temporaryDirectory(), nil] {
            let cache = ThumbnailCache(directory: directory)
            let hash = ThumbnailCache.sha256Hex(TestPNG.data)
            #expect(!cache.contains(hash) && cache.image(for: hash) == nil)
            #expect(throws: LibraryClientError.hashMismatch) { try cache.store(Data("other".utf8), for: hash) }
            try cache.store(TestPNG.data, for: hash)
            #expect(cache.contains(hash) && cache.data(for: hash) == TestPNG.data)
            let image = cache.image(for: hash)
            #expect(image != nil && cache.image(for: hash) === image)
            #expect((cache.fileURL(for: hash) == nil) == (directory == nil))
        }
        let garbage = ThumbnailCache(directory: nil)
        let hash = ThumbnailCache.sha256Hex(Data("not a png".utf8))
        try garbage.store(Data("not a png".utf8), for: hash)
        #expect(garbage.image(for: hash) == nil)
    }
}

@Suite(.serialized) @MainActor struct LibraryModelTests {
    let server = FakeLibraryServer()

    private func model(signedIn: Bool = true, store: LibraryCacheStore? = nil) -> LibraryModel {
        let model = LibraryModel(services: server.services(signedIn: signedIn), store: store, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        var counter = 0
        model.makeID = {
            counter += 1
            return "id-\(counter)"
        }
        model.now = { Date(timeIntervalSince1970: 100) }
        return model
    }

    private var me: String { server.accountID }

    private func doc(_ id: String, _ name: String, folder: String? = nil, thumbnail: String? = nil, space: String? = nil, shared: Bool = false) -> LibraryDocument {
        LibraryDocument(id: id, spaceID: space ?? me, folderID: folder, name: name, thumbnail: thumbnail, isSharedWithMe: shared)
    }

    @Test func refreshLearnsTheAccountTeamsAndListsTheTopLevel() async {
        let hash = server.putBlob(TestPNG.data)
        server.put(doc("d1", "Spring flyer", thumbnail: hash))
        server.put(doc("d2", "Catalog"))
        server.put(doc("d3", "In folder", folder: "f1"))
        server.put(LibraryFolder(id: "f1", spaceID: me, parentID: nil, name: "Clients"))
        server.setTeams([LibrarySpace(id: "t1", name: "Acme", kind: .team)])
        let model = model()
        #expect(model.currentSpaceID == LibraryModel.localPersonalID)
        await model.refresh()
        #expect(model.isOnline && model.errorMessage == nil && !model.isLoading)
        #expect(model.currentSpaceID == me && model.cache.personalSpaceID == me)
        #expect(model.spaces.map(\.name) == ["Personal", "Acme"])
        #expect(model.currentSpace.id == me)
        #expect(model.rows.map(\.document.name) == ["Catalog", "Spring flyer"])
        #expect(model.folders.map(\.name) == ["Clients"])
        #expect(model.thumbnailImage(for: model.rows[1].document) != nil)
        #expect(model.thumbnailImage(for: model.rows[0].document) == nil)
        #expect(model.thumbnailRevision == 1)
        // A second refresh finds the thumbnail cached and does not ask for Me again.
        await model.refresh()
        #expect(server.calls.filter { $0 == "me" }.count == 1)
        #expect(server.calls.filter { $0 == "download" }.count == 1)

        // Into the folder, the path bar follows; a team space lists its own documents.
        await model.show(.folder("f1"))
        #expect(model.rows.map(\.document.name) == ["In folder"] && model.folderPath.map(\.name) == ["Clients"])
        server.put(doc("t-doc", "Team doc", space: "t1"))
        await model.switchSpace(to: "t1")
        #expect(model.currentSpace.name == "Acme" && model.rows.map(\.document.name) == ["Team doc"])
        await model.switchSpace(to: "unknown")
        #expect(model.currentSpaceID == me)
    }

    @Test func aTeamYouLeftFallsBackToPersonal() async {
        server.setTeams([LibrarySpace(id: "t1", name: "Acme", kind: .team)])
        let model = model()
        await model.refresh()
        await model.switchSpace(to: "t1")
        server.setTeams([])
        await model.refresh()
        #expect(model.currentSpaceID == me)
    }

    @Test func sharedWithMeAndRecentsAreSections() async {
        server.put(doc("s1", "From Priya", space: "other", shared: true))
        let model = model()
        await model.refresh()
        await model.show(.sharedWithMe)
        #expect(model.rows.map(\.document.name) == ["From Priya"] && model.folders.isEmpty && model.folderPath.isEmpty)
        model.open([model.rows[0].document])
        await model.show(.recents)
        #expect(model.rows.map(\.id) == ["s1"] && model.nextCursor == nil)
    }

    @Test func pagesLoadWithCursors() async {
        server.setPageSize(2)
        for index in 1...5 { server.put(doc("d\(index)", "Doc \(index)")) }
        let model = model()
        await model.refresh()
        #expect(model.rows.count == 2 && model.nextCursor == "2")
        await model.loadMore()
        await model.loadMore()
        #expect(model.rows.count == 5 && model.nextCursor == nil)
        await model.loadMore()
        #expect(model.rows.count == 5)
        model.searchText = ""
        server.offline = true
        server.setPageSize(1)
        await model.reloadSection()
        #expect(!model.isOnline)
    }

    @Test func offlineTheCacheStillListsAndOnlyLocalCopiesOpen() async {
        let directory = TestEnvironment.temporaryDirectory()
        let store = LibraryCacheStore(url: directory.appending(path: LibraryCacheStore.fileName))
        server.put(doc("d1", "Opened"))
        server.put(doc("d2", "Never opened"))
        let online = model(store: store)
        await online.refresh()
        online.open([online.rows.first { $0.id == "d1" }!.document])

        server.offline = true
        let offline = model(store: store)
        var opened: [String] = []
        offline.onOpen = { opened += $0.map(\.id) }
        await offline.refresh()
        #expect(!offline.isOnline && offline.errorMessage == nil)
        #expect(offline.rows.map(\.document.name) == ["Never opened", "Opened"])
        let never = offline.rows[0].document, local = offline.rows[1].document
        #expect(offline.isAvailable(local) && offline.isOfflineAvailable(local))
        #expect(!offline.isAvailable(never) && !offline.isOfflineAvailable(never))
        offline.selection = [never.id, local.id]
        offline.openSelection()
        #expect(opened == ["d1"])
        #expect(offline.errorMessage == LibraryModel.notOnThisMacMessage("Never opened"))
        offline.open([never])
        #expect(opened == ["d1"])
        offline.keepAvailableOffline(never.id)
        #expect(offline.isAvailable(never))
        await offline.prefetchThumbnails()
        #expect(!server.calls.contains("download"))
    }

    @Test func signedOutBehavesLikeOffline() async {
        let model = model(signedIn: false)
        await model.refresh()
        #expect(!model.isOnline && model.errorMessage == nil)
        await model.rename("x", to: "y")
        await model.loadMore()
        #expect(server.calls.isEmpty)
    }

    @Test func creatingOnlineUploadsAtOnceAndOpens() async {
        let model = model()
        await model.refresh()
        var opened: [LibraryDocument] = []
        model.onOpen = { opened += $0 }
        let created = model.createDocument()
        #expect(created.id == "id-1" && created.name == "Untitled" && created.isPendingUpload && created.spaceID == me)
        #expect(opened.map(\.id) == ["id-1"])
        #expect(model.cache.recents.first?.documentID == "id-1")
        await model.pendingUploads["id-1"]?.value
        #expect(model.pendingUploads.isEmpty)
        #expect(model.cache.documents["id-1"]?.isPendingUpload == false)
        #expect(server.documents["id-1"]?.name == "Untitled")

        // In a folder, a new document lands there.
        server.put(LibraryFolder(id: "f1", spaceID: me, parentID: nil, name: "Clients"))
        await model.show(.folder("f1"))
        #expect(model.createDocument().folderID == "f1")
        await model.show(.recents)
        #expect(model.createDocument().folderID == nil)
    }

    @Test func creatingOfflineWaitsAndUploadsOnReconnect() async {
        server.offline = true
        let model = model()
        await model.refresh()
        let created = model.createDocument()
        await model.pendingUploads[created.id]?.value
        #expect(created.spaceID == LibraryModel.localPersonalID)
        #expect(model.cache.documents[created.id]?.isPendingUpload == true)
        #expect(model.isOfflineAvailable(created) && model.isAvailable(created))
        await model.rename(created.id, to: "  Poster  ")
        #expect(model.cache.documents[created.id]?.name == "Poster")
        await model.rename(created.id, to: "   ")
        await model.rename("missing", to: "x")

        server.offline = false
        await model.refresh()
        #expect(model.cache.documents[created.id]?.isPendingUpload == false)
        #expect(server.documents[created.id]?.spaceID == me)
        #expect(server.calls.contains("create:Poster"))
    }

    @Test func aCreateThatAlreadyReachedTheServerCountsAsUploaded() async {
        let model = model()
        await model.refresh()
        server.failNext(with: RPCError(code: .alreadyExists, message: "DOCUMENT_EXISTS"))
        let created = model.createDocument()
        await model.pendingUploads[created.id]?.value
        #expect(model.cache.documents[created.id]?.isPendingUpload == false)
    }

    @Test func aRefusedCreateShowsItsReason() async {
        let model = model()
        await model.refresh()
        server.failNext(with: RPCError(code: .permissionDenied, message: "Not allowed"))
        let created = model.createDocument()
        await model.pendingUploads[created.id]?.value
        #expect(model.errorMessage == "Not allowed" && model.cache.documents[created.id]?.isPendingUpload == true)
    }

    @Test func renameTrashDuplicateAndMoveGoThroughTheServer() async {
        server.put(doc("d1", "Spring flyer"))
        server.put(LibraryFolder(id: "f1", spaceID: me, parentID: nil, name: "Clients"))
        let model = model()
        await model.refresh()
        await model.rename("d1", to: "Summer flyer")
        #expect(model.cache.documents["d1"]?.name == "Summer flyer")
        let copy = await model.duplicate("d1")
        #expect(copy?.name == "Summer flyer copy" && model.cache.documents[copy!.id] != nil)
        #expect(await model.duplicate("missing") == nil)
        await model.move("d1", toFolder: "f1")
        #expect(model.cache.documents["d1"]?.folderID == "f1")
        #expect(!model.rows.contains { $0.id == "d1" })
        model.selection = [copy!.id]
        await model.trash(copy!.id)
        #expect(model.cache.documents[copy!.id]?.isTrashed == true && model.selection.isEmpty)
        #expect(!model.rows.contains { $0.id == copy!.id })

        server.failNext(with: RPCError(code: .notFound, message: "Gone"))
        await model.rename("d1", to: "x")
        #expect(model.errorMessage == "Gone")
        server.offline = true
        await model.trash("d1")
        #expect(model.errorMessage == LibraryModel.offlineActionMessage && model.cache.documents["d1"]?.isTrashed == false)
    }

    @Test func foldersAreCreatedRenamedAndDeleted() async {
        let model = model()
        await model.refresh()
        let folder = await model.createFolder(named: "Clients")
        #expect(folder?.parentID == nil && model.folders.map(\.name) == ["Clients"])
        await model.show(.folder(folder!.id))
        let inner = await model.createFolder(named: "Acme")
        #expect(inner?.parentID == folder?.id)
        await model.renameFolder(folder!.id, to: "Customers")
        #expect(model.folderPath.map(\.name) == ["Customers"])
        await model.deleteFolder(folder!.id)
        #expect(model.section == .folder(nil) && model.cache.folders[folder!.id] == nil)
        await model.deleteFolder(inner!.id)
        server.offline = true
        #expect(await model.createFolder(named: "Never") == nil)
        await model.renameFolder(inner!.id, to: "x")
        await model.deleteFolder("x")
        #expect(model.errorMessage == LibraryModel.offlineActionMessage)
    }

    @Test func onlineSearchShowsHighlightedSnippetsAndKeepsNameMatches() async {
        server.put(doc("d1", "Catalog"))
        server.put(doc("d2", "Spring flyer"))
        server.put(doc("d3", "Spring poster"))
        let hidden = doc("d4", "Deep", folder: "f9")
        server.put(hidden)
        let model = model()
        await model.refresh()
        server.setHits([
            LibrarySearchHit(documentID: "d1", snippets: [SearchSnippet(field: .text, highlighted: "<b>Spring</b> Sale")]),
            LibrarySearchHit(documentID: "d4", snippets: [SearchSnippet(field: .note, highlighted: "<b>spring</b>")]),
            LibrarySearchHit(documentID: "d2", snippets: [SearchSnippet(field: .documentName, highlighted: "<b>Spring</b> flyer")]),
            LibrarySearchHit(documentID: "gone", snippets: []),
        ])
        model.searchText = "Spring"
        // While the call is out, the cached names show.
        #expect(model.searchResults?.map(\.document.name) == ["Spring flyer", "Spring poster"])
        #expect(model.searchHint == nil)
        await model.pendingSearch?.value
        #expect(model.searchResults?.map(\.id) == ["d1", "d4", "d2", "d3"])
        #expect(model.searchResults?[0].snippet?.plainText == "Spring Sale")
        #expect(model.searchResults?[0].snippet?.field == .text)
        #expect(model.cache.documents["d4"] != nil, "an unknown hit is fetched with Get")
        #expect(server.calls.contains("search:Spring"))
        model.searchText = ""
        #expect(model.searchResults == nil)
    }

    @Test func aSearchOvertakenByTypingIsDropped() async {
        server.put(doc("d1", "Spring"))
        let model = model()
        await model.refresh()
        model.searchText = "Spr"
        let first = model.pendingSearch
        model.searchText = "Spring"
        await first?.value
        await model.runSearch("Spr")
        #expect(model.searchResults?.map(\.id) == ["d1"])
        await model.pendingSearch?.value
    }

    @Test func offlineSearchMatchesNamesOnly() async {
        server.put(doc("d1", "Spring flyer"))
        server.put(doc("s1", "Spring shared", space: "x", shared: true))
        let model = model()
        await model.refresh()
        await model.show(.sharedWithMe)
        await model.show(.folder(nil))
        server.offline = true
        await model.refresh()
        model.searchText = "spring"
        #expect(model.searchHint == LibraryModel.namesOnlyHint)
        #expect(model.searchResults?.map(\.id) == ["d1"])
        #expect(model.pendingSearch == nil)
        await model.show(.sharedWithMe)
        model.searchText = "spring"
        #expect(model.nameMatches("spring").map(\.id) == ["s1"])
        // A search that finds the network gone falls back to names.
        server.offline = false
        await model.refresh()
        model.searchText = "flyer"
        server.offline = true
        await model.pendingSearch?.value
        #expect(!model.isOnline)
    }

    @Test func thumbnailsThatDoNotHashAreSkippedAndOfflineStopsDownloads() async {
        let good = server.putBlob(TestPNG.data)
        let bad = server.putBlob(Data("junk".utf8), as: String(repeating: "0", count: 64))
        server.put(doc("d1", "Bad", thumbnail: bad))
        server.put(doc("d2", "Good", thumbnail: good))
        server.put(doc("d3", "Unparseable", thumbnail: "zz"))
        let model = model()
        await model.refresh()
        #expect(model.thumbnailImage(for: model.rows.first { $0.id == "d2" }!.document) != nil)
        #expect(model.thumbnailImage(for: model.rows.first { $0.id == "d1" }!.document) == nil)

        server.put(doc("d4", "Later", thumbnail: ThumbnailCache.sha256Hex(Data("x".utf8))))
        await model.reloadSection()
        server.offline = true
        await model.prefetchThumbnails(for: [doc("d4", "Later", thumbnail: String(repeating: "1", count: 64))])
        #expect(!model.isOnline)
    }

    @Test func galleryCreatesFromTheBuiltInTemplate() {
        let model = model()
        model.isShowingGallery = true
        model.createFromGallery()
        #expect(!model.isShowingGallery && model.cache.documents.count == 1)
    }
}

@Suite @MainActor struct LibraryWindowTests {
    @Test func theWindowRendersRowsSnippetsBadgesAndHints() async throws {
        let server = FakeLibraryServer()
        let hash = server.putBlob(TestPNG.data)
        let me = server.accountID
        server.put(LibraryDocument(id: "d1", spaceID: me, name: "Spring flyer", thumbnail: hash))
        server.put(LibraryDocument(id: "d2", spaceID: me, name: "Catalog"))
        server.put(LibraryDocument(id: "s1", spaceID: "x", name: "Shared", role: .viewer, isSharedWithMe: true))
        server.put(LibraryFolder(id: "f1", spaceID: me, parentID: nil, name: "Clients"))
        for index in 0..<120 { server.put(LibraryDocument(id: "z\(index)", spaceID: me, name: "Filler \(index)")) }
        server.setTeams([LibrarySpace(id: "t1", name: "Acme", kind: .team)])
        let model = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
        let controller = LibraryWindowController(model: model)
        #expect(controller.window?.identifier == LibraryWindowController.windowIdentifier)
        await controller.show().value
        #expect(controller.window?.isVisible == true)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        model.selection = ["d1"]
        content.layoutSubtreeIfNeeded()
        #expect(LibraryToolbar(model: model).title == "Personal")

        server.setHits([LibrarySearchHit(documentID: "d2", snippets: [SearchSnippet(field: .text, highlighted: "<b>Spring</b> Sale")])])
        model.searchText = "Spring"
        await model.pendingSearch?.value
        content.layoutSubtreeIfNeeded()
        #expect(LibraryToolbar(model: model).title == "Search results")
        server.offline = true
        model.searchText = "Catalog"
        await model.pendingSearch?.value
        model.searchText = "Cat"
        content.layoutSubtreeIfNeeded()

        server.offline = false
        await model.show(.sharedWithMe)
        model.open([LibraryDocument(id: "missing", spaceID: me, name: "Missing")])
        content.layoutSubtreeIfNeeded()
        #expect(LibraryToolbar(model: model).title == "Shared with Me")
        await model.show(.recents)
        #expect(LibraryToolbar(model: model).title == "Recents")
        await model.show(.folder("f1"))
        #expect(LibraryToolbar(model: model).title == "Personal › Clients")
        model.createDocument()
        content.layoutSubtreeIfNeeded()

        let gallery = NSHostingView(rootView: TemplateGalleryView(model: model))
        gallery.layoutSubtreeIfNeeded()
        #expect(gallery.fittingSize.width > 0)
        controller.close()
    }

    @Test func openAndLibraryCommandsShowTheWindow() {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let counter = Counter()
        LibraryCommands.install(into: registry) { counter.bump() }
        #expect(registry.perform(LibraryCommands.ID.open))
        #expect(registry.perform(LibraryCommands.ID.library))
        #expect(counter.count == 2)
        #expect(registry.command(LibraryCommands.ID.open)?.defaultKey == KeyEquivalent("o", .command))
        #expect(registry.command(LibraryCommands.ID.library)?.menuPath?.menu == "Window")
    }

    @Test func theAppOpensLibraryDocumentsInTabsAndCreatesThroughTheLibrary() async {
        let suite = TestDefaults()
        let server = FakeLibraryServer()
        let library = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.documents.documents.count == 1)
        #expect(delegate.menuTarget?.perform(StandardCommands.ID.new) == true)
        #expect(delegate.documents.documents.count == 2)
        #expect(library.cache.documents.count == 1)
        library.open([LibraryDocument(id: "lib-1", spaceID: "s", name: "From library")])
        #expect(delegate.documents.document(id: "lib-1")?.title == "From library")
        let task = delegate.showLibrary()
        await task.value
        #expect(delegate.libraryWindowController?.window?.isVisible == true)
        let again = delegate.showLibrary()
        await again.value
        #expect(delegate.menuTarget?.perform(LibraryCommands.ID.library) == true)
        delegate.libraryWindowController?.close()
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        suite.remove()
    }

    @Test func theLaunchEnvironmentBuildsAGRPCLibrary() async {
        let suite = TestDefaults()
        let account = LaunchEnvironment().makeAccountModel(infoDictionary: nil, defaults: suite.defaults)
        let library = LaunchEnvironment().makeLibraryModel(
            account: account, infoDictionary: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "3"], defaults: suite.defaults,
            store: nil, thumbnails: ThumbnailCache(directory: nil)
        )
        #expect((library.services.documents as? GRPCLibraryClient)?.clientVersion == "1.2/3")
        let fallback = LaunchEnvironment().makeLibraryModel(account: account, infoDictionary: nil, defaults: suite.defaults, store: nil, thumbnails: ThumbnailCache(directory: nil))
        #expect((fallback.services.documents as? GRPCLibraryClient)?.clientVersion == "0/0")
        await #expect(throws: AuthError.notSignedIn) { try await library.services.accessToken() }
        suite.remove()
    }
}
