import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Kerning Classes editor (kerning-metrics.adoc, "The Kerning Classes editor"; FONT-021): the
/// left and right classes with their members, the matrix of class kerns, the pair set of the
/// selected cell, Guess Classes, and the Exceptions list -- pair kerns between glyphs of kerned
/// classes, beside the class value.  Each button is one change.
@MainActor
@Observable
final class KerningClassesModel {
    struct Exception: Hashable, Identifiable {
        let id: OpID
        let left: String
        let right: String
        let value: Double
        let classValue: Double
    }

    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?
    var selectedClass: OpID?
    /// The *Members* field: glyph names or characters.
    var membersText = ""
    var newName = ""
    /// The matrix cell being edited.
    var cell: (left: OpID, right: OpID)?
    var cellText = ""
    /// Guess Classes' proposal, editable before btn:[Apply].
    var proposal: [(name: String, members: [OpID])] = []
    private(set) var message: String?
    /// Bumped by every change, so the lists re-read.
    private(set) var revision = 0
    @ObservationIgnored private var token: DocumentHandle.ObservationToken?

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?) {
        self.document = document
        self.perform = perform
        token = document.observe { [weak self] _ in self?.revision += 1 }
    }

    func stop() {
        if let token { document.stopObserving(token) }
        token = nil
    }

    var index: GlyphIndex { _ = revision; return GlyphIndex(document.state) }
    var kerning: Kerning { _ = revision; return Kerning(document.state) }

    func classes(_ side: KernSide) -> [Kerning.KernClass] { kerning.classes.filter { $0.side == side } }

    func name(of glyph: OpID) -> String { Self.name(of: glyph, in: index) }

    static func name(of glyph: OpID, in index: GlyphIndex) -> String { index[glyph]?.name ?? "?" }

    /// The glyphs a *Members* entry names: names, else each character's glyph.
    func glyphs(named text: String) -> [OpID] {
        let index = index
        return text.split(whereSeparator: { $0 == " " || $0 == "," }).flatMap { token -> [OpID] in
            if let glyph = index.glyph(named: String(token)) { return [glyph.id] }
            return token.unicodeScalars.compactMap { index.glyph(for: $0.value)?.id }
        }
    }

    /// btn:[+] under a list: a class named `newName`.
    @discardableResult
    func addClass(_ side: KernSide) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            message = "Type a class name"
            return nil
        }
        newName = ""
        return perform(CreateKernClass(name, side: side, members: glyphs(named: membersText)))
    }

    /// Adds the *Members* entry to the selected class; a glyph in another class of that side moves.
    @discardableResult
    func addMembers() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let selectedClass, let current = kerning.kernClass(selectedClass) else { return nil }
        let glyphs = glyphs(named: membersText)
        guard !glyphs.isEmpty else { return nil }
        let moved = glyphs.filter { glyph in kerning.kernClass(of: glyph, side: current.side).map { $0.id != selectedClass } == true }
        message = moved.isEmpty ? nil : "Moved \(moved.map(name(of:)).joined(separator: ", ")) from another class"
        membersText = ""
        return perform(EditKernClass(selectedClass, .addMembers(glyphs)))
    }

    @discardableResult
    func removeMember(_ glyph: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let selectedClass else { return nil }
        return perform(EditKernClass(selectedClass, .removeMembers([glyph])))
    }

    @discardableResult
    func removeClass() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let selectedClass else { return nil }
        self.selectedClass = nil
        return perform(EditKernClass(selectedClass, .remove))
    }

    /// A matrix cell's value ("" without one).
    func value(_ left: OpID, _ right: OpID) -> String {
        kerning.cell(left, right).map { FontUnits.format($0.value) } ?? ""
    }

    func select(cell left: OpID, _ right: OpID) {
        cell = (left, right)
        cellText = value(left, right)
    }

    /// The typed cell value.
    @discardableResult
    func commitCell() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let cell, let value = Double(cellText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return perform(SetClassKern(cell.left, cell.right, to: value))
    }

    /// The pair set of the selected cell: the first glyph of each class.
    var pairSet: String? {
        guard let cell, let left = kerning.kernClass(cell.left)?.members.first, let right = kerning.kernClass(cell.right)?.members.first else { return nil }
        return name(of: left) + " " + name(of: right)
    }

    /// Pair kerns between glyphs of kerned classes, with the class value.
    var exceptions: [Exception] {
        let kerning = kerning
        return kerning.effectivePairs.compactMap { pair in
            guard let classValue = kerning.classValue(pair.left, pair.right) else { return nil }
            return Exception(id: pair.id, left: name(of: pair.left), right: name(of: pair.right), value: pair.value, classValue: classValue)
        }
    }

    /// Removes an exception (the class value applies again).
    @discardableResult
    func removeException(_ exception: Exception) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let pair = kerning.effectivePairs.first(where: { $0.id == exception.id }) else { return nil }
        return perform(RemoveKernPairs([(pair.left, pair.right)]))
    }

    /// btn:[Guess Classes]: the proposal.
    func guess() {
        proposal = KerningGuesses.classes(in: index)
        message = proposal.isEmpty ? "No classes to propose" : nil
    }

    /// btn:[Apply] on the proposal: a left and a right class for each group, glyphs already in a
    /// class of that side left where they are; one change.
    @discardableResult
    func applyProposal() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let kerning = kerning
        var commands: [any WTModel.Command] = []
        for group in proposal {
            for side in [KernSide.left, .right] {
                let free = group.members.filter { kerning.kernClass(of: $0, side: side) == nil }
                guard free.count > 1 else { continue }
                commands.append(CreateKernClass(group.name, side: side, members: free))
            }
        }
        proposal = []
        guard !commands.isEmpty else { return nil }
        return perform(CompositeCommand("Guess classes", commands))
    }
}

