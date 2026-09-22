import Foundation

/// The declarative list of every command in the application.  The menu bar, context menus, the
/// shortcut editor and the command palette are all views over it; a feature registers its
/// commands here and gets all four.  Main-actor bound because validation and actions touch UI
/// state; it has no AppKit dependency so it is testable without a window.
@MainActor
final class CommandRegistry {
    enum Failure: Error, Equatable {
        case duplicateID(CommandID)
    }

    /// Commands in registration order.
    private(set) var commands: [Command] = []
    private var indexByID: [CommandID: Int] = [:]

    /// Called after every registration, so the menu bar can be rebuilt.
    var onChange: (@MainActor () -> Void)?

    init() {}

    var ids: [CommandID] { commands.map(\.id) }

    func register(_ command: Command) throws {
        guard indexByID[command.id] == nil else { throw Failure.duplicateID(command.id) }
        indexByID[command.id] = commands.count
        commands.append(command)
        onChange?()
    }

    func register(contentsOf newCommands: [Command]) throws {
        for command in newCommands { try register(command) }
    }

    /// Registers `command` unless a command with its id exists; returns whether it was added.
    /// Startup registration is idempotent through this so a re-run never throws.
    @discardableResult
    func registerIfAbsent(_ command: Command) -> Bool {
        guard indexByID[command.id] == nil else { return false }
        indexByID[command.id] = commands.count
        commands.append(command)
        onChange?()
        return true
    }

    func command(_ id: CommandID) -> Command? {
        indexByID[id].map { commands[$0] }
    }

    subscript(id: CommandID) -> Command? { command(id) }

    func contains(_ id: CommandID) -> Bool { indexByID[id] != nil }

    /// Top-level menu titles in the order they were first seen.
    var menuTitles: [String] {
        var seen: Set<String> = []
        return commands.compactMap { command in
            guard let menu = command.menuPath?.menu, !seen.contains(menu) else { return nil }
            seen.insert(menu)
            return menu
        }
    }

    /// Commands whose menu path starts with `title`, by section then registration order.
    func commands(inMenu title: String) -> [Command] {
        commands.enumerated()
            .filter { $0.element.menuPath?.menu == title }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.element.menuPath!.section, rhs.element.menuPath!.section)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    /// Commands that appear in the context menu of any of `contexts`, in menu-bar order.
    func commands(forContexts contexts: Set<MenuContext>, menuOrder: [String]) -> [Command] {
        let rank = Dictionary(uniqueKeysWithValues: menuOrder.enumerated().map { ($1, $0) })
        return commands.enumerated()
            .filter { !$0.element.contexts.isDisjoint(with: contexts) }
            .sorted { lhs, rhs in
                let l = (rank[lhs.element.menuPath?.menu ?? ""] ?? Int.max, lhs.element.menuPath?.section ?? 0, lhs.offset)
                let r = (rank[rhs.element.menuPath?.menu ?? ""] ?? Int.max, rhs.element.menuPath?.section ?? 0, rhs.offset)
                return l < r
            }
            .map(\.element)
    }

    /// The current validation of `id`; `nil` for an unknown command.
    func validate(_ id: CommandID) -> CommandValidation? {
        command(id)?.validation()
    }

    /// Runs `id` if it is known and enabled.  Responder-chain commands are handed to
    /// `responder`, which returns whether anything handled the selector.
    @discardableResult
    func perform(_ id: CommandID, responder: (String) -> Bool = { _ in false }) -> Bool {
        guard let command = command(id), command.validation().isEnabled else { return false }
        switch command.action {
        case let .perform(run):
            run()
            return true
        case let .responder(selector):
            return responder(selector)
        }
    }

    /// Commands whose title or keywords contain `query` (case- and diacritic-insensitive).
    /// The palette's fuzzy ranking (BASIC-033) replaces this; menus and tests use it as is.
    func search(_ query: String) -> [Command] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return commands }
        return commands.filter { command in
            ([command.title] + command.keywords).contains { haystack in
                haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
