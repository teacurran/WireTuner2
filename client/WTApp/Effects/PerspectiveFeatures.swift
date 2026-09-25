import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// menu:View[Perspective Grid] and the grid overlay (perspective.adoc, "Showing the grid",
/// "Defining grids", "Attaching objects to the grid"; FX-043, FX-044's menu items): *Show*
/// (window state, checked), *Define Grids…*, *Remove Perspective* and *Release with Perspective*,
/// the overlay of every page's grid in the windows that show it, and the Perspective tool's
/// question whether its window shows the grid.
@MainActor
final class PerspectiveFeatures {
    enum ID {
        static let remove: CommandID = "view.perspective.remove"
        static let release: CommandID = "view.perspective.release"
    }

    static let sheet = "define-grids-sheet"
    static let noDocument = "No document is open"
    static let notAttached = "Select an object on the perspective grid"

    let window: @MainActor () -> DocumentWindowController?
    let sheets: SheetPresenter
    private var windows: [ObjectIdentifier: (window: WeakWindow, shown: Bool, observation: DocumentHandle.ObservationToken?)] = [:]
    /// The sheet's model while it is open.
    private(set) var defineGrids: DefineGridsModel?

    init(window: @escaping @MainActor () -> DocumentWindowController?, sheets: SheetPresenter = SheetPresenter()) {
        self.window = window
        self.sheets = sheets
    }

    /// Holds a window weakly.
    struct WeakWindow {
        weak var window: DocumentWindowController?
    }

    // MARK: Windows

    /// Draws the grids in `window`'s furniture layer while it shows them, and repaints them as the
    /// document changes.
    func attach(_ window: DocumentWindowController) {
        let key = ObjectIdentifier(window)
        guard windows[key] == nil else { return }
        let previous = window.canvas.furnitureDrawer
        window.canvas.furnitureDrawer = { [weak self, weak window] ctx in
            previous?(ctx)
            if let window { self?.drawGrids(in: ctx, window: window) }
        }
        let observation = window.documentHandle.observe { [weak self, weak window] _ in
            guard let window, self?.isShown(window) == true else { return }
            window.canvas.setNeedsFurnitureDisplay()
        }
        windows[key] = (WeakWindow(window: window), false, observation)
    }

    func isShown(_ window: DocumentWindowController) -> Bool {
        windows[ObjectIdentifier(window)]?.shown ?? false
    }

    /// Whether a window showing `document` shows the grid.
    func isShown(document: DocumentHandle) -> Bool {
        windows.values.contains { $0.shown && $0.window.window?.documentHandle === document }
    }

    /// menu:View[Perspective Grid > Show]: this window's grids on or off (never a change).
    func toggleShown(_ window: DocumentWindowController) {
        attach(window)
        windows[ObjectIdentifier(window)]?.shown.toggle()
        window.canvas.setNeedsFurnitureDisplay()
    }

    /// The grids of every page in view.
    func drawGrids(in ctx: CGContext, window: DocumentWindowController) {
        guard isShown(window) else { return }
        let document = window.documentHandle
        let viewport = window.canvas.viewport
        for page in document.pageList.pages {
            Self.draw(PerspectiveGridDrawing(page: page, state: document.state), in: ctx, viewport: viewport)
        }
    }

