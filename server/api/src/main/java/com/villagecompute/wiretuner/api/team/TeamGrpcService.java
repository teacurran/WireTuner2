package com.villagecompute.wiretuner.api.team;

import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.account.v1.AcceptInviteRequest;
import com.villagecompute.wiretuner.account.v1.AcceptInviteResponse;
import com.villagecompute.wiretuner.account.v1.AddWorkspaceDomainRequest;
import com.villagecompute.wiretuner.account.v1.AddWorkspaceDomainResponse;
import com.villagecompute.wiretuner.account.v1.CreateTeamRequest;
import com.villagecompute.wiretuner.account.v1.CreateTeamResponse;
import com.villagecompute.wiretuner.account.v1.DeleteTeamRequest;
import com.villagecompute.wiretuner.account.v1.DeleteTeamResponse;
import com.villagecompute.wiretuner.account.v1.GetTeamRequest;
import com.villagecompute.wiretuner.account.v1.GetTeamResponse;
import com.villagecompute.wiretuner.account.v1.InviteMemberRequest;
import com.villagecompute.wiretuner.account.v1.InviteMemberResponse;
import com.villagecompute.wiretuner.account.v1.LeaveTeamRequest;
import com.villagecompute.wiretuner.account.v1.LeaveTeamResponse;
import com.villagecompute.wiretuner.account.v1.ListInvitesRequest;
import com.villagecompute.wiretuner.account.v1.ListInvitesResponse;
import com.villagecompute.wiretuner.account.v1.ListMembersRequest;
import com.villagecompute.wiretuner.account.v1.ListMembersResponse;
import com.villagecompute.wiretuner.account.v1.ListTeamsRequest;
import com.villagecompute.wiretuner.account.v1.ListTeamsResponse;
import com.villagecompute.wiretuner.account.v1.MutinyTeamServiceGrpc;
import com.villagecompute.wiretuner.account.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.account.v1.RemoveMemberResponse;
import com.villagecompute.wiretuner.account.v1.RemoveWorkspaceDomainRequest;
import com.villagecompute.wiretuner.account.v1.RemoveWorkspaceDomainResponse;
import com.villagecompute.wiretuner.account.v1.RevokeInviteRequest;
import com.villagecompute.wiretuner.account.v1.RevokeInviteResponse;
import com.villagecompute.wiretuner.account.v1.SetMemberRoleRequest;
import com.villagecompute.wiretuner.account.v1.SetMemberRoleResponse;
import com.villagecompute.wiretuner.account.v1.SetWorkspaceSettingsRequest;
import com.villagecompute.wiretuner.account.v1.SetWorkspaceSettingsResponse;
import com.villagecompute.wiretuner.account.v1.TransferOwnershipRequest;
import com.villagecompute.wiretuner.account.v1.TransferOwnershipResponse;
import com.villagecompute.wiretuner.account.v1.UpdateTeamRequest;
import com.villagecompute.wiretuner.account.v1.UpdateTeamResponse;
import com.villagecompute.wiretuner.account.v1.VerifyWorkspaceDomainRequest;
import com.villagecompute.wiretuner.account.v1.VerifyWorkspaceDomainResponse;
import com.villagecompute.wiretuner.account.v1.WorkspaceSettings;
import com.villagecompute.wiretuner.api.auth.AuthMethods;
import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.AccountIdentityRepository;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseRepository;
import com.villagecompute.wiretuner.api.persistence.Team;
import com.villagecompute.wiretuner.api.persistence.TeamInvite;
import com.villagecompute.wiretuner.api.persistence.TeamInviteRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMember;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;
import com.villagecompute.wiretuner.api.persistence.Workspace;
import com.villagecompute.wiretuner.api.persistence.WorkspaceDomain;
import com.villagecompute.wiretuner.api.persistence.WorkspaceDomainId;
import com.villagecompute.wiretuner.api.persistence.WorkspaceDomainRepository;
import com.villagecompute.wiretuner.api.persistence.WorkspaceRepository;
import com.villagecompute.wiretuner.api.share.RoleNotices;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.account.v1.TeamService} (SEC-001; docs/spec/security.adoc, Teams). Each RPC
 * resolves the caller's membership first: not a member (or the team is deleted, for anything but
 * reading it) is {@code TEAM_NOT_FOUND}, so existence is never revealed; a role below the RPC's
 * minimum is {@code ROLE_INSUFFICIENT}. Team documents follow membership through
 * {@link DocumentRoles}: removing or losing a member ends their access at the next call, and their
 * named roles and link uses on the team's documents go with the membership.
 */
