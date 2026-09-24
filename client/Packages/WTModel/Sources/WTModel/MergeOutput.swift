import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// DATA-021 (model half): *Merge to PDF* and *Print Merge* (data-merge.adoc, "Merge to PDF or
// Print"; "Merge engine", `MergeToOutput`).  Each output page is drawn from the template with one
// record applied -- the same substitution as the preview and *Merge to Pages* -- straight into
// an `ExportPage`, so nothing is written to the document.  Pages are made one at a time, so a
// consumer that writes each page before asking for the next (one file per record, the print
// loop) keeps memory flat.  `WTInterchange.MergeExport` writes the files.

/// The output pages of one merge to PDF or print.
public struct MergeOutput: Sendable {
    public let state: EngineState
    public let records: RecordSet
    public let options: MergeOptions
    /// The planned output pages, in order: what the Print dialog's page ranges refer to.
    public let plan: [MergedPage]
    private let pages: [OpID: Page]
    private let selection: [OpID]
    private let model: DataModel

    /// The merge of `records` through the template page(s) `templates` (a grid copies the
    /// `selection`'s objects); throws when a template is not a page.
    public init(state: EngineState, records: RecordSet, options: MergeOptions = MergeOptions(), templates: [OpID], selection: [OpID] = []) throws {
        let list = PageList(state)
        let resolved = try templates.map { try PageEditing.page($0, in: list) }
        guard let first = resolved.first else { throw PageSetupError.notAPage(.zero) }
        self.state = state
        self.records = records
        self.options = options
        self.selection = selection
        pages = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        model = DataModel(state)
        let bounds = selection.compactMap { Objects.bounds(of: $0, in: state) }.reduce(Rect.null) { $0.union($1) }
        plan = MergeEngine.plan(templates: templates, indices: options.records.indices(count: records.count), layout: options.layout,
                                page: first.rect, selection: bounds)
    }

    /// How many pages the merge makes (`knowsPageRange`).
    public var count: Int { plan.count }

    /// The 0-based records on output page `index`.
    public func records(on index: Int) -> [Int] { plan[index].placements.map(\.record) }

    /// Output page `index`, drawn with `textLayout` (on the main actor when given; without one,
    /// text is not drawn, as for any export built off the main actor).  The page's rectangle is
    /// the template page's, so page geometry is the template's (`rectForPage`).
    public func page(_ index: Int, textLayout: TextSceneLayout? = nil) -> ExportPage {
        let output = plan[index]
        let template = pages[output.template]!
        var builder = DocumentDisplayListBuilder(canvas: "merge")
        builder.textLayout = textLayout
        var items: [DisplayItem] = []
        for placement in output.placements {
            guard let record = records.record(at: placement.record) else { continue }
            builder.substitution = RecordSubstitution(model: model, record: record, removeBlankLines: options.removeBlankLines)
            let scene = builder.rebuild(state)
            if case .grid = options.layout {
                let move = AffineTransform.translation(x: placement.offset.dx, y: placement.offset.dy)
                items += selection.compactMap { scene.object($0)?.item.transformed(by: move) }
            } else {
                items += builder.outputDisplayList(state).items
            }
        }
        let name = output.placements.count == 1 ? "\(template.name) · \(output.placements[0].record + 1)" : "\(template.name) · \(index + 1)"
        return ExportPage(name: name, bounds: template.rect, displayList: DisplayList(canvas: "merge", items: items), bleed: template.bleed)
    }

    /// Each output page's records as field-name values, for file names (`{order_id}`).
    public func fieldValues(on index: Int) -> [String: String] {
        guard let record = plan[index].placements.first.flatMap({ records.record(at: $0.record) }) else { return [:] }
        var values: [String: String] = [:]
        for field in records.fields where !field.name.isEmpty {
            values[field.name] = record.value(field.id).text
        }
        return values
    }

    /// The report rows of the records merged: coercion problems, missing fields and barcodes
    /// that cannot be encoded.
    public func issues() -> [MergeIssue] {
        let merged = Set(plan.flatMap { $0.placements.map { $0.record + 1 } })
        var issues = records.issues.filter { merged.contains($0.record) }
        for number in merged.sorted() {
            guard let record = records.record(at: number - 1) else { continue }
            issues += RecordSubstitution(model: model, record: record).issues(in: state)
        }
        return MergeEngine.report(issues)
    }
}
