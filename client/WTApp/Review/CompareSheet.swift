import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The review sheet in compare mode (COLLAB-002): two versions of a document side by side --
/// a branch and its parent, two versions from the history -- with the state buttons retitled
/// (*Main* / *Branch* / *Overlay*, *Older* / *Newer* / *Overlay*), read-only when there is nothing
/// to write to, and with per-object *Use <A>* / *Use <B>* when there is: *Use <A>* re-asserts A's
/// registers on the write target in one change, *Use <B>* writes nothing.
@MainActor
@Observable
final class CompareSheetModel {
    enum Side: Equatable {
        case a, b
    }

    struct Row: Identifiable, Equatable {
        let id: OpID
        let name: String
        let kind: String
        let overlaps: Bool
    }

    let comparison: DocumentComparison
    let titleA: String
    let titleB: String
    let heading: String
    /// Where *Use <A>* writes (the live document); nil is read-only.
    @ObservationIgnored let perform: (@MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>)?
    /// The live state the choices are made against.
    @ObservationIgnored var current: @MainActor () -> EngineState
    var selected: OpID?
    var side = Side.a
    var overlay = false
    private(set) var chosen: Set<OpID> = []
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(comparison: DocumentComparison, titleA: String, titleB: String, heading: String,
         perform: (@MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>)? = nil,
         current: @escaping @MainActor () -> EngineState = { EngineState() }) {
        self.comparison = comparison
        self.titleA = titleA
        self.titleB = titleB
        self.heading = heading
        self.perform = perform
        self.current = current
        selected = comparison.entries.first?.node
    }

    var isReadOnly: Bool { perform == nil }

    var summary: String {
        let count = comparison.entries.count
        let both = comparison.entries.filter(\.overlaps).count
        let objects = count == 1 ? "1 object differs" : "\(count.formatted()) objects differ"
        return both == 0 ? objects : "\(objects); \(both) changed on both sides"
    }

    func name(_ node: OpID) -> String {
        comparison.a.store.isCreated(node) ? ObjectNaming.name(of: node, in: comparison.a) : ObjectNaming.name(of: node, in: comparison.b)
    }

    func kindTitle(_ kind: DocumentComparison.Kind) -> String {
        switch kind {
        case .changed: "Changed"
        case .onlyA: "Only in \(titleA)"
        case .onlyB: "Only in \(titleB)"
        }
    }

    var rows: [Row] {
        comparison.entries.map { Row(id: $0.node, name: name($0.node), kind: kindTitle($0.kind), overlaps: $0.overlaps) }
    }

    func select(_ node: OpID) {
        selected = node
        overlay = false
    }

    func show(_ side: Side) {
        self.side = side
        overlay = false
    }

    /// The selected object in the chosen state, or both at half strength with *Overlay*.
    func previewImage(size: Size = Size(width: 360, height: 240)) -> CGImage? {
        guard let selected else { return nil }
        let states = overlay ? [comparison.a, comparison.b] : [side == .a ? comparison.a : comparison.b]
        return ReviewPreview.image(node: selected, states: states, size: size)
    }

    /// *Use <A>* on the selected object: A's version re-asserted on the write target.
    @discardableResult
    func useA() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let perform, let selected else { return nil }
        chosen.insert(selected)
        guard let command = DocumentComparison.useA(selected, a: comparison.a, target: current(), name: name(selected)) else { return nil }
        return perform(command)
    }

    /// *Use <B>*: B is what the write target holds; nothing is written.
    func useB() {
        guard perform != nil, let selected else { return }
        chosen.insert(selected)
    }

    func isChosen(_ node: OpID) -> Bool { chosen.contains(node) }

    func close() { onClose() }
}

struct CompareSheetView: View {
    let model: CompareSheetModel

    static func select(_ model: CompareSheetModel, _ node: OpID) -> () -> Void { { model.select(node) } }
    static func side(_ model: CompareSheetModel, _ side: CompareSheetModel.Side) -> () -> Void { { model.show(side) } }
    static func overlay(_ model: CompareSheetModel) -> () -> Void { { model.overlay.toggle() } }
    static func useA(_ model: CompareSheetModel) -> () -> Void { { model.useA() } }
    static func useB(_ model: CompareSheetModel) -> () -> Void { { model.useB() } }
    static func close(_ model: CompareSheetModel) -> () -> Void { { model.close() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.heading).font(.title3.bold())
            Text(model.summary).accessibilityIdentifier("compare.summary")
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.rows) { row in
                            Button(action: Self.select(model, row.id)) {
                                HStack {
                                    Text(row.name).lineLimit(1)
                                    Spacer()
                                    Text(row.overlaps ? "\(row.kind) · both" : row.kind).font(.caption).foregroundStyle(.secondary)
                                    if model.isChosen(row.id) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 2)
                                .background(model.selected == row.id ? SwiftUI.Color.accentColor.opacity(0.15) : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 240)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(model.titleA, action: Self.side(model, .a)).accessibilityIdentifier("compare.a")
                        Button(model.titleB, action: Self.side(model, .b)).accessibilityIdentifier("compare.b")
                        Toggle("Overlay", isOn: Binding(get: { model.overlay }, set: { model.overlay = $0 })).toggleStyle(.button)
                    }
                    if let image = model.previewImage() {
                        Image(decorative: image, scale: 2).accessibilityIdentifier("compare.preview")
                    } else {
                        Text("Select an object to preview it.").foregroundStyle(.secondary)
                    }
                    if !model.isReadOnly, model.selected != nil {
                        HStack {
                            Button("Use \(model.titleA)", action: Self.useA(model)).accessibilityIdentifier("compare.useA")
                            Button("Use \(model.titleB)", action: Self.useB(model)).accessibilityIdentifier("compare.useB")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Done", action: Self.close(model)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 440)
    }
}

/// Shows the compare sheet on a window.
@MainActor
enum CompareSheet {
    static let identifier = NSUserInterfaceItemIdentifier("compare-sheet")

    @discardableResult
    static func present(_ model: CompareSheetModel, on window: NSWindow?) -> NSWindow {
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: CompareSheetView(model: model)))
        sheet.identifier = identifier
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        model.onClose = { [weak window, weak sheet] in
            guard let sheet else { return }
            if let window { window.endSheet(sheet) } else { sheet.orderOut(nil) }
        }
        window?.beginSheet(sheet)
        return sheet
    }
}