@GrpcService
public class TeamGrpcService extends MutinyTeamServiceGrpc.TeamServiceImplBase {

    static final Duration INVITE_LIFETIME = Duration.ofDays(7);
    static final int TOKEN_BYTES = 32;
    static final int DOMAIN_TOKEN_BYTES = 16;

    private static final SecureRandom RANDOM = new SecureRandom();

    @Inject
    RoleGuard guard;

    @Inject
    TeamRepository teams;

    @Inject
    TeamMemberRepository teamMembers;

    @Inject
    TeamInviteRepository invites;

    @Inject
    WorkspaceRepository workspaces;

    @Inject
    WorkspaceDomainRepository domains;

    @Inject
    AccountRepository accounts;

    @Inject
    AccountIdentityRepository identities;

    @Inject
    DocumentRepository documents;

    @Inject
    DocumentMemberRepository documentMembers;

    @Inject
    ShareLinkUseRepository shareLinkUses;

    @Inject
    InviteMailer mailer;

    @Inject
    DomainVerifier verifier;

    @Inject
    RoleNotices notices;

    /** A committed RPC's result and the account that acted, for the role notices that follow. */
    record Acted<T>(T value, UUID actor) {

        Acted(T value, Principal principal) {
            this(value, principal.accountId());
        }
    }

    /** The caller's membership and the team it is in. */
    record Membership(Principal principal, Team team, TeamMember member) {

        String role() {
            return member.role;
        }

        boolean isOwner() {
            return TeamRoles.OWNER.equals(member.role);
        }
    }

    // ----------------------------------------------------------------------------------- teams

    @Override
    public Uni<CreateTeamResponse> createTeam(CreateTeamRequest request) {
        return tx(() -> guard.authenticated().flatMap(principal -> {
            Team team = new Team();
            team.id = UUID.randomUUID();
            team.name = request.getName();
            team.ownerAccountId = principal.accountId();
            team.defaultDocumentRole = TeamMessages.defaultDocumentRole(request.getDefaultDocumentRole());
            boolean derived = request.getSlug().isEmpty();
            String wanted = derived ? Slugs.derive(request.getName()) : request.getSlug();
            return teams.findBySlug(wanted).flatMap(taken -> {
                if (taken == null) {
                    team.slug = wanted;
                } else if (derived) {
                    team.slug = Slugs.withSuffix(wanted, team.id.toString().substring(0, 6));
                } else {
                    return Uni.createFrom().failure(StatusExceptions.slugTaken(wanted));
                }
                TeamMember owner = new TeamMember();
                owner.id = new TeamMemberId(team.id, principal.accountId());
                owner.role = TeamRoles.OWNER;
                return teams.persist(team).chain(() -> teamMembers.persist(owner))
                        .chain(() -> teamMessage(team, TeamRoles.OWNER));
            });
        })).map(team -> CreateTeamResponse.newBuilder().setTeam(team).build());
    }

