import WTGeometry
import AppKit
import SwiftUI
import WTRender
import WTSync

/// The review sheet's SwiftUI body (reconcile.adoc's layout): header, filters, the list, the
/// preview with its state buttons and *Overlay*, the attribute rows and per-object choices, the
/// paragraph diffs, and the whole-document buttons.
struct ReviewSheetView: View {
    let model: ReviewSheetModel

    static func select(_ model: ReviewSheetModel, _ id: String) -> () -> Void { { model.select(id) } }
    static func filter(_ model: ReviewSheetModel) -> Binding<ReviewSheetModel.Filter> {
        Binding(get: { model.filter }, set: { model.setFilter($0) })
    }
    static func side(_ model: ReviewSheetModel, _ side: ReviewSheetModel.Side) -> () -> Void {
        { model.side = side; model.overlay = false }
    }
    static func overlay(_ model: ReviewSheetModel) -> () -> Void { { model.overlay.toggle() } }
    static func action(_ model: ReviewSheetModel, _ action: ReviewAction) -> () -> Void { { model.perform(action) } }
    static func paragraph(_ model: ReviewSheetModel, _ action: ReviewAction, _ row: ReviewSheetModel.ParagraphRow) -> () -> Void {
        { model.perform(action, paragraph: row) }
    }
    static func document(_ model: ReviewSheetModel, _ action: ReviewModel.DocumentAction) -> () -> Void { { model.perform(action) } }
    static func done(_ model: ReviewSheetModel) -> () -> Void { { Task { await model.done() } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.title3.bold())
            Text(model.summary).accessibilityIdentifier("review.summary")
            if let overlap = model.overlapLine { Text(overlap).accessibilityIdentifier("review.overlap") }
            Picker("Show", selection: Self.filter(model)) {
                ForEach(ReviewSheetModel.Filter.allCases) { filter in Text(model.filterTitle(filter)).tag(filter) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("review.filter")
            HStack(alignment: .top, spacing: 12) {
                list.frame(width: 240)
                detail.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 300)
            footer
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.rows) { row in
                    Button(action: Self.select(model, row.id)) {
                        HStack {
                            Text(row.name).lineLimit(1)
                            Spacer()
                            Text(row.kind).font(.caption).foregroundStyle(.secondary)
                            if model.isReviewed(row.id) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .background(model.selectedRow?.id == row.id ? SwiftUI.Color.accentColor.opacity(0.2) : SwiftUI.Color.clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("review.row.\(row.id)")
                }
            }
        }
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("review.list")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(ReviewSheetModel.Side.allCases) { side in
                    Button(side.title, action: Self.side(model, side))
                        .buttonStyle(.bordered)
                        .tint(!model.overlay && model.side == side ? SwiftUI.Color.accentColor : nil)
                        .accessibilityIdentifier("review.side.\(side.rawValue)")
                }
                Toggle("Overlay", isOn: Binding(get: { model.overlay }, set: { model.overlay = $0 }))
                    .accessibilityIdentifier("review.overlay")
            }
            Group {
                if let image = model.previewImage() {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text("Nothing to preview").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 240)
            .accessibilityIdentifier("review.preview")
            ForEach(model.propertyRows) { property in
                Grid(alignment: .leading, horizontalSpacing: 8) {
                    GridRow {
                        Text(property.title).bold()
                        Text("Mine: \(property.mine)\(property.kept == .mine ? "  ← current" : "")").lineLimit(2)
                    }
                    GridRow {
                        Text("")
                        Text("Theirs: \(property.theirs)\(property.kept == .theirs ? "  ← current" : "")").lineLimit(2)
                    }
                }
                .font(.callout)
                .accessibilityIdentifier("review.property.\(property.title)")
            }
            ForEach(model.paragraphRows) { paragraph in
                VStack(alignment: .leading, spacing: 4) {
                    Self.diffText(paragraph.diff).accessibilityIdentifier("review.diff")
                    if model.allowsChoices {
                        HStack {
                            Button("Use mine", action: Self.paragraph(model, .useMine, paragraph))
                            Button("Use theirs", action: Self.paragraph(model, .useTheirs, paragraph))
                            Button("Keep both", action: Self.paragraph(model, .keepBoth, paragraph))
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                ForEach(model.actions, id: \.self) { action in
                    Button(ReviewSheetModel.actionTitle(action), action: Self.action(model, action))
                        .accessibilityIdentifier("review.action.\(ReviewSheetModel.actionTitle(action))")
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("review.message") }
            HStack {
                ForEach(model.documentActions, id: \.self) { action in
                    Button(model.documentActionTitle(action), action: Self.document(model, action))
                        .disabled(model.isWorking || (action != .keepMerged && model.workUnavailableReason != nil))
                        .help(action != .keepMerged ? model.workUnavailableReason ?? "" : "")
                        .accessibilityIdentifier("review.document.\(model.documentActionTitle(action))")
                }
                Spacer()
                Button("Done", action: Self.done(model)).keyboardShortcut(.defaultAction).accessibilityIdentifier("review.done")
            }
        }
    }

    /// The paragraph with mine-only text underlined in the accent colour and theirs-only text
    /// struck through in orange.
    static func diffText(_ diff: ParagraphDiff) -> Text {
        diff.segments.reduce(Text("")) { text, segment in
            switch segment.side {
            case .both: text + Text(segment.text)
            case .mine: text + Text(segment.text).underline().foregroundColor(.accentColor)
            case .theirs: text + Text(segment.text).strikethrough().foregroundColor(.orange)
            }
        }
    }
}

/// Shows the review sheet on a document window, one at a time; dismissing it uploads the merge.
@MainActor
final class ReviewSheetController {
    static let identifier = NSUserInterfaceItemIdentifier("review-sheet")

    private(set) var model: ReviewSheetModel?
    private(set) var sheet: NSWindow?
    private weak var parent: NSWindow?

    init() {}

    var isShown: Bool { sheet != nil }

    /// Opens `model` on `window` (replacing nothing: a sheet already open stays).
    @discardableResult
    func present(_ model: ReviewSheetModel, on window: NSWindow?) -> Bool {
        guard sheet == nil else { return false }
        self.model = model
        model.onFinish = { [weak self] in self?.close() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ReviewSheetView(model: model)))
        sheet.identifier = Self.identifier
        sheet.styleMask.insert(.resizable)
        self.sheet = sheet
        parent = window
        window?.beginSheet(sheet)
        return true
    }

    /// Closes the sheet without a choice: the merge uploads.
    @discardableResult
    func dismiss() -> Task<Void, Never>? {
        guard let model else { return nil }
        return Task { await model.dismiss() }
    }

    func close() {
        if let sheet { parent?.endSheet(sheet) }
        sheet = nil
        model = nil
    }
}
