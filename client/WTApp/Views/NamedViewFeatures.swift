import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Named views in the app (document-view.adoc, "Named views"; BASIC-015's app half): the New
/// View sheet writes `CreateCustomView` with the view it was opened on (the Zoom tool's
/// kbd:[Shift]-drag or menu:View[Custom > New…]), menu:View[Custom] lists the key window's
/// document's views after *Previous* and recalls one, *Edit…* opens the Edit Views sheet, and the
/// status bar's magnification pop-up lists the views after the Fit entries.  Recalling is local:
/// it sets the window's magnification, drawing mode and scroll position, and pushes the window's
/// Previous pair (`NamedViewRecall`), which *Previous* swaps.
@MainActor
final class NamedViewFeatures {
    static let noDocument = ViewCommands.noDocument
    static let needsTwo = "Recall two named views first"
    static let sheet = "edit-views-sheet"
    static let prefix = "view.custom.named."

    /// The command of the named view at `index` in menu:View[Custom].
    static func id(_ index: Int) -> CommandID { CommandID("\(prefix)\(index)") }

    let window: @MainActor () -> DocumentWindowController?
    let sheets: SheetPresenter
    /// The menu bar is rebuilt after the Custom submenu's items change.
    var onMenuChange: @MainActor () -> Void = {}
    private weak var registry: CommandRegistry?
    /// Each window's Previous pair (never shared, never saved to the document).
    private(set) var recalls: [ObjectIdentifier: NamedViewRecall] = [:]
    /// The names menu:View[Custom] lists now.
    private(set) var listed: [String] = []
    /// The Edit Views sheet's model while it is open.
    private(set) var editing: EditViewsModel?

    init(window: @escaping @MainActor () -> DocumentWindowController?, sheets: SheetPresenter = SheetPresenter()) {
        self.window = window
        self.sheets = sheets
    }

    // MARK: Reading

    /// `mode` as the canvas draws it.
    static func viewMode(_ mode: Wiretuner_Doc_V1_DrawingMode) -> ViewMode {
        switch mode {
        case .fastPreview: .fastPreview
        case .keyline: .keyline
        case .fastKeyline: .fastKeyline
        default: .preview
        }
    }

    /// `mode` as a named view stores it.
    static func drawingMode(_ mode: ViewMode) -> Wiretuner_Doc_V1_DrawingMode {
        switch mode {
        case .preview: .preview
        case .fastPreview: .fastPreview
        case .keyline: .keyline
        case .fastKeyline: .fastKeyline
        }
    }

    /// The pasteboard rectangle `viewport` shows (its corners' bounds when rotated).
    static func visibleRect(_ viewport: Viewport) -> Rect {
        let corners = [Point(x: 0, y: 0), Point(x: viewport.size.width, y: 0), Point(x: 0, y: viewport.size.height),
                       Point(x: viewport.size.width, y: viewport.size.height)].map(viewport.toPasteboard)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return Rect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The target a view of `viewport` in `mode` records: the visible area fitted to the view's
    /// size, as the Zoom tool's kbd:[Shift]-drag defines it (`NamedViews.target(fitting:)`).
    static func target(of viewport: Viewport, mode: ViewMode) -> NamedViewTarget {
        NamedViews.target(fitting: visibleRect(viewport), viewSize: viewport.size, mode: drawingMode(mode))
    }

    /// The viewport `target` recalls in a view shaped like `viewport` (its rotation kept: a named
    /// view has none).
    static func viewport(for target: NamedViewTarget, like viewport: Viewport) -> Viewport {
        var recalled = viewport
        recalled.zoom = target.magnification
        recalled.scrollOrigin = target.scrollOrigin
        return recalled
    }

    // MARK: Recall

    func recall(of window: DocumentWindowController) -> NamedViewRecall {
        recalls[ObjectIdentifier(window)] ?? NamedViewRecall()
    }

    /// Shows `view` in `window` and pushes it onto the window's Previous pair.
    func recall(_ view: NamedView, in window: DocumentWindowController) {
        window.setViewMode(Self.viewMode(view.target.mode))
        window.setViewport(Self.viewport(for: view.target, like: window.viewport))
        var pair = recall(of: window).live(in: window.documentHandle.state)
        pair.recalled(view.id)
        recalls[ObjectIdentifier(window)] = pair
    }

    /// menu:View[Custom > Previous]: the view before the latest, the pair swapped; nil when there
    /// are not two live recalled views.
    @discardableResult
    func previous(in window: DocumentWindowController) -> NamedView? {
        guard let (view, pair) = recall(of: window).previous(in: window.documentHandle.state) else { return nil }
        window.setViewMode(Self.viewMode(view.target.mode))
        window.setViewport(Self.viewport(for: view.target, like: window.viewport))
        recalls[ObjectIdentifier(window)] = pair
        return view
    }

    // MARK: Commands

    func commands() -> [Command] {
        let window = self.window
        let menu = StandardCommands.Menu.view, custom = StandardCommands.Menu.custom, places = StandardCommands.Section.viewPlaces
        return [
            Command(id: StandardCommands.ID.customEdit, title: "Edit…", menu: MenuPath(menu, custom, section: places), keywords: ["named view", "rename view"],
                    validation: { window() == nil ? .disabled(Self.noDocument) : .enabled },
                    action: .perform { [weak self] in if let controller = window() { self?.showEditViews(controller) } }),
            Command(id: StandardCommands.ID.customPrevious, title: "Previous", menu: MenuPath(menu, custom, section: places, subsection: 1),
                    keywords: ["named view", "last view"],
                    validation: { [weak self] in
                        guard let controller = window(), let self else { return .disabled(Self.noDocument) }
                        return self.recall(of: controller).canGoBack(in: controller.documentHandle.state) ? .enabled : .disabled(Self.needsTwo)
                    },
                    action: .perform { [weak self] in if let controller = window() { self?.previous(in: controller) } }),
        ]
    }

    /// The Custom submenu's item for the named view at `index`, named `name`.
    func viewCommand(_ index: Int, name: String) -> Command {
        let window = self.window
        return Command(
            id: Self.id(index), title: name,
            menu: MenuPath(StandardCommands.Menu.view, StandardCommands.Menu.custom, section: StandardCommands.Section.viewPlaces, subsection: 2),
            keywords: ["named view"],
            validation: { window() == nil ? .disabled(Self.noDocument) : .enabled },
            action: .perform { [weak self] in
                guard let controller = window() else { return }
                let views = NamedViews.list(controller.documentHandle.state)
                if views.indices.contains(index) { self?.recall(views[index], in: controller) }
            }
        )
    }

    func install(commands registry: CommandRegistry) {
        self.registry = registry
        for command in commands() { registry.replace(command) }
    }

    /// The Custom submenu lists the key window's views; the menu bar is rebuilt when they changed.
    func refreshMenu() {
        let names = window().map { NamedViews.list($0.documentHandle.state).map(\.name) } ?? []
        guard names != listed, let registry else { return }
        registry.remove(Set(listed.indices.map(Self.id)))
        for (index, name) in names.enumerated() { registry.registerIfAbsent(viewCommand(index, name: name)) }
        listed = names
        onMenuChange()
    }

    // MARK: Windows

    /// A document window: the magnification pop-up lists its views and recalls them, and its
    /// changes and activation refresh the Custom submenu.
    func attach(_ window: DocumentWindowController) {
        let previous = window.statusBar.onMagnification
        window.statusBar.onMagnification = { [weak self, weak window] text in self?.magnification(text, in: window, previous: previous) }
        let becameMain = window.onBecomeMain
        window.onBecomeMain = { [weak self] main in
            becameMain?(main)
            self?.refreshMenu()
        }
        window.documentHandle.observe { [weak self, weak window] _ in self?.viewsDidChange(in: window) }
        viewsDidChange(in: window)
    }

    /// Text entered in `window`'s magnification pop-up: a named view's name recalls it; anything
    /// else is a magnification (`previous`).
    func magnification(_ text: String, in window: DocumentWindowController?, previous: (@MainActor (String) -> Void)?) {
        guard let window, let view = NamedViews.list(window.documentHandle.state).first(where: { $0.name == text }) else {
            previous?(text)
            return
        }
        recall(view, in: window)
        window.statusBar.show(zoom: window.viewport.zoom)
    }

    /// `window`'s document changed: its status bar and, when it is the key window, the menu follow.
    func viewsDidChange(in window: DocumentWindowController?) {
        guard let window else { return }
        let names = NamedViews.list(window.documentHandle.state).map(\.name)
        if names != window.statusBar.namedViews { window.statusBar.show(namedViews: names) }
        if self.window() === window { refreshMenu() }
        editing?.touch()
    }

    // MARK: Edit Views

    /// menu:View[Custom > Edit…]: the Edit Views sheet on `window`.
    @discardableResult
    func showEditViews(_ window: DocumentWindowController) -> EditViewsModel {
        if let editing { return editing }
        let model = EditViewsModel(window: window) { [weak self] in
            self?.editing = nil
            self?.sheets.dismiss(Self.sheet)
        }
        editing = model
        sheets.present(EditViewsSheet(model: model), title: "Edit Views", identifier: Self.sheet)
        return model
    }
}

extension DocumentWindowController {
    /// The New View sheet's btn:[OK]: a named view of `viewport` in this window's drawing mode
    /// ("New View"), after the document's other views.
    @discardableResult
    func createNamedView(_ name: String, from viewport: Viewport) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return objectEditing.perform(CreateCustomView(name: trimmed, target: NamedViewFeatures.target(of: viewport, mode: viewMode)))
    }
}
