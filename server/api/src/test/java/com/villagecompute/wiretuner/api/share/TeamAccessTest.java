package com.villagecompute.wiretuner.api.share;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.account.v1.LeaveTeamRequest;
import com.villagecompute.wiretuner.account.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.account.v1.SetMemberRoleRequest;
import com.villagecompute.wiretuner.account.v1.TeamRole;
import com.villagecompute.wiretuner.account.v1.TeamServiceGrpc;
import com.villagecompute.wiretuner.account.v1.UpdateTeamRequest;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.sync.LiveSessions;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.InviteRequest;
import com.villagecompute.wiretuner.docs.v1.ListMembersRequest;
import com.villagecompute.wiretuner.docs.v1.MoveToFolderRequest;
import com.villagecompute.wiretuner.docs.v1.SetTeamAccessRequest;
import com.villagecompute.wiretuner.docs.v1.ShareServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.TeamAccess;
import com.villagecompute.wiretuner.docs.v1.TransferOwnershipRequest;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;
import com.villagecompute.wiretuner.api.PerfReport;
import com.villagecompute.wiretuner.api.PerfTest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * COLLAB-011: the per-document team access override and the named-role-wins rule, role changes that
 * reach live sessions from TeamService, space moves and the Invitations job, and the team-admin rule
 * for moving a document out of a team.
 */
@QuarkusTest
public class TeamAccessTest extends SyncTestSupport {

    static final DocumentRole EDITOR = DocumentRole.DOCUMENT_ROLE_EDITOR;
    static final DocumentRole VIEWER = DocumentRole.DOCUMENT_ROLE_VIEWER;
    static final DocumentRole COMMENTER = DocumentRole.DOCUMENT_ROLE_COMMENTER;

    @GrpcClient("share")
    ShareServiceGrpc.ShareServiceBlockingStub share;

    @GrpcClient("team")
    TeamServiceGrpc.TeamServiceBlockingStub teams;

    @Inject
    InvitationsJob invitations;

    @Inject
    LiveSessions sessions;

    UUID dave;

    @BeforeEach
    void more() {
        dave = TestUsers.accountId(account, DAVE);
    }

    ShareServiceGrpc.ShareServiceBlockingStub by(String user) {
        return TestUsers.as(share, user);
    }

    /** A team of Alice's (default {@code role}) with Bob as a member, and a document in it by Alice. */
    record Setup(UUID team, UUID doc) {
    }