    /// One page's grid: the horizon across the page, each plane's lines in its colour and the
    /// vanishing points as rings.
    static func draw(_ drawing: PerspectiveGridDrawing, in ctx: CGContext, viewport: Viewport) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(0.5)
        for plane in drawing.planes {
            ctx.setStrokeColor(CGColor(srgbRed: plane.color.components[0], green: plane.color.components[1], blue: plane.color.components[2], alpha: 0.8))
            for (from, to) in plane.lines {
                ctx.move(to: viewport.toView(from).cgPoint)
                ctx.addLine(to: viewport.toView(to).cgPoint)
            }
            ctx.strokePath()
        }
        ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 0.9))
        ctx.setLineWidth(1)
        let horizon = drawing.spec.horizonY
        ctx.move(to: viewport.toView(Point(x: drawing.page.minX, y: horizon)).cgPoint)
        ctx.addLine(to: viewport.toView(Point(x: drawing.page.maxX, y: horizon)).cgPoint)
        ctx.strokePath()
        for (point, _) in drawing.vanishingPoints {
            let view = viewport.toView(point)
            ctx.strokeEllipse(in: CGRect(x: view.x - 4, y: view.y - 4, width: 8, height: 8))
        }
    }

    // MARK: Commands

    /// The selected objects on the grid (wrappers or objects inside one).
    static func attached(_ window: DocumentWindowController) -> [OpID] {
        let state = window.documentHandle.state
        return window.objectEditing.selectedNodes.filter { PerspectiveReading.wrapper(of: $0, in: state) != nil }
    }

    func commands() -> [Command] {
        let ids = StandardCommands.ID.self
        let view = StandardCommands.Menu.view
        let submenu = StandardCommands.Menu.perspectiveGrid
        let section = StandardCommands.Section.viewPerspective
        let window = window
        let attached: @MainActor @Sendable () -> CommandValidation = {
            guard let window = window() else { return .disabled(Self.noDocument) }
            return Self.attached(window).isEmpty ? .disabled(Self.notAttached) : .enabled
        }
        return [
            Command(id: ids.perspectiveShow, title: "Show", menu: MenuPath(view, submenu, section: section), keywords: ["perspective", "grid"],
                    validation: { window().map { .checked(self.isShown($0)) } ?? .disabled(Self.noDocument) },
                    action: .perform { if let window = window() { self.toggleShown(window) } }),
            Command(id: ids.perspectiveDefine, title: "Define Grids…", menu: MenuPath(view, submenu, section: section, subsection: 1), keywords: ["perspective", "grid"],
                    validation: { window() == nil ? .disabled(Self.noDocument) : .enabled },
                    action: .perform { if let window = window() { self.showDefineGrids(window) } }),
            Command(id: ID.remove, title: "Remove Perspective", menu: MenuPath(view, submenu, section: section, subsection: 2), keywords: ["perspective", "flat"],
                    validation: attached,
                    action: .perform {
                        guard let window = window() else { return }
                        let nodes = Self.attached(window)
                        if !nodes.isEmpty { window.objectEditing.perform(RemovePerspective(nodes)) }
                    }),
            Command(id: ID.release, title: "Release with Perspective", menu: MenuPath(view, submenu, section: section, subsection: 2),
                    keywords: ["perspective", "bake", "expand"], validation: attached,
                    action: .perform {
                        guard let window = window() else { return }
                        let nodes = Self.attached(window)
                        if !nodes.isEmpty { _ = BlendMenu.performSelecting(ReleaseWithPerspective(nodes), window.objectEditing) }
                    }),
        ]
    }

    /// menu:View[Perspective Grid > Define Grids…].
    @discardableResult
    func showDefineGrids(_ window: DocumentWindowController) -> DefineGridsModel {
        let model = DefineGridsModel(document: window.documentHandle)
        defineGrids = model
        sheets.present(DefineGridsSheet(model: model) { [weak self] in
            self?.defineGrids = nil
            self?.sheets.dismiss(Self.sheet)
        }, title: "Define Grids", identifier: Self.sheet)
        return model
    }

    func install(commands registry: CommandRegistry) {
        for command in commands() { registry.replace(command) }
        PerspectiveTool.showsGrid = { [weak self] document in self?.isShown(document: document) ?? false }
    }
}

/// The Define Grids sheet (perspective.adoc, "Defining grids"): the document's grids by name, with
/// btn:[New], btn:[Duplicate], btn:[Delete], renaming (names unique), the vanishing points, the
/// cell size and the three planes' colours.  Every edit is its own change; btn:[OK] makes the grid
/// selected in the list the page's grid.
@MainActor
@Observable
final class DefineGridsModel {
    @ObservationIgnored let document: DocumentHandle
    /// The page the sheet was opened on.
    @ObservationIgnored let page: Page
    var selected: OpID?
    private(set) var message: String?
    private(set) var revision = 0
    @ObservationIgnored private var observation: DocumentHandle.ObservationToken?

    init(document: DocumentHandle) {
        self.document = document
        page = document.activePage
        selected = PerspectiveReading.grid(of: page, in: document.state)
        observation = document.observe { [weak self] _ in self?.revision += 1 }
    }

    isolated deinit {
        if let observation { document.stopObserving(observation) }
    }

    var grids: [PerspectiveGridInfo] {
        _ = revision
        return PerspectiveReading.grids(document.state)
    }

