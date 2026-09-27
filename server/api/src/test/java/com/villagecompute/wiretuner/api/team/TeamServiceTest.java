package com.villagecompute.wiretuner.api.team;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AcceptInviteRequest;
import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.AddWorkspaceDomainRequest;
import com.villagecompute.wiretuner.account.v1.CreateTeamRequest;
import com.villagecompute.wiretuner.account.v1.DeleteTeamRequest;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.account.v1.GetTeamRequest;
import com.villagecompute.wiretuner.account.v1.InviteMemberRequest;
import com.villagecompute.wiretuner.account.v1.LeaveTeamRequest;
import com.villagecompute.wiretuner.account.v1.ListInvitesRequest;
import com.villagecompute.wiretuner.account.v1.ListInvitesResponse;
import com.villagecompute.wiretuner.account.v1.ListMembersRequest;
import com.villagecompute.wiretuner.account.v1.ListMembersResponse;
import com.villagecompute.wiretuner.account.v1.ListTeamsRequest;
import com.villagecompute.wiretuner.account.v1.ListTeamsResponse;
import com.villagecompute.wiretuner.account.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.account.v1.RemoveWorkspaceDomainRequest;
import com.villagecompute.wiretuner.account.v1.RevokeInviteRequest;
import com.villagecompute.wiretuner.account.v1.SetMemberRoleRequest;
import com.villagecompute.wiretuner.account.v1.SetWorkspaceSettingsRequest;
import com.villagecompute.wiretuner.account.v1.Team;
import com.villagecompute.wiretuner.account.v1.TeamInvite;
import com.villagecompute.wiretuner.account.v1.TeamMember;
import com.villagecompute.wiretuner.account.v1.TeamRole;
import com.villagecompute.wiretuner.account.v1.TeamServiceGrpc;
import com.villagecompute.wiretuner.account.v1.TransferOwnershipRequest;
import com.villagecompute.wiretuner.account.v1.UpdateTeamRequest;
import com.villagecompute.wiretuner.account.v1.VerifyWorkspaceDomainRequest;
import com.villagecompute.wiretuner.account.v1.VerifyWorkspaceDomainResponse;
import com.villagecompute.wiretuner.account.v1.WorkspaceDomain;
import com.villagecompute.wiretuner.account.v1.WorkspaceSettings;
import com.villagecompute.wiretuner.api.DnsStub;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.Document;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.ListRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.mailer.Mail;
import io.quarkus.mailer.MockMailbox;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SEC-001: TeamService per RPC and team role, invitations through the mock mailbox, workspace
 * domains through the DNS stub, and team membership as the document role source.
 */
@QuarkusTest
class TeamServiceTest extends ServiceTestSupport {

    static final Pattern TOKEN = Pattern.compile("/invite/([A-Za-z0-9_-]+)");

    @GrpcClient("team")
    TeamServiceGrpc.TeamServiceBlockingStub teams;

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @Inject
    MockMailbox mailbox;

    @Inject
    RoleGuard guard;

    UUID alice;
    UUID bob;
    UUID carol;
    UUID dave;
    UUID erin;

