import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Edit Tab sheet and the Tabs table (tabs-indents.adoc, "Setting tabs" and "Tab leaders";
/// TYPE-024).  A double-click on the ruler opens the sheet for a new stop at that place, one on a
/// stop edits it; the Paragraph section's btn:[Tabs…] opens the table of every stop in the first
/// paragraph.  Both act on every paragraph the targets touch -- a stop is found in each by where it
/// stands, as the ruler's gestures do -- and btn:[OK] writes one change.  A leader on a wrapping
/// tab is refused: the leader controls are off while *Wrapping* is chosen.
struct TabDraft: Equatable, Identifiable {
    /// The stop's position when the sheet opened (nil: a new stop).
    let original: Double?
    var kind: Wiretuner_Doc_V1_TabKind
    var position: Double
    var leader: String
    var deleted = false
    /// Rows of the table are told apart by this, not by position (which the user edits).
    let id: Int

    init(original: Double?, kind: Wiretuner_Doc_V1_TabKind, position: Double, leader: String, id: Int = 0) {
        self.original = original
        self.kind = kind == .unspecified ? .left : kind
        self.position = position
        self.leader = leader
        self.id = id
    }

    init(_ stop: Wiretuner_Doc_V1_TabStop, id: Int = 0) {
        self.init(original: stop.position, kind: stop.kind, position: stop.position, leader: stop.leader, id: id)
    }

    var stop: Wiretuner_Doc_V1_TabStop {
        .with {
            $0.kind = kind
            $0.position = position.rounded(toPlaces: 2)
            $0.leader = kind == .wrapping ? "" : leader
        }
    }

    /// Why the draft cannot be written, or nil.
    var refusal: String? {
        if !position.isFinite || position < 0 { return "Type a position of 0 or more." }
        if kind == .wrapping, !leader.isEmpty { return "A wrapping tab cannot have a leader." }
        if leader.count > 1 { return "A leader is one character." }
        return nil
    }
}

/// What the sheet and the table write to: the paragraphs of each target, the stops of the first.
@MainActor
struct TabEditing {
    let targets: [TextTarget]
    /// The first targeted paragraph's stops, sorted.
    let stops: [Wiretuner_Doc_V1_TabStop]

    static let kinds: [(kind: Wiretuner_Doc_V1_TabKind, title: String)] = [
        (.left, "Left"), (.right, "Right"), (.center, "Center"), (.decimal, "Decimal"), (.wrapping, "Wrapping"),
    ]
    /// The leader pop-up's presets; any other single character is typed in the field.
    static let leaders: [(leader: String, title: String)] = [("", "None"), (".", "Dots"), ("-", "Dashes"), ("_", "Underscores")]
    static let custom = "Custom"

    init(targets: [TextTarget], in state: EngineState) {
        self.targets = targets
        let first = targets.first.flatMap { target -> TextParagraph? in
            state.textNode(target.node)?.paragraphs(touching: target.range).first
        }
        stops = first.map { TextTabs.stops($0).map(\.stop) } ?? []
    }

    /// The draft a double-click at `position` (ruler points) opens: the stop there, else a new
    /// left stop.
    func draft(at position: Double, tolerance: Double = TextTabs.tolerance) -> TabDraft {
        if let stop = stops.first(where: { abs($0.position - position) <= tolerance }) { return TabDraft(stop) }
        return TabDraft(original: nil, kind: .left, position: max(position, 0).rounded(toPlaces: 2), leader: "")
    }

    /// The table's rows: every stop of the first paragraph.
    var rows: [TabDraft] { stops.enumerated().map { TabDraft($1, id: $0) } }

    /// The commands one draft needs, against the targets.
    func commands(_ draft: TabDraft) -> [any WTModel.Command] {
        targets.flatMap { target -> [any WTModel.Command] in
            guard let original = draft.original else {
                return draft.deleted ? [] : [AddTabStop(node: target.node, from: target.from, to: target.to, stop: draft.stop)]
            }
            if draft.deleted { return [DeleteTabStop(node: target.node, from: target.from, to: target.to, at: original)] }
            let before = stops.first { abs($0.position - original) < TextTabs.tolerance }
            var fields: [TextTabs.Field] = []
            let kind = before.map { $0.kind == .unspecified ? .left : $0.kind } ?? .left
            if kind != draft.kind { fields.append(.kind) }
            if abs(original - draft.stop.position) >= TextTabs.tolerance { fields.append(.position) }
            if (before?.leader ?? "") != draft.stop.leader { fields.append(.leader) }
            guard !fields.isEmpty else { return [] }
            return [SetTabStop(node: target.node, from: target.from, to: target.to, at: original, stop: draft.stop, fields: fields)]
        }
    }

    /// The Edit Tab sheet's btn:[OK]: one change, or nil when nothing changed or the draft is
    /// refused.
    func commit(_ draft: TabDraft) -> (any WTModel.Command)? {
        guard draft.refusal == nil else { return nil }
        let commands = commands(draft)
        guard !commands.isEmpty else { return nil }
        return CommandBatch(draft.original == nil ? "Add Tab" : "Edit Tab", commands)
    }

    /// The table's btn:[OK]: every row's commands in one change ("Edit Tabs"); nil when nothing
    /// changed or a row is refused.
    func commit(rows: [TabDraft]) -> (any WTModel.Command)? {
        guard rows.allSatisfy({ $0.deleted || $0.refusal == nil }) else { return nil }
        let commands = rows.flatMap(commands)
        guard !commands.isEmpty else { return nil }
        return CommandBatch("Edit Tabs", commands)
    }

    // MARK: Bindings the sheets share

    /// The leader pop-up: a preset's title, or *Custom* for another character.
    static func leaderChoice(_ draft: Binding<TabDraft>) -> Binding<String> {
        Binding(get: { leaders.first { $0.leader == draft.wrappedValue.leader }?.title ?? custom },
                set: { title in if let preset = leaders.first(where: { $0.title == title }) { draft.wrappedValue.leader = preset.leader } })
    }

    /// The leader field: at most one character.
    static func leaderText(_ draft: Binding<TabDraft>) -> Binding<String> {
        Binding(get: { draft.wrappedValue.leader }, set: { draft.wrappedValue.leader = String($0.prefix(1)) })
    }

    /// The alignment pop-up; choosing *Wrapping* drops the leader.
    static func kind(_ draft: Binding<TabDraft>) -> Binding<Wiretuner_Doc_V1_TabKind> {
        Binding(get: { draft.wrappedValue.kind }, set: { kind in
            draft.wrappedValue.kind = kind
            if kind == .wrapping { draft.wrappedValue.leader = "" }
        })
    }

    static func position(_ draft: Binding<TabDraft>) -> Binding<Double> {
        Binding(get: { draft.wrappedValue.position }, set: { draft.wrappedValue.position = $0 })
    }
}

/// The Edit Tab sheet.
struct EditTabSheet: View {
    @State var draft: TabDraft
    let commit: (TabDraft) -> Void
    let cancel: () -> Void

    static func committing(_ draft: TabDraft, _ commit: @escaping (TabDraft) -> Void) -> () -> Void {
        { commit(draft) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.original == nil ? "New Tab" : "Edit Tab").font(.headline)
            Form {
                TabFields(draft: $draft)
            }
            if let refusal = draft.refusal {
                Text(refusal).font(.caption).foregroundStyle(.red).accessibilityIdentifier("editTab.refused")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("editTab.cancel")
                Button("OK", action: Self.committing(draft, commit)).keyboardShortcut(.defaultAction)
                    .disabled(draft.refusal != nil).accessibilityIdentifier("editTab.ok")
            }
        }
        .padding()
        .frame(width: 320)
        .accessibilityIdentifier("editTab")
    }
}

