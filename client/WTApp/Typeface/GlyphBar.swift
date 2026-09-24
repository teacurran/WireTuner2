import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// How the typeface sheets and bars perform a command: the window's object commands, returning
/// the task that applies it (nil when the window is gone).
typealias TypefacePerform = @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?

/// Font-unit numbers as the typeface fields show them: whole units without a fraction, else up to
/// two decimals.
enum FontUnits {
    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// A typed number (font units), nil when it is not one.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

/// The glyph bar under a glyph tab's title bar (glyph-editing.adoc, "Spacing"; FONT-011): the
/// previous and next glyph, the glyph's name and Unicode, and its advance width and side
/// bearings in font units -- derived from the flattened outline (`GlyphOutlines.metrics`), and
/// typing one moves the artwork or changes the width.
@MainActor
@Observable
final class GlyphBarModel {
    @ObservationIgnored let document: DocumentHandle
    let glyph: OpID
    @ObservationIgnored let perform: TypefacePerform
    @ObservationIgnored var step: @MainActor (Int) -> Void = { _ in }
    @ObservationIgnored var showParts: @MainActor () -> Void = {}
    @ObservationIgnored var fit: @MainActor () -> Void = {}
    private(set) var name = ""
    private(set) var unicode = ""
    var widthText = ""
    var leftText = ""
    var rightText = ""
    /// Whether the glyph has an outline (side bearings are editable only then).
    private(set) var hasOutline = false
    private(set) var problem: String?

    init(document: DocumentHandle, glyph: OpID, perform: @escaping TypefacePerform) {
        self.document = document
        self.glyph = glyph
        self.perform = perform
        reload()
    }

    static let invalidNumber = "Type a number of font units"

    /// Reads the glyph and its metrics again.
    func reload() {
        let state = document.state
        guard let read = GlyphIndex(state)[glyph], let metrics = GlyphOutlines.metrics(of: glyph, in: state) else { return }
        name = read.name
        unicode = read.codepoints.map { String(format: "U+%04X", $0) }.joined(separator: " ")
        hasOutline = metrics.bounds != nil
        widthText = FontUnits.format(metrics.advanceWidth)
        leftText = FontUnits.format(metrics.leftSideBearing)
        rightText = FontUnits.format(metrics.rightSideBearing)
    }

    /// The Width field: `SetGlyphWidth`.
    @discardableResult
    func commitWidth() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let width = FontUnits.parse(widthText), width >= 0 else { return refuse() }
        return run(SetGlyphWidth([glyph], to: width))
    }

    /// The LSB field: moves the artwork; with `keepRSB` the width grows by the same amount.
    @discardableResult
    func commitLeft(keepRSB: Bool = false) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let value = FontUnits.parse(leftText) else { return refuse() }
        return run(SetGlyphBearings([glyph], .left(value, keepRSB: keepRSB)))
    }

    /// The RSB field: changes the width.
    @discardableResult
    func commitRight() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let value = FontUnits.parse(rightText) else { return refuse() }
        return run(SetGlyphBearings([glyph], .right(value)))
    }

    /// btn:[Center]: equal side bearings in the current width.
    @discardableResult
    func center() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        run(SetGlyphBearings([glyph], .center))
    }

    // The bar's controls.
    func previous() { step(-1) }
    func next() { step(1) }
    func submitWidth() { commitWidth() }
    func submitLeft() { commitLeft() }
    func submitRight() { commitRight() }
    func submitCenter() { center() }

    private func refuse() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        problem = Self.invalidNumber
        reloadSoon()
        return nil
    }

    private func run(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        problem = nil
        let task = perform(command)
        Task { [weak self] in
            _ = await task?.value
            self?.reload()
        }
        return task
    }

    private func reloadSoon() {
        Task { [weak self] in self?.reload() }
    }
}