    Setup teamDoc(String role) {
        UUID team = team(alice, role);
        teamMember(team, bob, "member");
        UUID doc = uuid7();
        TestUsers.as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(doc.toString())
                .setSpaceId(team.toString()).setName("Team doc").build());
        return new Setup(team, doc);
    }

    DocumentRole roleOf(String user, UUID doc) {
        return TestUsers.as(docs, user).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build()).getDocument()
                .getCallerRole();
    }

    TeamAccess setTeamAccess(String user, UUID doc, DocumentRole override) {
        return by(user).setTeamAccess(SetTeamAccessRequest.newBuilder().setDocumentId(doc.toString()).setOverride(override)
                .build()).getTeamAccess();
    }

    Subscription watching(String user, UUID doc) {
        Subscription s = subscribe(user, null, doc, replicaId(), 0);
        s.next(FrameCase.PRESENCE);
        UUID account = TestUsers.accountId(this.account, user);
        await(() -> sessions.live(doc, account).await().atMost(WAIT));
        return s;
    }

    static DocumentEvent event(Subscription s, DocumentEvent.EventCase kind) {
        while (true) {
            DocumentEvent event = s.next(FrameCase.EVENT).getEvent();
            if (event.getEventCase() == kind) {
                return event;
            }
        }
    }

    public static void run(java.util.function.Supplier<io.smallrye.mutiny.Uni<Void>> job) {
        try {
            io.quarkus.vertx.VertxContextSupport.subscribeAndAwait(job);
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }

    long push(String user, UUID doc, long replica, long seq) {
        return blocking(user, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change(replica, seq)).build()).getServerSeq();
    }

    // ------------------------------------------------------------------------------ team access

    @Test
    void theOverrideRaisesOrLowersTheTeamAndANamedRoleWinsEitherWay() {
        Setup s = teamDoc("editor");
        assertThat(roleOf(BOB, s.doc())).isEqualTo(EDITOR);

        TeamAccess lowered = setTeamAccess(ALICE, s.doc(), VIEWER);
        assertThat(lowered.getTeamDefault()).isEqualTo(EDITOR);
        assertThat(lowered.getOverride()).isEqualTo(VIEWER);
        assertThat(roleOf(BOB, s.doc())).isEqualTo(VIEWER);
        assertThat(by(BOB).listMembers(ListMembersRequest.newBuilder().setDocumentId(s.doc().toString()).build())
                .getTeamAccess().getOverride()).isEqualTo(VIEWER);

        // A named role lower than the team's access wins (the COLLAB-011 rule), and so does a higher one.
        setTeamAccess(ALICE, s.doc(), DocumentRole.DOCUMENT_ROLE_UNSPECIFIED);
        assertThat(roleOf(BOB, s.doc())).isEqualTo(EDITOR);
        share(s.doc(), bob, "viewer");
        assertThat(roleOf(BOB, s.doc())).isEqualTo(VIEWER);
        share(s.doc(), bob, "editor");
        setTeamAccess(ALICE, s.doc(), COMMENTER);
        assertThat(roleOf(BOB, s.doc())).isEqualTo(EDITOR);
        // Team admins keep the owner's powers whatever their named role.
        teamMember(s.team(), carol, "admin");
        share(s.doc(), carol, "viewer");
        assertThat(roleOf(CAROL, s.doc())).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);

        assertFails(() -> setTeamAccess(BOB, s.doc(), VIEWER), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        UUID personal = document(ALICE);
        assertFails(() -> setTeamAccess(ALICE, personal, VIEWER), Status.Code.FAILED_PRECONDITION,
                ErrorReasons.TEAM_ROLE_INVALID);
    }

    @Test
    void loweringTheTeamAccessReachesLiveSessionsAndRefusesTheNextPush() {
        lowerTeamAccess();
    }

    /** The perf run: the lowered access reaches the session within a second (COLLAB-011). */
    @PerfTest
    void loweringTheTeamAccessReachesLiveSessionsWithinASecond() {
        long elapsed = lowerTeamAccess();
        PerfReport.measured("Team access change to a live session (COLLAB-011)",
                String.format(Locale.ROOT, "%.0f ms", elapsed / 1e6), "< 1000 ms",
                elapsed < TimeUnit.MILLISECONDS.toNanos(1000));
        assertThat(elapsed).isLessThan(TimeUnit.MILLISECONDS.toNanos(1000));
    }

    private long lowerTeamAccess() {
        Setup s = teamDoc("editor");
        long replica = replicaId();
        Subscription bobs = watching(BOB, s.doc());
        Subscription alices = watching(ALICE, s.doc());
        assertThat(push(BOB, s.doc(), replica, 1)).isEqualTo(1);

        long started = System.nanoTime();
        setTeamAccess(ALICE, s.doc(), VIEWER);
        DocumentEvent changed = event(bobs, DocumentEvent.EventCase.ROLE_CHANGED);
        long elapsed = System.nanoTime() - started;
        assertThat(changed.getRoleChanged().getRole()).isEqualTo(VIEWER);
        assertThat(changed.getRoleChanged().getActor().getUserId()).isEqualTo(alice.toString());
        assertFails(() -> push(BOB, s.doc(), replica, 2), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertThat(event(alices, DocumentEvent.EventCase.MEMBERS_CHANGED).getMembersChanged().getActor().getUserId())
                .isEqualTo(alice.toString());
        bobs.cancel();
        alices.cancel();
        return elapsed;
    }

    // ------------------------------------------------------------------------------ TeamService

    @Test
    void teamMembershipAndDefaultChangesReachLiveSessions() {
        Setup s = teamDoc("editor");
        teamMember(s.team(), carol, "member");
        Subscription bobs = watching(BOB, s.doc());
        Subscription carols = watching(CAROL, s.doc());

        TestUsers.as(teams, ALICE).updateTeam(UpdateTeamRequest.newBuilder().setTeamId(s.team().toString())
                .setDefaultDocumentRole(COMMENTER).build());
        assertThat(event(bobs, DocumentEvent.EventCase.ROLE_CHANGED).getRoleChanged().getRole()).isEqualTo(COMMENTER);
        assertThat(event(carols, DocumentEvent.EventCase.ROLE_CHANGED).getRoleChanged().getRole()).isEqualTo(COMMENTER);

        // A rename alone tells nobody anything.
        TestUsers.as(teams, ALICE).updateTeam(UpdateTeamRequest.newBuilder().setTeamId(s.team().toString())
                .setName("Renamed").build());
        TestUsers.as(teams, ALICE).setMemberRole(SetMemberRoleRequest.newBuilder().setTeamId(s.team().toString())
                .setAccountId(bob.toString()).setRole(TeamRole.TEAM_ROLE_GUEST).build());
        DocumentEvent removed = event(bobs, DocumentEvent.EventCase.ACCESS_REMOVED);
        assertThat(removed.getAccessRemoved().getActor().getUserId()).isEqualTo(alice.toString());
        ServerFrame none = carols.frames.poll();
        assertThat(none == null || !none.getEvent().hasRoleChanged()).isTrue();

        TestUsers.as(teams, CAROL).leaveTeam(LeaveTeamRequest.newBuilder().setTeamId(s.team().toString()).build());
        assertThat(event(carols, DocumentEvent.EventCase.ACCESS_REMOVED).getAccessRemoved().getActor().getUserId())
                .isEqualTo(carol.toString());
        // Removing someone who is not a member changes nothing and tells nobody.
        TestUsers.as(teams, ALICE).removeMember(RemoveMemberRequest.newBuilder().setTeamId(s.team().toString())
                .setAccountId(carol.toString()).build());
        bobs.cancel();
        carols.cancel();
    }

    @Test
    void removingAMemberEndsTheirSessions() {
        Setup s = teamDoc("viewer");
        Subscription bobs = watching(BOB, s.doc());
        TestUsers.as(teams, ALICE).removeMember(RemoveMemberRequest.newBuilder().setTeamId(s.team().toString())
                .setAccountId(bob.toString()).build());
        event(bobs, DocumentEvent.EventCase.ACCESS_REMOVED);
        bobs.done.orTimeout(WAIT.toMillis(), TimeUnit.MILLISECONDS).join();
    }

    // -------------------------------------------------------------------------------- moves

    @Test
    void movingOutOfATeamNeedsAnAdminAndTellsTheTeam() {
        Setup s = teamDoc("editor");
        Subscription bobs = watching(BOB, s.doc());
        MoveToFolderRequest home = MoveToFolderRequest.newBuilder().setDocumentId(s.doc().toString())
                .setSpaceId(alice.toString()).build();
        // An outsider holding the owner row (by transfer) is not a team admin.
        by(ALICE).invite(InviteRequest.newBuilder().setDocumentId(s.doc().toString()).setAccountId(dave.toString())
                .setRole(EDITOR).build());
        by(ALICE).transferOwnership(TransferOwnershipRequest.newBuilder().setDocumentId(s.doc().toString())
                .setNewOwnerAccountId(dave.toString()).build());
        assertFails(() -> TestUsers.as(docs, DAVE).moveToFolder(MoveToFolderRequest.newBuilder()
                .setDocumentId(s.doc().toString()).setSpaceId(dave.toString()).build()), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);

        TestUsers.as(docs, ALICE).moveToFolder(home);
        event(bobs, DocumentEvent.EventCase.ACCESS_REMOVED);
        bobs.cancel();
    }

    // ------------------------------------------------------------------------------ the job

    @Test
    void theInvitationsJobExpiresInvitationsAndAnnouncesExpiredLinksOnce() {
        UUID doc = document(ALICE);
        UUID staleInvite = UUID.randomUUID();
        UUID freshInvite = UUID.randomUUID();
        exec("INSERT INTO document_invite (id, document_id, email, role, created_at) VALUES (?, ?, ?, 'viewer', now() - interval '31 days')",
                staleInvite, doc, "stale-" + staleInvite + "@example.com");
        exec("INSERT INTO document_invite (id, document_id, email, role) VALUES (?, ?, ?, 'viewer')",
                freshInvite, doc, "fresh-" + freshInvite + "@example.com");
        UUID team = team(alice, "editor");
        UUID lapsed = UUID.randomUUID();
        exec("INSERT INTO team_invite (id, team_id, email, role, token_hash, expires_at) VALUES (?, ?, ?, 'member', ?, now() - interval '1 day')",
                lapsed, team, "lapsed@example.com", "%064d".formatted(Math.abs(lapsed.getLeastSignificantBits())));
        UUID link = UUID.randomUUID();
        exec("INSERT INTO share_link (id, document_id, token_hash, role, created_by, expires_at, revoke_on_expiry)"
                + " VALUES (?, ?, ?, 'editor', ?, now() + interval '3 seconds', true)", link, doc,
                "%064x".formatted(link.getMostSignificantBits() & Long.MAX_VALUE), alice);
        exec("INSERT INTO share_link_use (share_link_id, account_id) VALUES (?, ?)", link, bob);
        Subscription bobs = watching(BOB, doc);
        Subscription alices = watching(ALICE, doc);

        await(() -> count("SELECT count(*) FROM share_link WHERE id = ? AND expires_at <= now()", link) == 1);
        run(invitations::expire);
        DocumentEvent removed = event(bobs, DocumentEvent.EventCase.ACCESS_REMOVED);
        assertThat(removed.getAccessRemoved().hasActor()).isFalse();
        assertThat(count("SELECT count(*) FROM document_invite WHERE id = ?", staleInvite)).isZero();
        assertThat(count("SELECT count(*) FROM document_invite WHERE id = ?", freshInvite)).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM team_invite WHERE id = ?", lapsed)).isZero();
        assertThat(value("SELECT expiry_announced_at IS NOT NULL FROM share_link WHERE id = ?", link)).isEqualTo(true);

        // Alice was watching too but the link was not hers: she hears that the members changed, no role.
        assertThat(event(alices, DocumentEvent.EventCase.MEMBERS_CHANGED).getMembersChanged().hasActor()).isFalse();
        run(invitations::scheduled);
        alices.assertNoChange(Duration.ofMillis(200));
        ServerFrame again = alices.frames.poll();
        assertThat(again == null || !again.getEvent().hasRoleChanged()).isTrue();
        alices.cancel();
    }
}
