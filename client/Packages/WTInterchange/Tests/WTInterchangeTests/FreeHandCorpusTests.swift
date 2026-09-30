import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WTInterchange
import WTGeometry
import WTRender

/// The FreeHand importer over real files that are not in the repository (IO-041): with
/// `WT_EXTERNAL_CORPUS` naming a folder, every `.fh*` and `.ft*` file under it is imported and
/// its result recorded -- success or the refusal, the time taken, the object counts and the
/// import notice -- with a PNG of each page, all written to `WT_CORPUS_OUTPUT` (default: a
/// scratch folder) for visual review.  Without the variable (CI) the test does nothing.  A file
/// that fails is reported, not fatal: the suite fails only when the importer crashes or a file
/// that reads produces no artwork.
@Suite("FreeHand corpus")
struct FreeHandCorpusTests {
    static var corpus: URL? {
        ProcessInfo.processInfo.environment["WT_EXTERNAL_CORPUS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    static var output: URL {
        if let path = ProcessInfo.processInfo.environment["WT_CORPUS_OUTPUT"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Corpus.directory().appendingPathComponent("freehand-corpus")
    }

    /// Every FreeHand file under `root`, sorted by path.
    static func files(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if ImportFormat.freehand.fileExtensions.contains(ext) { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    @Test("Every FreeHand file of the external corpus imports", .enabled(if: FreeHandCorpusTests.corpus != nil))
    func externalCorpus() throws {
        let root = try #require(FreeHandCorpusTests.corpus)
        let output = FreeHandCorpusTests.output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines = ["# FreeHand corpus", "", "Corpus: `\(root.path)`", "",
                     "|File|Result|Time|Version|Pages|Layers|Paths|Groups|Clips|Text|Images|Symbols|Swatches|Notes|", "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        var empty: [String] = []
        for url in FreeHandCorpusTests.files(under: root) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let data = try Data(contentsOf: url)
            let start = Date()
            do {
                let records = try FreeHandImporter.records(data, name: url.lastPathComponent)
                let (pages, scene) = try FreeHandImporter().pages(data, name: url.lastPathComponent)
                let seconds = Date().timeIntervalSince(start)
                let nodes = scene.nodes.flatMap(\.descendants)
                func count(_ match: (ImportedNode) -> Bool) -> Int { nodes.filter(match).count }
                let paths = count { if case .path = $0 { return true }; return false }
                let groups = count { if case .group(let g) = $0 { return g.role != .layer }; return false }
                let clips = count { if case .group(let g) = $0 { return g.clip != nil }; return false }
                let texts = count { if case .text = $0 { return true }; return false }
                let images = count { if case .image = $0 { return true }; return false }
                if nodes.isEmpty { empty.append(relative) }
                let notes = scene.notes.isEmpty ? "" : scene.notes.joined(separator: " ").replacingOccurrences(of: "|", with: "/")
                lines.append("|\(relative)|ok|\(String(format: "%.2f", seconds)) s|\(records.version)|\(pages.count)|\(scene.nodes.count)|\(paths)|\(groups)|\(clips)|\(texts)|\(images)|\(scene.symbols.count)|\(scene.swatches.count)|\(notes)|")
                let export = scene.exportScene()
                let stem = relative.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
                for (index, page) in pages.enumerated() {
                    let exportPage = ExportPage(name: "\(stem) page \(index + 1)", bounds: page, displayList: export.pages[0].displayList)
                    let image = Corpus.reference(exportPage, scale: 1)
                    try FreeHandCorpusTests.png(image).write(to: output.appendingPathComponent("\(stem)-page\(index + 1).png"))
                }
                let wholeImage = Corpus.reference(export.pages[0], scale: 1)
                try FreeHandCorpusTests.png(wholeImage).write(to: output.appendingPathComponent("\(stem)-all.png"))
            } catch {
                lines.append("|\(relative)|failed: \(error)|\(String(format: "%.2f", Date().timeIntervalSince(start))) s||||||||||||")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        #expect(empty.isEmpty, "files that read but produced no artwork: \(empty)")
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
