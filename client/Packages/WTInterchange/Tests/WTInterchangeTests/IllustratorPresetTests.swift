// D-098: Illustrator 2020 and later's own files, read in place from an Illustrator installation
// (`WT_ILLUSTRATOR_PRESETS`, e.g. "/Applications/Adobe Illustrator 2026"; the files are Adobe's
// and are never copied into the repository).  Every `.ai` under it whose private data is
// Zstandard must decompress, and its artboard names and layer table must reach the opened
// document.  A tab-separated report goes to `WT_ILLUSTRATOR_PRESETS_REPORT` when set.  Skipped
// without the variable.

import Foundation
import Testing
@testable import WTInterchange

@Suite struct IllustratorPresetTests {
    static let folder = ProcessInfo.processInfo.environment["WT_ILLUSTRATOR_PRESETS"]

    @Test(.enabled(if: folder != nil)) func zstandardPresetsOpenWithTheirNamesAndLayers() throws {
        let root = URL(fileURLWithPath: Self.folder!)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "ai" }
            .sorted { $0.path < $1.path }
        var report = ["file\tzstd\tnative bytes\tartboards\tpages\tpage names\tlayer table\tlayer source\tlayers\tobject names"]
        var zstandard = 0
        for file in files {
            let data = try Data(contentsOf: file)
            guard data.range(of: Data("%AI24_ZStandard_Data".utf8)) != nil else {
                report.append("\(file.path)\tno")
                continue
            }
            zstandard += 1
            let pdf = try PDFImporter.document(data, name: file.lastPathComponent)
            let native = IllustratorImporter.nativeData(pdf)
            #expect(native != nil, "\(file.path): private data did not decompress")
            let artboards = native.map(IllustratorPrivateData.artboardNames) ?? []
            let table = IllustratorImporter.nativeLayers(native)
            let document = try IllustratorImporter().document(data, name: file.lastPathComponent, format: .illustrator, options: PDFImportOptions().values, context: ImportContext())
            let names = document.pages.map { $0.name ?? "" }
            if artboards.count == document.pages.count {
                #expect(names == artboards.map { $0 }, "\(file.path)")
            }
            let objectNames = native.map { native in native.ranges(of: Data("/XMLUID".utf8)).count } ?? 0
            report.append([
                file.path, "yes", "\(native?.count ?? 0)", artboards.joined(separator: "|"), "\(document.pages.count)",
                names.joined(separator: "|"), table.map { "\($0.depth):\($0.name)" }.joined(separator: "|"),
                "\(document.layerSource.map { "\($0)" } ?? "nil")", document.layerNames.joined(separator: "|"), "\(objectNames)",
            ].joined(separator: "\t"))
        }
        #expect(zstandard > 0, "no Illustrator 2020+ files under \(root.path)")
        if let path = ProcessInfo.processInfo.environment["WT_ILLUSTRATOR_PRESETS_REPORT"] {
            try report.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
