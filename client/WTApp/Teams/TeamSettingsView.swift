import SwiftUI

/// The team settings sheet (SEC-003), opened from the library window while a team is the
/// current space.  Every decision is `TeamSettingsModel`'s; this only lays it out.
struct TeamSettingsView: View {
    @Bindable var model: TeamSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TeamSettingsStatus(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TeamMembersSection(model: model)
                    if model.canAdminister { TeamInvitesSection(model: model) }
                    TeamAccessSection(model: model)
                    TeamWorkspaceSection(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Refresh", action: model.handler(.reload)).accessibilityIdentifier("team.refresh")
                Spacer()
                Button("Done", action: model.handler(.done)).keyboardShortcut(.defaultAction).accessibilityIdentifier("team.done")
            }
        }
        .padding(20)
        .frame(width: 560, height: 620, alignment: .topLeading)
        .accessibilityIdentifier("team-settings")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.team?.name ?? "Team").font(.title2.bold()).accessibilityIdentifier("team.name")
            if let role = model.callerRole {
                Text("You are \(role == .admin ? "an" : "a") \(role.title.lowercased())").foregroundStyle(.secondary)
                    .accessibilityIdentifier("team.callerRole")
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
    }
}

/// Offline, errors, what the last action did, and the pending removal to confirm.
struct TeamSettingsStatus: View {
    let model: TeamSettingsModel

