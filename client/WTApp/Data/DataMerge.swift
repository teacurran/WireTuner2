import AppKit
import PDFKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// The merge sheet (data-merge.adoc, "Merging"; DATA-017, DATA-020 and DATA-021's WTApp halves):
/// the target -- pages, PDF or printer -- the records, the layout (one record per page, or a grid
/// of the selected objects), the finishing options, a progress count with btn:[Cancel] and the
/// report.  *Merge to Pages* is one undo step; *Merge to PDF* and printing write nothing to the
/// document.
@MainActor
@Observable
final class MergeSheetModel {
    enum Target: String, CaseIterable, Identifiable {
        case pages = "Pages"
        case pdf = "PDF"
        case printer = "Printer"
        var id: String { rawValue }
    }

    var target: Target = .pages
    var recordsText = ""
    var usesGrid = false
    var columns = 3
    var rows = 8
    var gap = 4.0
    var margins = 36.0
    var acrossFirst = true
    var removeBlankLines = true
    var shrinkToFit = false
    var minimumSize = 6.0
    var oneFile = true
    var pattern: String
    private(set) var progress: (done: Int, total: Int)?
    private(set) var report: [MergeIssue]?
    private(set) var message: String?
    private(set) var written: [URL] = []
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored let window: DocumentWindowController
    @ObservationIgnored let session: DataSession
    /// Where *Merge to PDF* writes (asks with an open panel by default).
    @ObservationIgnored var chooseDirectory: @MainActor () async -> URL?
    /// Runs the print operation (the Print dialog by default).
    @ObservationIgnored var runPrint: @MainActor (NSPrintOperation) -> Void = { $0.run() }

    init(window: DocumentWindowController, session: DataSession) {
        self.window = window
        self.session = session
        pattern = "\(window.documentHandle.title)-{page}"
        chooseDirectory = { [weak window] in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Merge"
            return await ModalUI.urls(panel, on: window?.window).first
        }
    }

    var document: DocumentHandle { window.documentHandle }
    /// The template page(s): the selected pages.
    var templates: [OpID] { document.selectedPages.map(\.id) }
    /// The objects a grid copies: the selection.
    var selection: [OpID] { window.selection.model.selection.ids.map(\.opID) }

    var range: MergeRange? { MergeRange(recordsText) }

    var layout: MergeLayout {
        usesGrid ? .grid(columns: max(1, columns), rows: max(1, rows), gap: max(0, gap), margins: max(0, margins), order: acrossFirst ? .acrossThenDown : .downThenAcross)
            : .onePerPage
    }

    var options: MergeOptions {
        MergeOptions(records: range ?? .all, layout: layout, removeBlankLines: removeBlankLines, shrinkToFit: shrinkToFit ? max(0.5, minimumSize) : nil)
    }

    /// How many records the range selects.
    var recordCount: Int { (range ?? .all).indices(count: session.records.count).count }

