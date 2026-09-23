import Foundation
import GRPCNIOTransportHTTP2
import WTSync

/// The team font libraries over WTSync's `FontLibraryClient` (font-substitution.adoc, "Team font
/// library"): a document in a team's space uses that team's library; online means the library
/// answers and someone is signed in.  Fetched files land in the blob cache, so fonts fetched once
/// load offline.
@MainActor
final class TeamFontLibraryConnection: TeamFontLibrary {
    let client: FontLibraryClient
    let library: LibraryModel
    let account: AccountModel

    init(client: FontLibraryClient, library: LibraryModel, account: AccountModel) {
        self.client = client
        self.library = library
        self.account = account
    }

    var isOnline: Bool { library.isOnline && account.isSignedIn }

    func team(of documentID: String) -> String? {
        guard let space = library.cache.documents[documentID]?.spaceID, library.cache.teams.contains(where: { $0.id == space }) else { return nil }
        return space
    }

    func families(team: String) async -> Set<String> {
        await client.catalog(team: team).families
    }

    func files(forFamily family: String, team: String) async throws -> [URL] {
        try await client.files(forFamily: family, team: team)
    }
}

extension LaunchEnvironment {
    /// The team font library client over the configured API, its files in the blob cache; none
    /// in test launches.
    @MainActor
    func makeFontLibraryClient(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults) -> FontLibraryClient? {
        guard !isTesting, let directory = try? FontLibraryClient.defaultDirectory(), let blobs = try? BlobCache.defaultDirectory() else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: Self.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: defaults)
        )
        guard let transport = try? GRPCFontLibraryTransport.http2(api: configuration.api, identity: identity) else { return nil }
        let auth = account.auth
        return FontLibraryClient(transport: transport, cache: BlobCache(directory: blobs), directory: directory) { try await auth.validAccessToken() }
    }
}
