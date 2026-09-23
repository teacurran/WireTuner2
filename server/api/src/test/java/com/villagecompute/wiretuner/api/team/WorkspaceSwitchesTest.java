package com.villagecompute.wiretuner.api.team;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.account.v1.GetTeamRequest;
import com.villagecompute.wiretuner.account.v1.TeamServiceGrpc;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.docs.v1.CreateLinkRequest;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.ListRequest;
import com.villagecompute.wiretuner.docs.v1.ShareServiceGrpc;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SEC-002 require-SSO, checked against the token's {@code wt_auth_method} on every call: a member of
 * an SSO-required workspace reaches the team's documents and library only from a session signed in
 * through the workspace's connection; password and passkey sessions are refused; guests, personal
 * documents and TeamService itself are not held to it.
 */
@QuarkusTest
class WorkspaceSwitchesTest extends ServiceTestSupport {

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("team")
    TeamServiceGrpc.TeamServiceBlockingStub teams;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @GrpcClient("share")
    ShareServiceGrpc.ShareServiceBlockingStub share;

    UUID alice;
    UUID bob;
    UUID dave;

    @BeforeEach
    void setUp() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        dave = TestUsers.accountId(account, DAVE);
    }

    UUID document(String user, UUID space) {
        UUID id = uuid7();
        as(docs, user).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(space.toString())
                .setName("SSO").build());
        return id;
    }

    @Test
    void anSsoRequiredTeamRefusesPasswordAndPasskeySessions() {
        UUID team = team(alice, "editor");
        teamMember(team, bob, "member");
        teamMember(team, dave, "guest");
        UUID doc = document(ALICE, team);
        UUID personal = document(ALICE, alice);
        share(doc, dave, "viewer");
        exec("INSERT INTO workspace (team_id, sso_idp_alias, require_sso) VALUES (?, 'acme', true)", team);
        GetRequest get = GetRequest.newBuilder().setDocumentId(doc.toString()).build();

        assertFails(() -> as(docs, ALICE).get(get), Status.Code.FAILED_PRECONDITION, ErrorReasons.SSO_REQUIRED);
        assertFails(() -> TestUsers.viaClient(docs, BOB, TestUsers.PASSKEY).get(get), Status.Code.FAILED_PRECONDITION,
                ErrorReasons.SSO_REQUIRED);
        assertThat(TestUsers.viaClient(docs, ALICE, TestUsers.SSO).get(get).getDocument().getId()).isEqualTo(doc.toString());
        // A guest is outside the company.
        assertThat(as(docs, DAVE).get(get).getDocument().getId()).isEqualTo(doc.toString());
        // The team's library space, too.
        ListRequest list = ListRequest.newBuilder().setSpaceId(team.toString()).build();
        assertFails(() -> as(docs, BOB).list(list), Status.Code.FAILED_PRECONDITION, ErrorReasons.SSO_REQUIRED);
        assertThat(TestUsers.viaClient(docs, BOB, TestUsers.SSO).list(list).getDocumentsList()).hasSize(1);
        // Personal documents and TeamService are not held to it.
        assertThat(as(docs, ALICE).get(GetRequest.newBuilder().setDocumentId(personal.toString()).build())
                .getDocument().getId()).isEqualTo(personal.toString());
        assertThat(as(teams, ALICE).getTeam(GetTeamRequest.newBuilder().setTeamId(team.toString()).build()).getTeam()
                .getId()).isEqualTo(team.toString());
        // A stranger still learns nothing; an outsider it was shared with is not a member either.
        assertFails(() -> as(docs, TestUsers.ERIN).get(get), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        share(doc, TestUsers.accountId(account, TestUsers.ERIN), "viewer");
        assertThat(as(docs, TestUsers.ERIN).get(get).getDocument().getId()).isEqualTo(doc.toString());
        // Require-SSO alone does not restrict sharing.
        assertThat(TestUsers.viaClient(share, ALICE, TestUsers.SSO).createLink(CreateLinkRequest.newBuilder()
                .setDocumentId(doc.toString()).setRole(DocumentRole.DOCUMENT_ROLE_VIEWER).build()).getToken()).isNotEmpty();
    }

    @Test
    void requireSsoWithoutAConnectionRefusesEveryMember() {
        UUID team = team(alice, "editor");
        UUID doc = document(ALICE, team);
        exec("INSERT INTO workspace (team_id, require_sso) VALUES (?, true)", team);
        assertFails(() -> TestUsers.viaClient(docs, ALICE, TestUsers.SSO).get(GetRequest.newBuilder()
                .setDocumentId(doc.toString()).build()), Status.Code.FAILED_PRECONDITION, ErrorReasons.SSO_REQUIRED);
    }
}
