import AppKit
import SwiftUI

/// The account window's linked identities (security.adoc, "Accounts"; SEC-003): the sign-in methods
/// `AccountService.Me` lists, with *Add Sign-in Method…* and a *Remove…* per method.  The account
/// service has no call to link or unlink an identity, so both open the realm's account console on
/// its linked-accounts page, where Keycloak -- which owns every credential -- does it; *Refresh*
/// reads the list back.  The last method cannot be removed.
enum LinkedIdentities {
    /// The realm's account console page for linked sign-in methods.
    static func consoleURL(issuer: URL) -> URL {
        var components = URLComponents(url: issuer.appending(path: "account"), resolvingAgainstBaseURL: false)!
        components.fragment = "/account-security/linked-accounts"
        return components.url!
    }

    /// Opens a URL in the browser; replaceable in tests.
    @MainActor static var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Opens the console for `model`'s realm.
    @MainActor
    static func manage(_ model: AccountModel) {
        open(consoleURL(issuer: model.auth.configuration.issuer))
    }

    /// "Apple", "Password", "Acme SSO".
    static func title(_ provider: String) -> String {
        if provider.hasPrefix("sso:") { return "\(provider.dropFirst(4)) SSO" }
        return provider.capitalized
    }
}

struct LinkedIdentitiesView: View {
    let identities: [AccountProfile.Identity]
    let manage: @MainActor () -> Void

    var body: some View {
        HStack {
            Text("Linked identities").font(.subheadline.bold())
            Spacer()
            Button("Add Sign-in Method…", action: manage)
                .help("Link a passkey, your Apple Account or a password in your account's settings")
                .accessibilityIdentifier("account.identity.add")
        }
        ForEach(identities) { identity in
            HStack {
                Text(LinkedIdentities.title(identity.provider))
                Text(identity.email).foregroundStyle(.secondary)
                if identity.isRelay { Text("Hidden email").font(.caption) }
                if !identity.emailVerified { Text("Unverified").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Remove…", action: manage)
                    .disabled(identities.count < 2)
                    .help(identities.count < 2 ? "The last sign-in method cannot be removed" : "Unlink this sign-in method in your account's settings")
                    .accessibilityIdentifier("account.identity.\(identity.id).remove")
            }
            .accessibilityIdentifier("account.identity.\(identity.id)")
        }
    }
}