struct GlyphBar: View {
    @Bindable var model: GlyphBarModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.previous) { Image(systemName: "chevron.left") }
                .help("Previous Glyph").accessibilityIdentifier("glyphBar.previous")
            Button(action: model.next) { Image(systemName: "chevron.right") }
                .help("Next Glyph").accessibilityIdentifier("glyphBar.next")
            Text(model.name).font(.headline).accessibilityIdentifier("glyphBar.name")
            Text(model.unicode).font(.caption).foregroundStyle(.secondary)
            Spacer()
            field("Width", text: $model.widthText, id: "glyphBar.width", commit: model.submitWidth)
            field("LSB", text: $model.leftText, id: "glyphBar.lsb", commit: model.submitLeft).disabled(!model.hasOutline)
            field("RSB", text: $model.rightText, id: "glyphBar.rsb", commit: model.submitRight).disabled(!model.hasOutline)
            Button("Center", action: model.submitCenter).disabled(!model.hasOutline).accessibilityIdentifier("glyphBar.center")
            Button("Components and Anchors…", action: model.showParts).accessibilityIdentifier("glyphBar.parts")
            Button("Fit", action: model.fit).accessibilityIdentifier("glyphBar.fit")
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func field(_ title: String, text: Binding<String>, id: String, commit: @escaping @MainActor () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption)
            TextField(title, text: text).frame(width: 56).onSubmit(commit).accessibilityIdentifier(id)
        }
    }
}

// MARK: Components and anchors

/// menu:Glyph[Components and Anchors…] (glyph-editing.adoc, "Components" and "Anchors";
/// FONT-012, FONT-013): the glyph's components with their source and offset -- add by glyph name
/// (placed by anchor arithmetic when a base/mark pair matches), remove, decompose -- and its
/// anchors with name, position (font y) and role -- add, move, remove.  Each button is one change.
@MainActor
@Observable
final class GlyphPartsModel {
    struct ComponentRow: Identifiable, Hashable {
        let id: OpID
        let source: String
        let x: Double
        let y: Double
        let status: String
    }

    struct AnchorRow: Identifiable, Hashable {
        let id: OpID
        let name: String
        let x: Double
        let y: Double
        let isMark: Bool
        let isDuplicate: Bool

        /// A duplicate name (read as `name.dupN`) shows in red.
        var color: Color { isDuplicate ? .red : .primary }
    }

    @ObservationIgnored let document: DocumentHandle
    let glyph: OpID
    @ObservationIgnored let perform: TypefacePerform
    private(set) var components: [ComponentRow] = []
    private(set) var anchors: [AnchorRow] = []
    var componentName = ""
    var anchorName = "top"
    var anchorX = "0"
    var anchorY = "0"
    private(set) var problem: String?

    init(document: DocumentHandle, glyph: OpID, perform: @escaping TypefacePerform) {
        self.document = document
        self.glyph = glyph
        self.perform = perform
        reload()
    }

    static let unknownGlyph = "No glyph has that name"
    static let invalidAnchor = "Type an anchor name (letters, digits, . and _) and a position in font units"

    func reload() {
        let state = document.state
        let index = GlyphIndex(state)
        guard let read = index[glyph] else { return }
        components = read.components.map { component in
            let source = component.source.flatMap { index[$0]?.name } ?? "—"
            return ComponentRow(id: component.id, source: source, x: component.transform.tx, y: -component.transform.ty,
                                status: Self.label(of: component.status))
        }
        anchors = read.anchors.map { AnchorRow(id: $0.id, name: $0.name, x: $0.position.x, y: -$0.position.y, isMark: $0.role == .mark, isDuplicate: $0.isDuplicate) }
    }

    /// What a component row says about its status.
    static func label(of status: GlyphComponent.Status) -> String {
        switch status {
        case .resolved: ""
        case .dangling: "removed"
        case .loop: "loop"
        }
    }

