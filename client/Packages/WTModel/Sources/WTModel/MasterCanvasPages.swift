import WTCRDT
import WTGeometry

// DOC-012's rest (master-pages.adoc, "Client": "the Document panel, rulers, guides and the Page
// tool operate on the master while its tab is frontmost"): the pages a master page's canvas reads.

extension PageList {
    init(pages: [Page], masters: [MasterPage], settings: DocumentSettings) {
        self.pages = pages
        self.masters = masters
        self.settings = settings
    }

    /// The page list as the tab of master page `id` reads it: the master as the one page -- its id,
    /// name, geometry, bleed and guides, at the canvas origin (a master has no pasteboard position),
    /// the zero point at its bottom-left corner as an unset page's -- with the document's masters
    /// and settings.  Page setup, guide and resize commands given that id write the master
    /// (`SetPageGeometry`, `SetPageOrientation`, `SetBleed`, `AddGuides`, `MoveGuide`, ... each
    /// take a master page).  Nil when `id` is not a live master page.
    public func onMasterCanvas(_ id: OpID) -> PageList? {
        guard let master = master(id) else { return nil }
        let page = Page(id: master.id, number: 1, name: master.name, origin: .zero, geometry: master.geometry, bleed: master.bleed,
                        ownGeometry: master.geometry, ownBleed: master.bleed, master: nil,
                        rulerOrigin: Point(x: 0, y: master.geometry.height), guides: master.guides, isSynthesized: false)
        return PageList(pages: [page], masters: masters, settings: settings)
    }

    /// Whether this list is a master's canvas (`onMasterCanvas`): its one page is a master page.
    public var isMasterCanvas: Bool { pages.count == 1 && master(pages[0].id) != nil }
}