/// The sheet.
struct KerningClassesSheet: View {
    @Bindable var model: KerningClassesModel
    let close: () -> Void

    enum Action: CaseIterable {
        case addMembers, removeClass, commitCell, applyProposal
    }

    static func run(_ action: Action, _ model: KerningClassesModel) -> () -> Void {
        { perform(action, model) }
    }

    static func perform(_ action: Action, _ model: KerningClassesModel) {
        switch action {
        case .addMembers: model.addMembers()
        case .removeClass: model.removeClass()
        case .commitCell: model.commitCell()
        case .applyProposal: model.applyProposal()
        }
    }

    static func adding(_ side: KernSide, _ model: KerningClassesModel) -> () -> Void {
        { model.addClass(side) }
    }

    static func selecting(_ cell: (OpID, OpID), _ model: KerningClassesModel) -> () -> Void {
        { model.select(cell: cell.0, cell.1) }
    }

    static func removing(_ glyph: OpID, _ model: KerningClassesModel) -> () -> Void {
        { model.removeMember(glyph) }
    }

    static func removingException(_ exception: KerningClassesModel.Exception, _ model: KerningClassesModel) -> () -> Void {
        { model.removeException(exception) }
    }

    @ViewBuilder
    func list(_ side: KernSide) -> some View {
        VStack(alignment: .leading) {
            Text(side == .left ? "Left classes" : "Right classes").font(.caption.bold())
            List(model.classes(side), selection: $model.selectedClass) { item in Text(item.name).tag(item.id) }
                .frame(height: 120)
            Button("+", action: Self.adding(side, model)).accessibilityIdentifier("classes.add.\(side == .left ? "left" : "right")")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kerning Classes").font(.headline)
            HStack(alignment: .top) {
                list(.left)
                list(.right)
            }
            HStack {
                TextField("New class name", text: $model.newName).accessibilityIdentifier("classes.name")
                TextField("Members", text: $model.membersText).accessibilityIdentifier("classes.members")
                Button("Add Members", action: Self.run(.addMembers, model)).disabled(model.selectedClass == nil)
                Button("Remove Class", action: Self.run(.removeClass, model)).disabled(model.selectedClass == nil)
            }
            if let selected = model.selectedClass, let item = model.kerning.kernClass(selected) {
                HStack {
                    ForEach(item.members, id: \.self) { glyph in
                        Button(model.name(of: glyph), action: Self.removing(glyph, model)).help("Remove from the class")
                    }
                }
            }
            Text("Matrix").font(.caption.bold())
            Grid {
                GridRow {
                    Text("")
                    ForEach(model.classes(.right)) { Text($0.name).font(.caption) }
                }
                ForEach(model.classes(.left)) { left in
                    GridRow {
                        Text(left.name).font(.caption)
                        ForEach(model.classes(.right)) { right in
                            Button(model.value(left.id, right.id).isEmpty ? "·" : model.value(left.id, right.id), action: Self.selecting((left.id, right.id), model))
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            HStack {
                TextField("Cell", text: $model.cellText).onSubmit(Self.run(.commitCell, model)).frame(width: 80).accessibilityIdentifier("classes.cell")
                if let pair = model.pairSet { Text(pair).font(.title3) }
            }
            HStack {
                Button("Guess Classes", action: model.guess).accessibilityIdentifier("classes.guess")
                if !model.proposal.isEmpty {
                    Text(model.proposal.map { "\($0.name): \($0.members.map(model.name(of:)).joined(separator: " "))" }.joined(separator: "; ")).font(.caption)
                    Button("Apply", action: Self.run(.applyProposal, model))
                }
            }
            Text("Exceptions").font(.caption.bold())
            ForEach(model.exceptions) { exception in
                HStack {
                    Text("\(exception.left) \(exception.right): \(FontUnits.format(exception.value)) (class \(FontUnits.format(exception.classValue)))")
                    Button("Remove", action: Self.removingException(exception, model))
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// The Auto Kern sheet (kerning-metrics.adoc, "Automatic kerning"): the scope, the separation
/// (suggested from `n` `n`), the minimum kern, *Replace existing values*, btn:[Preview] and
/// btn:[Apply] -- one change.
@MainActor
@Observable
final class AutoKernModel {
    enum Scope: String, CaseIterable, Identifiable {
        case allClasses = "All classes", selectedClasses = "Selected classes", selectedGlyphs = "Selected glyphs"
        var id: String { rawValue }
    }

    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?
    var scope = Scope.allClasses
    var separation: Double
    var minimum = 5.0
    var replace = false
    /// The glyphs the grid selects, and the classes chosen.
    var glyphs: [OpID]
    var classes: [OpID] = []
    private(set) var preview: [(left: String, right: String, value: Double)] = []

    init(document: DocumentHandle, glyphs: [OpID], perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?) {
        self.document = document
        self.glyphs = glyphs
        self.perform = perform
        separation = AutoKern.suggestedSeparation(in: document.state) ?? 100
    }

    /// The pairs measured: class representatives (the first member) or glyph pairs.
    var pairs: [(left: OpID, right: OpID, cell: (OpID, OpID)?)] {
        let kerning = Kerning(document.state)
        switch scope {
        case .selectedGlyphs:
            return glyphs.flatMap { left in glyphs.map { (left, $0, nil) } }
        case .allClasses, .selectedClasses:
            let chosen = scope == .allClasses ? kerning.classes : kerning.classes.filter { classes.contains($0.id) }
            let lefts = chosen.filter { $0.side == .left && !$0.members.isEmpty }, rights = chosen.filter { $0.side == .right && !$0.members.isEmpty }
            return lefts.flatMap { left in rights.map { (left.members[0], $0.members[0], (left.id, $0.id)) } }
        }
    }

    /// The values Auto Kern would write, existing ones kept unless *Replace existing values*.
    var values: [(left: OpID, right: OpID, cell: (OpID, OpID)?, value: Double)] {
        let kerning = Kerning(document.state)
        let pairs = pairs
        let measured = AutoKern(separation: separation, minimum: minimum).values(pairs.map { ($0.left, $0.right) }, in: document.state)
        var values: [[OpID]: Double] = [:]
        for value in measured { values[[value.left, value.right]] = value.value }
        return pairs.compactMap { pair in
            guard let value = values[[pair.left, pair.right]] else { return nil }
            let exists = pair.cell.map { kerning.cell($0.0, $0.1) != nil } ?? (kerning.pair(pair.left, pair.right) != nil)
            return exists && !replace ? nil : (pair.left, pair.right, pair.cell, value)
        }
    }

    /// btn:[Preview].
    func showPreview() {
        let index = GlyphIndex(document.state)
        preview = values.map { (KerningClassesModel.name(of: $0.left, in: index), KerningClassesModel.name(of: $0.right, in: index), $0.value) }
    }

    /// btn:[Apply]: one change.
    @discardableResult
    func apply() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let values = values
        guard !values.isEmpty else { return nil }
        let cells: [any WTModel.Command] = values.compactMap { value in value.cell.map { SetClassKern($0.0, $0.1, to: value.value) } }
        let pairs = values.filter { $0.cell == nil }.map { ($0.left, $0.right, $0.value) }
        var commands = cells
        if !pairs.isEmpty { commands.append(ApplyAutoKern(pairs)) }
        return perform(CompositeCommand("Auto kern \(values.count) cells", commands))
    }
}

struct AutoKernSheet: View {
    @Bindable var model: AutoKernModel
    let close: () -> Void

    static func applying(_ model: AutoKernModel, close: @escaping () -> Void) -> () -> Void {
        {
            model.apply()
            close()
        }
    }

    var body: some View {
        Form {
            Text("Auto Kern").font(.headline)
            Picker("Kern", selection: $model.scope) { ForEach(AutoKernModel.Scope.allCases) { Text($0.rawValue).tag($0) } }
                .accessibilityIdentifier("autoKern.scope")
            TextField("Separation", value: $model.separation, format: .number).accessibilityIdentifier("autoKern.separation")
            TextField("Minimum kern", value: $model.minimum, format: .number)
            Toggle("Replace existing values", isOn: $model.replace).toggleStyle(.checkbox)
            if !model.preview.isEmpty {
                ForEach(Array(model.preview.enumerated()), id: \.offset) { _, row in Text("\(row.left) \(row.right): \(FontUnits.format(row.value))").font(.caption) }
            }
            HStack {
                Button("Preview", action: model.showPreview).accessibilityIdentifier("autoKern.preview")
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply", action: Self.applying(model, close: close)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
