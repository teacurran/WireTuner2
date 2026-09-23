import AppKit
import SwiftUI

/// The Share sheet (COLLAB-013), from menu:File[Share…] and the toolbar's btn:[Share].  Every
/// decision is `ShareSheetModel`'s; this only lays it out.
struct ShareSheetView: View {
    @Bindable var model: ShareSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Share “\(model.document.name)”").font(.title3.bold()).lineLimit(1).accessibilityIdentifier("share.title")
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            ShareStatusView(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.canResolveRequests, !model.requests.isEmpty { ShareRequestsSection(model: model) }
                    SharePeopleSection(model: model)
                    if model.mayInvite { ShareInviteSection(model: model) }
                    if model.isOwner { ShareLinksSection(model: model) }
                    if !model.transferCandidates.isEmpty { ShareTransferSection(model: model) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Refresh", action: model.handler(.reload)).disabled(!model.document.isUploaded).accessibilityIdentifier("share.refresh")
                Spacer()
                Button("Done", action: model.handler(.done)).keyboardShortcut(.defaultAction).accessibilityIdentifier("share.done")
            }
        }
        .padding(20)
        .frame(width: 540, height: 600, alignment: .topLeading)
        .accessibilityIdentifier("share-sheet")
    }
}

/// Why controls are off, errors, what the last action did, the workspace restriction and the
/// confirmation waiting for an answer.
struct ShareStatusView: View {
    let model: ShareSheetModel

