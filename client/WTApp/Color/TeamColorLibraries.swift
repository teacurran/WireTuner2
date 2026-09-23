import AppKit
import Foundation
import GRPCNIOTransportHTTP2
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTSync

/// Team colour libraries in the app (exporting-colors.adoc; COLOR-021's client UI): the *Team
/// Libraries* sheet listing each team's libraries from `ColorLibraryClient` (the cached listing
/// when offline, the update dot only after a listing succeeded), adding a library's colours with
/// their origin (`team:<id>`), the *Update from Library…* sheet's three-way listing, and
/// menu:File[Make Team Color Library…] and menu:File[Publish Library Version].
@MainActor
@Observable
final class TeamLibrariesModel {
    /// A team the account belongs to.
    struct Team: Hashable, Identifiable {
        let id: String
        let name: String
    }

    let workspace: ColorWorkspace
    /// The client; nil when there is no API to talk to (tests, signed out).
    @ObservationIgnored let client: ColorLibraryClient?
    /// The account's teams (the library's cached list).
    @ObservationIgnored var teams: @MainActor () -> [Team]
    /// Each team's last listing.
    private(set) var listings: [String: ColorLibraryClient.Listing] = [:]
    /// What the last action said went wrong.
    private(set) var message: String?
    /// The library whose update sheet is showing, with its colours and the classification.
    private(set) var update: (library: Wiretuner_Lib_V1_ColorLibrary, origin: String, rows: [LibraryUpdate])?
    /// The swatches ticked in the update sheet.
    var ticked: Set<OpID> = []
    var updateNames = false
    var updateSpot = false

    static let sheet = "team-libraries-sheet"
    static let updateSheet = "update-from-library-sheet"
    static let offlineReason = "Making a team color library needs a connection.  You are offline."

    init(workspace: ColorWorkspace, client: ColorLibraryClient?, teams: @escaping @MainActor () -> [Team] = { [] }) {
        self.workspace = workspace
        self.client = client
        self.teams = teams
    }

    /// Reads every team's libraries.
    func refresh() async {
        guard let client else { return }
        for team in teams() {
            listings[team.id] = await client.libraries(team: team.id)
        }
    }

    /// Whether any listed library has a newer version (the update dot).
    var hasUpdates: Bool { listings.values.contains { $0.libraries.contains(where: \.hasUpdate) } }

    /// Whether the last listings came from the cache because the server could not be reached.
    var isOffline: Bool { listings.values.contains { !$0.isCurrent } }

    /// Adds every colour of the library `id` (from the server, or the cache offline).
    @discardableResult
    func add(_ id: String) async -> Wiretuner_Doc_V1_Change? {
        guard let client else { return nil }
        do {
            let library = try await client.library(id)
            message = nil
            return await workspace.perform(ImportLibraryColors(library, origin: ColorLibraries.teamOrigin(id)))?.value
        } catch {
            message = "The library is not available offline."
            return nil
        }
    }

    // MARK: Update from Library…

    /// Fetches the library `id` and shows how the document's swatches from it stand.
    func prepareUpdate(_ id: String) async {
        guard let client, let document = workspace.document else { return }
        do {
            let library = try await client.library(id)
            let origin = ColorLibraries.teamOrigin(id)
            let rows = LibraryUpdate.classify(document.state, library: library, origin: origin)
            update = (library, origin, rows)
            ticked = Set(rows.filter { $0.status == .libraryChanged }.map(\.swatch))
            message = nil
        } catch {
            message = "The library is not available offline."
        }
    }

    /// The sheet's btn:[Update]: one change over the ticked swatches.
    @discardableResult
    func applyUpdate() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.updateSheet)
        guard let update, !ticked.isEmpty else { return nil }
        self.update = nil
        let swatches = update.rows.map(\.swatch).filter(ticked.contains)
        return workspace.perform(UpdateSwatchesFromLibrary(update.library, origin: update.origin, swatches: swatches, names: updateNames, spot: updateSpot))
    }

    func cancelUpdate() {
        update = nil
        workspace.dismiss(Self.updateSheet)
    }

    func toggle(_ id: OpID) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    static func title(_ status: LibraryUpdate.Status) -> String {
        switch status {
        case .unchanged: "Unchanged"
        case .libraryChanged: "Library changed"
        case .editedLocally: "Edited here"
        case .removedFromLibrary: "Removed from library"
        }
    }

    // MARK: Publishing

    /// menu:File[Make Team Color Library…]: publishes the front document to `team`.
    @discardableResult
    func publish(to team: String) async -> Bool {
        guard let client, let document = workspace.document else { return false }
        do {
            _ = try await client.publish(document.id, team: team, name: document.title)
            message = nil
            return true
        } catch {
            message = Self.offlineReason
            return false
        }
    }

    /// menu:File[Publish Library Version].
    @discardableResult
    func publishVersion() async -> Bool {
        guard let client, let document = workspace.document else { return false }
        do {
            _ = try await client.publish(document.id)
            return true
        } catch {
            message = "The library version could not be published: \(error.localizedDescription)"
            return false
        }
    }

    func dismiss() {
        workspace.dismiss(Self.sheet)
    }
}