/// Alignment, position and leader for one draft.
struct TabFields: View {
    @Binding var draft: TabDraft

    var body: some View {
        Picker("Alignment", selection: TabEditing.kind($draft)) {
            ForEach(TabEditing.kinds, id: \.title) { Text($0.title).tag($0.kind) }
        }
        .accessibilityIdentifier("editTab.kind.\(draft.id)")
        TextField("Position", value: TabEditing.position($draft), format: .number).accessibilityIdentifier("editTab.position.\(draft.id)")
        HStack {
            Picker("Leader", selection: TabEditing.leaderChoice($draft)) {
                ForEach(TabEditing.leaders, id: \.title) { Text($0.title).tag($0.title) }
                Text(TabEditing.custom).tag(TabEditing.custom)
            }
            .accessibilityIdentifier("editTab.leader.\(draft.id)")
            TextField("", text: TabEditing.leaderText($draft)).frame(width: 30).accessibilityIdentifier("editTab.leaderText.\(draft.id)")
        }
        .disabled(draft.kind == .wrapping)
    }
}

/// The Tabs table: every stop of the paragraph, each editable or removable, and btn:[Add].
struct TabsTableSheet: View {
    @State var rows: [TabDraft]
    let commit: ([TabDraft]) -> Void
    let cancel: () -> Void

    static func adding(_ rows: Binding<[TabDraft]>) -> () -> Void {
        {
            let next = (rows.wrappedValue.map(\.id).max() ?? -1) + 1
            let position = (rows.wrappedValue.filter { !$0.deleted }.map(\.position).max() ?? 0) + TextRulerModel.defaultSpacing
            rows.wrappedValue.append(TabDraft(original: nil, kind: .left, position: position, leader: "", id: next))
        }
    }

