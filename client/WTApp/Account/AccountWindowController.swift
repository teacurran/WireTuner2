import AppKit
import SwiftUI

/// The account window (menu:WireTuner[Account…]): sign-in entry points while signed out; the
/// linked identities and every device, with each device's sign-in method and a Revoke button for
/// the other Macs (SEC-003), while signed in.
@MainActor
final class AccountWindowController: NSWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("account-window")

    let model: AccountModel

    init(model: AccountModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Account"
        window.identifier = Self.identifier
        window.setAccessibilityIdentifier(Self.identifier.rawValue)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AccountView(model: model))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AccountWindowController is built in code")
    }

    func show() {
        window?.center()
        showWindow(nil)
        if model.isSignedIn, model.profile == nil { AccountView(model: model).handler(.refresh)() }
    }
}

struct AccountView: View {
    enum Action: Equatable {
        case signIn(SignInMethod)
        case refresh
        case signOut
        case revokeDevice(String)
    }

    let model: AccountModel
    @State private var workspace = ""

    /// A button's action; the buttons hold these instead of closures of their own.
    func handler(_ action: Action) -> () -> Void {
        { [model] in Task { await Self.perform(action, model: model) } }
    }

    static func perform(_ action: Action, model: AccountModel) async {
        switch action {
        case let .signIn(method): await model.signIn(method)
        case .refresh: await model.loadProfile()
        case .signOut: await model.signOut()
        case let .revokeDevice(id): await model.revokeDevice(id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.statusTitle).font(.headline).accessibilityIdentifier("account.status")
            if model.isSignedIn { signedIn } else { signedOut }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout).accessibilityIdentifier("account.error")
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 320, alignment: .topLeading)
        .disabled(model.isBusy)
    }

    @ViewBuilder private var signedOut: some View {
        Text("Sign in with a passkey, your Apple Account, your company's workspace or a password.")
            .font(.callout).foregroundStyle(.secondary)
        Button("Sign In…", action: handler(.signIn(.standard)))
            .accessibilityIdentifier("account.signIn")
        Button("Sign In with Apple…", action: handler(.signIn(.apple)))
            .accessibilityIdentifier("account.signInWithApple")
        HStack {
            TextField("Workspace", text: $workspace).accessibilityIdentifier("account.workspace")
            Button("Sign In with Workspace…", action: handler(.signIn(.workspace(alias: workspace))))
                .disabled(workspace.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("account.signInWorkspace")
        }
    }

    @ViewBuilder private var signedIn: some View {
        if let profile = model.profile {
            LinkedIdentitiesView(identities: profile.identities) { [model] in LinkedIdentities.manage(model) }
            Text("Devices").font(.subheadline.bold())
            ForEach(model.shownDevices) { device in
                HStack {
                    Text(device.name)
                    Text(device.methodTitle).foregroundStyle(.secondary)
                        .accessibilityIdentifier("account.device.\(device.id).method")
                    Spacer()
                    if device.isCurrent {
                        Text("This Mac").font(.caption)
                    } else if model.deviceClient != nil {
                        Button("Revoke", action: handler(.revokeDevice(device.id)))
                            .help("Sign this Mac out: its session ends and it cannot refresh its sign-in")
                            .accessibilityIdentifier("account.device.\(device.id).revoke")
                    }
                }
                .accessibilityIdentifier("account.device.\(device.id)")
            }
        } else {
            ProgressView().controlSize(.small)
        }
        HStack {
            Button("Refresh", action: handler(.refresh)).accessibilityIdentifier("account.refresh")
            Button("Sign Out", action: handler(.signOut)).accessibilityIdentifier("account.signOut")
        }
    }
}
