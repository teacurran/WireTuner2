import Foundation
import Observation
import WTText

/// The families and styles the substitute pickers list (`FontManager` in the app).
protocol FontCatalog {
    func families() -> [String]
    func styles(of family: String) -> [String]
}

extension FontManager: FontCatalog {}

/// The team font libraries (font-substitution.adoc, "Team font library"): whether they can be
/// reached, which team a document belongs to, the families a team's library offers and the files
/// of a family, fetched into the blob cache (WTSync's `FontLibraryClient` in the app).
@MainActor
protocol TeamFontLibrary: AnyObject {
    var isOnline: Bool { get }
    /// The team whose library a document uses; nil for a personal document.
    func team(of documentID: String) -> String?
    func families(team: String) async -> Set<String>
    func files(forFamily family: String, team: String) async throws -> [URL]
}

/// One document's team library, as the sheet uses it.
@MainActor
struct TeamFonts {
    let isOnline: Bool
    let families: Set<String>
    /// The font files of a family, to be activated for this process.
    let fetch: @MainActor (String) async throws -> [URL]
}

/// What the Missing Fonts sheet decided (font-substitution.adoc, "The Missing Fonts sheet").
struct MissingFontsDecision: Equatable {
    /// Substitutions for this document on this Mac only.
    var documentRows: [FontSubstitution] = []
    /// Substitutions remembered in the preference, for every document.
    var rememberedRows: [FontSubstitution] = []
    /// Replacements written to the document, as one change.
    var replacements: [ReplaceFonts.Replacement] = []
}

/// The Missing Fonts sheet (font-substitution.adoc; DOC-024): each missing face with its style
/// and the substitute in effect; btn:[Select All], btn:[Substitute…] (with *Remember this
/// substitution*, on by default), btn:[Replace…], *Keep original name* per face (off is the same
/// as replacing), and btn:[Fetch from team library] for faces the team's library has, greyed and
/// explained offline.  btn:[Open] turns the choices into a `MissingFontsDecision`.
@MainActor
@Observable
final class MissingFontsModel {
    enum Choice: Hashable {
        /// The default substitute (doing nothing).
        case defaultSubstitute
        case substitute(FaceName, remember: Bool)
        case replace(FaceName)
    }

    struct Row: Identifiable, Hashable {
        let face: FaceName
        var choice = Choice.defaultSubstitute
        var keepOriginalName = true
        /// The team's library has the family (fetch it instead of substituting).
        var inTeamLibrary = false
        var id: FaceName { face }
    }

    /// What btn:[Substitute…] or btn:[Replace…] is choosing a face for.
    enum Picking: Hashable {
        case substitute, replace
    }

    static let offlineHelp = "Fonts from your team's library can be fetched when you are back online."

    private(set) var rows: [Row]
    var selected: Set<FaceName> = []
    /// *Remember this substitution*.
    var remember = true
    let defaultSubstitute: FaceName
    @ObservationIgnored let catalog: any FontCatalog
    @ObservationIgnored let team: TeamFonts?
    /// Activates a fetched font file (`FontManager.activate(fontsAt:)`); returns the faces now
    /// available.
    @ObservationIgnored var activate: @MainActor (URL) throws -> [FaceName] = { try FontManager.shared.activate(fontsAt: $0, source: .teamLibrary) }
    /// Called after fonts were activated (the canvases repaint).
    @ObservationIgnored var didActivate: @MainActor () -> Void = {}
    private(set) var isFetching = false
    /// Why the last fetch failed, if it did.
    private(set) var fetchError: String?

    // The picker.
    private(set) var picking: Picking?
    var pickerFamily: String? {
        didSet { if pickerFamily != oldValue { pickerStyle = nil } }
    }
    var pickerStyle: String?

    init(faces: [FaceName], defaultSubstitute: FaceName, catalog: any FontCatalog, team: TeamFonts? = nil) {
        let families = team?.families ?? []
        rows = faces.sorted { $0.description < $1.description }.map { Row(face: $0, inTeamLibrary: families.contains($0.family)) }
        self.defaultSubstitute = defaultSubstitute
        self.catalog = catalog
        self.team = team
    }

    // MARK: Selecting

    func selectAll() {
        selected = Set(rows.map(\.face))
    }

    func toggle(_ face: FaceName) {
        if selected.contains(face) { selected.remove(face) } else { selected.insert(face) }
    }

    /// Whether btn:[Substitute…] and btn:[Replace…] have something to act on.
    var hasSelection: Bool { !selected.isEmpty }