    var body: some View {
        if !model.isOnline {
            Label(CollaborationErrors.offlineNotice, systemImage: "icloud.slash").foregroundStyle(.secondary)
                .accessibilityIdentifier("team.offline")
        }
        if let error = model.errorMessage {
            Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("team.error")
        }
        if let notice = model.notice {
            Text(notice).font(.callout).accessibilityIdentifier("team.notice")
        }
        if let member = model.confirmingRemoval {
            HStack {
                Text("Remove \(member.displayName) from the team? They lose access to its documents.")
                Spacer()
                Button("Cancel", action: model.handler(.cancelConfirmation)).accessibilityIdentifier("team.confirm.cancel")
                Button("Remove", role: .destructive, action: model.handler(.remove(member))).accessibilityIdentifier("team.confirm.remove")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct TeamMembersSection: View {
    let model: TeamSettingsModel

    var body: some View {
        Text("Members").font(.headline)
        if model.canSeeMembers {
            ForEach(model.members) { member in
                HStack {
                    VStack(alignment: .leading) {
                        Text(member.accountID == model.accountID ? "\(member.displayName) (you)" : member.displayName)
                        Text(member.email).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canChange(member) {
                        Picker("Role", selection: model.roleBinding(for: member)) {
                            ForEach(model.roleOptions(for: member), id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("team.member.\(member.accountID).role")
                        Button("Remove", action: model.handler(.confirmRemove(member)))
                            .accessibilityIdentifier("team.member.\(member.accountID).remove")
                    } else {
                        Text(member.role.title).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("team.member.\(member.accountID)")
            }
        } else {
            Text(TeamSettingsModel.guestNote).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("team.guestNote")
        }
    }
}

struct TeamInvitesSection: View {
    @Bindable var model: TeamSettingsModel

    var body: some View {
        Text("Invitations").font(.headline)
        HStack {
            TextField("Email address", text: $model.inviteEmail).accessibilityIdentifier("team.invite.email")
            Picker("Role", selection: $model.inviteRole) {
                ForEach(model.inviteRoles, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("team.invite.role")
            Button("Invite", action: model.handler(.invite)).disabled(!model.canInvite).accessibilityIdentifier("team.invite.send")
        }
        .disabled(!model.canEdit)
        ForEach(model.invites) { invite in
            HStack {
                VStack(alignment: .leading) {
                    Text(invite.email)
                    Text(Self.caption(invite)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resend", action: model.handler(.resend(invite))).accessibilityIdentifier("team.invite.\(invite.id).resend")
                Button("Revoke", action: model.handler(.revoke(invite))).accessibilityIdentifier("team.invite.\(invite.id).revoke")
            }
            .disabled(!model.canEdit)
            .accessibilityIdentifier("team.invite.\(invite.id)")
        }
    }

    /// "Member · expires Sep 30, 2026".
    static func caption(_ invite: TeamInviteInfo) -> String {
        [invite.role.title, invite.expiresAt.map { "expires \($0.formatted(date: .abbreviated, time: .omitted))" }].compactMap(\.self).joined(separator: " · ")
    }
}

struct TeamAccessSection: View {
    let model: TeamSettingsModel

    var body: some View {
        Text("Access to team documents").font(.headline)
        HStack {
            Text("Every member gets")
            Picker("Default role", selection: model.defaultRoleBinding) {
                ForEach(DocumentRole.grantable, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!model.canEdit)
            .accessibilityIdentifier("team.defaultRole")
        }
        if !model.canAdminister {
            Text(TeamSettingsModel.adminOnlyNote).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("team.adminOnly")
        }
    }
}

struct TeamWorkspaceSection: View {
    @Bindable var model: TeamSettingsModel

    var body: some View {
        Text("Company workspace").font(.headline)
        ForEach(model.domains) { domain in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(domain.domain)
                    if domain.isVerified {
                        Label("Verified", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Not verified. Add the DNS TXT record \(domain.txtRecord)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Spacer()
                if !domain.isVerified {
                    Button("Verify", action: model.handler(.verify(domain))).accessibilityIdentifier("team.domain.\(domain.domain).verify")
                }
                Button("Remove", action: model.handler(.removeDomain(domain))).accessibilityIdentifier("team.domain.\(domain.domain).remove")
            }
            .disabled(!model.canEdit)
            .accessibilityIdentifier("team.domain.\(domain.domain)")
        }
        HStack {
            TextField("example.com", text: $model.newDomain).accessibilityIdentifier("team.domain.new")
            Button("Add Domain", action: model.handler(.addDomain)).disabled(!model.canAddDomain).accessibilityIdentifier("team.domain.add")
        }
        .disabled(!model.canEdit)
        ForEach(TeamSettingsModel.WorkspaceSwitch.allCases, id: \.self) { workspaceSwitch in
            Toggle(workspaceSwitch.title, isOn: model.switchBinding(workspaceSwitch))
                .disabled(!model.isEnabled(workspaceSwitch))
                .accessibilityIdentifier("team.workspace.\(workspaceSwitch.rawValue)")
        }
        if model.settings.ssoAlias.isEmpty {
            Text(TeamSettingsModel.ssoNeedsConnection).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("team.workspace.ssoNote")
        } else {
            Text("SSO connection: \(model.settings.ssoAlias)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The Join Team sheet: paste the invitation's link, or arrive with it from a
/// `wiretuner://invite/<token>` URL.
struct JoinTeamView: View {
    @Bindable var model: JoinTeamModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a Team").font(.headline)
            if let team = model.joined {
                Text("You joined \(team.name).").accessibilityIdentifier("join.joined")
            } else {
                Text("Paste the link from your invitation email.").font(.callout).foregroundStyle(.secondary)
                TextField("Invitation link", text: $model.link).accessibilityIdentifier("join.link")
                if let problem = model.linkProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("join.problem")
                }
            }
            if !model.isOnline {
                Text(CollaborationErrors.offlineNotice).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("join.offline")
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("join.error")
            }
            HStack {
                Spacer()
                Button(model.joined == nil ? "Cancel" : "Done", action: model.doneHandler()).accessibilityIdentifier("join.done")
                if model.joined == nil {
                    Button("Join", action: model.joinHandler()).keyboardShortcut(.defaultAction).disabled(!model.canJoin)
                        .accessibilityIdentifier("join.join")
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityIdentifier("join-team")
    }
}