    @Override
    public Uni<ListTeamsResponse> listTeams(ListTeamsRequest request) {
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> guard.authenticated().flatMap(principal -> teams.getSession().chain(session -> session
                .createQuery("select t, m.role from Team t, TeamMember m where m.id.teamId = t.id"
                        + " and m.id.accountId = ?1 order by t.name, t.id", Object[].class)
                .setParameter(1, principal.accountId())
                .setFirstResult(offset)
                .setMaxResults(pageSize + 1)
                .getResultList())
                .flatMap(rows -> {
                    ListTeamsResponse.Builder response = ListTeamsResponse.newBuilder();
                    if (rows.size() > pageSize) {
                        response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                    }
                    return Multi.createFrom().iterable(rows.subList(0, Math.min(rows.size(), pageSize)))
                            .onItem().transformToUniAndConcatenate(row -> teamMessage((Team) row[0], (String) row[1]))
                            .collect().asList()
                            .map(found -> response.addAllTeams(found).build());
                })));
    }

    @Override
    public Uni<GetTeamResponse> getTeam(GetTeamRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        return tx(() -> membership(teamId, TeamRoles.GUEST, false).flatMap(m -> teamMessage(m.team(), m.role())))
                .map(team -> GetTeamResponse.newBuilder().setTeam(team).build());
    }

    @Override
    public Uni<UpdateTeamResponse> updateTeam(UpdateTeamRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true).flatMap(m -> {
            Team team = m.team();
            Uni<Void> slug = Uni.createFrom().voidItem();
            if (request.hasSlug() && !request.getSlug().equals(team.slug)) {
                slug = teams.findBySlug(request.getSlug()).flatMap(taken -> {
                    if (taken != null) {
                        return Uni.createFrom().failure(StatusExceptions.slugTaken(request.getSlug()));
                    }
                    team.slug = request.getSlug();
                    return Uni.createFrom().voidItem();
                });
            }
            if (request.hasName()) {
                team.name = request.getName();
            }
            if (request.hasDefaultDocumentRole()) {
                team.defaultDocumentRole = TeamMessages.defaultDocumentRole(request.getDefaultDocumentRole());
            }
            if (request.hasHistoryRetentionDays()) {
                team.historyRetentionDays = request.getHistoryRetentionDays();
            }
            return slug.chain(() -> teamMessage(team, m.role())).map(message -> new Acted<>(message, m.principal()));
        }))
                .call(acted -> request.hasDefaultDocumentRole() ? notices.team(teamId, null, acted.actor())
                        : Uni.createFrom().voidItem())
                .map(acted -> UpdateTeamResponse.newBuilder().setTeam(acted.value()).build());
    }

    @Override
    public Uni<DeleteTeamResponse> deleteTeam(DeleteTeamRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        return tx(() -> membership(teamId, TeamRoles.OWNER, true).flatMap(m -> {
            Instant now = Instant.now();
            m.team().deletedAt = now;
            return documents.update("trashedAt = ?1, updatedAt = ?1 where teamId = ?2 and trashedAt is null", now, teamId)
                    .chain(() -> teamMembers.delete("id.teamId = ?1 and role <> ?2", teamId, TeamRoles.OWNER))
                    .chain(() -> invites.delete("teamId = ?1 and acceptedAt is null", teamId))
                    .chain(() -> teamMessage(m.team(), m.role()))
                    .map(message -> new Acted<>(message, m.principal()));
        }))
                .call(acted -> notices.team(teamId, null, acted.actor()))
                .map(acted -> DeleteTeamResponse.newBuilder().setTeam(acted.value()).build());
    }

    @Override
    public Uni<TransferOwnershipResponse> transferOwnership(TransferOwnershipRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        UUID target = UUID.fromString(request.getAccountId());
        return tx(() -> membership(teamId, TeamRoles.OWNER, true).flatMap(m -> {
            if (target.equals(m.principal().accountId())) {
                return teamMessage(m.team(), m.role());
            }
            return teamMembers.findById(new TeamMemberId(teamId, target)).flatMap(member -> {
                if (member == null) {
                    return Uni.createFrom().failure(StatusExceptions.memberNotFound());
                }
                if (TeamRoles.GUEST.equals(member.role)) {
                    return Uni.createFrom().failure(StatusExceptions.teamRoleInvalid("a guest cannot own the team"));
                }
                m.team().ownerAccountId = target;
                // Demote first: the one-owner index sees the two updates in this order.
                return teamMembers.setRole(teamId, m.principal().accountId(), TeamRoles.ADMIN)
                        .chain(() -> teamMembers.setRole(teamId, target, TeamRoles.OWNER))
                        .chain(() -> teamMessage(m.team(), TeamRoles.ADMIN));
            });
        })).map(team -> TransferOwnershipResponse.newBuilder().setTeam(team).build());
    }

    // --------------------------------------------------------------------------------- members

    @Override
    public Uni<ListMembersResponse> listMembers(ListMembersRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> membership(teamId, TeamRoles.MEMBER, false).flatMap(m -> teams.getSession().chain(session -> session
                .createQuery("select m, a from TeamMember m, Account a where a.id = m.id.accountId and m.id.teamId = ?1"
                        + " order by case when m.role = 'owner' then 0 else 1 end, m.joinedAt, m.id.accountId",
                        Object[].class)
                .setParameter(1, teamId)
                .setFirstResult(offset)
                .setMaxResults(pageSize + 1)
                .getResultList())
                .map(rows -> {
                    ListMembersResponse.Builder response = ListMembersResponse.newBuilder();
                    if (rows.size() > pageSize) {
                        response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                    }
                    rows.subList(0, Math.min(rows.size(), pageSize)).forEach(row -> response.addMembers(
                            TeamMessages.member((TeamMember) row[0], (Account) row[1])));
                    return response.build();
                })));
    }

    @Override
    public Uni<SetMemberRoleResponse> setMemberRole(SetMemberRoleRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        UUID target = UUID.fromString(request.getAccountId());
        String role = TeamRoles.fromProto(request.getRole());
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true).flatMap(m -> teamMembers
                .findById(new TeamMemberId(teamId, target)).flatMap(member -> {
                    if (member == null) {
                        return Uni.createFrom().failure(StatusExceptions.memberNotFound());
                    }
                    if (TeamRoles.OWNER.equals(member.role)) {
                        return Uni.createFrom().failure(StatusExceptions.ownerMustTransfer());
                    }
                    boolean touchesAdmin = TeamRoles.ADMIN.equals(role) || TeamRoles.ADMIN.equals(member.role);
                    if (touchesAdmin && !m.isOwner()) {
                        return Uni.createFrom().failure(StatusExceptions.roleInsufficient(TeamRoles.OWNER, m.role()));
                    }
                    member.role = role;
                    return accounts.findById(target)
                            .map(account -> new Acted<>(TeamMessages.member(member, account), m.principal()));
                })))
                .call(acted -> notices.team(teamId, Set.of(target), acted.actor()))
                .map(acted -> SetMemberRoleResponse.newBuilder().setMember(acted.value()).build());
    }

    @Override
    public Uni<RemoveMemberResponse> removeMember(RemoveMemberRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        UUID target = UUID.fromString(request.getAccountId());
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true).flatMap(m -> teamMembers
                .findById(new TeamMemberId(teamId, target)).flatMap(member -> {
                    if (member == null) {
                        return Uni.createFrom().item(m.principal());
                    }
                    if (TeamRoles.OWNER.equals(member.role)) {
                        return Uni.createFrom().<Principal>failure(StatusExceptions.ownerMustTransfer());
                    }
                    if (TeamRoles.ADMIN.equals(member.role) && !m.isOwner()) {
                        return Uni.createFrom().<Principal>failure(StatusExceptions.roleInsufficient(TeamRoles.OWNER,
                                m.role()));
                    }
                    return endMembership(member).replaceWith(m.principal());
                })))
                .call(actor -> notices.team(teamId, Set.of(target), actor.accountId()))
                .replaceWith(RemoveMemberResponse.getDefaultInstance());
    }

    @Override
    public Uni<LeaveTeamResponse> leaveTeam(LeaveTeamRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        return tx(() -> membership(teamId, TeamRoles.GUEST, true).flatMap(m -> m.isOwner()
                ? Uni.createFrom().<Principal>failure(StatusExceptions.ownerMustTransfer())
                : endMembership(m.member()).replaceWith(m.principal())))
                .call(principal -> notices.team(teamId, Set.of(principal.accountId()), principal.accountId()))
                .replaceWith(LeaveTeamResponse.getDefaultInstance());
    }

    /**
     * Ends a membership and, with it, the account's named roles and link uses on the team's
     * documents: leaving a team removes access to its documents (docs/spec/security.adoc, Teams).
     */
    private Uni<Void> endMembership(TeamMember member) {
        UUID teamId = member.id.teamId();
        UUID accountId = member.id.accountId();
        return teamMembers.delete(member)
                .chain(() -> documentMembers.delete("id.accountId = ?1 and id.documentId in"
                        + " (select d.id from Document d where d.teamId = ?2)", accountId, teamId))
                .chain(() -> shareLinkUses.delete("id.accountId = ?1 and id.shareLinkId in"
                        + " (select l.id from ShareLink l, Document d where l.documentId = d.id and d.teamId = ?2)",
                        accountId, teamId))
                .replaceWithVoid();
    }

    // ------------------------------------------------------------------------------ invitations

    /** An invitation written in the transaction, and what its mail needs once the transaction commits. */
    record SentInvite(TeamInvite invite, String token, String teamName, String inviterName) {
    }

    @Override
    public Uni<InviteMemberResponse> inviteMember(InviteMemberRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        String email = request.getEmail().toLowerCase(Locale.ROOT);
        String role = TeamRoles.fromProto(request.getRole());
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true).flatMap(m -> {
            if (TeamRoles.ADMIN.equals(role) && !m.isOwner()) {
                return Uni.createFrom().failure(StatusExceptions.roleInsufficient(TeamRoles.OWNER, m.role()));
            }
            return teamMembers.getSession().chain(session -> session.createQuery("select count(m) from TeamMember m,"
                    + " Account a where a.id = m.id.accountId and m.id.teamId = ?1 and (lower(a.email) = ?2 or exists"
                    + " (select i from AccountIdentity i where i.accountId = a.id and lower(i.email) = ?2))", Long.class)
                    .setParameter(1, teamId)
                    .setParameter(2, email)
                    .getSingleResult()).flatMap(members -> {
                        if (members > 0) {
                            return Uni.createFrom().failure(StatusExceptions.alreadyMember());
                        }
                        String token = token(TOKEN_BYTES);
                        TeamInvite invite = new TeamInvite();
                        invite.id = UUID.randomUUID();
                        invite.teamId = teamId;
                        invite.email = email;
                        invite.role = role;
                        invite.tokenHash = DocumentRoles.tokenHash(token);
                        invite.invitedByAccountId = m.principal().accountId();
                        invite.expiresAt = invite.createdAt.plus(INVITE_LIFETIME);
                        return invites.deletePendingFor(teamId, email)
                                .chain(() -> invites.persist(invite))
                                .chain(() -> accounts.findById(m.principal().accountId()))
                                .map(inviter -> new SentInvite(invite, token, m.team().name, inviter.displayName));
                    });
        }))
                .call(sent -> mailer.send(sent.invite().email, sent.teamName(), sent.inviterName(), sent.invite().role,
                        sent.token(), sent.invite().expiresAt))
                .map(sent -> InviteMemberResponse.newBuilder().setInvite(TeamMessages.invite(sent.invite())).build());
    }

    @Override
    public Uni<ListInvitesResponse> listInvites(ListInvitesRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true).flatMap(m -> invites.listPending(teamId, Instant.now())))
                .map(pending -> {
                    ListInvitesResponse.Builder response = ListInvitesResponse.newBuilder();
                    int end = Math.min(pending.size(), offset + pageSize);
                    if (end < pending.size()) {
                        response.setNextCursor(Cursors.encode(Integer.toString(end)));
                    }
                    pending.subList(Math.min(offset, end), end).forEach(i -> response.addInvites(TeamMessages.invite(i)));
                    return response.build();
                });
    }

    @Override
    public Uni<RevokeInviteResponse> revokeInvite(RevokeInviteRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        UUID inviteId = UUID.fromString(request.getInviteId());
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true)
                .chain(() -> invites.delete("id = ?1 and teamId = ?2 and acceptedAt is null", inviteId, teamId)))
                .replaceWith(RevokeInviteResponse.getDefaultInstance());
    }

    @Override
    public Uni<AcceptInviteResponse> acceptInvite(AcceptInviteRequest request) {
        String hash = DocumentRoles.tokenHash(request.getToken());
        Instant now = Instant.now();
        return tx(() -> guard.authenticated().flatMap(principal -> invites.findByTokenHash(hash).flatMap(invite -> {
            if (invite == null || invite.acceptedAt != null || !invite.expiresAt.isAfter(now)) {
                return Uni.createFrom().failure(StatusExceptions.inviteInvalid());
            }
            return teams.findById(invite.teamId).flatMap(team -> team.deletedAt != null
                    ? Uni.createFrom().<Acted<com.villagecompute.wiretuner.account.v1.Team>>failure(
                            StatusExceptions.inviteInvalid())
                    : accept(principal, invite, team, now).map(message -> new Acted<>(message, principal)));
        })))
                .call(acted -> notices.team(UUID.fromString(acted.value().getId()), Set.of(acted.actor()),
                        acted.actor()))
                .map(acted -> AcceptInviteResponse.newBuilder().setTeam(acted.value()).build());
    }

    private Uni<com.villagecompute.wiretuner.account.v1.Team> accept(Principal principal, TeamInvite invite, Team team,
            Instant now) {
        return identities.count("accountId = ?1 and lower(email) = ?2 and emailVerified = true", principal.accountId(),
                invite.email).flatMap(verified -> {
                    if (verified == 0) {
                        return Uni.createFrom().failure(StatusExceptions.emailNotVerified());
                    }
                    return workspaces.findById(team.id);
                }).flatMap(workspace -> {
                    if (workspace != null && workspace.requireSso
                            && !(AuthMethods.SSO_PREFIX + workspace.ssoIdpAlias).equals(principal.authMethod())) {
                        return Uni.createFrom().failure(StatusExceptions.ssoRequired(workspace.ssoIdpAlias));
                    }
                    invite.acceptedAt = now;
                    return teamMembers.findById(new TeamMemberId(team.id, principal.accountId()));
                }).flatMap(existing -> {
                    if (existing != null) {
                        return teamMessage(team, existing.role);
                    }
                    TeamMember member = new TeamMember();
                    member.id = new TeamMemberId(team.id, principal.accountId());
                    member.role = invite.role;
                    return teamMembers.persist(member).chain(() -> teamMessage(team, member.role));
                });
    }

    // ------------------------------------------------------------------------------- workspace

    @Override
    public Uni<AddWorkspaceDomainResponse> addWorkspaceDomain(AddWorkspaceDomainRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        String name = request.getDomain().toLowerCase(Locale.ROOT);
        WorkspaceDomainId id = new WorkspaceDomainId(teamId, name);
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true)
                .chain(() -> domains.findVerified(name))
                .flatMap(verified -> verified != null && !verified.id.teamId().equals(teamId)
                        ? Uni.createFrom().<WorkspaceDomain>failure(StatusExceptions.domainTaken(name))
                        : domains.findById(id))
                .flatMap(existing -> existing != null ? Uni.createFrom().item(existing)
                        : ensureWorkspace(teamId).chain(() -> {
                            WorkspaceDomain domain = new WorkspaceDomain();
                            domain.id = id;
                            domain.verificationToken = HexFormat.of().formatHex(bytes(DOMAIN_TOKEN_BYTES));
                            return domains.persist(domain);
                        })))
                .map(domain -> AddWorkspaceDomainResponse.newBuilder().setDomain(TeamMessages.domain(domain)).build());
    }

    @Override
    public Uni<VerifyWorkspaceDomainResponse> verifyWorkspaceDomain(VerifyWorkspaceDomainRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        String name = request.getDomain().toLowerCase(Locale.ROOT);
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true)
                .chain(() -> domains.findById(new WorkspaceDomainId(teamId, name)))
                .flatMap(domain -> {
                    if (domain == null) {
                        return Uni.createFrom().failure(StatusExceptions.domainNotFound(name));
                    }
                    if (domain.verifiedAt != null) {
                        return Uni.createFrom().item(domain);
                    }
                    return domains.findVerified(name).flatMap(other -> other != null
                            ? Uni.createFrom().failure(StatusExceptions.domainTaken(name))
                            : verifier.verify(name, domain.verificationToken).map(found -> {
                                if (found) {
                                    domain.verifiedAt = Instant.now();
                                }
                                return domain;
                            }));
                }))
                .map(domain -> VerifyWorkspaceDomainResponse.newBuilder()
                        .setVerified(domain.verifiedAt != null)
                        .setDomain(TeamMessages.domain(domain))
                        .build());
    }

    @Override
    public Uni<RemoveWorkspaceDomainResponse> removeWorkspaceDomain(RemoveWorkspaceDomainRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        String name = request.getDomain().toLowerCase(Locale.ROOT);
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true)
                .chain(() -> domains.delete("id.teamId = ?1 and id.domain = ?2", teamId, name)))
                .replaceWith(RemoveWorkspaceDomainResponse.getDefaultInstance());
    }

    @Override
    public Uni<SetWorkspaceSettingsResponse> setWorkspaceSettings(SetWorkspaceSettingsRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        WorkspaceSettings settings = request.getSettings();
        return tx(() -> membership(teamId, TeamRoles.ADMIN, true)
                .chain(() -> domains.listForTeam(teamId))
                .flatMap(claimed -> {
                    boolean anyVerified = claimed.stream().anyMatch(d -> d.verifiedAt != null);
                    if ((settings.getRequireSso() || settings.getAutoAdmit()) && !anyVerified) {
                        return Uni.createFrom().failure(StatusExceptions.domainUnverified());
                    }
                    return ensureWorkspace(teamId).map(workspace -> {
                        workspace.ssoIdpAlias = settings.getSsoIdpAlias().isEmpty() ? null : settings.getSsoIdpAlias();
                        workspace.requireSso = settings.getRequireSso();
                        workspace.autoAdmit = settings.getAutoAdmit();
                        workspace.restrictSharing = settings.getRestrictSharing();
                        workspace.restrictPackageExport = settings.getRestrictPackageExport();
                        return TeamMessages.workspace(workspace, claimed);
                    });
                }))
                .map(workspace -> SetWorkspaceSettingsResponse.newBuilder().setWorkspace(workspace).build());
    }

    private Uni<Workspace> ensureWorkspace(UUID teamId) {
        return workspaces.findById(teamId).flatMap(existing -> {
            if (existing != null) {
                return Uni.createFrom().item(existing);
            }
            Workspace workspace = new Workspace();
            workspace.teamId = teamId;
            return workspaces.persist(workspace);
        });
    }

    // --------------------------------------------------------------------------------- helpers

    /**
     * The caller's membership of the team at {@code minimum} or above. Not a member is
     * {@code TEAM_NOT_FOUND}; so is a deleted team when {@code live} is required.
     */
    private Uni<Membership> membership(UUID teamId, String minimum, boolean live) {
        return guard.authenticated().flatMap(principal -> teamMembers.findById(new TeamMemberId(teamId, principal.accountId()))
                .flatMap(member -> member == null
                        ? Uni.createFrom().<Membership>failure(StatusExceptions.teamNotFound())
                        : teams.findById(teamId).flatMap(team -> {
                            if (live && team.deletedAt != null) {
                                return Uni.createFrom().failure(StatusExceptions.teamNotFound());
                            }
                            if (!TeamRoles.atLeast(member.role, minimum)) {
                                return Uni.createFrom().failure(StatusExceptions.roleInsufficient(minimum, member.role));
                            }
                            return Uni.createFrom().item(new Membership(principal, team, member));
                        })));
    }

    /** The team as a member with {@code callerRole} sees it: member count and workspace included. */
    private Uni<com.villagecompute.wiretuner.account.v1.Team> teamMessage(Team team, String callerRole) {
        return teams.flush()
                .chain(() -> teamMembers.countForTeam(team.id))
                .flatMap(count -> workspaces.findById(team.id).flatMap(workspace -> workspace == null
                        ? Uni.createFrom().item(TeamMessages.team(team, callerRole, count, null, List.of()))
                        : domains.listForTeam(team.id)
                                .map(claimed -> TeamMessages.team(team, callerRole, count, workspace, claimed))));
    }

    static String token(int bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes(bytes));
    }

    static byte[] bytes(int count) {
        byte[] bytes = new byte[count];
        RANDOM.nextBytes(bytes);
        return bytes;
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
