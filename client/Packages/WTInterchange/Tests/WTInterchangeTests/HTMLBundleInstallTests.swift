// WEB-009's package half: a 50-page publish with its progress and cancellation, and a bundle put in
// place as a whole -- assembled in a hidden sibling and swapped in only when complete, so a
// cancelled or failed publish leaves the previous bundle (or no folder) and never a partial one.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct HTMLBundleInstallTests {
    /// `count` pages, each with a filled rectangle.
    static func scene(pages count: Int) -> ExportScene {
        Corpus.scene((0..<count).map { index in
            Corpus.page([Corpus.path(Corpus.rect(10 + Double(index % 10), 10, 40, 30), [Corpus.fill(.solid(Corpus.red))])])
        })
    }

    /// Everything in `folder`: relative path to bytes.
    static func contents(_ folder: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))] = try? Data(contentsOf: url)
        }
        return result
    }

    /// The hidden siblings a publish assembles in, still beside `folder`.
    static func siblings(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(HTMLBundle.stagingPrefix(folder)) }
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    @Test func fiftyPagesPublishWithProgressAfterEachPage() throws {
        let steps = Steps()
        let bundle = try HTMLPublisher(settings: HTMLPublishSettings(pageMode: .separateFiles)).publish(Self.scene(pages: 50)) { done, total in
            #expect(total == 50)
            steps.append(done)
        }
        #expect(steps.all == Array(1...50))
        #expect(bundle.files.filter { $0.path.hasPrefix("pages/") }.count == 50 && bundle.file("page-50.html") != nil)
        let folder = Corpus.directory().appendingPathComponent("Fifty")
        let written = Steps()
        #expect(try bundle.install(at: folder) { done, _ in written.append(done) }.count == bundle.files.count)
        #expect(written.all == Array(1...bundle.files.count))
        #expect(Self.contents(folder) == Dictionary(uniqueKeysWithValues: bundle.files.map { ($0.path, $0.data) }))
        #expect(Self.siblings(folder).isEmpty)
    }

    @Test func aCancelledPublishStopsBetweenPages() async throws {
        let steps = Steps()
        let task = Task.detached {
            try HTMLPublisher().publish(Self.scene(pages: 50)) { done, _ in
                steps.append(done)
                if done == 10 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(steps.all == Array(1...10))
    }

    @Test func republishingSwapsTheWholeBundleInAndKeepsUnchangedFiles() throws {
        let root = Corpus.directory()
        let folder = root.appendingPathComponent("Site")
        let first = try HTMLPublisher().publish(Self.scene(pages: 3))
        try first.install(at: folder)
        let stable = folder.appendingPathComponent("style.css")
        let date = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: stable.path)
        // Unchanged: nothing changed, the unchanged file keeps its date.
        #expect(try first.install(at: folder).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: stable.path)[.modificationDate] as? Date) == date)
        // Two pages now: page 3's file goes with the previous bundle, and so does a stray file.
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let second = try HTMLPublisher().publish(Self.scene(pages: 2))
        #expect(try second.install(at: folder).contains("index.html"))
        #expect(Self.contents(folder) == Dictionary(uniqueKeysWithValues: second.files.map { ($0.path, $0.data) }))
        #expect(Self.siblings(folder).isEmpty)
        // A sibling left by a publish that never finished is cleared.
        let left = root.appendingPathComponent(HTMLBundle.stagingPrefix(folder) + "left")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try second.install(at: folder)
        #expect(Self.siblings(folder).isEmpty)
    }

    @Test func aCancelledOrFailedInstallLeavesThePreviousBundle() async throws {
        let folder = Corpus.directory().appendingPathComponent("Site")
        let previous = try HTMLPublisher().publish(Self.scene(pages: 2))
        try previous.install(at: folder)
        let before = Self.contents(folder)
        let next = try HTMLPublisher(settings: HTMLPublishSettings(pageMode: .separateFiles)).publish(Self.scene(pages: 5))
        // Cancelled after three files.
        let task = Task.detached {
            try next.install(at: folder) { done, _ in if done == 3 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Self.contents(folder) == before && Self.siblings(folder).isEmpty)
        // Cancelled after the last file, before the swap.
        let late = Task.detached {
            try next.install(at: folder) { done, total in if done == total { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        await #expect(throws: CancellationError.self) { try await late.value }
        #expect(Self.contents(folder) == before)
        // A file that cannot be written (a folder where a file goes).
        var broken = next
        broken.files.append((path: "index.html/inner", data: Data()))
        #expect(throws: ExportError.self) { try broken.install(at: folder) }
        #expect(Self.contents(folder) == before && Self.siblings(folder).isEmpty)
        // A parent that cannot be created.
        let blocked = folder.appendingPathComponent("index.html").appendingPathComponent("Site")
        #expect(throws: ExportError.self) { try next.install(at: blocked) }
        // Cancelled before it starts: no folder at all.
        let fresh = Corpus.directory().appendingPathComponent("Fresh")
        let early = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try next.install(at: fresh)
        }
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(!FileManager.default.fileExists(atPath: fresh.path) && Self.siblings(fresh).isEmpty)
    }

    @Test func aVolumeWithoutSwapMovesThePreviousBundleAside() throws {
        let root = Corpus.directory()
        let folder = root.appendingPathComponent("Site")
        let bundle = try HTMLPublisher().publish(Self.scene(pages: 1))
        try bundle.install(at: folder)
        let staging = root.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: staging.appendingPathComponent("index.html"))
        try HTMLBundle.replace(folder, with: staging) { _, _ in -1 }
        #expect(Self.contents(folder) == ["index.html": Data("a".utf8)] && Self.siblings(folder).isEmpty)
        // The move in fails: the previous folder comes back.
        let missing = root.appendingPathComponent("missing")
        #expect(throws: (any Error).self) { try HTMLBundle.replace(folder, with: missing) { _, _ in -1 } }
        #expect(Self.contents(folder) == ["index.html": Data("a".utf8)] && Self.siblings(folder).isEmpty)
        #expect(HTMLBundle.swap(missing, folder) != 0)
    }
}