extension LaunchEnvironment {
    /// The team colour library client over the configured API, caching in the colours folder;
    /// none in test launches.
    @MainActor
    func makeColorLibraryClient(account: AccountModel, infoDictionary: [String: Any]?, defaults: UserDefaults) -> ColorLibraryClient? {
        guard !isTesting, let directory = try? ColorLibraryClient.defaultDirectory() else { return nil }
        let configuration = AuthConfiguration(infoDictionary: infoDictionary)
        let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(
            clientVersion: Self.clientVersion(infoDictionary), deviceID: DeviceIdentity.current(defaults: defaults)
        )
        guard let transport = try? GRPCColorLibraryTransport.http2(api: configuration.api, identity: identity) else { return nil }
        let auth = account.auth
        return ColorLibraryClient(transport: transport, directory: directory) { try await auth.validAccessToken() }
    }
}

/// The *Team Libraries* sheet.
struct TeamLibrariesSheet: View {
    let model: TeamLibrariesModel

    static func adding(_ id: String, _ model: TeamLibrariesModel) -> () -> Void {
        { Task { await model.add(id) } }
    }

    static func updating(_ id: String, _ model: TeamLibrariesModel) -> () -> Void {
        {
            Task {
                await model.prepareUpdate(id)
                if model.update != nil {
                    model.dismiss()
                    model.workspace.present(UpdateFromLibrarySheet(model: model), title: "Update from Library", identifier: TeamLibrariesModel.updateSheet)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Team Libraries").font(.headline)
            if model.listings.values.allSatisfy(\.libraries.isEmpty) {
                Text("No team has published a color library yet.").foregroundStyle(.secondary)
            }
            ForEach(model.teams()) { team in
                if let listing = model.listings[team.id], !listing.libraries.isEmpty {
                    Text(team.name).font(.subheadline.bold())
                    ForEach(listing.libraries, id: \.info.documentID) { entry in
                        HStack {
                            if entry.hasUpdate { Circle().fill(SwiftUI.Color.accentColor).frame(width: 7, height: 7).accessibilityIdentifier("team-libraries.dot") }
                            Text(entry.info.name)
                            Spacer()
                            Button("Add", action: Self.adding(entry.info.documentID, model)).accessibilityIdentifier("team-libraries.add.\(entry.info.name)")
                            Button("Update…", action: Self.updating(entry.info.documentID, model))
                        }
                    }
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Done", action: model.dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// *Update from Library…*: each swatch from the library with how it stands, ticked when the
/// library changed it.
struct UpdateFromLibrarySheet: View {
    @Bindable var model: TeamLibrariesModel

    static func toggling(_ id: OpID, _ model: TeamLibrariesModel) -> Binding<Bool> {
        Binding(get: { model.ticked.contains(id) }, set: { _ in model.toggle(id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Update from \(model.update?.library.name ?? "Library")").font(.headline)
            ForEach(model.update?.rows ?? [], id: \.swatch) { row in
                Toggle(isOn: Self.toggling(row.swatch, model)) {
                    Text("\(model.workspace.swatches?.list[row.swatch]?.name ?? row.key) -- \(TeamLibrariesModel.title(row.status))")
                }
                .disabled(row.status == .unchanged)
            }
            Toggle("Update names", isOn: $model.updateNames)
            Toggle("Update spot/process", isOn: $model.updateSpot)
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelUpdate).keyboardShortcut(.cancelAction)
                Button("Update", action: ColorAction.run(model.applyUpdate)).keyboardShortcut(.defaultAction).accessibilityIdentifier("update-library.update")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
