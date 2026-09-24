import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// The live notices of the page chapters (document-panel.adoc, "Working with others"; pages.adoc,
/// "Working with others"; DOC-004, DOC-008): when someone else's size for a page overrides the one
/// this person set a moment ago -- "Priya changed page 2 to A4 while you set it to Letter", with
/// *Reapply mine* -- and when someone removes a page this person had just drawn on -- "Page 3 was
/// removed by Tom; your 4 objects are on the pasteboard", with *Restore page*.
@MainActor
final class PageNotices {
    /// One notice and what its button does.
    struct Notice: Identifiable {
        let id = UUID()
        let text: String
        let action: String
        let command: any WTModel.Command
    }

    /// How long a local page size or new object counts as "a moment ago".
    static let recent: TimeInterval = 120

    private(set) var notices: [Notice] = []
    /// When it is now; replaceable in tests.
    var clock: @MainActor () -> Date = { Date() }
    /// This person's last size per page, with when it was set.
    private var mine: [OpID: (geometry: PageGeometry, at: Date)] = [:]
    /// Objects this person created, with when.
    private var created: [(id: OpID, at: Date)] = []

    init() {}

    static func describe(_ geometry: PageGeometry, units: Units) -> String {
        geometry.preset.isEmpty ? "\(units.format(geometry.width)) × \(units.format(geometry.height, suffix: true))" : geometry.preset
    }

    /// Takes a change to the pages (or a local change that created objects): remembers what this
    /// person did, and posts a notice when someone else's change undid it.  Returns whether a
    /// notice was posted.  `author` names the change's writer; `state` is the document now.
    @discardableResult
    func pagesChanged(_ change: PageListChange, author: String, units: Units, state: EngineState) -> Bool {
        let now = clock()
        created.removeAll { now.timeIntervalSince($0.at) > Self.recent }
        mine = mine.filter { now.timeIntervalSince($0.value.at) <= Self.recent }
        switch change.origin {
        case .local:
            for page in change.after.pages where change.before[page.id]?.ownGeometry != page.ownGeometry && change.before[page.id] != nil {
                mine[page.id] = (page.ownGeometry, now)
            }
            created += (change.change?.createdObjects ?? []).map { ($0, now) }
            return false
        case .remote:
            var posted = false
            for page in change.after.pages {
                guard let before = change.before[page.id], before.ownGeometry != page.ownGeometry,
                      let local = mine[page.id], local.geometry != page.ownGeometry else { continue }
                mine[page.id] = nil
                notices.append(Notice(text: "\(author) changed page \(page.number) to \(Self.describe(page.ownGeometry, units: units)) while you set it to \(Self.describe(local.geometry, units: units))",
                                      action: "Reapply mine", command: SetPageGeometry([page.id], to: local.geometry)))
                posted = true
            }
            for page in change.before.pages where change.after[page.id] == nil && !page.isSynthesized {
                let mineOnPage = created.map(\.id).filter { id in
                    state.isLive(id) && Objects.bounds(of: id, in: state).map { page.bleedRect.contains($0.center) } == true
                }
                guard !mineOnPage.isEmpty else { continue }
                let objects = mineOnPage.count == 1 ? "your object is" : "your \(mineOnPage.count) objects are"
                notices.append(Notice(text: "Page \(page.number) was removed by \(author); \(objects) on the pasteboard", action: "Restore page",
                                      command: OpsCommand("Restore page", ops: [Ops.setDeleted(page.id, false)])))
                posted = true
            }
            return posted
        }
    }

    /// Removes the notice `id` (dismissed, or its button pressed).
    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }
}
