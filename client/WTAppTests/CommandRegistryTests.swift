import Foundation
import Testing
@testable import WireTuner

@MainActor
final class Counter {
    var count = 0
    func bump() { count += 1 }
}

@Suite @MainActor struct CommandRegistryTests {
    private func command(_ id: CommandID, menu: MenuPath? = MenuPath("File"), counter: Counter? = nil) -> Command {
        Command(id: id, title: id.rawValue, menu: menu, action: .perform { counter?.bump() })
    }

    @Test func registersAndLooksUpInOrder() throws {
        let registry = CommandRegistry()
        try registry.register(command("b"))
        try registry.register(contentsOf: [command("a"), command("c", menu: MenuPath("Edit"))])
        #expect(registry.ids == ["b", "a", "c"])
        #expect(registry.command("a")?.title == "a")
        #expect(registry["c"]?.menuPath?.menu == "Edit")
        #expect(registry.contains("b"))
        #expect(!registry.contains("zzz"))
        #expect(registry.command("zzz") == nil)
        #expect(registry.menuTitles == ["File", "Edit"])
    }

    @Test func rejectsDuplicateIDs() throws {
        let registry = CommandRegistry()
        try registry.register(command("a"))
        #expect(throws: CommandRegistry.Failure.duplicateID("a")) {
            try registry.register(command("a"))
        }
        #expect(!registry.registerIfAbsent(command("a")))
        #expect(registry.registerIfAbsent(command("b")))
        #expect(registry.ids == ["a", "b"])
    }

    @Test func notifiesOnChange() throws {
        let registry = CommandRegistry()
        let counter = Counter()
        registry.onChange = { counter.bump() }
        try registry.register(command("a"))
        registry.registerIfAbsent(command("b"))
        registry.registerIfAbsent(command("b"))
        #expect(counter.count == 2)
    }

    @Test func enumeratesMenuBySectionThenRegistration() throws {
        let registry = CommandRegistry()
        try registry.register(command("late", menu: MenuPath("File", section: 2)))
        try registry.register(command("first", menu: MenuPath("File", section: 0)))
        try registry.register(command("second", menu: MenuPath("File", section: 0)))
        try registry.register(command("other", menu: MenuPath("Edit")))
        try registry.register(command("noMenu", menu: nil))
        #expect(registry.commands(inMenu: "File").map(\.id) == ["first", "second", "late"])
        #expect(registry.commands(inMenu: "Help").isEmpty)
        #expect(registry.menuTitles == ["File", "Edit"])
    }

    @Test func enumeratesContextCommandsInMenuBarOrder() throws {
        let registry = CommandRegistry()
        try registry.register(Command(id: "help.x", title: "X", menu: MenuPath("Help"), contexts: [.path], action: .perform(Command.noop)))
        try registry.register(Command(id: "edit.b", title: "B", menu: MenuPath("Edit", section: 1), contexts: [.path], action: .perform(Command.noop)))
        try registry.register(Command(id: "edit.a", title: "A", menu: MenuPath("Edit", section: 0), contexts: [.path, .text], action: .perform(Command.noop)))
        try registry.register(Command(id: "tool.t", title: "T", menu: nil, contexts: [.text], action: .perform(Command.noop)))
        try registry.register(Command(id: "edit.none", title: "N", menu: MenuPath("Edit"), action: .perform(Command.noop)))
        let ids = registry.commands(forContexts: [.path], menuOrder: MenuTreeBuilder.standardMenuOrder).map(\.id)
        #expect(ids == ["edit.a", "edit.b", "help.x"])
        let textIDs = registry.commands(forContexts: [.text], menuOrder: MenuTreeBuilder.standardMenuOrder).map(\.id)
        #expect(textIDs == ["edit.a", "tool.t"])
    }

    @Test func performsEnabledClosureCommandsOnly() throws {
        let registry = CommandRegistry()
        let counter = Counter()
        try registry.register(command("run", counter: counter))
        try registry.register(Command.placeholder(id: "later", title: "Later"))
        try registry.register(Command.responder(id: "chain", title: "Chain", selector: "cut:"))
        #expect(registry.perform("run"))
        #expect(counter.count == 1)
        #expect(!registry.perform("later"))
        #expect(!registry.perform("missing"))
        #expect(!registry.perform("chain"))
        var seen: [String] = []
        #expect(registry.perform("chain") { seen.append($0); return true })
        #expect(seen == ["cut:"])
        #expect(registry.validate("later") == .disabled(Command.placeholderReason))
        #expect(registry.validate("chain") == .enabled)
        #expect(registry.validate("missing") == nil)
    }

    @Test func searchesTitlesAndKeywords() throws {
        let registry = CommandRegistry()
        try registry.register(Command(id: "a", title: "Zoom In", keywords: ["magnify"], action: .perform(Command.noop)))
        try registry.register(Command(id: "b", title: "Émigré", action: .perform(Command.noop)))
        try registry.register(Command(id: "c", title: "Other", action: .perform(Command.noop)))
        #expect(registry.search("zoom").map(\.id) == ["a"])
        #expect(registry.search("MAGN").map(\.id) == ["a"])
        #expect(registry.search("emigre").map(\.id) == ["b"])
        #expect(registry.search("  ").count == 3)
        #expect(registry.search("nothing").isEmpty)
    }

    @Test func commandFactoriesFillTheirFields() {
        let placeholder = Command.placeholder(id: "p", title: "P", key: KeyEquivalent("p", .command), menu: MenuPath("File"), contexts: [.page], keywords: ["k"])
        #expect(placeholder.defaultKey == KeyEquivalent("p", .command))
        #expect(placeholder.contexts == [.page])
        #expect(placeholder.keywords == ["k"])
        #expect(placeholder.action.responderSelectorName == nil)
        #expect(placeholder.validation() == .disabled(Command.placeholderReason))
        let responder = Command.responder(id: "r", title: "R", selector: "copy:")
        #expect(responder.action.responderSelectorName == "copy:")
        #expect(responder.validation() == .enabled)
        #expect(CommandValidation.checked(true) == CommandValidation(isEnabled: true, reason: nil, isChecked: true, title: nil))
        #expect(MenuPath("View", "Magnification", section: 1).menu == "View")
        #expect(MenuPath(components: ["View"], section: 0) == MenuPath("View"))
        #expect(CommandID("a") < CommandID("b"))
        #expect(CommandID("a").description == "a")
    }

    @Test func standardCommandsCoverTheStandardMenus() {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        StandardCommands.register(into: registry)
        #expect(registry.commands.count == StandardCommands.commands().count)
        #expect(Set(registry.menuTitles) == Set(MenuTreeBuilder.standardMenuOrder))
        #expect(registry.command(StandardCommands.ID.quit)?.action.responderSelectorName == "terminate:")
        #expect(registry.command(StandardCommands.ID.magnification(100))?.menuPath == MenuPath("View", "Magnification", section: 1))
        #expect(registry.command(StandardCommands.ID.magnification(25))?.defaultKey == nil)
        #expect(registry.validate(StandardCommands.ID.checkForUpdates)?.isEnabled == false)
        #expect(!registry.perform(StandardCommands.ID.checkForUpdates))
    }

    @Test func updateHooksDriveCheckForUpdates() {
        let registry = CommandRegistry()
        let counter = Counter()
        StandardCommands.register(
            into: registry,
            updates: StandardCommands.UpdateHooks(canCheckForUpdates: { true }, checkForUpdates: { counter.bump() })
        )
        #expect(registry.validate(StandardCommands.ID.checkForUpdates) == .enabled)
        #expect(registry.perform(StandardCommands.ID.checkForUpdates))
        #expect(counter.count == 1)
    }
}
