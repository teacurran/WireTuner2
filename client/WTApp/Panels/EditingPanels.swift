import AppKit
import WTModel

/// The Align, Transform and Find & Replace panels with their menu items (OBJ-019, OBJ-033,
/// TYPE-022, TYPE-037): registered before the catalog's placeholders, so they take those slots,
/// plus menu:Modify[Align], menu:Modify[Transform > Move… … Reflect…] (each opens the Transform
/// panel on its tab) and a double-click on a transformation tool doing the same.
@MainActor
final class EditingPanels {
    let align: AlignPanelState
    let transform: TransformPanelState
    let findReplace = FindReplaceState()
    /// Brings a panel forward (the layout's `showPanel`).
    var showPanel: @MainActor (PanelID) -> Void = { _ in }

    init(defaults: UserDefaults?) {
        align = AlignPanelState(defaults: defaults)
        transform = TransformPanelState(defaults: defaults)
    }

    /// The transformation tools' tabs (their ids are the kinds' names).
    static func tab(for tool: ToolID) -> TransformPanelModel.Tab? {
        TransformPanelModel.Tab(rawValue: tool.rawValue).flatMap { $0 == .move ? nil : $0 }
    }

    /// Opens the Transform panel on `tab`.
    func openTransform(_ tab: TransformPanelModel.Tab) {
        transform.show(tab)
        showPanel("transform")
    }

    func commands(target: @escaping @MainActor () -> ObjectEditing?) -> [Command] {
        let ids = ContextMenuCatalog.ID.self
        let tabs: [(CommandID, String, TransformPanelModel.Tab)] = [
            (ids.transformRotate, "Rotate…", .rotate), (ids.transformScale, "Scale…", .scale), (ids.transformSkew, "Skew…", .skew),
            (ids.transformReflect, "Reflect…", .reflect), (ids.transformMove, "Move…", .move),
        ]
        let transform = tabs.map { id, title, tab in
            Command(id: id, title: title, menu: MenuPath(ContextMenuCatalog.Menu.modify, "Transform", section: 2), contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["transform", "panel"], action: .perform { [weak self] in self?.openTransform(tab) })
        }
        return AlignPanel.commands(target: target) + transform
    }

    func install(panels: PanelRegistry, commands: CommandRegistry, selection: ActiveSelection, target: @escaping @MainActor () -> ObjectEditing?) {
        panels.registerIfAbsent(AlignPanel.descriptor(selection: selection, state: align))
        panels.registerIfAbsent(TransformPanel.descriptor(selection: selection, state: transform))
        panels.registerIfAbsent(FindReplacePanel.descriptor(selection: selection, state: findReplace))
        for command in self.commands(target: target) { commands.replace(command) }
    }

    /// A double-click on a transformation tool opens the Transform panel on its tab; every other
    /// tool keeps `previous` (its options sheet).
    func toolOptions(previous: @escaping @MainActor (ToolDescriptor) -> Void) -> @MainActor (ToolDescriptor) -> Void {
        { [weak self] descriptor in
            if let tab = Self.tab(for: descriptor.id), let self { self.openTransform(tab) } else { previous(descriptor) }
        }
    }
}