    var selectedGrid: PerspectiveGridInfo? { grids.first { $0.id == selected } }

    /// Performs `command`, then selects the grid it added (when it added one).
    @discardableResult
    func perform(_ command: any WTModel.Command, selectingAdded: Bool = false) -> Task<Void, Never> {
        let before = Set(grids.map(\.id))
        message = nil
        let task = document.perform(command)
        return Task { @MainActor in
            _ = await task.value
            revision += 1
            if selectingAdded, let added = grids.first(where: { !before.contains($0.id) }) { selected = added.id }
        }
    }

    /// btn:[New]: the built-in grid of the page, named "Grid" (or "Grid 2" ...).
    @discardableResult
    func new() -> Task<Void, Never> {
        perform(DefineGrid(name: PerspectiveReading.unusedName("Grid", in: document.state), page: page.id), selectingAdded: true)
    }

    /// btn:[Duplicate]: a copy of the selected grid ("<name> 2").
    @discardableResult
    func duplicate() -> Task<Void, Never>? {
        guard let selected else { return nil }
        return perform(DuplicateGrid(selected), selectingAdded: true)
    }

    /// btn:[Delete]: pages using it fall back to the default grid.
    @discardableResult
    func delete() -> Task<Void, Never>? {
        guard let selected else { return nil }
        self.selected = nil
        return perform(DeleteGrid(selected))
    }

    /// A new name for the selected grid; a name another grid has is refused with a message.
    @discardableResult
    func rename(_ name: String) -> Task<Void, Never>? {
        guard let grid = selectedGrid else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != grid.name else { return nil }
        if trimmed.isEmpty {
            message = "A grid needs a name."
            return nil
        }
        if grids.contains(where: { $0.name == trimmed && $0.id != grid.id }) {
            message = "Another grid is named “\(trimmed)”."
            return nil
        }
        return perform(RenameGrid(grid.id, to: trimmed))
    }

    private func edit(_ label: String, _ field: PerspectiveFields.GridField, _ build: (inout Wiretuner_Doc_V1_PerspectiveGrid) -> Void) -> Task<Void, Never>? {
        guard let selected else { return nil }
        return perform(EditGrid(selected, label: label, fields: [field], build))
    }

    /// *Vanishing points*: 1, 2 or 3.
    @discardableResult
    func setVanishingPoints(_ count: Int) -> Task<Void, Never>? {
        guard (1...3).contains(count) else { return nil }
        return edit("Vanishing points", .vanishingPoints) { $0.vanishingPoints = UInt32(count) }
    }

    /// *Cell size*, points.
    @discardableResult
    func setCellSize(_ points: Double) -> Task<Void, Never>? {
        guard points > 0, points.isFinite else {
            message = "The cell size must be more than zero."
            return nil
        }
        return edit("Cell size", .cellSize) { $0.cellSize = points }
    }

    /// A plane's colour: *Left grid*, *Right grid* or *Horizontal grid*.
    @discardableResult
    func setColor(_ field: PerspectiveFields.GridField, _ color: RenderColor) -> Task<Void, Never>? {
        let ref = ColorResolver.inline(color)
        switch field {
        case .leftColor: return edit("Left grid color", field) { $0.leftColor = ref }
        case .rightColor: return edit("Right grid color", field) { $0.rightColor = ref }
        case .floorColor: return edit("Horizontal grid color", field) { $0.floorColor = ref }
        default: return nil
        }
    }

    /// *Vanishing points* as the pop-up shows it: 1 ... 3, 0 (or no grid) reading 2.
    var vanishingPoints: Int {
        let stored = Int(selectedGrid?.stored.vanishingPoints ?? 2)
        return stored == 0 ? 2 : stored
    }

    /// *Cell size* in points (0 reading 36); nil without a grid.
    var cellSize: Double? {
        selectedGrid.map { $0.stored.cellSize > 0 ? $0.stored.cellSize : 36 }
    }