    /// The sheet's summary: records and the pages they make.
    var summary: String {
        guard range != nil else { return "Type records as 1-50, 51-, 3, 7, 12." }
        let pages = MergeEngine.pageCount(records: recordCount, perPage: layout.perPage) * max(templates.count, 1)
        return "\(recordCount) record\(recordCount == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s")"
    }

    /// Why the merge cannot run now.
    var problem: String? {
        if range == nil { return "The records are not a list of numbers and ranges." }
        if recordCount == 0 { return "There are no records to merge." }
        if usesGrid && selection.isEmpty { return "Select the objects that make one label for the grid." }
        return nil
    }

    /// Placeholders and bindings whose field is missing, and used fields the source lacks.
    var warnings: [String] {
        DataValidation.problems(in: document.state, columns: session.table?.columns).map { problem in
            switch problem.kind {
            case .missingPlaceholder: "A placeholder’s field is missing: it merges as {{missing}}."
            case .missingBinding: "A bound object’s field is missing: it merges unbound."
            case .unmappedField(let name): "The source has no column for “\(name)”."
            }
        }.uniqued()
    }

    func cancel() { cancelled = true }

    /// btn:[Merge].
    func merge() async {
        guard problem == nil else {
            message = problem
            return
        }
        report = nil
        message = nil
        switch target {
        case .pages: await mergeToPages()
        case .pdf: await mergeToPDF()
        case .printer: printMerge()
        }
        progress = nil
        cancelled = false
    }

    /// Shrink-to-fit is decided here, on the main actor with the layout engine; the command
    /// only places the fitted texts.
    func fitted(_ records: RecordSet, indices: [Int]) -> (texts: [MergeFitKey: MergeText], issues: [MergeIssue]) {
        guard let minimum = options.shrinkToFit else { return ([:], []) }
        let state = document.state
        let model = DataModel(state)
        let texts = DataPreviewScene.dependentNodes(in: state).compactMap { TextNode($0, in: state) }
        var fitted: [MergeFitKey: MergeText] = [:]
        var issues: [MergeIssue] = []
        let engine = document.textEngine
        for index in indices {
            guard let record = records.record(at: index) else { continue }
            let substitution = RecordSubstitution(model: model, record: record, removeBlankLines: removeBlankLines)
            for text in texts {
                let (placed, overflows) = MergeEngine.shrink(substitution.mergeText(text, state: state), minimum: minimum) { MergeEngine.fits($0, in: text, engine: engine) }
                fitted[MergeFitKey(record: index, node: text.id)] = placed
                if overflows { issues.append(MergeIssue(record: index + 1, field: nil, kind: .overflow(node: text.id))) }
            }
        }
        return (fitted, issues)
    }

    private func mergeToPages() async {
        guard let model = document.model else { return }
        let records = session.records
        let options = self.options
        let (texts, overflow) = fitted(records, indices: options.records.indices(count: records.count))
        do {
            let result = try await model.mergeToPages(templates: templates, records: records, options: options, selection: usesGrid ? selection : [], fitted: texts) { [weak self] done, total in
                self?.progress = (done, total)
                return self?.cancelled != true
            }
            report = result.cancelled ? nil : MergeEngine.report(result.issues + overflow)
            message = result.cancelled ? "The merge was cancelled; no pages were added." : "Merged \(recordCount) record\(recordCount == 1 ? "" : "s") into \(result.pages.count) page\(result.pages.count == 1 ? "" : "s")."
        } catch {
            message = "The merge failed: \(error)"
        }
    }

    /// The output pages of a merge to PDF or print.
    func output() throws -> MergeOutput {
        try MergeOutput(state: document.state, records: session.records, options: options, templates: templates, selection: usesGrid ? selection : [])
    }

    private func mergeToPDF() async {
        guard let directory = await chooseDirectory() else { return }
        do {
            let output = try output()
            let layout = TextSceneLayout(engine: document.textEngine)
            let pages = MergeExport.Pages(count: output.count, page: { index in
                MainActor.assumeIsolated { output.page(index, textLayout: layout) }
            }, fields: { output.fieldValues(on: $0) }, record: { output.records(on: $0).first ?? $0 })
            let export = MergeExport(info: ExportDocumentInfo(title: document.title))
            let mode: MergeExport.Mode = oneFile ? .oneFile(name: MergeFileNames.expand(pattern, values: FileNamePattern.Values(name: document.title, page: 1), fields: [:]))
                : .filePerRecord(pattern: pattern)
            let summary = try export.write(pages, mode: mode, to: directory) { [weak self] done, total in
                MainActor.assumeIsolated {
                    self?.progress = (done, total)
                    return self?.cancelled != true
                }
            }
            written = summary.files
            report = output.issues()
            message = "Wrote \(summary.files.count) file\(summary.files.count == 1 ? "" : "s")."
        } catch {
            message = "The PDF could not be written: \(error)"
        }
    }

    private func printMerge() {
        do {
            let view = MergePrintView(output: try output(), textLayout: TextSceneLayout(engine: document.textEngine))
            let operation = NSPrintOperation(view: view, printInfo: MergePrintView.printInfo())
            operation.jobTitle = "\(document.title) merge"
            runPrint(operation)
            message = "Sent \(view.output.count) page\(view.output.count == 1 ? "" : "s") to the printer."
        } catch {
            message = "The merge could not be printed: \(error)"
        }
    }

    /// A report row as the sheet lists it.
    func describe(_ issue: MergeIssue) -> String {
        let field = issue.field.map { " (\($0))" } ?? ""
        let what: String = switch issue.kind {
        case .overflow: "text does not fit"
        case .unfetchableImage(let url): "the picture \(url) could not be fetched"
        case .unencodableBarcode: "the barcode cannot encode the value"
        case .unparsableDate(let value): "“\(value)” is not a date"
        case .unparsableNumber(let value): "“\(value)” is not a number"
        case .transformFailed(let message): "the transform failed: \(message)"
        case .transformTimeout: "the transform ran too long"
        case .missingField(let name): "the field \(name) is missing"
        case .emptyField: "no value"
        }
        return "Record \(issue.record)\(field): \(what)"
    }

    /// A report row clicked: the canvas previews that record.
    func show(_ issue: MergeIssue) {
        session.go(to: issue.record)
        session.setPreview(true)
    }
}

extension Array where Element: Hashable {
    /// The elements without repeats, first occurrences kept in order.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

struct MergeSheet: View {
    @Bindable var model: MergeSheetModel
    let close: @MainActor () -> Void

