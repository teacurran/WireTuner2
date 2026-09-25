import Foundation
import Synchronization
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// DRAW-038: `.wthose` bundles and the hose library.
@Suite struct HoseLibraryTests {
    /// A fresh directory under the temporary folder, removed by `body`'s end.
    static func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoseLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// A document set with a square and a symbol instance.
    static func documentSet() throws -> (replica: Replica, set: OpID) {
        var a = Replica(0xA)
        let set = try HoseSetTests.set(&a, name: "Mixed")
        try HoseSetTests.addSquare(&a, to: set)
        let artwork = try LayerFixture.object(LayerFixture.rect(on: nil, x: 60), on: &a)
        try a.perform(AddAppearance.fill([artwork], Appearances.basicFill(red: 0, green: 1, blue: 0)))
        try a.perform(AddAppearance.stroke([artwork], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 2)))
        try a.perform(AddHoseObject(set, payload: ClipboardPayload(copying: [artwork], from: a.state)))
        try a.perform(SetHoseOptions(set, [.rotation(.incremental), .angle(0.2)]))
        return (a, set)
    }

    @Test func aSetRoundTripsThroughABundleLosslessly() async throws {
        try await Self.withDirectory { root in
            let (a, set) = try Self.documentSet()
            let id = UUID()
            let bundle = try HoseBundle(set: set, in: a.state, libraryID: id)
            #expect(bundle.name == "Mixed" && bundle.libraryID == id)
            let url = root.appendingPathComponent("Mixed.wthose")
            try bundle.write(to: url, preview: Data([1, 2, 3]))
            let read = try HoseBundle.read(from: url)
            #expect(read == bundle && read.tree.children.count == 2 && read.tree.children[1].stackOrder != nil)
            // Into another document: the same set, objects and options.
            var b = Replica(0xB)
            try b.perform(ImportHoseSet(read))
            let copied = try #require(HoseSets.set(libraryID: id, in: b.state))
            #expect(copied.options.rotation == .incremental && copied.options.angle == 0.2 && copied.objects.count == 2)
            let there = NodeTree(copied.objects[1], state: b.state)
            let here = NodeTree(HoseSets.set(set, in: a.state)!.objects[1], state: a.state)
            #expect(there.props.rect.size == here.props.rect.size && there.stackOrder == here.stackOrder && there.transform == here.transform)
            #expect(there.props.rect.appearance.fills.map(\.settings) == here.props.rect.appearance.fills.map(\.settings))
            #expect(there.props.rect.appearance.strokes.map(\.settings) == here.props.rect.appearance.strokes.map(\.settings))
            // Rewriting without a preview removes the old one.
            try bundle.write(to: url)
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("preview.png").path))
        }
    }

    @Test func unreadableBundlesAreRefused() async throws {
        try await Self.withDirectory { root in
            #expect(throws: HoseError.unreadableBundle) { try HoseBundle(tree: NodeTree(props: Wiretuner_Doc_V1_NodeProps())) }
            #expect(throws: HoseError.unreadableBundle) { try HoseBundle(decoding: [0xFF, 0xFF, 0xFF]) }
            #expect(throws: HoseError.unreadableBundle) { try HoseBundle(decoding: ClipboardPayload(nodes: []).encoded()) }
            let a = Replica(0xA)
            #expect(throws: HoseError.notASet(WellKnown.layers)) { try HoseBundle(set: WellKnown.layers, in: a.state) }
            #expect(throws: (any Error).self) { try HoseBundle.read(from: root.appendingPathComponent("missing.wthose")) }
        }
    }

    @Test func theFirstLaunchInstallsTheDefaultsAndRestoreBringsThemBack() async throws {
        try await Self.withDirectory { root in
            let library = HoseLibrary(directory: root.appendingPathComponent("Graphic Hoses"))
            let installed = try await library.prepare()
            #expect(installed.map(\.name) == ["Dots", "Leaves", "Stars"])
            #expect(try await library.load(installed[2]).libraryID == HoseDefaults.bundles[1].libraryID)
            try await library.delete(installed[0])
            // Not the first launch any more: nothing is reinstalled.
            #expect(try await library.prepare().map(\.name) == ["Leaves", "Stars"])
            try await library.restoreDefaults()
            #expect(await library.entries().map(\.name) == ["Dots", "Leaves", "Stars"])
            try await library.restoreDefaults()
            #expect(await library.entries().count == 3)
            #expect(HoseLibrary.defaultDirectory().path.hasSuffix("WireTuner/Graphic Hoses"))
            #expect(library.directory.lastPathComponent == "Graphic Hoses")
        }
    }

    @Test func savingReplacingAndImporting() async throws {
        try await Self.withDirectory { root in
            let library = HoseLibrary(directory: root)
            let (a, set) = try Self.documentSet()
            var bundle = try HoseBundle(set: set, in: a.state)
            bundle.tree.props.hoseSet.common.note = ""
            let saved = try await library.save(bundle, preview: Data([9]))
            #expect(saved.name == "Mixed" && saved.previewURL != nil)
            #expect(try await library.load(saved).libraryID != nil)
            let again = try await library.save(bundle)
            #expect(again.name == "Mixed-2" && again.previewURL == nil)
            // An edit that renames the set renames the bundle.
            var renamed = try await library.load(again)
            renamed.tree.props.hoseSet.common.name = "Party/Mix"
            let moved = try await library.replace(again, with: renamed)
            #expect(moved.name == "Party-Mix" && !FileManager.default.fileExists(atPath: again.url.path))
            let kept = try await library.replace(moved, with: renamed)
            #expect(kept == moved)
            // A dropped bundle is copied in.
            let elsewhere = root.appendingPathComponent("drop").appendingPathComponent("Gift.wthose")
            var gift = bundle
            gift.tree.props.hoseSet.common.name = ""
            try gift.write(to: elsewhere, preview: Data([7]))
            let imported = try await library.importBundle(at: elsewhere)
            #expect(imported.name == "Hose" && imported.previewURL != nil)
            #expect(await library.entries().map(\.name) == ["Hose", "Mixed", "Party-Mix"])
            await #expect(throws: (any Error).self) { try await library.importBundle(at: root.appendingPathComponent("nothing")) }
        }
    }

    @Test func theWatcherPicksUpADroppedFileWithinASecond() async throws {
        try await Self.withDirectory { root in
            let library = HoseLibrary(directory: root.appendingPathComponent("Library"))
            // The names reported and when the report came (the watcher's latency, measured on its own
            // queue so a loaded test run's task scheduling does not count).
            let seen = Mutex<(names: [String], at: Date?)>(([], nil))
            try await library.startWatching { entries in
                let names = entries.map(\.name)
                seen.withLock { if $0.at == nil, names.contains("Dropped") { $0 = (names, Date()) } }
            }
            // Dropped by someone else (the Finder, another window).
            let start = Date()
            try HoseDefaults.bundles[0].write(to: root.appendingPathComponent("Library").appendingPathComponent("Dropped.wthose"))
            while seen.withLock({ $0.at == nil }), Date().timeIntervalSince(start) < 5 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let report = seen.withLock { $0 }
            #expect(report.names == ["Dropped"])
            #expect(report.at.map { $0.timeIntervalSince(start) < 1 } == true)
            await library.stopWatching()
            await library.stopWatching()
            // Watching again replaces the previous source.
            try await library.startWatching { _ in }
            try await library.startWatching { _ in }
            await library.stopWatching()
        }
    }

    @Test func theDefaultsAreWellFormedSets() throws {
        var a = Replica(0xA)
        for bundle in HoseDefaults.bundles {
            try a.perform(ImportHoseSet(bundle))
        }
        let sets = HoseSets.list(in: a.state)
        #expect(Set(sets.map(\.name)) == ["Dots", "Stars", "Leaves"] && sets.allSatisfy { !$0.objects.isEmpty && $0.libraryID != nil })
        for set in sets {
            for object in set.objects {
                let bounds = try #require(Objects.bounds(of: object, in: a.state))
                #expect(abs(bounds.midX) < 1 && abs(bounds.midY) < 1)
            }
        }
    }
}