    /// The colour a plane shows in the sheet (its default when unset).
    func color(_ field: PerspectiveFields.GridField) -> RenderColor {
        let stored = selectedGrid?.stored
        let resolver = ColorResolver(document.state)
        switch field {
        case .rightColor: return stored.flatMap { $0.hasRightColor ? resolver.color($0.rightColor) : nil } ?? PerspectiveGridDrawing.rightColor
        case .floorColor: return stored.flatMap { $0.hasFloorColor ? resolver.color($0.floorColor) : nil } ?? PerspectiveGridDrawing.floorColor
        default: return stored.flatMap { $0.hasLeftColor ? resolver.color($0.leftColor) : nil } ?? PerspectiveGridDrawing.leftColor
        }
    }

    /// btn:[OK]: the selected grid becomes the page's (nothing when it already is, or the page is
    /// the synthesized one and no grid is chosen).
    @discardableResult
    func confirm() -> Task<Void, Never>? {
        let current = PerspectiveReading.grid(of: page, in: document.state)
        guard selected != current else { return nil }
        return perform(SetPageGrid(page.id, grid: selected))
    }
}

struct DefineGridsSheet: View {
    @Bindable var model: DefineGridsModel
    let finish: @MainActor () -> Void

    static let vanishingChoices = [1, 2, 3]

    static func confirming(_ model: DefineGridsModel, _ finish: @escaping @MainActor () -> Void) -> () -> Void {
        {
            model.confirm()
            finish()
        }
    }

    static func name(_ model: DefineGridsModel) -> Binding<String> {
        Binding(get: { model.selectedGrid?.name ?? "" }, set: { model.rename($0) })
    }

    static func vanishing(_ model: DefineGridsModel) -> Binding<Int> {
        Binding(get: { model.vanishingPoints }, set: { model.setVanishingPoints($0) })
    }

    /// A picked colour in sRGB.
    static func renderColor(_ value: SwiftUI.Color) -> RenderColor {
        let resolved = value.resolve(in: EnvironmentValues())
        return RenderColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }

    static func color(_ model: DefineGridsModel, _ field: PerspectiveFields.GridField) -> Binding<SwiftUI.Color> {
        Binding(get: {
            let color = model.color(field)
            return SwiftUI.Color(.sRGB, red: color.components[0], green: color.components[1], blue: color.components[2])
        }, set: { model.setColor(field, renderColor($0)) })
    }

    static func adding(_ model: DefineGridsModel) -> () -> Void { { model.new() } }
    static func duplicating(_ model: DefineGridsModel) -> () -> Void { { model.duplicate() } }
    static func deleting(_ model: DefineGridsModel) -> () -> Void { { model.delete() } }
    static func settingCellSize(_ model: DefineGridsModel) -> (Double) -> Void { { model.setCellSize($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Define Grids").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    List(model.grids, id: \.id, selection: $model.selected) { grid in
                        Text(grid.displayName).tag(grid.id)
                    }
                    .frame(width: 180, height: 180)
                    .accessibilityIdentifier("defineGrids.list")
                    HStack {
                        Button("New", action: Self.adding(model)).accessibilityIdentifier("defineGrids.new")
                        Button("Duplicate", action: Self.duplicating(model)).disabled(model.selected == nil).accessibilityIdentifier("defineGrids.duplicate")
                        Button("Delete", action: Self.deleting(model)).disabled(model.selected == nil).accessibilityIdentifier("defineGrids.delete")
                    }
                }
                Form {
                    TextField("Name", text: Self.name(model)).accessibilityIdentifier("defineGrids.name")
                    Picker("Vanishing points", selection: Self.vanishing(model)) {
                        ForEach(Self.vanishingChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .accessibilityIdentifier("defineGrids.vanishingPoints")
                    MeasureField(title: "Cell size", value: model.cellSize, unit: model.document.units.measureUnit, identifier: "defineGrids.cellSize",
                                 commit: Self.settingCellSize(model))
                    ColorPicker("Left grid", selection: Self.color(model, .leftColor)).accessibilityIdentifier("defineGrids.leftColor")
                    ColorPicker("Right grid", selection: Self.color(model, .rightColor)).accessibilityIdentifier("defineGrids.rightColor")
                    ColorPicker("Horizontal grid", selection: Self.color(model, .floorColor)).accessibilityIdentifier("defineGrids.floorColor")
                }
                .disabled(model.selectedGrid == nil)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("defineGrids.message")
            }
            HStack {
                Spacer()
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirming(model, finish)).keyboardShortcut(.defaultAction).accessibilityIdentifier("defineGrids.ok")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