    // MARK: Choosing

    /// btn:[Substitute…] or btn:[Replace…]: the picker opens.
    func beginPicking(_ picking: Picking) {
        guard hasSelection else { return }
        self.picking = picking
        pickerFamily = nil
    }

    /// btn:[Substitute…].
    func beginSubstitute() { beginPicking(.substitute) }

    /// btn:[Replace…].
    func beginReplace() { beginPicking(.replace) }

    func cancelPicking() {
        picking = nil
    }

    var families: [String] { catalog.families() }

    var styles: [String] { pickerFamily.map(catalog.styles(of:)) ?? [] }

    /// The picker's btn:[OK]: the chosen face (a style keeps each run's own when none is chosen)
    /// becomes the selected rows' substitute or replacement.
    func commitPicking() {
        guard let picking, let family = pickerFamily else { return }
        let face = FaceName(family: family, style: pickerStyle)
        switch picking {
        case .substitute: substitute(with: face)
        case .replace: replace(with: face)
        }
        self.picking = nil
    }

    /// The selected faces are shown in `face` on this Mac (remembered when *Remember this
    /// substitution* is on).
    func substitute(with face: FaceName) {
        update { $0.choice = .substitute(face, remember: remember) }
    }

    /// The selected faces are changed to `face` in the document.
    func replace(with face: FaceName) {
        update { $0.choice = .replace(face) }
    }

    private func update(_ change: (inout Row) -> Void) {
        for index in rows.indices where selected.contains(rows[index].face) { change(&rows[index]) }
    }

    func setKeepOriginalName(_ keep: Bool, for face: FaceName) {
        guard let index = rows.firstIndex(where: { $0.face == face }) else { return }
        rows[index].keepOriginalName = keep
    }

    /// The face laid out in `row`'s place (a substitute without a style keeps the run's).
    func substitute(for row: Row) -> FaceName {
        let chosen: FaceName
        switch row.choice {
        case .defaultSubstitute: chosen = defaultSubstitute
        case .substitute(let face, _), .replace(let face): chosen = face
        }
        return FaceName(family: chosen.family, style: chosen.style ?? row.face.style)
    }

    /// What the list shows in the row's substitute column.
    func caption(for row: Row) -> String {
        switch row.choice {
        case .defaultSubstitute: "\(substitute(for: row)) (default)"
        case .substitute(_, let remember): "\(substitute(for: row))\(remember ? " (remembered)" : "")"
        case .replace: "Replace with \(substitute(for: row))"
        }
    }

    // MARK: Team library

    /// Whether btn:[Fetch from team library] is available: online, a listed face in the library,
    /// no fetch running.
    var canFetch: Bool { team?.isOnline == true && rows.contains(where: \.inTeamLibrary) && !isFetching }

    /// The button's explanation when it is greyed for being offline.
    var fetchHelp: String? {
        team?.isOnline == false && rows.contains(where: \.inTeamLibrary) ? Self.offlineHelp : nil
    }

    /// Fetches and activates the listed faces the team's library has; the ones now available
    /// leave the list.
    func fetch() async {
        guard canFetch, let team else { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        var available: Set<String> = []
        for family in Set(rows.filter(\.inTeamLibrary).map(\.face.family)).sorted() {
            do {
                for url in try await team.fetch(family) { available.formUnion(try activate(url).map(\.family)) }
            } catch {
                fetchError = "“\(family)” could not be fetched: \(error.localizedDescription)"
            }
        }
        if !available.isEmpty { didActivate() }
        rows.removeAll { available.contains($0.face.family) }
        selected = selected.filter { face in rows.contains { $0.face == face } }
    }

    // MARK: Deciding

    /// btn:[Open]: substitutions (for this document, or remembered) and replacements -- a
    /// substitute or the default substitute with *Keep original name* off replaces.
    var decision: MissingFontsDecision {
        var decision = MissingFontsDecision()
        for row in rows {
            let substitute = FontSubstitution(missing: row.face, substitute: substitute(for: row))
            switch row.choice {
            case .replace(let face):
                decision.replacements.append(ReplaceFonts.Replacement(old: row.face, new: face))
            case _ where !row.keepOriginalName:
                decision.replacements.append(ReplaceFonts.Replacement(old: row.face, new: substitute.substitute))
            case .substitute(_, let remember):
                if remember { decision.rememberedRows.append(substitute) } else { decision.documentRows.append(substitute) }
            case .defaultSubstitute:
                break
            }
        }
        return decision
    }
}