    /// btn:[Add Component]: the glyph named in the field.
    @discardableResult
    func addComponent() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let source = GlyphIndex(document.state).glyph(named: componentName.trimmingCharacters(in: .whitespaces)) else {
            problem = Self.unknownGlyph
            return nil
        }
        return run(AddComponent(source.id, to: glyph))
    }

    @discardableResult
    func removeComponent(_ id: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        run(RemoveComponents([id], of: glyph))
    }

    /// btn:[Decompose] on a row, or every component (nil).
    @discardableResult
    func decompose(_ id: OpID? = nil) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        run(DecomposeComponents(glyph, components: id.map { [$0] }))
    }

    /// btn:[Add Anchor]: name and position from the fields (font y; stored y is its negation).
    @discardableResult
    func addAnchor() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let name = anchorName.trimmingCharacters(in: .whitespaces)
        guard name.count <= 63, name.range(of: "^[A-Za-z0-9._]+$", options: .regularExpression) != nil, let x = FontUnits.parse(anchorX), let y = FontUnits.parse(anchorY) else {
            problem = Self.invalidAnchor
            return nil
        }
        return run(AddAnchor(name, at: Point(x: x, y: -y), to: glyph))
    }

    /// Moves anchor `id` to (`x`, `y`) in font units.
    @discardableResult
    func moveAnchor(_ id: OpID, x: Double, y: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        run(EditAnchor(id, of: glyph, .move(Point(x: x, y: -y))))
    }

    /// Switches anchor `id` between a base anchor and a mark anchor.
    @discardableResult
    func toggleRole(_ id: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let isMark = anchors.contains { $0.id == id && $0.isMark }
        return run(EditAnchor(id, of: glyph, .role(isMark ? .base : .mark)))
    }

    @discardableResult
    func removeAnchor(_ id: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        run(EditAnchor(id, of: glyph, .remove))
    }

    private func run(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        problem = nil
        let task = perform(command)
        Task { [weak self] in
            _ = await task?.value
            self?.reload()
        }
        return task
    }

    /// The sheet's buttons.
    enum Action {
        case addComponent, removeComponent, decompose, addAnchor, toggleRole, removeAnchor
    }

    /// What the button for `action` on row `id` (nil: the whole glyph or the fields) does.
    func action(_ action: Action, _ id: OpID? = nil) -> @MainActor () -> Void {
        {
            switch (action, id) {
            case (.addComponent, _): self.addComponent()
            case (.removeComponent, let id?): self.removeComponent(id)
            case (.decompose, let id): self.decompose(id)
            case (.addAnchor, _): self.addAnchor()
            case (.toggleRole, let id?): self.toggleRole(id)
            case (.removeAnchor, let id?): self.removeAnchor(id)
            case (.removeComponent, nil), (.toggleRole, nil), (.removeAnchor, nil): break
            }
        }
    }
}

struct GlyphPartsSheet: View {
    @Bindable var model: GlyphPartsModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Components and Anchors").font(.headline)
            Text("Components").font(.subheadline)
            ForEach(model.components) { row in
                HStack {
                    Text(row.source).frame(width: 120, alignment: .leading)
                    Text("\(FontUnits.format(row.x)), \(FontUnits.format(row.y))").foregroundStyle(.secondary)
                    if !row.status.isEmpty { Text(row.status).foregroundStyle(.red) }
                    Spacer()
                    Button("Decompose", action: model.action(.decompose, row.id))
                    Button("Remove", action: model.action(.removeComponent, row.id))
                }
            }
            HStack {
                TextField("Glyph name", text: $model.componentName).accessibilityIdentifier("parts.componentName")
                Button("Add Component", action: model.action(.addComponent)).accessibilityIdentifier("parts.addComponent")
                Button("Decompose All", action: model.action(.decompose)).disabled(model.components.isEmpty)
            }
            Divider()
            Text("Anchors").font(.subheadline)
            ForEach(model.anchors) { row in
                HStack {
                    Text(row.name).frame(width: 120, alignment: .leading).foregroundStyle(row.color)
                    Text("\(FontUnits.format(row.x)), \(FontUnits.format(row.y))").foregroundStyle(.secondary)
                    Spacer()
                    Button(row.isMark ? "Mark" : "Base", action: model.action(.toggleRole, row.id))
                    Button("Remove", action: model.action(.removeAnchor, row.id))
                }
            }
            HStack {
                TextField("Name", text: $model.anchorName).frame(width: 90).accessibilityIdentifier("parts.anchorName")
                TextField("x", text: $model.anchorX).frame(width: 60)
                TextField("y", text: $model.anchorY).frame(width: 60)
                Button("Add Anchor", action: model.action(.addAnchor)).accessibilityIdentifier("parts.addAnchor")
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
    }
}
