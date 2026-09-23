import Foundation

/// The account menu (APP-008): Sign In…, Sign In with Apple…, Account… and Sign Out, in the
/// application menu beside Settings.  Workspace sign-in is in the account window, where the
/// workspace name is typed.
enum AccountCommands {
    enum ID {
        static let signIn: CommandID = "account.signIn"
        static let signInWithApple: CommandID = "account.signInWithApple"
        static let showAccount: CommandID = "account.show"
        static let signOut: CommandID = "account.signOut"
    }

    static let alreadySignedIn = "Already signed in"
    static let notSignedIn = "Not signed in"
    static let signingIn = "Signing in…"

    @MainActor
    static func commands(model: AccountModel, showAccount: @escaping @MainActor @Sendable () -> Void) -> [Command] {
        let path = MenuPath(StandardCommands.Menu.application, section: 1)
        let canSignIn: @MainActor @Sendable () -> CommandValidation = {
            if model.isBusy { return .disabled(signingIn) }
            return model.isSignedIn ? .disabled(alreadySignedIn) : .enabled
        }
        return [
            Command(
                id: ID.signIn, title: "Sign In…", menu: path, keywords: ["account", "log in", "passkey"],
                validation: canSignIn, action: .perform { Task { await model.signIn(.standard) } }
            ),
            Command(
                id: ID.signInWithApple, title: "Sign In with Apple…", menu: path, keywords: ["account", "apple id"],
                validation: canSignIn, action: .perform { Task { await model.signIn(.apple) } }
            ),
            Command(
                id: ID.showAccount, title: "Account…", menu: path, keywords: ["devices", "identities", "profile"],
                validation: { model.isSignedIn ? CommandValidation(title: "Account (\(model.statusTitle.replacingOccurrences(of: "Signed in as ", with: "")))…") : .enabled },
                action: .perform(showAccount)
            ),
            Command(
                id: ID.signOut, title: "Sign Out", menu: path, keywords: ["account", "log out"],
                validation: { model.isSignedIn ? .enabled : .disabled(notSignedIn) },
                action: .perform { Task { await model.signOut() } }
            ),
        ]
    }

    @MainActor
    static func install(into registry: CommandRegistry, model: AccountModel, showAccount: @escaping @MainActor @Sendable () -> Void) {
        for command in commands(model: model, showAccount: showAccount) { registry.replace(command) }
    }
}