    @BeforeEach
    void setUp() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        carol = TestUsers.accountId(account, CAROL);
        dave = TestUsers.accountId(account, DAVE);
        erin = TestUsers.accountId(account, ERIN);
        mailbox.clear();
    }

    TeamServiceGrpc.TeamServiceBlockingStub by(String user) {
        return as(teams, user);
    }

    /** A team alice owns, with bob as admin, carol as member and dave as guest. */
    UUID crew() {
        Team team = by(ALICE).createTeam(CreateTeamRequest.newBuilder().setName("Crew " + UUID.randomUUID()).build())
                .getTeam();
        UUID id = UUID.fromString(team.getId());
        teamMember(id, bob, "admin");
        teamMember(id, carol, "member");
        teamMember(id, dave, "guest");
        return id;
    }

    static String unique() {
        return UUID.randomUUID().toString().substring(0, 8);
    }

    // ----------------------------------------------------------------------------------- Teams

    @Test
    void createTeamDerivesAUniqueSlugAndMakesTheCallerOwner() {
        String name = "Élan Studio " + unique();
        Team team = by(ALICE).createTeam(CreateTeamRequest.newBuilder().setName(name).build()).getTeam();
        assertThat(team.getSlug()).isEqualTo(Slugs.derive(name)).startsWith("elan-studio-");
        assertThat(team.getOwnerAccountId()).isEqualTo(alice.toString());
        assertThat(team.getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_OWNER);
        assertThat(team.getMemberCount()).isEqualTo(1);
        assertThat(team.getDefaultDocumentRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_EDITOR);
        assertThat(team.hasWorkspace()).isFalse();
        assertThat(team.hasDeletedAt()).isFalse();

        // The same name again: the derived slug gets a suffix.
        Team twin = by(BOB).createTeam(CreateTeamRequest.newBuilder().setName(name)
                .setDefaultDocumentRole(DocumentRole.DOCUMENT_ROLE_VIEWER).build()).getTeam();
        assertThat(twin.getSlug()).startsWith(team.getSlug() + "-").hasSize(team.getSlug().length() + 7);
        assertThat(twin.getDefaultDocumentRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);

        // An explicit slug must be free.
        assertFails(() -> by(BOB).createTeam(CreateTeamRequest.newBuilder().setName("Other").setSlug(team.getSlug())
                .build()), Status.Code.ALREADY_EXISTS, "SLUG_TAKEN");
        String slug = "explicit-" + unique();
        assertThat(by(BOB).createTeam(CreateTeamRequest.newBuilder().setName("Other").setSlug(slug)
                .setDefaultDocumentRole(DocumentRole.DOCUMENT_ROLE_COMMENTER).build()).getTeam().getSlug()).isEqualTo(slug);
    }

    @Test
    void listTeamsShowsEachMembershipWithTheCallersRole() {
        UUID one = crew();
        UUID two = crew();
        UUID three = team(erin, "editor");
        teamMember(three, carol, "admin");

        // Other tests leave Carol in many teams, so every page is read.
        assertThat(allTeams(CAROL)).filteredOn(t -> List.of(one.toString(), two.toString(), three.toString())
                .contains(t.getId())).extracting(Team::getCallerRole)
                .containsExactlyInAnyOrder(TeamRole.TEAM_ROLE_MEMBER, TeamRole.TEAM_ROLE_MEMBER, TeamRole.TEAM_ROLE_ADMIN);

        ListTeamsResponse page = by(CAROL).listTeams(ListTeamsRequest.newBuilder().setPageSize(1).build());
        assertThat(page.getTeamsList()).hasSize(1);
        ListTeamsResponse next = by(CAROL).listTeams(ListTeamsRequest.newBuilder().setPageSize(1)
                .setCursor(page.getNextCursor()).build());
        assertThat(next.getTeams(0).getId()).isNotEqualTo(page.getTeams(0).getId());

        // Guests see the teams they are guests of.
        assertThat(allTeams(DAVE)).extracting(Team::getId).contains(one.toString(), two.toString());
        assertFails(() -> by(CAROL).listTeams(ListTeamsRequest.newBuilder().setCursor("bad!").build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
        String negative = com.villagecompute.wiretuner.api.grpc.Cursors.encode("-5");
        assertFails(() -> by(CAROL).listTeams(ListTeamsRequest.newBuilder().setCursor(negative).build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
        String word = com.villagecompute.wiretuner.api.grpc.Cursors.encode("five");
        assertFails(() -> by(CAROL).listTeams(ListTeamsRequest.newBuilder().setCursor(word).build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    /** Every team `user` is on, read a page of 50 at a time until the cursor runs out. */
    List<Team> allTeams(String user) {
        List<Team> found = new java.util.ArrayList<>();
        String cursor = "";
        do {
            ListTeamsResponse page = by(user).listTeams(ListTeamsRequest.newBuilder().setPageSize(50).setCursor(cursor).build());
            found.addAll(page.getTeamsList());
            cursor = page.getNextCursor();
        } while (!cursor.isEmpty());
        return found;
    }

    @Test
    void getTeamIsForMembersOnly() {
        UUID team = crew();
        GetTeamRequest get = GetTeamRequest.newBuilder().setTeamId(team.toString()).build();
        Team seen = by(DAVE).getTeam(get).getTeam();
        assertThat(seen.getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_GUEST);
        assertThat(seen.getMemberCount()).isEqualTo(4);
        assertFails(() -> by(ERIN).getTeam(get), Status.Code.NOT_FOUND, "TEAM_NOT_FOUND");
    }

    @Test
    void updateTeamNeedsAnAdmin() {
        UUID team = crew();
        String slug = "renamed-" + unique();
        UpdateTeamRequest update = UpdateTeamRequest.newBuilder().setTeamId(team.toString()).setName("Renamed")
                .setSlug(slug).setDefaultDocumentRole(DocumentRole.DOCUMENT_ROLE_COMMENTER).build();
        assertFails(() -> by(CAROL).updateTeam(update), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        Team updated = by(BOB).updateTeam(update).getTeam();
        assertThat(updated.getName()).isEqualTo("Renamed");
        assertThat(updated.getSlug()).isEqualTo(slug);
        assertThat(updated.getDefaultDocumentRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_COMMENTER);
        assertThat(updated.getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_ADMIN);

        // Same slug again is no change; nothing present changes nothing; a taken slug is refused.
        assertThat(by(BOB).updateTeam(UpdateTeamRequest.newBuilder().setTeamId(team.toString()).setSlug(slug).build())
                .getTeam().getSlug()).isEqualTo(slug);
        assertThat(by(BOB).updateTeam(UpdateTeamRequest.newBuilder().setTeamId(team.toString()).build()).getTeam()
                .getName()).isEqualTo("Renamed");
        UUID other = crew();
        String otherSlug = by(ALICE).getTeam(GetTeamRequest.newBuilder().setTeamId(other.toString()).build()).getTeam()
                .getSlug();
        assertFails(() -> by(BOB).updateTeam(UpdateTeamRequest.newBuilder().setTeamId(team.toString()).setSlug(otherSlug)
                .build()), Status.Code.ALREADY_EXISTS, "SLUG_TAKEN");
    }

    @Test
    void anAdminLengthensTheHistoryWindow() {
        UUID team = crew();
        GetTeamRequest get = GetTeamRequest.newBuilder().setTeamId(team.toString()).build();
        // Unset: the default window, 0 on the wire and null in the column.
        assertThat(by(CAROL).getTeam(get).getTeam().getHistoryRetentionDays()).isZero();
        UpdateTeamRequest.Builder update = UpdateTeamRequest.newBuilder().setTeamId(team.toString());
        assertFails(() -> by(CAROL).updateTeam(update.setHistoryRetentionDays(90).build()), Status.Code.PERMISSION_DENIED,
                "ROLE_INSUFFICIENT");
        assertThat(value("SELECT history_retention_days FROM team WHERE id = ?", team)).isNull();

        assertThat(by(BOB).updateTeam(update.setHistoryRetentionDays(90).build()).getTeam().getHistoryRetentionDays())
                .isEqualTo(90);
        assertThat(count("SELECT history_retention_days FROM team WHERE id = ?", team)).isEqualTo(90);
        assertThat(by(CAROL).getTeam(get).getTeam().getHistoryRetentionDays()).isEqualTo(90);
        // Other updates leave it; a window under 30 days or over ten years is refused.
        assertThat(by(BOB).updateTeam(UpdateTeamRequest.newBuilder().setTeamId(team.toString()).setName("Kept").build())
                .getTeam().getHistoryRetentionDays()).isEqualTo(90);
        assertFails(() -> by(BOB).updateTeam(update.setHistoryRetentionDays(29).build()), Status.Code.INVALID_ARGUMENT,
                "VALIDATION_FAILED");
        assertFails(() -> by(BOB).updateTeam(update.setHistoryRetentionDays(3651).build()), Status.Code.INVALID_ARGUMENT,
                "VALIDATION_FAILED");
        assertThat(by(ALICE).updateTeam(update.setHistoryRetentionDays(30).build()).getTeam().getHistoryRetentionDays())
                .isEqualTo(30);
    }

    @Test
    void deleteTeamTrashesItsDocumentsAndEndsMemberships() {
        UUID team = crew();
        Document doc = as(docs, CAROL).create(CreateRequest.newBuilder().setDocumentId(uuid7().toString())
                .setSpaceId(team.toString()).setName("Team work").build()).getDocument();
        by(ALICE).inviteMember(InviteMemberRequest.newBuilder().setTeamId(team.toString()).setEmail("x" + unique()
                + "@wiretuner.local").setRole(TeamRole.TEAM_ROLE_MEMBER).build());
        DeleteTeamRequest delete = DeleteTeamRequest.newBuilder().setTeamId(team.toString()).build();
        assertFails(() -> by(BOB).deleteTeam(delete), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        Team deleted = by(ALICE).deleteTeam(delete).getTeam();
        assertThat(deleted.hasDeletedAt()).isTrue();
        assertThat(deleted.getMemberCount()).isEqualTo(1);
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", UUID.fromString(doc.getId()))).isNotNull();
        assertThat(count("SELECT count(*) FROM team_invite WHERE team_id = ?", team)).isZero();

        // The owner still sees it (to transfer documents out); nobody can change it; members are gone.
        GetTeamRequest get = GetTeamRequest.newBuilder().setTeamId(team.toString()).build();
        assertThat(by(ALICE).getTeam(get).getTeam().hasDeletedAt()).isTrue();
        assertFails(() -> by(CAROL).getTeam(get), Status.Code.NOT_FOUND, "TEAM_NOT_FOUND");
        assertFails(() -> by(ALICE).deleteTeam(delete), Status.Code.NOT_FOUND, "TEAM_NOT_FOUND");
        assertThat(as(docs, ALICE).get(GetRequest.newBuilder().setDocumentId(doc.getId()).build()).getDocument()
                .getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
    }

    @Test
    void transferOwnershipMakesTheCallerAnAdmin() {
        UUID team = crew();
        TransferOwnershipRequest.Builder transfer = TransferOwnershipRequest.newBuilder().setTeamId(team.toString());
        assertFails(() -> by(BOB).transferOwnership(transfer.setAccountId(carol.toString()).build()),
                Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> by(ALICE).transferOwnership(transfer.setAccountId(dave.toString()).build()),
                Status.Code.FAILED_PRECONDITION, "TEAM_ROLE_INVALID");
        assertFails(() -> by(ALICE).transferOwnership(transfer.setAccountId(erin.toString()).build()),
                Status.Code.NOT_FOUND, "MEMBER_NOT_FOUND");
        assertThat(by(ALICE).transferOwnership(transfer.setAccountId(alice.toString()).build()).getTeam()
                .getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_OWNER);

        Team moved = by(ALICE).transferOwnership(transfer.setAccountId(carol.toString()).build()).getTeam();
        assertThat(moved.getOwnerAccountId()).isEqualTo(carol.toString());
        assertThat(moved.getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_ADMIN);
        assertThat(value("SELECT role FROM team_member WHERE team_id = ? AND account_id = ?", team, carol))
                .isEqualTo("owner");
    }

    // --------------------------------------------------------------------------------- Members

    @Test
    void membersAreListedOwnerFirstAndNeverToGuests() {
        UUID team = crew();
        ListMembersRequest request = ListMembersRequest.newBuilder().setTeamId(team.toString()).build();
        ListMembersResponse members = by(CAROL).listMembers(request);
        assertThat(members.getMembersList()).extracting(TeamMember::getAccountId)
                .containsExactly(alice.toString(), bob.toString(), carol.toString(), dave.toString());
        assertThat(members.getMembers(0).getRole()).isEqualTo(TeamRole.TEAM_ROLE_OWNER);
        assertThat(members.getMembers(0).getEmail()).isEqualTo(TestUsers.email(ALICE));

        ListMembersResponse page = by(CAROL).listMembers(request.toBuilder().setPageSize(3).build());
        assertThat(page.getMembersList()).hasSize(3);
        assertThat(by(CAROL).listMembers(request.toBuilder().setPageSize(3).setCursor(page.getNextCursor()).build())
                .getMembersList()).extracting(TeamMember::getRole).containsExactly(TeamRole.TEAM_ROLE_GUEST);

        // A guest cannot list the team; a stranger cannot see it at all.
        assertFails(() -> by(DAVE).listMembers(request), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> by(ERIN).listMembers(request), Status.Code.NOT_FOUND, "TEAM_NOT_FOUND");
    }

    @Test
    void setMemberRoleAdminChangesAreTheOwners() {
        UUID team = crew();
        SetMemberRoleRequest.Builder set = SetMemberRoleRequest.newBuilder().setTeamId(team.toString());

        TeamMember demoted = by(BOB).setMemberRole(set.setAccountId(carol.toString()).setRole(TeamRole.TEAM_ROLE_GUEST)
                .build()).getMember();
        assertThat(demoted.getRole()).isEqualTo(TeamRole.TEAM_ROLE_GUEST);
        assertThat(demoted.getDisplayName()).isNotEmpty();
        assertFails(() -> by(BOB).setMemberRole(set.setAccountId(carol.toString()).setRole(TeamRole.TEAM_ROLE_ADMIN)
                .build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> by(CAROL).setMemberRole(set.setAccountId(dave.toString()).setRole(TeamRole.TEAM_ROLE_MEMBER)
                .build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertThat(by(ALICE).setMemberRole(set.setAccountId(carol.toString()).setRole(TeamRole.TEAM_ROLE_ADMIN).build())
                .getMember().getRole()).isEqualTo(TeamRole.TEAM_ROLE_ADMIN);
        // Another admin may not demote an admin.
        assertFails(() -> by(BOB).setMemberRole(set.setAccountId(carol.toString()).setRole(TeamRole.TEAM_ROLE_MEMBER)
                .build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> by(ALICE).setMemberRole(set.setAccountId(alice.toString()).setRole(TeamRole.TEAM_ROLE_ADMIN)
                .build()), Status.Code.FAILED_PRECONDITION, "OWNER_MUST_TRANSFER");
        assertFails(() -> by(ALICE).setMemberRole(set.setAccountId(erin.toString()).setRole(TeamRole.TEAM_ROLE_MEMBER)
                .build()), Status.Code.NOT_FOUND, "MEMBER_NOT_FOUND");
    }

    @Test
    void aRemovedMembersNextChangeIsRejectedAndTheirSharesGo() {
        UUID team = crew();
        teamMember(team, erin, "member");
        Document doc = as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(uuid7().toString())
                .setSpaceId(team.toString()).setName("Shared plan").build()).getDocument();
        UUID docId = UUID.fromString(doc.getId());
        share(docId, erin, "editor");
        Principal erinSession = new Principal(erin, "erin", null, "password", null, "req");
        assertThat(tx(() -> guard.require(erinSession, docId, Role.EDITOR)).role()).isEqualTo(Role.EDITOR);

        RemoveMemberRequest remove = RemoveMemberRequest.newBuilder().setTeamId(team.toString())
                .setAccountId(erin.toString()).build();
        assertFails(() -> by(CAROL).removeMember(remove), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        by(BOB).removeMember(remove);
        by(BOB).removeMember(remove);

        // The next change from erin's session fails the role check the ingest path runs.
        assertFails(() -> tx(() -> guard.require(erinSession, docId, Role.EDITOR)), Status.Code.NOT_FOUND,
                "DOCUMENT_NOT_FOUND");
        assertThat(count("SELECT count(*) FROM document_member WHERE account_id = ? AND document_id = ?", erin, docId))
                .isZero();
        assertFails(() -> as(docs, ERIN).get(GetRequest.newBuilder().setDocumentId(doc.getId()).build()),
                Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");

        // The owner cannot be removed; only the owner removes an admin.
        assertFails(() -> by(BOB).removeMember(remove.toBuilder().setAccountId(alice.toString()).build()),
                Status.Code.FAILED_PRECONDITION, "OWNER_MUST_TRANSFER");
        teamMember(team, erin, "admin");
        assertFails(() -> by(BOB).removeMember(remove), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        by(ALICE).removeMember(remove);
        assertThat(count("SELECT count(*) FROM team_member WHERE team_id = ? AND account_id = ?", team, erin)).isZero();
    }

    @Test
    void leavingEndsTheMembershipExceptForTheOwner() {
        UUID team = crew();
        LeaveTeamRequest leave = LeaveTeamRequest.newBuilder().setTeamId(team.toString()).build();
        assertFails(() -> by(ALICE).leaveTeam(leave), Status.Code.FAILED_PRECONDITION, "OWNER_MUST_TRANSFER");
        by(DAVE).leaveTeam(leave);
        assertFails(() -> by(DAVE).leaveTeam(leave), Status.Code.NOT_FOUND, "TEAM_NOT_FOUND");
        assertThat(by(ALICE).getTeam(GetTeamRequest.newBuilder().setTeamId(team.toString()).build()).getTeam()
                .getMemberCount()).isEqualTo(3);
    }

    // ----------------------------------------------------------------------------- Invitations

    String mailedToken(String email) {
        List<Mail> mails = mailbox.getMailsSentTo(email);
        assertThat(mails).isNotEmpty();
        Mail mail = mails.get(mails.size() - 1);
        Matcher matcher = TOKEN.matcher(mail.getText());
        assertThat(matcher.find()).as(mail.getText()).isTrue();
        return matcher.group(1);
    }

    @Test
    void anInvitationIsMailedAndAcceptedOnce() {
        UUID team = team(alice, "editor");
        TeamInvite invite = by(ALICE).inviteMember(InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setEmail(TestUsers.email(ERIN).toUpperCase()).setRole(TeamRole.TEAM_ROLE_MEMBER).build()).getInvite();
        assertThat(invite.getEmail()).isEqualTo(TestUsers.email(ERIN));
        assertThat(invite.getInvitedByAccountId()).isEqualTo(alice.toString());
        assertThat(invite.hasAcceptedAt()).isFalse();
        Mail mail = mailbox.getMailsSentTo(TestUsers.email(ERIN)).get(0);
        assertThat(mail.getSubject()).contains("invited you to");
        assertThat(mail.getHtml()).contains("/invite/");
        String token = mailedToken(TestUsers.email(ERIN));
        assertThat(value("SELECT token_hash FROM team_invite WHERE id = ?", UUID.fromString(invite.getId())))
                .isEqualTo(com.villagecompute.wiretuner.api.auth.DocumentRoles.tokenHash(token)).isNotEqualTo(token);

        ListInvitesResponse pending = by(ALICE).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString())
                .build());
        assertThat(pending.getInvitesList()).extracting(TeamInvite::getId).containsExactly(invite.getId());

        Team joined = by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(token).build()).getTeam();
        assertThat(joined.getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_MEMBER);
        assertThat(joined.getMemberCount()).isEqualTo(2);
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(token).build()),
                Status.Code.NOT_FOUND, "INVITE_INVALID");
        assertThat(by(ALICE).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString()).build())
                .getInvitesList()).isEmpty();

        // Erin is a member now: inviting her again is refused.
        assertFails(() -> by(ALICE).inviteMember(InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setEmail(TestUsers.email(ERIN)).setRole(TeamRole.TEAM_ROLE_GUEST).build()),
                Status.Code.ALREADY_EXISTS, "ALREADY_MEMBER");
    }

    @Test
    void invitationsAreForAdminsAndAdminInvitesForTheOwner() {
        UUID team = crew();
        InviteMemberRequest.Builder invite = InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setEmail("new" + unique() + "@wiretuner.local");
        assertFails(() -> by(CAROL).inviteMember(invite.setRole(TeamRole.TEAM_ROLE_MEMBER).build()),
                Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> by(BOB).inviteMember(invite.setRole(TeamRole.TEAM_ROLE_ADMIN).build()),
                Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertThat(by(ALICE).inviteMember(invite.setRole(TeamRole.TEAM_ROLE_ADMIN).build()).getInvite().getRole())
                .isEqualTo(TeamRole.TEAM_ROLE_ADMIN);
        // A re-invitation replaces the pending one.
        TeamInvite again = by(BOB).inviteMember(invite.setRole(TeamRole.TEAM_ROLE_GUEST).build()).getInvite();
        assertThat(by(BOB).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString()).build())
                .getInvitesList()).extracting(TeamInvite::getId).containsExactly(again.getId());
        assertFails(() -> by(CAROL).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString()).build()),
                Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        for (int i = 0; i < 2; i++) {
            by(BOB).inviteMember(invite.setEmail("more" + unique() + "@wiretuner.local").build());
        }
        ListInvitesResponse page = by(BOB).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString())
                .setPageSize(2).build());
        assertThat(page.getInvitesList()).hasSize(2);
        ListInvitesResponse rest = by(BOB).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString())
                .setPageSize(2).setCursor(page.getNextCursor()).build());
        assertThat(rest.getInvitesList()).hasSize(1);
        assertThat(rest.getNextCursor()).isEmpty();
        String beyond = com.villagecompute.wiretuner.api.grpc.Cursors.encode("99");
        assertThat(by(BOB).listInvites(ListInvitesRequest.newBuilder().setTeamId(team.toString()).setCursor(beyond)
                .build()).getInvitesList()).isEmpty();
    }

    @Test
    void aRevokedExpiredOrMisaddressedInvitationCannotBeAccepted() {
        UUID team = team(alice, "editor");
        InviteMemberRequest.Builder invite = InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setRole(TeamRole.TEAM_ROLE_MEMBER);

        TeamInvite revoked = by(ALICE).inviteMember(invite.setEmail(TestUsers.email(ERIN)).build()).getInvite();
        String revokedToken = mailedToken(TestUsers.email(ERIN));
        RevokeInviteRequest revoke = RevokeInviteRequest.newBuilder().setTeamId(team.toString())
                .setInviteId(revoked.getId()).build();
        by(ALICE).revokeInvite(revoke);
        by(ALICE).revokeInvite(revoke);
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(revokedToken).build()),
                Status.Code.NOT_FOUND, "INVITE_INVALID");

        TeamInvite expiring = by(ALICE).inviteMember(invite.setEmail(TestUsers.email(ERIN)).build()).getInvite();
        String expiredToken = mailedToken(TestUsers.email(ERIN));
        exec("UPDATE team_invite SET expires_at = now() - interval '1 minute' WHERE id = ?",
                UUID.fromString(expiring.getId()));
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(expiredToken).build()),
                Status.Code.NOT_FOUND, "INVITE_INVALID");

        String nobody = "nobody" + unique() + "@wiretuner.local";
        by(ALICE).inviteMember(invite.setEmail(nobody).build());
        String misaddressed = mailedToken(nobody);
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(misaddressed).build()),
                Status.Code.FAILED_PRECONDITION, "EMAIL_NOT_VERIFIED");
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken("never-issued-token-"
                + unique()).build()), Status.Code.NOT_FOUND, "INVITE_INVALID");

        by(ALICE).inviteMember(invite.setEmail(TestUsers.email(ERIN)).build());
        String orphaned = mailedToken(TestUsers.email(ERIN));
        exec("UPDATE team SET deleted_at = now() WHERE id = ?", team);
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(orphaned).build()),
                Status.Code.NOT_FOUND, "INVITE_INVALID");
    }

    @Test
    void acceptingWhenAlreadyAMemberKeepsTheRole() {
        UUID team = team(alice, "editor");
        by(ALICE).inviteMember(InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setEmail(TestUsers.email(ERIN)).setRole(TeamRole.TEAM_ROLE_GUEST).build());
        String token = mailedToken(TestUsers.email(ERIN));
        teamMember(team, erin, "admin");
        assertThat(by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(token).build()).getTeam()
                .getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_ADMIN);
    }

    // ------------------------------------------------------------------------------- Workspace

    @Test
    void aDomainIsClaimedVerifiedByTxtRecordAndHeldByOneTeam() {
        UUID team = crew();
        String domain = "d" + unique() + ".example";
        AddWorkspaceDomainRequest add = AddWorkspaceDomainRequest.newBuilder().setTeamId(team.toString())
                .setDomain(domain.toUpperCase()).build();
        assertFails(() -> by(CAROL).addWorkspaceDomain(add), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        WorkspaceDomain claimed = by(BOB).addWorkspaceDomain(add).getDomain();
        assertThat(claimed.getDomain()).isEqualTo(domain);
        assertThat(claimed.getVerificationToken()).hasSize(32);
        assertThat(claimed.hasVerifiedAt()).isFalse();
        assertThat(by(BOB).addWorkspaceDomain(add).getDomain().getVerificationToken())
                .isEqualTo(claimed.getVerificationToken());

        VerifyWorkspaceDomainRequest verify = VerifyWorkspaceDomainRequest.newBuilder().setTeamId(team.toString())
                .setDomain(domain).build();
        assertThat(by(BOB).verifyWorkspaceDomain(verify).getVerified()).isFalse();
        DnsStub.TXT.put(domain, List.of("v=spf1 -all"));
        assertThat(by(BOB).verifyWorkspaceDomain(verify).getVerified()).isFalse();

        // A second team claims the same domain while it is unverified.
        UUID rival = team(erin, "editor");
        WorkspaceDomain rivalClaim = as(teams, ERIN).addWorkspaceDomain(AddWorkspaceDomainRequest.newBuilder()
                .setTeamId(rival.toString()).setDomain(domain).build()).getDomain();

        DnsStub.TXT.put(domain, List.of("v=spf1 -all", DomainVerifier.record(claimed.getVerificationToken())));
        VerifyWorkspaceDomainResponse verified = by(BOB).verifyWorkspaceDomain(verify);
        assertThat(verified.getVerified()).isTrue();
        assertThat(verified.getDomain().hasVerifiedAt()).isTrue();
        assertThat(by(BOB).verifyWorkspaceDomain(verify).getVerified()).isTrue();

        // Now it is held: the rival can neither claim nor verify it.
        DnsStub.TXT.put(domain, List.of(DomainVerifier.record(rivalClaim.getVerificationToken())));
        assertFails(() -> as(teams, ERIN).verifyWorkspaceDomain(VerifyWorkspaceDomainRequest.newBuilder()
                .setTeamId(rival.toString()).setDomain(domain).build()), Status.Code.ALREADY_EXISTS, "DOMAIN_TAKEN");
        UUID third = team(erin, "editor");
        assertFails(() -> as(teams, ERIN).addWorkspaceDomain(AddWorkspaceDomainRequest.newBuilder()
                .setTeamId(third.toString()).setDomain(domain).build()), Status.Code.ALREADY_EXISTS, "DOMAIN_TAKEN");
        assertThat(by(BOB).addWorkspaceDomain(add).getDomain().hasVerifiedAt()).isTrue();

        assertFails(() -> by(BOB).verifyWorkspaceDomain(verify.toBuilder().setDomain("unclaimed.example").build()),
                Status.Code.NOT_FOUND, "DOMAIN_NOT_FOUND");

        RemoveWorkspaceDomainRequest remove = RemoveWorkspaceDomainRequest.newBuilder().setTeamId(team.toString())
                .setDomain(domain).build();
        assertFails(() -> by(CAROL).removeWorkspaceDomain(remove), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        by(BOB).removeWorkspaceDomain(remove);
        by(BOB).removeWorkspaceDomain(remove);
        assertThat(count("SELECT count(*) FROM workspace_domain WHERE team_id = ?", team)).isZero();
    }

    @Test
    void workspaceSettingsNeedAVerifiedDomainForSsoAndAutoAdmit() {
        UUID team = crew();
        WorkspaceSettings sso = WorkspaceSettings.newBuilder().setSsoIdpAlias("acme").setRequireSso(true)
                .setRestrictSharing(true).setRestrictPackageExport(true).build();
        SetWorkspaceSettingsRequest set = SetWorkspaceSettingsRequest.newBuilder().setTeamId(team.toString())
                .setSettings(sso).build();
        assertFails(() -> by(BOB).setWorkspaceSettings(set), Status.Code.FAILED_PRECONDITION, "DOMAIN_UNVERIFIED");
        assertFails(() -> by(BOB).setWorkspaceSettings(set.toBuilder().setSettings(WorkspaceSettings.newBuilder()
                .setAutoAdmit(true)).build()), Status.Code.FAILED_PRECONDITION, "DOMAIN_UNVERIFIED");
        assertFails(() -> by(CAROL).setWorkspaceSettings(set), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        // Restrictions alone need no domain.
        var plain = by(BOB).setWorkspaceSettings(SetWorkspaceSettingsRequest.newBuilder().setTeamId(team.toString())
                .setSettings(WorkspaceSettings.newBuilder().setRestrictSharing(true)).build()).getWorkspace();
        assertThat(plain.getSettings().getRestrictSharing()).isTrue();
        assertThat(plain.getSettings().getSsoIdpAlias()).isEmpty();

        String domain = "sso" + unique() + ".example";
        WorkspaceDomain claimed = by(BOB).addWorkspaceDomain(AddWorkspaceDomainRequest.newBuilder()
                .setTeamId(team.toString()).setDomain(domain).build()).getDomain();
        // Claimed is not enough.
        assertFails(() -> by(BOB).setWorkspaceSettings(set), Status.Code.FAILED_PRECONDITION, "DOMAIN_UNVERIFIED");
        DnsStub.TXT.put(domain, List.of(DomainVerifier.record(claimed.getVerificationToken())));
        by(BOB).verifyWorkspaceDomain(VerifyWorkspaceDomainRequest.newBuilder().setTeamId(team.toString())
                .setDomain(domain).build());

        var workspace = by(BOB).setWorkspaceSettings(set).getWorkspace();
        assertThat(workspace.getSettings()).isEqualTo(sso);
        assertThat(workspace.getDomainsList()).extracting(WorkspaceDomain::getDomain).containsExactly(domain);
        Team seen = by(CAROL).getTeam(GetTeamRequest.newBuilder().setTeamId(team.toString()).build()).getTeam();
        assertThat(seen.getWorkspace().getSettings().getRequireSso()).isTrue();

        // Require-SSO: a password session cannot accept an invitation into the workspace.
        by(ALICE).inviteMember(InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setEmail(TestUsers.email(ERIN)).setRole(TeamRole.TEAM_ROLE_MEMBER).build());
        String token = mailedToken(TestUsers.email(ERIN));
        assertFails(() -> by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(token).build()),
                Status.Code.FAILED_PRECONDITION, "SSO_REQUIRED");

        // A session signed in through the workspace's SSO connection may.
        assertThat(TestUsers.viaClient(teams, ERIN, TestUsers.SSO).acceptInvite(AcceptInviteRequest.newBuilder()
                .setToken(token).build()).getTeam().getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_MEMBER);

        // Without require-SSO a password session may accept too.
        by(BOB).setWorkspaceSettings(set.toBuilder().setSettings(sso.toBuilder().setRequireSso(false)).build());
        exec("DELETE FROM team_member WHERE team_id = ? AND account_id = ?", team, erin);
        by(ALICE).inviteMember(InviteMemberRequest.newBuilder().setTeamId(team.toString())
                .setEmail(TestUsers.email(ERIN)).setRole(TeamRole.TEAM_ROLE_MEMBER).build());
        String second = mailedToken(TestUsers.email(ERIN));
        assertThat(by(ERIN).acceptInvite(AcceptInviteRequest.newBuilder().setToken(second).build()).getTeam()
                .getCallerRole()).isEqualTo(TeamRole.TEAM_ROLE_MEMBER);
    }

    // ------------------------------------------------------------------ Teams and documents

    @Test
    void aPersonInThreeTeamsSeesTheRightDocumentsInEach() {
        UUID viewers = team(alice, "viewer");
        UUID editors = team(bob, "editor");
        UUID guests = team(erin, "editor");
        teamMember(viewers, carol, "member");
        teamMember(editors, carol, "admin");
        teamMember(guests, carol, "guest");
        Document inViewers = teamDocument(ALICE, viewers, "Viewers' doc");
        Document inEditors = teamDocument(BOB, editors, "Editors' doc");
        Document sharedGuest = teamDocument(ERIN, guests, "Shared with the guest");
        Document hiddenGuest = teamDocument(ERIN, guests, "Hidden from the guest");
        share(UUID.fromString(sharedGuest.getId()), carol, "commenter");

        assertThat(listed(viewers)).containsExactly(inViewers.getId() + ":" + DocumentRole.DOCUMENT_ROLE_VIEWER);
        assertThat(listed(editors)).containsExactly(inEditors.getId() + ":" + DocumentRole.DOCUMENT_ROLE_OWNER);
        assertThat(listed(guests)).containsExactly(sharedGuest.getId() + ":" + DocumentRole.DOCUMENT_ROLE_COMMENTER)
                .doesNotContain(hiddenGuest.getId() + ":" + DocumentRole.DOCUMENT_ROLE_COMMENTER);
    }

    Document teamDocument(String user, UUID team, String name) {
        return as(docs, user).create(CreateRequest.newBuilder().setDocumentId(uuid7().toString())
                .setSpaceId(team.toString()).setName(name).build()).getDocument();
    }

    List<String> listed(UUID team) {
        return as(docs, CAROL).list(ListRequest.newBuilder().setSpaceId(team.toString()).build()).getDocumentsList()
                .stream().map(d -> d.getId() + ":" + d.getCallerRole()).toList();
    }
}