    var body: some View {
        if let unavailable = model.unavailableNotice {
            Label(unavailable, systemImage: "icloud.slash").foregroundStyle(.secondary).accessibilityIdentifier("share.offline")
        }
        if let restriction = model.restrictionNotice {
            Label(restriction, systemImage: "building.2").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("share.restricted")
        }
        if let error = model.errorMessage {
            Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("share.error")
        }
        if let notice = model.notice {
            Text(notice).font(.callout).accessibilityIdentifier("share.notice")
        }
        if let confirmation = model.confirming {
            let prompt = ShareSheetModel.prompt(confirmation)
            HStack {
                Text(prompt.message)
                Spacer()
                Button("Cancel", action: model.handler(.cancelConfirmation)).accessibilityIdentifier("share.confirm.cancel")
                Button(prompt.button, role: .destructive, action: model.handler(prompt.action)).accessibilityIdentifier("share.confirm.ok")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct ShareRequestsSection: View {
    @Bindable var model: ShareSheetModel

    var body: some View {
        HStack {
            Text("Access requests").font(.headline)
            Spacer()
            Picker("Grant as", selection: $model.requestRole) {
                ForEach(DocumentRole.grantable, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .accessibilityIdentifier("share.request.role")
        }
        ForEach(model.requests) { request in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(request.name)
                    if !request.message.isEmpty { Text(request.message).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Deny", action: model.handler(.resolve(request, nil))).accessibilityIdentifier("share.request.\(request.id).deny")
                Button("Approve", action: model.handler(.resolve(request, model.requestRole))).accessibilityIdentifier("share.request.\(request.id).approve")
            }
            .accessibilityIdentifier("share.request.\(request.id)")
        }
    }
}

struct SharePeopleSection: View {
    let model: ShareSheetModel

    var body: some View {
        Text("People").font(.headline)
        ForEach(model.people) { member in
            HStack {
                VStack(alignment: .leading) {
                    Text(Self.title(member, isMe: model.isMe(member)))
                    if !member.email.isEmpty { Text(member.email).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.canChangeRole(member) {
                    Picker("Role", selection: model.roleBinding(for: member)) {
                        ForEach(model.roleOptions(for: member), id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("share.member.\(member.id).role")
                } else {
                    Text(Self.roleText(member)).foregroundStyle(.secondary).accessibilityIdentifier("share.member.\(member.id).roleText")
                }
                if model.canRemove(member) {
                    Button("Remove", action: model.handler(.confirm(.remove(member)))).accessibilityIdentifier("share.member.\(member.id).remove")
                }
            }
            .accessibilityIdentifier("share.member.\(member.id)")
        }
        if let access = model.roster.teamAccess {
            HStack {
                Text("Everyone in \(access.teamName)")
                Spacer()
                if model.canManageTeamAccess {
                    Picker("Team access", selection: model.teamAccessBinding) {
                        Text("Team default (\(access.teamDefault?.title ?? "None"))").tag(DocumentRole?.none)
                        ForEach(DocumentRole.grantable, id: \.self) { Text($0.title).tag(DocumentRole?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("share.team.role")
                } else {
                    Text(access.effective?.title ?? "No access").foregroundStyle(.secondary).accessibilityIdentifier("share.team.roleText")
                }
            }
            .accessibilityIdentifier("share.team")
        }
    }

    /// "Priya (you)", "Sam · creator", "sam@example.com · invited".
    static func title(_ member: ShareMember, isMe: Bool) -> String {
        var title = member.name
        if isMe { title += " (you)" }
        if member.isCreator { title += " · creator" }
        if member.isPending { title += " · invited" }
        return title
    }

    /// The named role, else the effective one with how it arises ("Editor via link").
    static func roleText(_ member: ShareMember) -> String {
        if let role = member.role { return role.title }
        let role = member.effectiveRole?.title ?? "No access"
        return member.sources.contains(.link) ? "\(role) via link" : role
    }
}

struct ShareInviteSection: View {
    @Bindable var model: ShareSheetModel

    var body: some View {
        Text("Invite").font(.headline)
        HStack {
            TextField("Email address", text: $model.inviteEmail).onSubmit(model.handler(.invite)).accessibilityIdentifier("share.invite.email")
            Picker("Role", selection: $model.inviteRole) {
                ForEach(model.inviteRoles, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("share.invite.role")
            Button("Invite", action: model.handler(.invite)).disabled(!model.canInvite).accessibilityIdentifier("share.invite.send")
        }
        TextField("Message (optional)", text: $model.inviteMessage).accessibilityIdentifier("share.invite.message")
    }
}

struct ShareLinksSection: View {
    @Bindable var model: ShareSheetModel

    var body: some View {
        Text("Links").font(.headline)
        ForEach(model.links) { link in
            HStack {
                Text(ShareSheetModel.summary(link)).font(.callout)
                Spacer()
                Button("Copy Link", action: model.handler(.copyLink(link)))
                    .disabled(model.linkURL(link) == nil)
                    .help(model.linkURL(link) == nil ? ShareSheetModel.noTokenHelp : "Copy the link")
                    .accessibilityIdentifier("share.link.\(link.id).copy")
                Button("Revoke", action: model.handler(.confirm(.revokeLink(link)))).accessibilityIdentifier("share.link.\(link.id).revoke")
            }
            .disabled(!model.canCreateLink)
            .accessibilityIdentifier("share.link.\(link.id)")
        }
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Role")
                Picker("Link role", selection: $model.linkRole) {
                    ForEach(DocumentRole.grantable, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("share.newLink.role")
            }
            GridRow {
                Toggle("Expires", isOn: $model.linkExpires).accessibilityIdentifier("share.newLink.expires")
                HStack {
                    DatePicker("Expiry", selection: $model.linkExpiry, displayedComponents: .date).labelsHidden().disabled(!model.linkExpires)
                        .accessibilityIdentifier("share.newLink.expiry")
                    Toggle("Revoke access from this link on expiry", isOn: $model.linkRevokeOnExpiry).disabled(!model.linkExpires)
                        .accessibilityIdentifier("share.newLink.revokeOnExpiry")
                }
            }
            GridRow {
                Text("Password")
                SecureField("Optional", text: $model.linkPassword).accessibilityIdentifier("share.newLink.password")
            }
            if model.isTeamDocument {
                GridRow {
                    Text("")
                    Toggle("Restrict to team members", isOn: $model.linkTeamMembersOnly).disabled(model.isRestricted)
                        .accessibilityIdentifier("share.newLink.teamOnly")
                }
            }
        }
        .disabled(!model.canCreateLink)
        Button("New Link", action: model.handler(.createLink)).disabled(!model.canCreateLink).accessibilityIdentifier("share.newLink.create")
    }
}

struct ShareTransferSection: View {
    @Bindable var model: ShareSheetModel

    var body: some View {
        Text("Ownership").font(.headline)
        HStack {
            Picker("New owner", selection: $model.transferTargetID) {
                Text("Choose a person").tag(String?.none)
                ForEach(model.transferCandidates) { Text($0.name).tag(String?.some($0.accountID)) }
            }
            .fixedSize()
            .accessibilityIdentifier("share.transfer.target")
            Button("Transfer Ownership…", action: model.handler(.confirmTransfer)).disabled(!model.canTransfer)
                .accessibilityIdentifier("share.transfer")
        }
    }
}
