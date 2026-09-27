import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// LIB-011's remainder: the *Kind* and *Date* columns, the *Show* filter, master pages in the list,
/// and the drags from, to and within the list.
@Suite(.serialized) @MainActor struct LibraryExtrasTests {
    typealias Fixture = SymbolLibraryPanelTests.Fixture

    /// Two symbols, "Alpha" (a brush tip) and "Beta".
    static func symbols(_ f: Fixture) async throws -> (alpha: OpID, beta: OpID) {
        let rects = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 40, y: 0, width: 20, height: 20)])
        for (rect, name) in zip(rects, ["Alpha", "Beta"]) {
            f.select([rect.opID])
            await f.settle(f.model.newSymbol())
            let row = try #require(f.model.rows.first { $0.name == "Symbol" || $0.name.hasPrefix("Symbol") })
            f.model.beginRename(row.id)
            f.model.renameText = name
            await f.settle(f.model.commitRename())
        }
        let alpha = try #require(f.model.rows.first { $0.name == "Alpha" }).id
        let beta = try #require(f.model.rows.first { $0.name == "Beta" }).id
        var props = Wiretuner_Doc_V1_NodeProps()
        props.symbol.usage = .brushTip
        _ = await f.document.perform(OpsCommand("Usage", ops: [Ops.set(alpha, [RegisterPath([NodeKind.symbol.rawValue, 2])], values: props)])).value
        await f.document.settle()
        return (alpha, beta)
    }

    @Test func kindAndDateColumnsSortAndTheShowFilterHides() async throws {
        let f = Fixture()
        SymbolChangeLog.follow(f.controller) { _ in "Priya" }
        let (alpha, beta) = try await Self.symbols(f)
        #expect(f.model.rows.first { $0.id == alpha }?.usage == .brushTip && f.model.rows.first { $0.id == beta }?.usage == .graphic)
        f.model.sort(by: .kind)
        #expect(f.model.rows.map(\.id) == [beta, alpha], "graphics before brush tips")
        // The newest change to Beta dates it after Alpha.
        f.model.beginRename(beta)
        f.model.renameText = "Beta 2"
        await f.settle(f.model.commitRename())
        let changed = try #require(f.model.rows.first { $0.id == beta }?.changed)
        #expect(changed.author == nil, "a local change has no other author")
        f.model.sort(by: .date)
        #expect(f.model.rows.last?.id == beta)
        #expect(SymbolChangeLog.tooltip(SymbolChangeLog.Entry(date: Date(), author: "Priya")).hasSuffix("by Priya"))
        #expect(!SymbolChangeLog.tooltip(changed).contains(" by "))
        // A remote change names its author.
        var remote = Wiretuner_Doc_V1_NodeProps()
        remote.symbol.common.name = "Gamma"
        await f.document.receiveRemote(OpsCommand("Rename", ops: [Ops.set(beta, [RegisterPath([NodeKind.symbol.rawValue, 1, 1])], values: remote)]))
        #expect(SymbolChangeLog.shared.entry(beta, in: f.document)?.author == "Priya")
        // The Show submenu.
        let items = f.model.optionsMenu()
        let hideGraphics = try #require(items.first { $0.title == "Hide Graphics" })
        hideGraphics.action()
        #expect(f.model.rows.map(\.id) == [alpha] && f.model.optionsMenu().contains { $0.title == "Show Graphics" })
        f.model.optionsMenu().first { $0.title == "Show Graphics" }?.action()
        #expect(f.model.rows.count == 2)
        #expect(SymbolLibraryKind(.hoseElement).title == "Hose element" && SymbolLibraryKind.masterPage.plural == "Master Pages")
        #expect(SymbolLibraryKind.brushTip.plural == "Brush Tips" && SymbolLibraryKind.hoseElement.plural == "Hose Elements")
        PanelRendering.host(SymbolLibraryPanelBody(model: f.model))
        // A change without a record is not logged.
        SymbolChangeLog.shared.record(ContentChange(summary: ChangeSummary(), before: DisplayList(canvas: "c", items: []), after: DisplayList(canvas: "c", items: []), change: nil),
                                      document: f.document, author: nil)
    }

    @Test func masterPagesAreListedWithTheirPages() async throws {
        let f = Fixture()
        _ = await f.document.perform(NewMasterPage(name: "Letterhead")).value
        await f.document.settle()
        let master = try #require(f.document.pageList.masters.first)
        _ = await f.document.perform(ApplyMasterPage(master.id, to: [f.document.pageList.pages[0].id])).value
        await f.document.settle()
        let row = try #require(f.model.rows.first { $0.kind == .master })
        #expect(row.name == "Letterhead" && row.usage == .masterPage && row.count == 1)
        // Masters are not renamed or removed from the Library.
        f.model.click(row.id)
        f.model.beginRename(row.id)
        #expect(f.model.renaming == nil && f.model.remove() == nil)
        // A master row's double-click opens the master in its tab (DOC-012's rest).
        let opened = TestBox<[OpID]>([])
        f.model.editMaster = { opened.value.append($0) }
        SymbolLibraryPanelBody.editing(row.id, f.model)()
        #expect(opened.value == [master.id])
        f.model.optionsMenu().first { $0.title == "Hide Master Pages" }?.action()
        #expect(!f.model.rows.contains { $0.kind == .master })
        f.model.shown.insert(.masterPage)
        PanelRendering.host(SymbolLibraryPanelBody(model: f.model))
    }

    @Test func dragsPlaceCreateReplaceMoveAndDuplicate() async throws {
        let f = Fixture()
        let (alpha, beta) = try await Self.symbols(f)
        // A symbol dragged onto the canvas places an instance at the drop point.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.library.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(SymbolLibraryDrag.instancePayload(beta, document: f.document), forType: ObjectDragging.type)
        let before = f.instances.count
        await ObjectDragging(editing: f.controller.objectEditing).drop(pasteboard, at: Point(x: 300, y: 300))?.value
        await f.document.settle()
        #expect(f.instances.count == before + 1)
        let placed = try #require(f.instances.first { Symbols.symbol(of: $0, in: f.document.state) == beta && Objects.pasteboardTransform(of: $0, in: f.document.state).tx == 300 })
        _ = placed
        // The providers carry the instance and the rows.
        let row = try #require(f.model.rows.first { $0.id == beta })
        let provider = SymbolLibraryDrag.provider(row, model: f.model)
        #expect(provider.hasItemConformingToTypeIdentifier(SymbolLibraryDrag.objectsType.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(SymbolLibraryDrag.rowsType.identifier))
        let instanceData = try await Self.load(provider, SymbolLibraryDrag.objectsType.identifier)
        #expect(instanceData == SymbolLibraryDrag.instancePayload(beta, document: f.document))
        let rowsData = try await Self.load(provider, SymbolLibraryDrag.rowsType.identifier)
        #expect(String(decoding: rowsData, as: UTF8.self) == SymbolLibraryDrag.rowsPayload([beta]))
        #expect(SymbolLibraryDrag.rows(from: SymbolLibraryDrag.rowsPayload([alpha, beta]), in: f.model) == f.model.rows.map(\.id).filter { [alpha, beta].contains($0) })
        // Option-drag within the list duplicates; onto a folder moves.
        let count = f.model.rows.filter { $0.kind == .symbol }.count
        await f.settle(SymbolLibraryDrag.dropRows([beta], on: nil, model: f.model, option: true))
        #expect(f.model.rows.filter { $0.kind == .symbol }.count == count + 1)
        await f.settle(f.model.newFolder())
        let folder = try #require(f.model.rows.first { $0.kind == .folder })
        await f.settle(SymbolLibraryDrag.dropRows([alpha, folder.id], on: folder, model: f.model, option: false))
        #expect(f.model.rows.first { $0.id == alpha }?.folder == folder.id)
        #expect(SymbolLibraryDrag.dropRows([alpha], on: row, model: f.model, option: false) == nil)
        #expect(SymbolLibraryDrag.dropRows([folder.id], on: folder, model: f.model, option: false) == nil)
        #expect(SymbolLibraryDrag.dropRows([folder.id], on: nil, model: f.model, option: true) == nil)
        // Rows through the providers (as a drop delivers them).
        let rowProvider = NSItemProvider()
        let payload = Data(SymbolLibraryDrag.rowsPayload([beta]).utf8)
        rowProvider.registerDataRepresentation(forTypeIdentifier: SymbolLibraryDrag.rowsType.identifier, visibility: .ownProcess) { done in
            done(payload, nil)
            return nil
        }
        let held = SymbolLibraryDrag.optionHeld
        SymbolLibraryDrag.optionHeld = { true }
        defer { SymbolLibraryDrag.optionHeld = held }
        #expect(SymbolLibraryDrag.handle([rowProvider], on: nil, model: f.model))
        for _ in 0..<50 where f.model.rows.filter({ $0.kind == .symbol }).count < count + 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.model.rows.filter { $0.kind == .symbol }.count == count + 2)
        #expect(!SymbolLibraryDrag.handle([NSItemProvider()], on: nil, model: f.model))
        // Canvas objects dropped on the list make a symbol; on a symbol, the sheet asks, then replaces.
        var asked: [OpID] = []
        var dismissed = 0
        let present = SymbolLibraryDrag.presentReplace, dismiss = SymbolLibraryDrag.dismissReplace
        defer { SymbolLibraryDrag.presentReplace = present; SymbolLibraryDrag.dismissReplace = dismiss }
        SymbolLibraryDrag.presentReplace = { _, symbol in asked.append(symbol) }
        SymbolLibraryDrag.dismissReplace = { dismissed += 1 }
        f.select([])
        #expect(!SymbolLibraryDrag.dropObjects(on: beta, model: f.model) && !SymbolLibraryDrag.dropObjects(on: f.model))
        #expect(SymbolLibraryDrag.confirmReplace(beta, model: f.model) == nil)
        let loose = await f.document.addRectangles([Rect(x: 100, y: 100, width: 10, height: 10), Rect(x: 130, y: 100, width: 10, height: 10)])
        let objects = NSItemProvider()
        objects.registerDataRepresentation(forTypeIdentifier: SymbolLibraryDrag.objectsType.identifier, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        f.select([loose[0].opID])
        let symbols = f.model.rows.filter { $0.kind == .symbol }.count
        #expect(SymbolLibraryDrag.handle([objects], on: nil, model: f.model))
        await f.document.settle()
        #expect(f.model.rows.filter { $0.kind == .symbol }.count == symbols + 1)
        f.select([loose[1].opID])
        #expect(SymbolLibraryDrag.handle([objects], on: f.model.rows.first { $0.id == beta }, model: f.model) && asked == [beta])
        await f.settle(SymbolLibraryDrag.confirmReplace(beta, model: f.model))
        #expect(dismissed == 2 && f.document.undoTitle == "Undo Replace Symbol Artwork")
        // The sheet renders and connects to a presenter.
        f.select([])
        PanelRendering.host(ReplaceArtworkSheet(model: f.model, symbol: beta))
        ReplaceArtworkSheet.replacing(f.model, beta)()
        let presenter = SheetPresenter()
        var shown: [NSWindow] = []
        presenter.present = { shown.append($0) }
        ReplaceArtworkSheet.connect(presenter: presenter)
        SymbolLibraryDrag.presentReplace(f.model, beta)
        SymbolLibraryDrag.dismissReplace()
        #expect(shown.count == 1 && presenter.sheets.isEmpty)
        PanelRendering.host(Text("").symbolLibraryDrags(row, model: f.model).symbolLibraryListDrop(model: f.model))
    }

    /// The bytes a provider hands over for `type`.
    static func load(_ provider: NSItemProvider, _ type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
