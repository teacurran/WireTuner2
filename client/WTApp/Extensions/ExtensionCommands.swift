import Foundation

/// The Extensions menu (extensions.adoc, "The Extensions menu"), generated from the
/// `ExtensionRegistry`: Repeat <name> (`Cmd+Shift+=`), one submenu per category with its
/// operations, and Other > Manage Extensions….  A turned-off operation keeps its registry
/// entry (and its place) but loses its menu item.
enum ExtensionCommands {
    enum ID {
        static let repeatLast: CommandID = "extension.repeat"
        static let manage: CommandID = "extension.manage"
    }

    static let repeatKey = KeyEquivalent("=", [.command, .shift])

    @MainActor
    static func operationCommand(_ descriptor: ExtensionDescriptor, registry: ExtensionRegistry) -> Command {
        let id = descriptor.id
        let menu = registry.isEnabled(id) ? MenuPath(ExtensionRegistry.menuTitle, descriptor.category, section: 1) : nil
        return Command(
            id: descriptor.commandID, title: descriptor.title, menu: menu, keywords: ["extension", descriptor.category.lowercased()],
            validation: { registry.validation(ofExtension: id) },
            action: .perform { registry.perform(id) }
        )
    }

    @MainActor
    static func repeatCommand(registry: ExtensionRegistry) -> Command {
        Command(
            id: ID.repeatLast, title: "Repeat Extension", key: repeatKey, menu: MenuPath(ExtensionRegistry.menuTitle), keywords: ["again", "extension"],
            validation: { registry.repeatValidation },
            action: .perform { registry.performRepeat() }
        )
    }

    @MainActor
    static func manageCommand(showManage: @escaping @MainActor @Sendable () -> Void) -> Command {
        Command(
            id: ID.manage, title: "Manage Extensions…", menu: MenuPath(ExtensionRegistry.menuTitle, ExtensionRegistry.otherCategory, section: 1),
            keywords: ["extensions", "turn off", "disable"], action: .perform(showManage)
        )
    }

    /// Registers (or refreshes, in place) every Extensions menu command.
    @MainActor
    static func sync(into commands: CommandRegistry, registry: ExtensionRegistry, showManage: @escaping @MainActor @Sendable () -> Void) {
        commands.replace(repeatCommand(registry: registry))
        for descriptor in registry.descriptors where descriptor.isOperation {
            commands.replace(operationCommand(descriptor, registry: registry))
        }
        commands.registerIfAbsent(manageCommand(showManage: showManage))
    }
}
