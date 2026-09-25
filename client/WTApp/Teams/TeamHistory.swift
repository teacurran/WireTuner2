import Foundation
import SwiftUI
import WTProto

/// The team's history window (security.adoc, "Teams": `UpdateTeam.history_retention_days`;
/// history.adoc, "How long history is kept"; SEC-003): how many days the team's documents keep
/// every change -- 30 by default, up to ten years.  Admins choose it in the team settings sheet;
/// members see it.
enum TeamHistory {
    /// The server's range (`UpdateTeamRequest.history_retention_days`).
    static let range = 30...3650
    static let defaultDays = 30

    /// The windows the sheet offers.
    static let choices: [(days: Int, title: String)] = [
        (30, "30 days"), (90, "90 days"), (180, "6 months"), (365, "1 year"), (730, "2 years"), (1825, "5 years"), (3650, "10 years"),
    ]

    /// The window `Team.history_retention_days` stands for: 0 (unset) is the default.
    static func days(_ stored: Int) -> Int { stored == 0 ? defaultDays : stored }

    /// "1 year", or "400 days" for a window the choices do not name.
    static func title(_ days: Int) -> String {
        choices.first { $0.days == days }?.title ?? "\(days) days"
    }

    static func request(teamID: String, days: Int) -> Wiretuner_Account_V1_UpdateTeamRequest {
        var message = Wiretuner_Account_V1_UpdateTeamRequest()
        message.teamID = teamID
        message.historyRetentionDays = UInt32(min(max(days, range.lowerBound), range.upperBound))
        return message
    }
}

/// Why a client could not set the history window.
enum TeamHistoryError: Error, Equatable {
    case unsupported
}

extension TeamClient {
    /// A client without the call (the tests' fakes) refuses.
    func setHistoryRetention(teamID: String, days: Int, accessToken: String) async throws -> TeamDetail {
        throw TeamHistoryError.unsupported
    }
}

extension GRPCTeamClient {
    func setHistoryRetention(teamID: String, days: Int, accessToken: String) async throws -> TeamDetail {
        let response: Team.UpdateTeam.Output = try await caller.unary(Team.UpdateTeam.descriptor, TeamHistory.request(teamID: teamID, days: days), accessToken: accessToken)
        return response.detail
    }
}

/// The sheet's *History* row.
struct TeamHistorySection: View {
    let model: TeamSettingsModel

    static func choices(including days: Int) -> [(days: Int, title: String)] {
        TeamHistory.choices.contains { $0.days == days } ? TeamHistory.choices : (TeamHistory.choices + [(days, TeamHistory.title(days))]).sorted { $0.days < $1.days }
    }

    var body: some View {
        let days = model.historyDays
        Text("History").font(.headline)
        HStack {
            Text("Keep every change for")
            Picker("History", selection: model.historyDaysBinding) {
                ForEach(Self.choices(including: days), id: \.days) { Text($0.title).tag($0.days) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!model.canEdit)
            .accessibilityIdentifier("team.historyDays")
        }
        Text("Named versions are kept however long the window is.").font(.caption).foregroundStyle(.secondary)
    }
}