    static func merge(_ model: MergeSheetModel) -> () -> Void { { Task { await model.merge() } } }
    static func show(_ issue: MergeIssue, _ model: MergeSheetModel) -> () -> Void { { model.show(issue) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge").font(.headline)
            Form {
                Picker("To", selection: $model.target) {
                    ForEach(MergeSheetModel.Target.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("merge.target")
                TextField("Records", text: $model.recordsText, prompt: Text("All")).accessibilityIdentifier("merge.records")
                Picker("Layout", selection: $model.usesGrid) {
                    Text("One record per page").tag(false)
                    Text("Multiple records per page").tag(true)
                }
                .accessibilityIdentifier("merge.layout")
                if model.usesGrid {
                    Stepper("Columns: \(model.columns)", value: $model.columns, in: 1...20)
                    Stepper("Rows: \(model.rows)", value: $model.rows, in: 1...40)
                    TextField("Gap (pt)", value: $model.gap, format: .number)
                    TextField("Margins (pt)", value: $model.margins, format: .number)
                    Picker("Order", selection: $model.acrossFirst) {
                        Text("Across then down").tag(true)
                        Text("Down then across").tag(false)
                    }
                }
                Toggle("Remove blank lines", isOn: $model.removeBlankLines)
                Toggle("Shrink text to fit", isOn: $model.shrinkToFit)
                if model.shrinkToFit {
                    TextField("Minimum size (pt)", value: $model.minimumSize, format: .number)
                }
                if model.target == .pdf {
                    Picker("Files", selection: $model.oneFile) {
                        Text("One file").tag(true)
                        Text("One file per record").tag(false)
                    }
                    TextField("File names", text: $model.pattern).accessibilityIdentifier("merge.pattern")
                }
            }
            Text(model.summary).font(.caption).accessibilityIdentifier("merge.summary")
            ForEach(model.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if let progress = model.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("\(progress.done) of \(progress.total) records")
                }
                Button("Cancel", action: model.cancel).accessibilityIdentifier("merge.cancel")
            }
            if let message = model.message {
                Text(message).font(.caption).accessibilityIdentifier("merge.message")
            }
            if let report = model.report, !report.isEmpty {
                Text("Report").font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.indices, id: \.self) { index in
                            Button(model.describe(report[index]), action: Self.show(report[index], model)).buttonStyle(.link).font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .accessibilityIdentifier("merge.report")
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Merge", action: Self.merge(model)).keyboardShortcut(.defaultAction).disabled(model.problem != nil || model.progress != nil)
                    .accessibilityIdentifier("merge.run")
            }
        }
        .padding()
        .frame(width: 440)
    }
}

/// *Print Merge*: the merged output pages as a paginated view -- `knowsPageRange` answers the
/// merged count and `rectForPage` each output page's rectangle (the template page's geometry) --
/// each page drawn only when the print loop asks for it, so nothing is written and memory stays
/// flat.
@MainActor
final class MergePrintView: NSView {
    let output: MergeOutput
    let textLayout: TextSceneLayout
    /// Each output page's size, in order (pages stack top to bottom).
    private let sizes: [CGSize]

    init(output: MergeOutput, textLayout: TextSceneLayout) {
        self.output = output
        self.textLayout = textLayout
        let pages = PageList(output.state)
        sizes = output.plan.map { planned in pages[planned.template].map { CGSize(width: $0.rect.width, height: $0.rect.height) } ?? CGSize(width: 612, height: 792) }
        let width = sizes.map(\.width).max() ?? 612
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: sizes.reduce(0) { $0 + $1.height }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MergePrintView is built in code")
    }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: output.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let index = min(max(page - 1, 0), max(sizes.count - 1, 0))
        guard !sizes.isEmpty else { return .zero }
        let top = sizes[..<index].reduce(0) { $0 + $1.height }
        return NSRect(x: 0, y: top, width: sizes[index].width, height: sizes[index].height)
    }

    /// Output page `index` as a one-page PDF (vector, as exported).
    func pdf(_ index: Int) -> PDFPage? {
        let page = output.page(index, textLayout: textLayout)
        let viewport = Viewport(scrollOrigin: Point(x: page.bounds.minX, y: page.bounds.minY), size: Size(width: page.bounds.width, height: page.bounds.height))
        return CoreGraphicsRenderer().renderPDF(page.displayList, viewport: viewport).flatMap { PDFDocument(data: $0)?.page(at: 0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for index in 0..<output.count {
            let rect = rectForPage(index + 1)
            guard rect.intersects(dirtyRect), let page = pdf(index) else { continue }
            context.saveGState()
            // PDF pages draw y-up: flip into the page's rectangle.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
    }

    /// No margins: the pages carry their own.
    static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        return info
    }
}

extension DataFeatures {
    /// btn:[Merge…].
    @discardableResult
    func presentMerge() -> MergeSheetModel? {
        guard let (window, session) = front else { return nil }
        let model = MergeSheetModel(window: window, session: session)
        window.presentSheet("sheet.merge") { close in MergeSheet(model: model, close: close) }
        return model
    }
}
