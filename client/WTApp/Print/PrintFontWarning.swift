import AppKit
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel
import WTRender
import WTText

/// The pane's missing-font warning (PRINT-014; print-fonts.adoc, "Missing fonts"): the faces the
/// printed text names that resolve through substitution on this Mac, read from the job's sheets --
/// text on the pasteboard or on pages the job does not print is left out -- and shown at the top of
/// the *{product}* pane as "2 missing fonts: Univers, Garamond".
struct PrintFontWarning: Equatable {
    /// The missing faces on the printed pages, by name.
    var faces: [FaceName] = []
    /// Missing families the team library offers that this Mac has not fetched yet.
    var pending: Set<String> = []

    /// The missing families, each once, sorted.
    var families: [String] { Array(Set(faces.map(\.family))).sorted() }

    /// The warning's text; nil when nothing is missing.
    var message: String? {
        let families = families
        guard !families.isEmpty else { return nil }
        let count = families.count == 1 ? "1 missing font" : "\(families.count) missing fonts"
        let waiting = families.contains(where: pending.contains) ? " (waiting for the team library)" : ""
        return "\(count): \(families.joined(separator: ", "))\(waiting)"
    }
}

/// How a Print dialog checks its job's fonts: the *Warn about missing fonts before printing*
/// preference, the faces each text node of the document names (`DocumentFontIndex`), the font
/// manager's report over faces, and the substitution sheet a click on the warning opens.
@MainActor
struct PrintFontChecker {
    var warns: @MainActor () -> Bool
    var faces: @MainActor () -> [OpID: Set<FaceName>]
    var report: @MainActor (Set<FaceName>) -> FontReport
    /// Opens the substitution sheet over the faces; `done` runs once it closes.
    var substitute: @MainActor (_ faces: [FaceName], _ done: @escaping @MainActor () -> Void) -> Void

    /// The warning for `plan`: nothing when the preference is off.
    func check(_ plan: PrintPlan) -> PrintFontWarning {
        guard warns() else { return PrintFontWarning() }
        let byNode = faces()
        let named = PrintFontCheck(plan: plan).textNodes.reduce(into: Set<FaceName>()) { $0.formUnion(byNode[OpID($1)] ?? []) }
        let report = report(named)
        return PrintFontWarning(faces: report.substitutedFaces.keys.sorted { $0.description < $1.description }, pending: report.teamLibraryPending)
    }

    /// The checker for `document` in the app: nil until its font index exists.
    static func make(fonts: DocumentFonts, preferences: PreferenceStore, document: DocumentHandle) -> PrintFontChecker? {
        guard let index = fonts.index(for: document.id) else { return nil }
        return PrintFontChecker(
            warns: { preferences[PreferenceCatalog.Printing.warnMissingFonts] },
            faces: { index.faces },
            report: { index.report(for: $0) },
            substitute: { faces, done in fonts.presentSubstitutions(faces, for: document, index: index, done: done) }
        )
    }
}

extension DocumentFonts {
    /// The substitution sheet over `faces`, from the Print dialog: a sheet on the print panel.
    /// Substitutions are remembered or kept for this document as on open; replacements are one
    /// change on btn:[Open].  btn:[Cancel] only closes the sheet.
    @discardableResult
    func presentSubstitutions(_ faces: [FaceName], for document: DocumentHandle, index: DocumentFontIndex,
                              on parent: NSWindow? = NSApp.modalWindow ?? NSApp.keyWindow, done: @escaping @MainActor () -> Void) -> MissingFontsModel {
        let model = MissingFontsModel(faces: faces, defaultSubstitute: index.substitutions.defaultSubstitute, catalog: index.manager)
        model.didActivate = { [weak self] in self?.fontsChanged() }
        let shown = ShownSheet()
        let finish: @MainActor (Bool) -> Void = { [weak self] open in
            if let sheet = shown.window { sheet.sheetParent?.endSheet(sheet) ?? sheet.close() }
            Task { @MainActor in
                await self?.applySubstitutions(model.decision, open: open, document: document, index: index)
                done()
            }
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: MissingFontsSheet(model: model, finish: finish)))
        sheet.title = "Missing Fonts"
        sheet.identifier = NSUserInterfaceItemIdentifier("print-missing-fonts")
        shown.window = sheet
        if let parent { parent.beginSheet(sheet) } else { sheet.makeKeyAndOrderFront(nil) }
        return model
    }

    /// What the sheet decided: rows remembered or kept for the document, replacements on
    /// btn:[Open].
    func applySubstitutions(_ decision: MissingFontsDecision, open: Bool, document: DocumentHandle, index: DocumentFontIndex) async {
        FontSubstitutionRows.remember(decision.rememberedRows, in: preferences)
        if !decision.documentRows.isEmpty {
            let rows = await substitutions.rows(for: document) + decision.documentRows
            await substitutions.setRows(rows, for: document)
            index.documentSubstitutions = rows
        }
        fontsChanged()
        if open, !decision.replacements.isEmpty {
            _ = await document.perform(ReplaceFont(decision.replacements)).value
        }
    }
}

/// The substitution sheet's window, once it exists (its buttons close it).
@MainActor
private final class ShownSheet {
    weak var window: NSWindow?
}

/// The warning row at the top of the pane: a click opens the substitution sheet.
struct PrintFontWarningView: View {
    let model: PrintPaneModel

    var body: some View {
        if let message = model.fonts.message {
            Button(action: model.showSubstitutions) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .buttonStyle(.link)
            .help("Choose substitutes for the missing fonts")
            .accessibilityIdentifier("print.missingFonts")
        }
    }
}
