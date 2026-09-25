import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Find Problems panel (glyph-editing.adoc, "Checking a glyph"; FONT-014): the checks of the
/// current glyph (a glyph tab's) or of the whole font (`FontValidation`), errors first; a row opens
/// its glyph, a fix button runs the Glyph menu's command for it (*Correct Directions* is the
/// generator's, *Round to Units* rounds the glyph's points, *Remove Component* removes the
/// components that no longer resolve), and btn:[Select in Grid] selects the glyphs with problems.
@MainActor
@Observable
final class FindProblemsModel {
    enum Scope: String, CaseIterable, Identifiable {
        case glyph = "Current glyph", font = "Font"
        var id: String { rawValue }
    }

    /// A fix a row offers.
    enum Fix: String {
        case roundToUnits = "Round to Units"
        case removeComponent = "Remove Component"
    }

    var scope = Scope.font
    @ObservationIgnored let selection: ActiveSelection?
    /// Opens a glyph from the front window.
    @ObservationIgnored var openGlyph: @MainActor (OpID) -> Void = { _ in }
    /// Selects glyphs in the document's grid.
    @ObservationIgnored var selectInGrid: @MainActor ([OpID]) -> Void = { _ in }
    private(set) var revision = 0
    /// The document watched, so the list checks again after each change.
    @ObservationIgnored private var watched: (document: DocumentHandle, token: DocumentHandle.ObservationToken)?

    init(selection: ActiveSelection?) {
        self.selection = selection
    }

    var document: DocumentHandle? { selection?.document }

    /// The glyph the front window edits, when it is a glyph tab.
    var currentGlyph: OpID? { document?.canvasNode }

    /// The problems in the scope.
    var problems: [FontProblem] {
        _ = revision
        guard let document else { return [] }
        watch(document)
        guard DocumentKind(document.state) == .typeface else { return [] }
        let all = FontValidation.problems(in: document.state)
        guard scope == .glyph else { return all }
        guard let glyph = currentGlyph else { return [] }
        return all.filter { $0.glyph == glyph }
    }

    /// The glyphs with problems.
    var glyphs: [OpID] {
        var seen: Set<OpID> = []
        return problems.compactMap(\.glyph).filter { seen.insert($0).inserted }
    }

    static func fix(for problem: FontProblem) -> Fix? {
        switch problem.kind {
        case .offGrid: .roundToUnits
        case .danglingComponent, .componentLoop: .removeComponent
        default: nil
        }
    }

    /// Runs `fix` on the problem's glyph, one change.
    @discardableResult
    func run(_ fix: Fix, for problem: FontProblem) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let glyph = problem.glyph, let document else { return nil }
        let command: (any WTModel.Command)? = switch fix {
        case .roundToUnits: RoundGlyphPoints(glyph)
        case .removeComponent: GlyphComponentFixes.removal(glyph, in: document.state)
        }
        guard let command else { return nil }
        let task = selection?.editing?.perform(command) ?? document.perform(command)
        return Task { @MainActor in
            let change = await task.value
            self.revision += 1
            return change
        }
    }

    func refresh() { revision += 1 }

    /// Follows `document`'s changes (the front window's document).
    func watch(_ document: DocumentHandle) {
        guard watched?.document !== document else { return }
        if let watched { watched.document.stopObserving(watched.token) }
        let token = document.observe { [weak self] _ in self?.revision += 1 }
        watched = (document, token)
    }
}

struct FindProblemsView: View {
    @Bindable var model: FindProblemsModel

    static func opening(_ glyph: OpID?, _ model: FindProblemsModel) -> () -> Void {
        { if let glyph { model.openGlyph(glyph) } }
    }

    static func fixing(_ fix: FindProblemsModel.Fix, _ problem: FontProblem, _ model: FindProblemsModel) -> () -> Void {
        { model.run(fix, for: problem) }
    }

    static func selecting(_ model: FindProblemsModel) -> () -> Void {
        { model.selectInGrid(model.glyphs) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Check", selection: $model.scope) { ForEach(FindProblemsModel.Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("problems.scope")
                Button("Check Again", action: model.refresh)
            }
            let problems = model.problems
            if problems.isEmpty {
                Text("No problems found").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("problems.none")
            }
            List(Array(problems.enumerated()), id: \.offset) { _, problem in
                HStack {
                    Image(systemName: problem.level == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(problem.level == .error ? Color.red : Color.orange)
                    Button(problem.message, action: Self.opening(problem.glyph, model)).buttonStyle(.plain)
                    Spacer()
                    if let fix = FindProblemsModel.fix(for: problem) {
                        Button(fix.rawValue, action: Self.fixing(fix, problem, model)).font(.caption)
                    }
                }
            }
            .accessibilityIdentifier("problems.list")
            Button("Select in Grid", action: Self.selecting(model)).disabled(model.glyphs.isEmpty).accessibilityIdentifier("problems.select")
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
