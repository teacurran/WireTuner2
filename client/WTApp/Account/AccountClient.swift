import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf
import WTProto

/// The signed-in account as the account window shows it (security.adoc, "Accounts"): the
/// linked identities and the devices with the method each signed in with.
struct AccountProfile: Equatable, Sendable {
    struct Identity: Equatable, Sendable, Identifiable {
        var provider: String
        var email: String
        var emailVerified: Bool
        var isRelay: Bool
        var linkedAt: Date?
        var id: String { provider + "|" + email }
    }

    struct Device: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var platform: String
        /// `passkey`, `apple`, `password` or `sso:<alias>`.
        var authMethod: String
        var lastSeenAt: Date?
        var isCurrent: Bool
        /// When the device was revoked; nil while it is active.
        var revokedAt: Date? = nil

        /// "Passkey", "Apple", "Password" or the workspace alias (SEC-003's labels).
        var methodTitle: String { AccountProfile.methodTitle(authMethod) }
    }

    var email: String
    var displayName: String
    var identities: [Identity]
    var devices: [Device]
    /// The account id: the id of the personal library space.
    var accountID: String = ""

    static func methodTitle(_ method: String) -> String {
        switch method {
        case "passkey": return "Passkey"
        case "apple": return "Apple"
        case "password": return "Password"
        case let sso where sso.hasPrefix("sso:"): return String(sso.dropFirst(4))
        case "": return "Unknown"
        default: return method
        }
    }
}

extension AccountProfile {
    /// From `AccountService.Me`: the account, its identities and the calling device (the full
    /// device list is `ListDevices`, `AccountModel.loadDevices`).
    init(_ response: Wiretuner_Account_V1_MeResponse) {
        let account = response.account
        self.init(
            email: account.email, displayName: account.displayName,
            identities: account.identities.map { identity in
                Identity(
                    provider: identity.provider, email: identity.email, emailVerified: identity.emailVerified,
                    isRelay: identity.isRelay, linkedAt: identity.hasLinkedAt ? identity.linkedAt.date : nil
                )
            },
            devices: response.hasDevice ? [Device(response.device)] : [],
            accountID: account.id
        )
    }
}

extension AccountProfile.Device {
    init(_ device: Wiretuner_Account_V1_Device) {
        self.init(
            id: device.id, name: device.name, platform: device.platform, authMethod: device.authMethod,
            lastSeenAt: device.hasLastSeenAt ? device.lastSeenAt.date : nil, isCurrent: device.current,
            revokedAt: device.hasRevokedAt ? device.revokedAt.date : nil
        )
    }
}

/// The account RPCs the app needs.  A protocol so the account model is tested without a
/// server.
protocol AccountClient: Sendable {
    func me(accessToken: String) async throws -> AccountProfile
}

/// The metadata every call carries (api-conventions.adoc, "Metadata").
struct CallMetadata: Equatable, Sendable {
    var accessToken: String
    var clientVersion: String
    var deviceID: String
    var requestID: String = UUID().uuidString

    var pairs: [(String, String)] {
        [
            ("authorization", "Bearer \(accessToken)"), ("wt-client", "macos/\(clientVersion)"),
            ("wt-device", deviceID), ("wt-request-id", requestID),
        ]
    }

    var metadata: Metadata {
        var metadata = Metadata()
        for (key, value) in pairs { metadata.addString(value, forKey: key) }
        return metadata
    }

    static func == (lhs: CallMetadata, rhs: CallMetadata) -> Bool {
        lhs.pairs.map { "\($0.0)=\($0.1)" } == rhs.pairs.map { "\($0.0)=\($0.1)" }
    }
}

/// `AccountService` over grpc-swift 2's HTTP/2 transport, one connection per call (the
/// account window is opened rarely; SYNC-001's long-lived client serves the document RPCs).
struct GRPCAccountClient: AccountClient {
    let api: URL
    let clientVersion: String
    let deviceID: String

    /// The host, port and security of `api` (`http` is plaintext: the compose API).
    var endpoint: (host: String, port: Int, tls: Bool) {
        let tls = api.scheme == "https"
        return (api.host ?? "localhost", api.port ?? (tls ? 443 : 80), tls)
    }

    func me(accessToken: String) async throws -> AccountProfile {
        let endpoint = self.endpoint
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: endpoint.host, port: endpoint.port),
            transportSecurity: endpoint.tls ? .tls : .plaintext
        )
        let metadata = CallMetadata(accessToken: accessToken, clientVersion: clientVersion, deviceID: deviceID).metadata
        return try await withGRPCClient(transport: transport) { client in
            let service = Wiretuner_Account_V1_AccountService.Client(wrapping: client)
            let response = try await service.me(request: ClientRequest(message: Wiretuner_Account_V1_MeRequest(), metadata: metadata))
            return AccountProfile(response)
        }
    }
}

/// The stable per-install device id `wt-device` carries (not the replica id).
enum DeviceIdentity {
    static let defaultsKey = "wt.device_id"

    static func current(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty { return existing }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}
