import CoreGraphics
import Foundation
import Testing
@testable import WTInterchange

/// Object names over real files that are not in the repository (LIB-030, D-095): with
/// `WT_EXTERNAL_CORPUS` naming a folder, every Illustrator (`.ai`, `.eps`) and FreeHand file under
/// it is opened as a document, and the report -- per file, the names its native art holds, the
/// objects that arrived named, and FreeHand's even/odd paths -- goes to `WT_CORPUS_OUTPUT`
/// (default: a scratch folder) as `object-names.md`.  Without the variable (CI) it does nothing.
@Suite("Object names corpus")
struct ObjectNamesCorpusTests {
    static var output: URL {
        if let path = ProcessInfo.processInfo.environment["WT_CORPUS_OUTPUT"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Corpus.directory().appendingPathComponent("object-names")
    }

    /// The native art of an Illustrator file: a PDF-compatible file's private data, an EPS's
    /// `%AI9_PrivateDataBegin` art, or the PostScript itself.
    static func native(_ data: Data, name: String) -> IllustratorNativeArt? {
        if IllustratorImporter.isPDFCompatible(data), let pdf = try? PDFImporter.document(data, name: name) {
            return IllustratorImporter.nativeData(pdf).map { IllustratorNativeArt(scanning: $0) }
        }
        guard let file = try? EPSFile(data, name: name) else { return nil }
        if file.postscript.range(of: Data("%PDF-".utf8)) != nil { return nil }
        return IllustratorNativeArt(scanning: IllustratorPrivateData.eps(file.postscript) ?? file.postscript)
    }

    /// The names `art` holds.
    static func names(_ art: IllustratorNativeArt) -> Set<String> {
        Set(art.layers.flatMap { $0.leaves.compactMap(\.name) + $0.groups.map(\.name) })
    }

    @Test("Object names in the external corpus", .enabled(if: FreeHandCorpusTests.corpus != nil))
    func externalCorpus() throws {
        // On a thread with an import's stack: the legacy reader's nesting outgrows a test's.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        let thread = Thread {
            do { try ObjectNamesCorpusTests.report() } catch { failure = error }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        if let failure { throw failure }
    }

    static func report() throws {
        let root = try #require(FreeHandCorpusTests.corpus)
        try FileManager.default.createDirectory(at: ObjectNamesCorpusTests.output, withIntermediateDirectories: true)
        var lines = ["# Object names", "", "|File|Format|Native names|Named objects|Even/odd paths|Scan|Note|", "|---|---|---|---|---|---|---|"]
        var totals: [String: (files: Int, native: Int, named: Int)] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if ["ai", "eps"].contains(ext) || ImportFormat.freehand.fileExtensions.contains(ext) { urls.append(url) }
        }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let data = try Data(contentsOf: url)
            let format = ImportFormat.freehand.fileExtensions.contains(url.pathExtension.lowercased()) ? "FreeHand" : url.pathExtension.lowercased()
            let scanStart = Date()
            let art = format == "FreeHand" ? nil : ObjectNamesCorpusTests.native(data, name: url.lastPathComponent)
            let scanSeconds = Date().timeIntervalSince(scanStart)
            let nativeNames = art.map(ObjectNamesCorpusTests.names) ?? []
            var named = 0
            var evenOdd = 0
            var note = ""
            do {
                let document = try ImportRegistry.standard.document(data, name: url.lastPathComponent)
                let nodes = document.pages.flatMap(\.nodes).flatMap(\.descendants)
                for node in nodes {
                    if case .group(let group) = node, group.role != .group { continue }
                    guard let name = node.name else { continue }
                    if format == "FreeHand" ? name != "Blend" : nativeNames.contains(name) { named += 1 }
                }
                evenOdd = nodes.filter { if case .path(let path) = $0 { return path.fillRule == .evenOdd }; return false }.count
            } catch {
                note = "\(error)".replacingOccurrences(of: "|", with: "/")
            }
            let held = art?.nameCount ?? 0
            totals[format, default: (0, 0, 0)].files += 1
            totals[format, default: (0, 0, 0)].native += held
            totals[format, default: (0, 0, 0)].named += named
            lines.append("|\(relative)|\(format)|\(held)|\(named)|\(format == "FreeHand" ? String(evenOdd) : "")|\(String(format: "%.2f s", scanSeconds))|\(note)|")
        }
        lines += ["", "|Format|Files|Native names|Named objects|", "|---|---|---|---|"]
        lines += totals.keys.sorted().map { "|\($0)|\(totals[$0]!.files)|\(totals[$0]!.native)|\(totals[$0]!.named)|" }
        try (lines.joined(separator: "\n") + "\n").write(to: ObjectNamesCorpusTests.output.appendingPathComponent("object-names.md"), atomically: true, encoding: .utf8)
    }
}
