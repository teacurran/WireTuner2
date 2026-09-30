import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// What the review sheet lists after a reconnect for LIB-013's concurrent symbol import (nothing:
/// two symbols and no conflict rows) and DATA-011's concurrent script save (the script, with both
/// sources).
@Suite struct ImportAndScriptReviewTests {
    @Test func twoPeopleImportingTheSameSymbolListNoConflictRows() throws {
        var source = DocumentCore(state: EngineState(), replica: 0xC)
        let created = try source.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 10)), recording: Reconnect.recording)
        let rect = try #require(created?.change?.createdObjects.first)
        _ = try source.perform(ConvertToSymbol([rect], name: "Badge"), recording: Reconnect.recording)
        let symbol = try #require(Symbols.symbols(in: source.state).first)
        let package = SymbolPackage(symbols: [symbol], from: source.state)
        var world = Reconnect()
        try world.byMe(ImportSymbols(package))
        try world.byThem(ImportSymbols(package))
        let divergence = world.measure()
        #expect(!divergence.hasRows, "\(divergence.entries)")
        world.upload()
        #expect(Symbols.symbols(in: world.mine.state).count == 2)
    }

    @Test func concurrentScriptSavesAreListedWithBothSources() throws {
        var world = Reconnect()
        let script = try #require(try world.shared(SaveScript(name: "Tidy", source: "console.log(1)"))).createdNodes[0]
        try world.byMe(SaveScript(script, name: "Tidy", source: "console.log('mine')"))
        try world.byThem(SaveScript(script, name: "Tidy", source: "console.log('theirs')"))
        let divergence = world.measure()
        let entry = try #require(divergence.entries.first { $0.node == script })
        #expect(entry.kinds.contains(.sameRegister) && entry.localWriteLost == (DocumentScript.script(script, in: world.mine.state)?.source == "console.log('theirs')"))
        #expect(entry.localPaths.contains(ScriptFields.source) && entry.remotePaths.contains(ScriptFields.source))
        world.upload()
        #expect(DocumentScript.script(script, in: world.theirs.state)?.source == DocumentScript.script(script, in: world.mine.state)?.source)
    }
}
