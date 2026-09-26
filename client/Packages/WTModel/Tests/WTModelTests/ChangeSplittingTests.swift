import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto

/// TYPE-008's remainder: an import over the server's 10,000 ops per change goes up as consecutive
/// changes that together make exactly the one-change result (importing-text.adoc, "Server").
@Suite struct ChangeSplittingTests {
    /// Paragraphs that alternate two alignments and colors, so every paragraph and run writes ops.
    static func file(_ count: Int) -> ImportedTextFile {
        ImportedTextFile(paragraphs: (0..<count).map { index in
            ExportParagraph([ExportTextRun("line \(index)", attributes: ExportTextAttributes(size: index.isMultiple(of: 2) ? 10 : 12))],
                            style: ExportParagraphStyle(alignment: index.isMultiple(of: 2) ? .center : .right, spaceAfter: Double(index % 3)))
        }, plain: false)
    }

    @Test func aLargeImportSplitsIntoPartsThatMakeTheSameText() throws {
        // A small limit stands in for the server's 10,000 (the rule is the same at any size).
        let limit = 40
        let command = ImportText(Self.file(60), frame: .point(Point(x: 0, y: 0)))
        var whole = Replica(0xA)
        let one = try #require(try whole.perform(command))
        #expect(one.ops.count > 2 * limit && ChangeSplitting.opLimit == 10_000)

        var split = Replica(0xA)
        let parts = try ChangeSplitting.split(command, in: split.state, replica: 0xA, limit: limit)
        #expect(parts.count == (one.ops.count + limit - 1) / limit && parts.map(\.label).first == "Import text [1/\(parts.count)]")
        let recording = DocumentCore.Recording(group: 3, limit: 100, now: Replica.now)
        var changes: [Wiretuner_Doc_V1_Change] = []
        for part in parts {
            let outcome = try #require(try split.core.perform(part, recording: recording))
            changes.append(try #require(outcome.change))
        }
        #expect(changes.allSatisfy { $0.ops.count <= limit } && changes.flatMap(\.ops).count == one.ops.count)
        // The same text, paragraphs and marks as the one-change import (positions are drawn at random).
        func block(_ replica: Replica) -> TextNode? {
            replica.state.store.children(WellKnown.layers).flatMap { replica.state.liveChildren($0) }.compactMap { TextNode($0, in: replica.state) }.first
        }
        let a = try #require(block(whole)?.sequence), b = try #require(block(split)?.sequence)
        #expect(a.string == b.string && a.string.split(separator: "\n").count == 60)
        // One undo step takes the whole import back.
        split.undo()
        #expect(split.state.store.children(WellKnown.layers).flatMap { split.state.liveChildren($0) }.isEmpty)
    }

    @Test func aSmallCommandIsItsOwnChange() throws {
        let command = ImportText(Self.file(3), frame: .point(.zero))
        let parts = try ChangeSplitting.split(command, in: EngineState())
        #expect(parts.count == 1 && parts[0].label == "Import text")
        #expect(try ChangeSplitting.split(command, in: EngineState(), limit: 0).count == 1)
        // A part rebuilt against a state other than its plan still takes its own slice.
        let tiny = try ChangeSplitting.split(command, in: EngineState(), limit: 5)
        var replica = Replica(0xB)
        for part in tiny { _ = try replica.perform(part) }
        #expect(tiny.count > 1 && tiny[0].coalescing == .none)
    }
}
