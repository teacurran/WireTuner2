import AppIntents
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender
@testable import WireTuner

/// DOC-027: the version 1 App Intents run against a test document through the same host and
/// model commands as the scripting dictionary, labelled "Shortcut: …" (scripting.adoc).
extension ScriptingSurfaces {
    @Suite @MainActor struct DocumentIntentsTests {
        let handle = DocumentHandle.memory(id: "doc-1", title: "Brochure")
        let entity = DocumentEntity(id: "doc-1", name: "Brochure")

        func install(online: Bool = true) {
            let handle = handle
            ScriptingHost.shared.role = { _ in .owner }
            ScriptingHost.shared.isOnline = { online }
            IntentsHost.shared.open = { $0 == "doc-1" ? handle : nil }
            IntentsHost.shared.libraryDocuments = {
                [LibraryDocument(id: "doc-1", spaceID: "s", name: "Brochure"), LibraryDocument(id: "doc-2", spaceID: "s", name: "Spring Catalog"),
                 LibraryDocument(id: "gone", spaceID: "s", name: "Trashed", isTrashed: true)]
            }
        }

        @Test func documentsAreFoundThroughTheLibraryCache() async throws {
            install(online: false)
            let query = DocumentQuery()
            #expect(try await query.entities(matching: "spring").map(\.id) == ["doc-2"])
            #expect(try await query.entities(matching: "zzz").isEmpty)
            #expect(try await query.entities(for: ["doc-1", "gone"]).map(\.name) == ["Brochure"])
            #expect(try await query.suggestedEntities().count == 2)
            #expect(DocumentQuery.matching("BRO", in: DocumentQuery.documents()).map(\.id) == ["doc-1"])
            #expect(String(localized: entity.displayRepresentation.title) == "Brochure")
        }

        @Test func openAndCreateOpenDocuments() async throws {
            install()
            let intent = OpenDocumentIntent()
            intent.document = entity
            _ = try await intent.perform()
            intent.document = DocumentEntity(id: "elsewhere", name: "Elsewhere")
            await #expect(throws: IntentFailure.notFound("Elsewhere")) { _ = try await intent.perform() }
            install(online: false)
            await #expect(throws: IntentFailure.offline("Elsewhere")) { _ = try await intent.perform() }

            var created: [(String, String?)] = []
            let handle = handle
            IntentsHost.shared.create = { name, template in
                created.append((name, template))
                return name == "fail" ? nil : handle
            }
            let create = CreateDocumentIntent()
            create.name = "Memo"
            create.template = DocumentEntity(id: "t1", name: "Letterhead")
            _ = try await create.perform()
            #expect(created.first?.0 == "Memo" && created.first?.1 == "t1")
            create.name = "fail"
            await #expect(throws: IntentFailure.self) { _ = try await create.perform() }
        }

        @Test func addPagesAndFindReplaceAreOneShortcutChangeEach() async throws {
            install()
            await handle.settle()
            _ = handle.perform(NewMasterPage(from: PageList(handle.state).pages[0].id, name: "A"))
            await handle.settle()
            let add = AddPagesIntent()
            add.document = entity
            add.count = 2
            add.width = 200
            add.height = 100
            add.orientation = .portrait
            add.master = "A"
            _ = try await add.perform()
            let pages = PageList(handle.state).pages
            #expect(pages.count == 3 && pages[2].master == PageList(handle.state).masters[0].id)
            add.master = "Missing"
            await #expect(throws: IntentFailure.self) { _ = try await add.perform() }
            add.master = nil
            add.width = -5
            await #expect(throws: IntentFailure.self) { _ = try await add.perform() }

            _ = handle.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "sale Sale"))
            await handle.settle()
            let replace = FindReplaceTextIntent()
            replace.document = entity
            replace.find = "sale"
            replace.replacement = "deal"
            replace.matchCase = true
            _ = try await replace.perform()
            let text = try #require(ScriptObjects.list("objects", in: handle.state)?.first { ScriptObjects.kindName($0, in: handle.state) == "text" })
            #expect(ScriptObjects.get(text, "text", in: handle.state) as? String == "deal Sale")
            replace.find = "zebra"
            _ = try await replace.perform()

            ScriptingHost.shared.role = { _ in .commenter }
            await #expect(throws: IntentFailure.needsEditor("Brochure")) { _ = try await IntentsHost.shared.perform(DocumentTemplate(), label: "x", on: handle) }
            ScriptingHost.shared.role = { _ in .owner }
        }

        @Test func exportReportPrintAndShareProduceTheirResults() async throws {
            install()
            let folder = FileManager.default.temporaryDirectory.appending(path: "WireTunerIntentTests-\(UUID().uuidString)")
            IntentsHost.shared.scratch = { folder }
            var exported: [ExportFormat] = []
            ScriptingHost.shared.export = { _, format, url in
                exported.append(format)
                try? Data("x".utf8).write(to: url)
                return format == .eps ? "EPS failed" : nil
            }
            let export = ExportDocumentIntent()
            export.document = entity
            export.format = .svg
            _ = try await export.perform()
            #expect(exported == [.svg] && FileManager.default.fileExists(atPath: folder.appending(path: "Brochure.svg").path))
            export.format = .eps
            await #expect(throws: IntentFailure.failed("EPS failed")) { _ = try await export.perform() }
            #expect(ExportFormatEntity.allCases.map(\.format).count == 6 && OrientationEntity.landscape.orientation == .landscape)

            let report = GetDocumentReportIntent()
            report.document = entity
            _ = try await report.perform()
            let text = try String(contentsOf: folder.appending(path: "Brochure Report.txt"), encoding: .utf8)
            #expect(text.hasPrefix("Document: Brochure"))

            ScriptingHost.shared.print = { _, preset, _ in preset == nil ? nil : "no presets" }
            let print = PrintDocumentIntent()
            print.document = entity
            _ = try await print.perform()
            print.preset = "Proof"
            await #expect(throws: IntentFailure.failed("no presets")) { _ = try await print.perform() }

            ScriptingHost.shared.shareLink = { _ in "https://links.example/l/abc" }
            let share = ShareLinkIntent()
            share.document = entity
            _ = try await share.perform()
            ScriptingHost.shared.shareLink = { _ in throw ScriptFailure(ScriptFailure.privilege, "Owner only") }
            await #expect(throws: IntentFailure.failed("Owner only")) { _ = try await share.perform() }
            install(online: false)
            await #expect(throws: IntentFailure.offline("Brochure")) { _ = try await share.perform() }
            try? FileManager.default.removeItem(at: folder)
        }

        @Test func failuresHaveLocalizedReasons() {
            for failure in [IntentFailure.offline("A"), .notFound("A"), .needsEditor("A"), .invalid("bad"), .failed("broke")] {
                #expect(!String(localized: failure.localizedStringResource).isEmpty)
            }
        }
    }
}
