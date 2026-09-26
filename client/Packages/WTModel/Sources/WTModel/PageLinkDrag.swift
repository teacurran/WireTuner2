import WTCRDT
import WTGeometry

// WEB-022: what a Link tool drag does when it is released (interactivity.adoc, "The Link tool").
// The tool itself (the drag, the connector, the page highlight, the cursors) is WTApp's; the rule
// that turns a source object and a drop point into a page link is here.

/// The Link tool's release rule.
public enum PageLinkDrag {
    /// What releasing does.
    public enum Outcome: Equatable, Sendable {
        /// Link the source to `page` (its number names the change).
        case link(page: OpID, number: Int)
        /// Remove the source's page link.
        case clear
        /// Nothing: dropped on the pasteboard, on the synthesized page, or on the source's own
        /// page when it has no link to remove.
        case nothing
    }

    /// Whether the Link tool can link `node`: a live object whose kind carries navigation and
    /// that is not locked (directly or through its layer).
    public static func isLinkable(_ node: OpID, in state: EngineState) -> Bool {
        state.isLive(node) && NavigationFields.isLinkable(node, in: state) && !Objects.isEffectivelyLocked(node, in: state)
    }

    /// The page the drop at `point` (pasteboard) targets: the page under it, never the synthesized
    /// page of a document without pages (it is not a node a link can name).
    public static func page(at point: Point, in pages: PageList) -> Page? {
        pages.page(containing: point).flatMap { $0.isSynthesized ? nil : $0 }
    }

    /// Releasing a drag of `source` at `point`: another page links to it; the source's own page
    /// removes its link, or with kbd:[Option] (`option`) links to that page (a "return here"
    /// button on a spread).
    public static func outcome(source: OpID, drop point: Point, option: Bool, in state: EngineState) -> Outcome {
        let pages = PageList(state)
        guard let target = page(at: point, in: pages) else { return .nothing }
        let own = Objects.bounds(of: source, in: state).flatMap(pages.page(ofBounds:))
        if target.id == own?.id && !option {
            return NavigationInfo(source, in: state).goToPage == nil ? .nothing : .clear
        }
        return .link(page: target.id, number: target.number)
    }

    /// The change a release writes, nil for `.nothing`: "Link to page N" or "Remove page link".
    public static func command(source: OpID, outcome: Outcome) -> SetGoToPage? {
        switch outcome {
        case .link(let page, let number): SetGoToPage([source], page: page, pageNumber: number)
        case .clear: SetGoToPage([source], page: nil)
        case .nothing: nil
        }
    }
}