    static func removing(_ id: Int, _ rows: Binding<[TabDraft]>) -> () -> Void {
        { if let index = rows.wrappedValue.firstIndex(where: { $0.id == id }) { rows.wrappedValue[index].deleted = true } }
    }

    static func committing(_ rows: [TabDraft], _ commit: @escaping ([TabDraft]) -> Void) -> () -> Void {
        { commit(rows) }
    }

    static func refusal(_ rows: [TabDraft]) -> String? {
        rows.lazy.filter { !$0.deleted }.compactMap(\.refusal).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tabs").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach($rows) { $row in
                        if !row.deleted {
                            HStack(alignment: .top) {
                                Form { TabFields(draft: $row) }
                                Button("Remove", systemImage: "minus.circle", action: Self.removing(row.id, $rows)).labelStyle(.iconOnly)
                                    .accessibilityIdentifier("tabs.remove.\(row.id)")
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            if let refusal = Self.refusal(rows) {
                Text(refusal).font(.caption).foregroundStyle(.red).accessibilityIdentifier("tabs.refused")
            }
            HStack {
                Button("Add", action: Self.adding($rows)).accessibilityIdentifier("tabs.add")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("tabs.cancel")
                Button("OK", action: Self.committing(rows, commit)).keyboardShortcut(.defaultAction)
                    .disabled(Self.refusal(rows) != nil).accessibilityIdentifier("tabs.ok")
            }
        }
        .padding()
        .frame(width: 380, height: 360)
        .accessibilityIdentifier("tabs")
    }
}

/// The ruler's double-click and the Paragraph section's btn:[Tabs…] (TYPE-024).
@MainActor
enum TabSheets {
    static let editIdentifier = NSUserInterfaceItemIdentifier("edit-tab-sheet")
    static let tableIdentifier = NSUserInterfaceItemIdentifier("tabs-sheet")
    /// Set by tests: sheets are built but not shown.
    static var showsSheets = true
    /// The sheet shown last (tests read it).
    private(set) static var presented: NSWindow?

    /// The targets of a ruler: the Text tool's selection in its block.
    static func targets(of session: TextEditingSession) -> [TextTarget] {
        guard let node = session.node, let text = session.text else { return [] }
        let range = session.selectedRange
        return [TextTarget(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound), range: range)]
    }

    /// The ruler's double-click at `position` (ruler points): the Edit Tab sheet on `window`.
    @discardableResult
    static func editTab(at position: Double, window: DocumentWindowController) -> NSWindow? {
        guard let session = window.objectEditing.textSession else { return nil }
        let editing = TabEditing(targets: targets(of: session), in: window.documentHandle.state)
        guard !editing.targets.isEmpty else { return nil }
        let tolerance = 5 / max((TypeWindowParts.parts(of: window)?.rulers.view.model?.scale ?? 1), 0.0001)
        return present(on: window.window, identifier: editIdentifier) { close in
            EditTabSheet(draft: editing.draft(at: position, tolerance: tolerance), commit: { draft in
                if let command = editing.commit(draft) { _ = window.objectEditing.perform(command) }
                close()
            }, cancel: close)
        }
    }

    /// The Paragraph section's btn:[Tabs…]: the table as a sheet on the document window.
    static func opening(_ model: ObjectPanelModel) -> () -> Void {
        { table(for: model, host: NSApp.mainWindow) }
    }

    /// btn:[Tabs…]: the table for `model`'s targets.
    @discardableResult
    static func table(for model: ObjectPanelModel, host: NSWindow?) -> NSWindow? {
        let editing = TabEditing(targets: model.textTargets, in: model.document.state)
        guard !editing.targets.isEmpty else { return nil }
        return present(on: host, identifier: tableIdentifier) { close in
            TabsTableSheet(rows: editing.rows, commit: { rows in
                if let command = editing.commit(rows: rows) { model.perform(command) }
                close()
            }, cancel: close)
        }
    }

    static func present<V: View>(on host: NSWindow?, identifier: NSUserInterfaceItemIdentifier, _ make: (@escaping () -> Void) -> V) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.identifier = identifier
        let close: () -> Void = { [weak sheet, weak host] in
            guard let sheet else { return }
            if let host, host.attachedSheet === sheet { host.endSheet(sheet) } else { sheet.orderOut(nil) }
        }
        sheet.contentViewController = NSHostingController(rootView: make(close))
        presented = sheet
        if showsSheets, let host { host.beginSheet(sheet) }
        return sheet
    }
}

fileprivate extension Double {
    /// Rounded to `places` decimals.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
