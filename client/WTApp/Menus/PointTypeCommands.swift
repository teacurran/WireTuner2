import Foundation
import WTModel

/// The point items of the menu bar and of the context menu on selected points (editing-paths.adoc,
/// "Changing points"; context-menus.adoc, "Selected points"): the three point types, Retract
/// Handles and Automatic.  Each acts on every selected point of the selected paths and live shapes
/// at once -- the Object panel's point section's commands (`ObjectPanelModel`), so a shape converts
/// to a path in the same change (D-078) and several objects' points are one change.
enum PointTypeCommands {
    enum ID {
        static func kind(_ kind: PointKind) -> CommandID { CommandID("modify.points.\(name(kind))") }
        static let retract: CommandID = "modify.points.retractHandles"
        static let automatic: CommandID = "modify.points.automatic"

        static func name(_ kind: PointKind) -> String {
            switch kind {
            case .corner: "corner"
            case .curve: "curve"
            case .connector: "connector"
            }
        }
    }

    /// The menu-bar submenu, menu:Modify[Points], beside Join, Split and Alter Path.
    static let submenu = "Points"
    static let noPoints = "Select one or more points"
    static let kinds: [(kind: PointKind, title: String)] = [(.corner, "Corner"), (.curve, "Curve"), (.connector, "Connector")]

    /// The point section of the front window's selection, nil without points.
    @MainActor
    static func section(_ window: DocumentWindowController) -> ObjectPanelModel.PointSection? {
        model(window).point
    }

    @MainActor
    static func model(_ window: DocumentWindowController) -> ObjectPanelModel {
        ObjectPanelModel(document: window.documentHandle, selection: window.selection.model.selection)
    }

    /// A type's item: checked when every selected point has it, a dash when only some do.
    @MainActor
    static func validation(_ kind: PointKind, _ section: ObjectPanelModel.PointSection?) -> CommandValidation {
        guard let section else { return .disabled(noPoints) }
        return CommandValidation(isChecked: section.kind == kind, isMixed: section.kind == nil && section.kinds.contains(kind))
    }

    /// *Automatic*: checked when every selected point has it, a dash when only some do.
    @MainActor
    static func automaticValidation(_ section: ObjectPanelModel.PointSection?) -> CommandValidation {
        guard let section else { return .disabled(noPoints) }
        return CommandValidation(isChecked: section.automatic == .on, isMixed: section.automatic == .mixed)
    }

    /// *Automatic* turns it on for every point unless all have it, when it turns it off.
    @MainActor
    static func automaticCommand(_ window: DocumentWindowController) -> (any WTModel.Command)? {
        let model = model(window)
        guard let section = model.point else { return nil }
        return model.setAutomatic(section.automatic != .on)
    }

    @MainActor
    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        let modify = ContextMenuCatalog.Menu.modify
        func run(_ make: @escaping @MainActor (DocumentWindowController) -> (any WTModel.Command)?) -> CommandAction {
            .perform { if let front = window(), let command = make(front) { front.objectEditing.perform(command) } }
        }
        func current(_ check: @escaping @MainActor (ObjectPanelModel.PointSection?) -> CommandValidation) -> @MainActor @Sendable () -> CommandValidation {
            { window().map { check(section($0)) } ?? .disabled(ViewCommands.noDocument) }
        }
        let keywords = ["point", "point type", "anchor", "handles"]
        var result = kinds.map { kind, title in
            Command(id: ID.kind(kind), title: title, menu: MenuPath(modify, submenu, section: 3), contexts: [.points], keywords: keywords + [title.lowercased()],
                    validation: current { validation(kind, $0) }, action: run { model($0).setKind(kind) })
        }
        result += [
            Command(id: ID.retract, title: "Retract Handles", menu: MenuPath(modify, submenu, section: 3, subsection: 1), contexts: [.points],
                    keywords: keywords + ["retract"], validation: current { $0 == nil ? .disabled(noPoints) : .enabled },
                    action: run { model($0).retractHandles() }),
            Command(id: ID.automatic, title: "Automatic", menu: MenuPath(modify, submenu, section: 3, subsection: 1), contexts: [.points],
                    keywords: keywords + ["automatic", "smooth"], validation: current(automaticValidation), action: run(automaticCommand)),
        ]
        return result
    }
}

extension AppDelegate {
    /// The point items (menu:Modify[Points] and the selected points' context menu).
    func installPointTypeCommands() {
        let documents = documents!
        for command in PointTypeCommands.commands(window: { documents.activeWindowController }) { commands.replace(command) }
    }
}
