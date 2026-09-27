import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

/// DATA-023: data merge with several clients (data-merge.adoc, "Working with others" and "Merge
/// semantics"), through the simulator.  Every scenario converges to one hash on every client
/// (`expectConverged`) with the review entries it expects.  Concurrency is made by cutting clients
/// off: what they do while partitioned is concurrent with everything the others do.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct DataMergeScenarioTests {
    struct Base {
        var clients: [SimClient]
        var page: OpID
        var name: OpID
        var city: OpID
        /// A text block "Hi {{name}}" on the page.
        var block: OpID
        var shape: OpID

        var ana: SimClient { clients[0] }
        var ben: SimClient { clients[1] }
    }

    /// Two clients (Ben keeps a review pending until the scenario settles it) sharing a page, the
    /// fields `name` and `city`, a template text block and a shape.
    static func start(_ sim: Simulation) async throws -> Base {
        let ana = try await sim.addClient("ana")
        let ben = try await sim.addClient("ben", keepsMergedResult: false)
        await ana.perform(SetBleed([PageList.synthesizedID], to: 0))
        let page = PageList(ana.state).pages[0].id
        let fields = try #require(await ana.perform(AddFields([.init("name"), .init("city")]))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)
        let block = try await Workload.createText(ana, "Hi ")
        let text = try #require(TextNode(block, in: ana.state))
        #expect(await ana.perform(InsertPlaceholder(node: block, at: text.anchor(at: 3), field: fields[0])) != nil)
        let shape = try await Workload.createShapes(ana, count: 1)[0]
        try await sim.settle()
        return Base(clients: [ana, ben], page: page, name: fields[0], city: fields[1], block: block, shape: shape)
    }

    /// Ana's work reaches the server first; then Ben reconnects and measures against it.
    static func reconnect(_ sim: Simulation, _ base: Base) async throws {
        base.ana.goOnline()
        try await sim.settle([base.ana])
        sim.advance(by: .seconds(3 * 3600))
        base.ben.goOnline()
    }

    /// Reconnects, expects that nothing asks for a review, and converges.
    static func reconnectQuietly(_ sim: Simulation, _ base: Base) async throws {
        try await reconnect(sim, base)
        try await sim.settle()
        try await sim.expectConverged()
        #expect(base.ben.reviews == 0 && base.ben.lastReview?.holdsOutbox != true)
        #expect(base.ben.lastReview.map { $0.entries.isEmpty && $0.mergeRuns.isEmpty && $0.removedFields.isEmpty } ?? true)
    }

    static func offline(_ base: Base) {
        base.clients.forEach { $0.goOffline() }
    }

    static func placeholders(_ client: SimClient, _ node: OpID) -> [String] {
        guard let text = TextNode(node, in: client.state) else { return [] }
        return DataModel(client.state).placeholders(in: text).map(\.label)
    }

    /// Rename of a field on one client while another binds an object to it: the binding holds the
    /// field by id, so it reads the new name everywhere; nothing to review.
    @Test func fieldRenameVersusBind() async throws {
        let sim = try await Simulation(name: "data-rename-bind", seed: Simulation.seed(2301), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        Self.offline(base)
        #expect(await base.ana.perform(RenameField(base.city, to: "town")) != nil)
        let label = try await Workload.createText(base.ben, "label")
        #expect(await base.ben.perform(BindToField([label], field: base.city, kind: .text)) != nil)
        try await Self.reconnectQuietly(sim, base)
        for client in base.clients {
            #expect(DataModel(client.state).binding(of: label, in: client.state)?.resolved?.name == "town")
        }
    }

    /// Delete of a field on one client while another places it: the placeholder reads
    /// `{{missing}}`; the reconnect lists *field removed with 1 binding*, whose *Restore* makes it
    /// resolve again on every client.
    @Test func fieldDeleteVersusPlaceholder() async throws {
        let sim = try await Simulation(name: "data-delete-placeholder", seed: Simulation.seed(2302), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        Self.offline(base)
        #expect(await base.ana.perform(DeleteField(base.city)) != nil)
        let text = try #require(TextNode(base.block, in: base.ben.state))
        #expect(await base.ben.perform(InsertPlaceholder(node: base.block, at: text.anchor(at: 0), field: base.city)) != nil)
        try await Self.reconnect(sim, base)
        try await base.ben.waitFor("needs review") { $0 == .needsReview }
        let review = try #require(await base.ben.client.pendingReview)
        #expect(review.removedFields == [FieldRemovedEntry(field: base.city, name: "city", uses: 1, deletedLocally: false)])
        #expect(Self.placeholders(base.ben, base.block) == ["{{missing}}", "{{name}}"])
        #expect(await base.ben.perform(review.removedFields[0].restore) != nil)
        try await base.ben.keepMerged()
        try await sim.settle()
        try await sim.expectConverged()
        for client in base.clients {
            #expect(Self.placeholders(client, base.block) == ["{{city}}", "{{name}}"])
        }
    }

    /// Two clients adding a field of the same name: both live, the later id reads ` (2)`.
    @Test func duplicateFieldNames() async throws {
        let sim = try await Simulation(name: "data-duplicate-names", seed: Simulation.seed(2303), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        Self.offline(base)
        let first = try #require(await base.ana.perform(AddFields("email"))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        let second = try #require(await base.ben.perform(AddFields("Email"))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        // Both inserted into the settings node's fields, no register in common: nothing to decide,
        // so nothing is listed (the settings node is never *Both edited*, FONT-029).
        try await Self.reconnectQuietly(sim, base)
        let (kept, suffixed) = first < second ? (first, second) : (second, first)
        for client in base.clients {
            let model = DataModel(client.state)
            #expect(model.fields.count == 4)
            #expect(model.field(kept)?.displayName.lowercased() == "email" && model.field(suffixed)?.displayName.lowercased() == "email (2)")
        }
    }

    /// The URL changed on one client while another adds a header: both kept.
    @Test func sourceURLVersusHeader() async throws {
        let sim = try await Simulation(name: "data-url-header", seed: Simulation.seed(2304), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        let source = try #require(await base.ana.perform(AddSource(name: "CRM", kind: .http) { $0.http.url = "https://a.example.com/people" }))
            .insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        try await sim.settle()
        Self.offline(base)
        var spec = Wiretuner_Doc_V1_DataSourceSpec()
        spec.http.url = "https://b.example.com/people"
        #expect(await base.ana.perform(EditSource(source, spec: spec, paths: [[4, 2]])) != nil)
        #expect(await base.ben.perform(SetSourceHeaders(source, [("Accept", "application/json")])) != nil)
        try await Self.reconnect(sim, base)
        try await base.ben.waitFor("review") { $0 == .needsReview || $0 == .saved }
        if await base.ben.client.pendingReview != nil { try await base.ben.keepMerged() }
        try await sim.settle()
        try await sim.expectConverged()
        for client in base.clients {
            let merged = try #require(DataModel(client.state).source(source))
            #expect(merged.spec.http.url == "https://b.example.com/people" && merged.spec.http.headers.map(\.name) == ["Accept"])
        }
    }

    /// Two clients refreshing the embedded sample: one whole value stands, and no review entry.
    @Test func sampleRace() async throws {
        let sim = try await Simulation(name: "data-sample-race", seed: Simulation.seed(2305), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        let source = try #require(await base.ana.perform(AddSource(name: "Pasted", kind: .pasted))).insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        try await sim.settle()
        func sample(_ byte: UInt8, _ count: UInt32) -> Wiretuner_Doc_V1_EmbeddedRecords {
            .with { $0.blobSha256 = Data(repeating: byte, count: 32); $0.mediaType = "text/csv"; $0.recordCount = count }
        }
        Self.offline(base)
        #expect(await base.ana.perform(SetSample(source, sample(1, 5))) != nil)
        #expect(await base.ben.perform(SetSample(source, sample(2, 3))) != nil)
        try await Self.reconnectQuietly(sim, base)
        let merged = try #require(DataModel(base.ana.state).source(source)?.sample)
        #expect([sample(1, 5), sample(2, 3)].contains(merged))
    }

    /// Two clients merging records to pages after the same template: one *two merge runs* entry,
    /// and each of its choices converges to its expected page list.
    @Test(arguments: MergeRunConflict.Choice.allCases) func concurrentMergeRuns(choice: MergeRunConflict.Choice) async throws {
        let sim = try await Simulation(name: "data-merge-runs-\(choice)", seed: Simulation.seed(2306), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        func records(_ names: [String], _ client: SimClient) -> RecordSet {
            RecordSet(model: DataModel(client.state), source: nil, raw: names.map { DataRecord(["name": $0, "city": "Oslo"]) })
        }
        Self.offline(base)
        let theirs = try #require(await base.ana.perform(MergeToPages(templates: [base.page], records: records(["Ada", "Bo", "Cy"], base.ana), indices: [0, 1, 2])))
        let mine = try #require(await base.ben.perform(MergeToPages(templates: [base.page], records: records(["Di", "Ed"], base.ben), indices: [0, 1])))
        try await Self.reconnect(sim, base)
        try await base.ben.waitFor("needs review") { $0 == .needsReview }
        let review = try #require(await base.ben.client.pendingReview)
        #expect(review.entries.isEmpty && review.mergeRuns.count == 1)
        let entry = review.mergeRuns[0]
        #expect(entry.page == base.page && entry.mine.pages.count == 2 && entry.theirs.pages.count == 3)
        #expect(Set(entry.mine.pages).isSubset(of: mine.createdNodes) && Set(entry.theirs.pages).isSubset(of: theirs.createdNodes))
        let command = try #require(entry.command(choice, in: base.ben.state))
        #expect(await base.ben.perform(command) != nil)
        try await base.ben.keepMerged()
        try await sim.settle()
        try await sim.expectConverged()
        let expected: [OpID] = switch choice {
        case .keepBoth: [base.page] + entry.ordered.earlier.pages + entry.ordered.later.pages
        case .removeTheirs: [base.page] + entry.mine.pages
        case .removeMine: [base.page] + entry.theirs.pages
        }
        for client in base.clients {
            #expect(client.state.store.children(WellKnown.pages).filter { client.state.isLive($0) } == expected)
        }
    }

    /// A merge concurrent with an edit of the template: the copies hold the template as the merger
    /// saw it, the edit lands on the template only.
    @Test func mergeVersusTemplateEdit() async throws {
        let sim = try await Simulation(name: "data-merge-template", seed: Simulation.seed(2307), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        Self.offline(base)
        let records = RecordSet(model: DataModel(base.ana.state), source: nil, raw: [DataRecord(["name": "Ada"]), DataRecord(["name": "Bo"])])
        let merge = try #require(await base.ana.perform(MergeToPages(templates: [base.page], records: records, indices: [0, 1])))
        #expect(await base.ben.perform(InsertText(node: base.block, text: "!", at: .end)) != nil)
        try await Self.reconnectQuietly(sim, base)
        for client in base.clients {
            let copies = merge.createdObjects.compactMap { TextNode($0, in: client.state)?.string }
            #expect(copies == ["Hi Ada", "Hi Bo"])
            #expect(Self.placeholders(client, base.block) == ["{{name}}"])
            #expect(TextNode(base.block, in: client.state)?.string.hasSuffix("!") == true)
        }
    }

    /// An API source fetched by two clients through the data service: the same records for both
    /// (the cloud fetches with the scope's credential), cached for offline, and `offline` for a
    /// partitioned client.  In-process against `SimDataService`; the compose variant is below.
    @Test func twoClientsFetchTheSameAPISource() async throws {
        let sim = try await Simulation(name: "data-api-fetch", seed: Simulation.seed(2308), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        let service = SimDataService()
        let url = "https://crm.example.com/people"
        service.serve(url, records: (0..<60).map { ["name": "Person \($0)", "city": "City \($0 % 7)"] }, pageSize: 25)
        service.allow("crm.example.com")
        let source = try #require(await base.ana.perform(AddSource(name: "CRM", kind: .http) { $0.http.url = url; $0.http.credentialName = "crm" }))
            .insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        try await sim.settle()
        let tables = try await base.clients.asyncMap { client -> DataTable in
            let name = client.name
            let data = DataSourceClient(transport: service.transport(link: client.link), directory: sim.directory.appending(components: name, "data"),
                                        token: { "token-\(name)" })
            let model = DataModel(client.state)
            let info = try #require(model.source(source))
            if client === base.ana {
                // No credential yet: the service refuses, as the server does.
                await #expect(throws: DataServiceError.credentialMissing) { try await data.fetchAll(documentID: client.documentID, source: info, model: model) }
                var put = Wiretuner_Data_V1_PutCredentialRequest()
                put.name = "crm"
                put.kind = .bearer
                put.host = "crm.example.com"
                put.token = "sk_live_simulated_secret"
                let stored = try await data.putCredential(put)
                #expect(stored.name == "crm")
            }
            return try await data.fetchAll(documentID: client.documentID, source: info, model: model)
        }
        #expect(tables[0].records.count == 60 && tables[0] == tables[1])
        #expect(tables[0].records[59].values["name"] == "Person 59")
        // Offline: the cache answers, the service is unreachable.
        base.ben.goOffline()
        let data = DataSourceClient(transport: service.transport(link: base.ben.link), directory: sim.directory.appending(components: "ben", "data"),
                                    token: { "token" })
        let info = try #require(DataModel(base.ben.state).source(source))
        await #expect(throws: DataServiceError.offline) { try await data.fetchAll(documentID: base.ben.documentID, source: info, model: DataModel(base.ben.state)) }
        let cached = await data.cachedRecords(documentID: base.ben.documentID, source: source)
        #expect(cached?.records.map(\.values) == tables[1].records.map(\.values))
        await #expect(throws: DataServiceError.offline) { try await data.credentials(documentID: base.ben.documentID) }
        base.ben.goOnline()
        #expect(try await data.credentials(documentID: base.ben.documentID).map(\.name) == ["crm"])
        #expect(service.fetches == 3)
        try await sim.settle()
        try await sim.expectConverged()
    }

    /// An offline day of field and source edits on two clients: every edit survives, the one
    /// register both wrote (the same field renamed on both) is the reconnect's one entry, and after
    /// *Keep the merged result* both converge.
    @Test func anOfflineDayOfFieldAndSourceEditsOnTwoClients() async throws {
        let sim = try await Simulation(name: "data-offline-day", seed: Simulation.seed(2309), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        let source = try #require(await base.ana.perform(AddSource(name: "CRM", kind: .http) { $0.http.url = "https://crm.example.com/a" }))
            .insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        try await sim.settle()
        Self.offline(base)
        var random = sim.random.fork(23)
        for hour in 0..<24 {
            await base.ana.perform(SetFieldFormat(base.name, pattern: "p\(hour)"))
            await base.ben.perform(SetSourceParams(source, [(name: "page", defaultValue: "\(random.below(100))")]))
            sim.advance(by: .seconds(3600))
        }
        #expect(await base.ana.perform(RenameField(base.city, to: "town")) != nil)
        #expect(await base.ben.perform(RenameField(base.city, to: "place")) != nil)
        #expect(await base.ana.perform(AddFields("zip")) != nil)
        #expect(await base.ben.perform(SetFieldType(base.name, to: .number)) != nil)
        try await Self.reconnect(sim, base)
        try await base.ben.waitFor("needs review") { $0 == .needsReview }
        let review = try #require(await base.ben.client.pendingReview)
        #expect(review.entries.map(\.node) == [WellKnown.settings])
        #expect(review.entries[0].kinds.contains(.sameRegister))
        #expect(review.entries[0].properties.map(\.property).contains(.register(DataFieldsPaths.name(base.city))))
        try await base.ben.keepMerged()
        try await sim.settle()
        try await sim.expectConverged()
        let model = DataModel(base.ana.state)
        #expect(["town", "place"].contains(model.field(base.city)?.name ?? ""))
        #expect(model.field(named: "zip") != nil && model.field(base.name)?.kind == .number && model.field(base.name)?.pattern == "p23")
        #expect(model.source(source)?.spec.http.params.count == 1)
    }

    /// A package of a document with an API source and a stored credential holds the credential's
    /// name, never its secret, and reads back to the same state.
    @Test func aPackageRoundTripCarriesNoCredentialMaterial() async throws {
        let sim = try await Simulation(name: "data-package", seed: Simulation.seed(2310), scale: 0.002)
        defer { Task { await sim.shutdown() } }
        let base = try await Self.start(sim)
        let secret = "sk_live_package_secret_7f3a"
        let service = SimDataService()
        service.allow("crm.example.com")
        let data = DataSourceClient(transport: service.transport(link: base.ana.link), directory: sim.directory.appending(components: "ana", "data"),
                                    token: { "token" })
        var put = Wiretuner_Data_V1_PutCredentialRequest()
        put.name = "crm-token"
        put.kind = .bearer
        put.host = "crm.example.com"
        put.token = secret
        _ = try await data.putCredential(put)
        #expect(service.secrets == [secret])
        // Credential headers are refused in the document itself.
        #expect(await base.ana.perform(AddSource(name: "Leak", kind: .http) {
            $0.http.url = "https://crm.example.com/x"
            $0.http.headers = [.with { $0.name = "Authorization"; $0.value = "Bearer \(secret)" }]
        }) == nil)
        #expect(await base.ana.perform(AddSource(name: "CRM", kind: .http) { $0.http.url = "https://crm.example.com/people"; $0.http.credentialName = "crm-token" }) != nil)
        try await sim.settle()
        let state = base.ben.state
        let contents = DocumentPackage.contents(of: state, info: DocumentPackage.Info(documentID: sim.documentID, title: "Letters"),
                                                page: PageList(state).pages[0].rect, cached: { _ in nil })
        let package = try PackageWriter().data(contents).data
        let opened = try DocumentPackage.reader.open(package)
        let reopened = try DocumentPackage.state(of: opened)
        #expect(reopened.stateHash == state.stateHash)
        #expect(DataModel(reopened).activeSource?.spec.http.credentialName == "crm-token")
        let snapshot = Data(Snapshot.encode(reopened))
        let manifest = try Data(opened.manifest.jsonUTF8Data())
        for bytes in [package, snapshot, manifest] + Array(opened.blobs.values) {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "the secret is in the package")
            #expect(bytes.range(of: Data("Bearer".utf8)) == nil)
        }
        #expect(snapshot.range(of: Data("crm-token".utf8)) != nil, "the scan reads the document's strings")
    }
}

/// DATA-023's compose scenario: two clients fetching the same API source through the compose
/// stack's data service receive identical records.  Runs only with `WT_SIM_COMPOSE=1` and
/// `WT_SIM_DATA_URL`, an https JSON API the compose server can reach (the SSRF guard refuses
/// private addresses, so the stack has no fixture of its own) whose records carry `name`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WT_SIM_COMPOSE"] == "1"
                && ProcessInfo.processInfo.environment["WT_SIM_DATA_URL"] != nil), .serialized, .timeLimit(.minutes(5)))
struct ComposeDataScenarioTests {
    /// alice's account id (the personal scope a host is allowed in).
    nonisolated static func accountID() async throws -> String {
        let token = try await ComposeSimulationTests.PasswordTokens.shared.accessToken(forceRefresh: false)
        let api = ComposeSimulationTests.api
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: api.host!, port: api.port ?? 80), transportSecurity: .plaintext)
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/0.0.1/1", forKey: "wt-client")
        metadata.addString(Simulation.deviceID(for: "simulation"), forKey: "wt-device")
        return try await withGRPCClient(transport: transport) { client in
            try await Wiretuner_Account_V1_AccountService.Client(wrapping: client).me(Wiretuner_Account_V1_MeRequest(), metadata: metadata).account.id
        }
    }

    @Test func twoClientsFetchTheSameAPISourceThroughTheComposeStack() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["WT_SIM_DATA_URL"])
        let host = try #require(URL(string: url)?.host)
        let sim = try await ComposeSimulationTests.simulation("compose-data-fetch", seed: 2311)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana", user: ComposeSimulationTests.alice)
        let ben = try await sim.addClient("ben", user: ComposeSimulationTests.alice)
        #expect(await ana.perform(AddFields("name")) != nil)
        let source = try #require(await ana.perform(AddSource(name: "API", kind: .http) { $0.http.url = url }))
            .insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        try await sim.settle()
        var tables: [DataTable] = []
        for client in [ana, ben] {
            let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(clientVersion: "0.0.1/1", deviceID: client.device)
            let transport = try GRPCDataSourceTransport<HTTP2ClientTransport.Posix>.http2(api: ComposeSimulationTests.api, identity: identity)
            defer { Task { await transport.close() } }
            let data = DataSourceClient(transport: transport, directory: sim.directory.appending(components: client.name, "data"),
                                        token: { try await ComposeSimulationTests.PasswordTokens.shared.accessToken(forceRefresh: false) })
            if client === ana {
                var scope = Wiretuner_Data_V1_Scope()
                scope.accountID = try await Self.accountID()
                _ = try await data.putAllowedHost(scope: scope, host: host)
            }
            let model = DataModel(client.state)
            tables.append(try await data.fetchAll(documentID: client.documentID, source: try #require(model.source(source)), model: model))
        }
        #expect(!tables[0].records.isEmpty && tables[0] == tables[1])
        try await sim.expectConverged()
    }
}
