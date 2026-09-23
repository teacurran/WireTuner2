import Foundation
import WTCRDT
import WTModel

/// What DRAW-036 installs (connectors.adoc): the Connector tool in place of its stub, and
/// menu:Modify[Alter Path > Reverse Direction] for connectors -- each selected connector's ends
/// swap, so its arrowheads swap ends, in one change.  Reversing paths is not delivered yet, so the
/// command asks for a connector when none is selected.
@MainActor
enum ConnectorCommands {
    static let noConnector = "Select a connector"

    /// The selected connectors of `editing`, in selection order.
    static func selectedConnectors(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return editing.selectedNodes.filter { state.nodeKind($0) == .connector }
    }

    static func reverseDirection(target: @escaping ObjectMenuCommands.Target) -> Command {
        Command(
            id: ContextMenuCatalog.ID.reverseDirection, title: "Reverse Direction",
            menu: MenuPath(ContextMenuCatalog.Menu.modify, "Alter Path", section: 3), keywords: ["connector", "arrowheads", "swap ends"],
            validation: {
                guard let editing = target() else { return .disabled("No document is open") }
                return selectedConnectors(editing).isEmpty ? .disabled(noConnector) : .enabled
            },
            action: .perform {
                guard let editing = target() else { return }
                let connectors = selectedConnectors(editing)
                if !connectors.isEmpty { editing.perform(ReverseConnectors(connectors)) }
            }
        )
    }

    static func install(commands: CommandRegistry, tools: ToolRegistry, target: @escaping ObjectMenuCommands.Target) {
        tools.replace(ConnectorTool.descriptor)
        commands.replace(reverseDirection(target: target))
    }
}
