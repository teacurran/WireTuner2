// DATA-021 (export half): writing *Merge to PDF* (data-merge.adoc, "Merge to PDF or Print").
// The merged pages come from `WTModel.MergeOutput` one at a time; this writes them as one PDF or
// one PDF per record, names files from a pattern that takes the export tokens plus any field in
// braces, and stops between records when cancelled.  Nothing here touches the document.

import Foundation

/// File names for a merge to PDF (`invoice-{order_id}`).
public enum MergeFileNames {
    /// `pattern` expanded for one record: `{name}`, `{page}`, `{pagename}`, `{date}` as for any
    /// export (`FileNamePattern`), then `{field}` from `fields` (an unknown field stays as
    /// typed).  Characters a file name cannot hold (`/`, `:`) become `-`.
    public static func expand(_ pattern: String, values: FileNamePattern.Values, fields: [String: String]) -> String {
        var text = FileNamePattern(pattern).expand(values)
        for (name, value) in fields {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return String(text.map { $0 == "/" || $0 == ":" ? "-" : $0 })
    }

    /// Names made unique in order: a name seen before gets ` 2`, ` 3` ... (the first keeps its
    /// name).  Compared case-insensitively, as the file system does.
    public static func unique(_ names: [String]) -> [String] {
        var used: Set<String> = []
        return names.map { name in
            var candidate = name
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(name) \(suffix)"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}

/// Writes the pages of a merge to PDF.
public struct MergeExport {
    /// *One file* or *One file per record* (with the file name pattern).
    public enum Mode: Hashable, Sendable {
        case oneFile(name: String)
        case filePerRecord(pattern: String)
    }

    /// The pages, made on demand: how many, each page, and the field values of the record on it
    /// (for names).
    public struct Pages: Sendable {
        public var count: Int
        public var page: @Sendable (Int) throws -> ExportPage
        public var fields: @Sendable (Int) -> [String: String]
        /// The record each page belongs to (0-based), so a record's pages go to one file.
        public var record: @Sendable (Int) -> Int

        public init(count: Int, page: @escaping @Sendable (Int) throws -> ExportPage, fields: @escaping @Sendable (Int) -> [String: String] = { _ in [:] },
                    record: @escaping @Sendable (Int) -> Int = { $0 }) {
            self.count = count
            self.page = page
            self.fields = fields
            self.record = record
        }
    }

    public var options: PDFOptions
    public var info: ExportDocumentInfo
    private let exporter: PDFExporter

    public init(options: PDFOptions = PDFOptions(), info: ExportDocumentInfo = ExportDocumentInfo(), exporter: PDFExporter = PDFExporter()) {
        self.options = options
        self.info = info
        self.exporter = exporter
    }

    /// Writes `pages` into `directory`; `progress(done, total)` is called after each record's
    /// file (or page, for one file) and returning false stops after the current record, keeping
    /// what was written.  Returns the files written.
    public func write(_ pages: Pages, mode: Mode, to directory: URL, progress: (Int, Int) -> Bool = { _, _ in true }) throws -> ExportSummary {
        guard pages.count > 0 else { throw ExportError.nothingToExport }
        switch mode {
        case .oneFile(let name):
            var collected: [ExportPage] = []
            for index in 0..<pages.count {
                collected.append(try pages.page(index))
                if !progress(index + 1, pages.count) { break }
            }
            let (data, notes) = try exporter.data(scene: ExportScene(name: name, pages: collected, info: info), options: options)
            let url = directory.appending(component: MergeFileNames.unique([name])[0] + ".pdf")
            try data.write(to: url, options: .atomic)
            return ExportSummary(files: [url], notes: notes)
        case .filePerRecord(let pattern):
            // Group consecutive pages by record: a two-page template makes two pages per file.
            var groups: [[Int]] = []
            for index in 0..<pages.count {
                if let last = groups.last?.last, pages.record(last) == pages.record(index) { groups[groups.count - 1].append(index) } else { groups.append([index]) }
            }
            let names = MergeFileNames.unique(groups.enumerated().map { number, group in
                MergeFileNames.expand(pattern, values: FileNamePattern.Values(name: info.title ?? "Merge", page: number + 1), fields: pages.fields(group[0]))
            })
            var files: [URL] = []
            var notes: [String] = []
            for (number, (group, name)) in zip(groups, names).enumerated() {
                let scene = ExportScene(name: name, pages: try group.map(pages.page), info: info)
                let written = try exporter.data(scene: scene, options: options)
                let url = directory.appending(component: name + ".pdf")
                try written.data.write(to: url, options: .atomic)
                files.append(url)
                notes += written.notes
                if !progress(number + 1, groups.count) { break }
            }
            return ExportSummary(files: files, notes: notes)
        }
    }
}
