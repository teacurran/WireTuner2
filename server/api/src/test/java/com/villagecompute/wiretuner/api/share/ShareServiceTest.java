package com.villagecompute.wiretuner.api.share;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.docs.v1.AccessRequest;
import com.villagecompute.wiretuner.docs.v1.AccessSource;
import com.villagecompute.wiretuner.docs.v1.CreateLinkRequest;
import com.villagecompute.wiretuner.docs.v1.CreateLinkResponse;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.InviteRequest;
import com.villagecompute.wiretuner.docs.v1.ListAccessRequestsRequest;
import com.villagecompute.wiretuner.docs.v1.ListAccessRequestsResponse;
import com.villagecompute.wiretuner.docs.v1.ListLinksRequest;
import com.villagecompute.wiretuner.docs.v1.ListMembersRequest;
import com.villagecompute.wiretuner.docs.v1.ListMembersResponse;
import com.villagecompute.wiretuner.docs.v1.Member;
import com.villagecompute.wiretuner.docs.v1.OpenLinkRequest;
import com.villagecompute.wiretuner.docs.v1.OpenLinkResponse;
import com.villagecompute.wiretuner.docs.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.docs.v1.RemoveMemberResponse;
import com.villagecompute.wiretuner.docs.v1.RequestAccessRequest;
import com.villagecompute.wiretuner.docs.v1.ResolveAccessRequestRequest;
import com.villagecompute.wiretuner.docs.v1.RevokeLinkRequest;
import com.villagecompute.wiretuner.docs.v1.SetRoleRequest;
import com.villagecompute.wiretuner.docs.v1.ShareLink;
import com.villagecompute.wiretuner.docs.v1.ShareServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.TransferOwnershipRequest;
import com.villagecompute.wiretuner.docs.v1.TransferOwnershipResponse;
import com.villagecompute.wiretuner.docs.v1.UpdateLinkRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.mailer.Mail;
import io.quarkus.mailer.MockMailbox;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/** SRV-010: ShareService per RPC and role, its mail through the mock mailbox, and the restrict-sharing switch (SEC-002). */
@QuarkusTest
class ShareServiceTest extends ServiceTestSupport {

    static final DocumentRole EDITOR = DocumentRole.DOCUMENT_ROLE_EDITOR;
    static final DocumentRole COMMENTER = DocumentRole.DOCUMENT_ROLE_COMMENTER;
    static final DocumentRole VIEWER = DocumentRole.DOCUMENT_ROLE_VIEWER;
    static final DocumentRole OWNER = DocumentRole.DOCUMENT_ROLE_OWNER;
    static final DocumentRole NONE = DocumentRole.DOCUMENT_ROLE_UNSPECIFIED;

    @GrpcClient("share")
    ShareServiceGrpc.ShareServiceBlockingStub share;

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @Inject
    MockMailbox mailbox;

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

    ShareServiceGrpc.ShareServiceBlockingStub by(String user) {
        return as(share, user);
    }

    /** A new document of {@code user} in {@code space} (their own account when null). */
    UUID document(String user, UUID space) {
        UUID id = uuid7();
        UUID in = space == null ? TestUsers.accountId(account, user) : space;
        as(docs, user).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(in.toString())
                .setName("Shared " + id.toString().substring(0, 8)).build());
        return id;
    }

    static InviteRequest invite(UUID doc, UUID account, DocumentRole role) {
        return InviteRequest.newBuilder().setDocumentId(doc.toString()).setAccountId(account.toString()).setRole(role)
                .build();
    }

    static InviteRequest inviteEmail(UUID doc, String email, DocumentRole role) {
        return InviteRequest.newBuilder().setDocumentId(doc.toString()).setEmail(email).setRole(role)
                .setMessage("Have a look").build();
    }

    ListMembersResponse members(String user, UUID doc) {
        return by(user).listMembers(ListMembersRequest.newBuilder().setDocumentId(doc.toString()).build());
    }

    Member memberOf(ListMembersResponse page, UUID account) {
        return page.getMembersList().stream().filter(m -> m.getAccountId().equals(account.toString())).findFirst()
                .orElse(null);
    }

    /** An account row that never signs in (no token), with the given email. */
    UUID quietAccount(String email, String name) {
        UUID id = UUID.randomUUID();
        exec("INSERT INTO account (id, subject, email, display_name) VALUES (?, ?, ?, ?)", id, "quiet-" + id, email, name);
        return id;
    }

    // ---------------------------------------------------------------------------------- invite

    @Test
    void invitationsByAccountAndByEmailAreMailedAndListed() {
        UUID doc = document(ALICE, null);
        Member bobMember = by(ALICE).invite(invite(doc, bob, EDITOR)).getMember();
        assertThat(bobMember.getAccountId()).isEqualTo(bob.toString());
        assertThat(bobMember.getRole()).isEqualTo(EDITOR);
        assertThat(bobMember.getEffectiveRole()).isEqualTo(EDITOR);
        assertThat(bobMember.getSourcesList()).containsExactly(AccessSource.ACCESS_SOURCE_NAMED);
        assertThat(bobMember.getEmail()).isEmpty();
        Mail mail = mailbox.getMailsSentTo(TestUsers.email(BOB)).get(0);
        assertThat(mail.getSubject()).contains("shared");
        assertThat(mail.getText()).contains("/d/" + doc).contains("editor").doesNotContain("Have a look");

        // An address that belongs to an account names the account.
        Member carolMember = by(ALICE).invite(inviteEmail(doc, TestUsers.email(CAROL).toUpperCase(), VIEWER)).getMember();
        assertThat(carolMember.getAccountId()).isEqualTo(carol.toString());
        assertThat(mailbox.getMailsSentTo(TestUsers.email(CAROL)).get(0).getHtml()).contains("Have a look");

        // An unknown address is a pending invitation; inviting it again replaces the role.
        String stranger = "stranger-" + UUID.randomUUID() + "@example.test";
        Member pending = by(ALICE).invite(inviteEmail(doc, stranger, VIEWER)).getMember();
        assertThat(pending.getPending()).isTrue();
        assertThat(pending.getEmail()).isEqualTo(stranger);
        assertThat(mailbox.getMailsSentTo(stranger)).hasSize(1);
        assertThat(by(ALICE).invite(inviteEmail(doc, stranger, EDITOR)).getMember().getRole()).isEqualTo(EDITOR);
        assertThat(count("SELECT count(*) FROM document_invite WHERE document_id = ?", doc)).isEqualTo(1);

        assertFails(() -> by(ALICE).invite(invite(doc, bob, VIEWER)), Status.Code.ALREADY_EXISTS, ErrorReasons.ALREADY_MEMBER);
        assertFails(() -> by(ALICE).invite(invite(doc, alice, VIEWER)), Status.Code.ALREADY_EXISTS, ErrorReasons.ALREADY_MEMBER);
        assertFails(() -> by(ALICE).invite(invite(doc, UUID.randomUUID(), VIEWER)), Status.Code.NOT_FOUND,
                ErrorReasons.MEMBER_NOT_FOUND);
        assertFails(() -> by(CAROL).invite(invite(doc, dave, VIEWER)), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> by(DAVE).invite(invite(doc, erin, VIEWER)), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);

        // Someone who opened it through a link (a color-only row) is raised to a named role.
        UUID colored = quietAccount("", "Colored");
        exec("INSERT INTO document_member (document_id, account_id, role, color_index) VALUES (?, ?, 'none', 5)", doc, colored);
        Member raised = by(ALICE).invite(invite(doc, colored, VIEWER)).getMember();
        assertThat(raised.getRole()).isEqualTo(VIEWER);
        assertThat(raised.getColorIndex()).isEqualTo(5);
        by(ALICE).removeMember(RemoveMemberRequest.newBuilder().setDocumentId(doc.toString())
                .setAccountId(colored.toString()).build());

        // An editor may invite; an account without an address gets no mail.
        UUID quiet = quietAccount("", "Quiet");
        assertThat(by(BOB).invite(invite(doc, quiet, COMMENTER)).getMember().getRole()).isEqualTo(COMMENTER);

        ListMembersResponse asOwner = members(ALICE, doc);
        assertThat(asOwner.hasTeamAccess()).isFalse();
        assertThat(asOwner.getMembersList()).extracting(Member::getDisplayName)
                .containsExactly("Alice Tester", "Bob Tester", "Carol Tester", "Quiet", "");
        Member owner = asOwner.getMembers(0);
        assertThat(owner.getRole()).isEqualTo(OWNER);
        assertThat(owner.getIsCreator()).isTrue();
        assertThat(owner.getEmail()).isEqualTo(TestUsers.email(ALICE));
        assertThat(asOwner.getMembers(4).getPending()).isTrue();
        assertThat(members(BOB, doc).getMembers(1).getEmail()).isEmpty();
    }

    @Test
    void aPendingInvitationBindsWhenItsAddressSignsIn() {
        UUID doc = document(ALICE, null);
        String address = "later-" + UUID.randomUUID() + "@example.test";
        by(ALICE).invite(inviteEmail(doc, address, COMMENTER));
        UUID later = quietAccount("", "Later");
        exec("INSERT INTO account_identity (account_id, provider, provider_subject, email, email_verified)"
                + " VALUES (?, 'password', ?, ?, true)", later, "sub-" + later, address.toUpperCase());
        // A color-only row is raised to the invited role.
        exec("INSERT INTO document_member (document_id, account_id, role, color_index) VALUES (?, ?, 'none', 3)", doc, later);
        com.villagecompute.wiretuner.api.Reactive.tx(() -> signIn.apply(later, "password"));
        assertThat(value("SELECT role FROM document_member WHERE document_id = ? AND account_id = ?", doc, later))
                .isEqualTo("commenter");
        assertThat(count("SELECT count(*) FROM document_invite WHERE document_id = ?", doc)).isZero();
        Member bound = memberOf(members(ALICE, doc), later);
        assertThat(bound.getColorIndex()).isEqualTo(3);
        assertThat(bound.getEffectiveRole()).isEqualTo(COMMENTER);
    }

    @Inject
    com.villagecompute.wiretuner.api.auth.SignInEffects signIn;

    // ------------------------------------------------------------------------ roles and removal

    @Test
    void rolesChangeWithinTheRules() {
        UUID doc = document(ALICE, null);
        by(ALICE).invite(invite(doc, bob, EDITOR));
        by(BOB).invite(invite(doc, carol, VIEWER));
        by(ALICE).invite(invite(doc, dave, EDITOR));
        SetRoleRequest.Builder set = SetRoleRequest.newBuilder().setDocumentId(doc.toString());

        assertThat(by(BOB).setRole(set.setAccountId(carol.toString()).setRole(COMMENTER).build()).getMember().getRole())
                .isEqualTo(COMMENTER);
        assertFails(() -> by(BOB).setRole(set.setAccountId(dave.toString()).setRole(VIEWER).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertThat(by(BOB).setRole(set.setAccountId(dave.toString()).setRole(EDITOR).build()).getMember().getRole())
                .isEqualTo(EDITOR);
        assertThat(by(ALICE).setRole(set.setAccountId(dave.toString()).setRole(VIEWER).build()).getMember().getRole())
                .isEqualTo(VIEWER);
        assertFails(() -> by(ALICE).setRole(set.setAccountId(alice.toString()).setRole(VIEWER).build()),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.OWNER_MUST_TRANSFER);
        assertFails(() -> by(ALICE).setRole(set.setAccountId(erin.toString()).setRole(VIEWER).build()),
                Status.Code.NOT_FOUND, ErrorReasons.MEMBER_NOT_FOUND);
        exec("INSERT INTO document_member (document_id, account_id, role) VALUES (?, ?, 'none')", doc, erin);
        assertFails(() -> by(ALICE).setRole(set.setAccountId(erin.toString()).setRole(VIEWER).build()),
                Status.Code.NOT_FOUND, ErrorReasons.MEMBER_NOT_FOUND);
        assertFails(() -> by(DAVE).setRole(set.setAccountId(carol.toString()).setRole(VIEWER).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
    }

    @Test
    void membersAreRemovedByTheOwnerByTheirInviterOrByThemselves() {
        UUID doc = document(ALICE, null);
        by(ALICE).invite(invite(doc, bob, EDITOR));
        by(BOB).invite(invite(doc, carol, COMMENTER));
        by(BOB).invite(invite(doc, erin, EDITOR));
        by(ALICE).invite(invite(doc, dave, VIEWER));
        RemoveMemberRequest.Builder remove = RemoveMemberRequest.newBuilder().setDocumentId(doc.toString());

        RemoveMemberResponse removed = by(BOB).removeMember(remove.setAccountId(carol.toString()).build());
        assertThat(removed.hasMember()).isFalse();
        assertThat(value("SELECT role FROM document_member WHERE document_id = ? AND account_id = ?", doc, carol))
                .isEqualTo("none");
        assertThat(memberOf(members(ALICE, doc), carol)).isNull();
        // Idempotent.
        assertThat(by(BOB).removeMember(remove.setAccountId(carol.toString()).build()).hasMember()).isFalse();

        assertFails(() -> by(BOB).removeMember(remove.setAccountId(dave.toString()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> by(BOB).removeMember(remove.setAccountId(erin.toString()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        UUID stranger = quietAccount("", "Nobody");
        assertFails(() -> by(BOB).removeMember(remove.setAccountId(stranger.toString()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> by(DAVE).removeMember(remove.setAccountId(bob.toString()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> by(ALICE).removeMember(remove.setAccountId(alice.toString()).build()),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.OWNER_MUST_TRANSFER);
        assertThat(by(DAVE).removeMember(remove.setAccountId(dave.toString()).build()).hasMember()).isFalse();
        // The owner removing someone without a named role changes nothing.
        assertThat(by(ALICE).removeMember(remove.setAccountId(stranger.toString()).build()).hasMember()).isFalse();
        assertThat(by(ALICE).removeMember(remove.setAccountId(erin.toString()).build()).hasMember()).isFalse();

        // Someone who keeps access through a link keeps a member entry, with the link as its source.
        CreateLinkResponse link = by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString())
                .setRole(VIEWER).build());
        by(BOB).openLink(OpenLinkRequest.newBuilder().setToken(link.getToken()).build());
        Member left = by(ALICE).removeMember(remove.setAccountId(bob.toString()).build()).getMember();
        assertThat(left.getRole()).isEqualTo(NONE);
        assertThat(left.getSourcesList()).containsExactly(AccessSource.ACCESS_SOURCE_LINK);
        assertThat(left.getEffectiveRole()).isEqualTo(VIEWER);
    }

    // ------------------------------------------------------------------------------------ links

    @Test
    void aPasswordedLinkOpensOnceWithItsPassword() {
        UUID doc = document(ALICE, null);
        assertFails(() -> by(BOB).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString()).setRole(VIEWER)
                .build()), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        Instant expires = Instant.now().plusSeconds(3600);
        CreateLinkResponse created = by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString())
                .setRole(VIEWER).setPassword("open sesame").setRevokeOnExpiry(true)
                .setExpiresAt(Timestamp.newBuilder().setSeconds(expires.getEpochSecond())).build());
        assertThat(created.getToken()).hasSize(22);
        ShareLink link = created.getLink();
        assertThat(link.getHasPassword()).isTrue();
        assertThat(link.getRevokeOnExpiry()).isTrue();
        assertThat(link.getExpiresAt().getSeconds()).isEqualTo(expires.getEpochSecond());
        assertThat(link.getCreatedByAccountId()).isEqualTo(alice.toString());
        assertThat((String) value("SELECT password_hash FROM share_link WHERE id = ?", UUID.fromString(link.getId())))
                .startsWith("$argon2id$v=19$m=19456,t=2,p=1$");
        assertThat(value("SELECT token_hash FROM share_link WHERE id = ?", UUID.fromString(link.getId())))
                .isEqualTo(DocumentRoles.tokenHash(created.getToken()));

        OpenLinkRequest.Builder open = OpenLinkRequest.newBuilder().setToken(created.getToken());
        assertFails(() -> by(BOB).openLink(open.build()), Status.Code.PERMISSION_DENIED, ErrorReasons.LINK_PASSWORD_REQUIRED);
        assertFails(() -> by(BOB).openLink(open.setPassword("guess").build()), Status.Code.PERMISSION_DENIED,
                ErrorReasons.LINK_PASSWORD_REQUIRED);
        OpenLinkResponse opened = by(BOB).openLink(open.setPassword("open sesame").build());
        assertThat(opened.getDocumentId()).isEqualTo(doc.toString());
        assertThat(opened.getDocumentName()).startsWith("Shared ");
        assertThat(opened.getEffectiveRole()).isEqualTo(VIEWER);
        // A second open needs no password.
        assertThat(by(BOB).openLink(OpenLinkRequest.newBuilder().setToken(created.getToken()).build()).getEffectiveRole())
                .isEqualTo(VIEWER);
        assertThat(as(docs, BOB).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build())).isNotNull();

        List<ShareLink> links = by(ALICE).listLinks(ListLinksRequest.newBuilder().setDocumentId(doc.toString()).build())
                .getLinksList();
        assertThat(links).extracting(ShareLink::getUses).containsExactly(1);
        assertFails(() -> by(BOB).listLinks(ListLinksRequest.newBuilder().setDocumentId(doc.toString()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        Member bobMember = memberOf(members(ALICE, doc), bob);
        assertThat(bobMember.getSourcesList()).containsExactly(AccessSource.ACCESS_SOURCE_LINK);
    }

    @Test
    void linksAreUpdatedRevokedAndExpire() {
        UUID doc = document(ALICE, null);
        CreateLinkResponse created = by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString())
                .setRole(VIEWER).setPassword("pw").build());
        UUID linkId = UUID.fromString(created.getLink().getId());

        // Every field at once: role, expiry cleared, revoke-on-expiry, password cleared, restriction.
        ShareLink updated = by(ALICE).updateLink(UpdateLinkRequest.newBuilder().setLinkId(linkId.toString())
                .setRole(EDITOR).setExpiresAt(Timestamp.getDefaultInstance()).setRevokeOnExpiry(true).setPassword("")
                .setTeamMembersOnly(false).build()).getLink();
        assertThat(updated.getRole()).isEqualTo(EDITOR);
        assertThat(updated.hasExpiresAt()).isFalse();
        assertThat(updated.getRevokeOnExpiry()).isTrue();
        assertThat(updated.getHasPassword()).isFalse();
        // No field: nothing changes; a new password is hashed.
        assertThat(by(ALICE).updateLink(UpdateLinkRequest.newBuilder().setLinkId(linkId.toString()).build()).getLink())
                .isEqualTo(updated);
        assertThat(by(ALICE).updateLink(UpdateLinkRequest.newBuilder().setLinkId(linkId.toString()).setPassword("new")
                .build()).getLink().getHasPassword()).isTrue();
        by(ALICE).updateLink(UpdateLinkRequest.newBuilder().setLinkId(linkId.toString()).setPassword("").build());

        assertThat(by(CAROL).openLink(OpenLinkRequest.newBuilder().setToken(created.getToken()).build()).getEffectiveRole())
                .isEqualTo(EDITOR);
        assertFails(() -> by(CAROL).updateLink(UpdateLinkRequest.newBuilder().setLinkId(linkId.toString()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> by(ALICE).updateLink(UpdateLinkRequest.newBuilder().setLinkId(UUID.randomUUID().toString())
                .build()), Status.Code.NOT_FOUND, ErrorReasons.LINK_INVALID);

        by(ALICE).revokeLink(RevokeLinkRequest.newBuilder().setLinkId(linkId.toString()).build());
        Object revokedAt = value("SELECT revoked_at FROM share_link WHERE id = ?", linkId);
        by(ALICE).revokeLink(RevokeLinkRequest.newBuilder().setLinkId(linkId.toString()).build());
        assertThat(value("SELECT revoked_at FROM share_link WHERE id = ?", linkId)).isEqualTo(revokedAt);
        assertFails(() -> as(docs, CAROL).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build()),
                Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        assertFails(() -> by(DAVE).openLink(OpenLinkRequest.newBuilder().setToken(created.getToken()).build()),
                Status.Code.NOT_FOUND, ErrorReasons.LINK_INVALID);
        assertFails(() -> by(DAVE).openLink(OpenLinkRequest.newBuilder().setToken("never-issued-token-x").build()),
                Status.Code.NOT_FOUND, ErrorReasons.LINK_INVALID);
        assertThat(by(ALICE).listLinks(ListLinksRequest.newBuilder().setDocumentId(doc.toString()).build())
                .getLinksList()).isEmpty();
        assertThat(by(ALICE).listLinks(ListLinksRequest.newBuilder().setDocumentId(doc.toString()).setIncludeRevoked(true)
                .build()).getLinksList()).extracting(ShareLink::hasRevokedAt).containsExactly(true);

        CreateLinkResponse expired = by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString())
                .setRole(VIEWER).setExpiresAt(Timestamp.newBuilder().setSeconds(Instant.now().getEpochSecond() - 5)).build());
        assertFails(() -> by(DAVE).openLink(OpenLinkRequest.newBuilder().setToken(expired.getToken()).build()),
                Status.Code.NOT_FOUND, ErrorReasons.LINK_INVALID);
    }

    @Test
    void teamMembersOnlyLinksAndRestrictedWorkspaces() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        UUID doc = document(ALICE, team);
        CreateLinkResponse membersOnly = by(ALICE).createLink(CreateLinkRequest.newBuilder()
                .setDocumentId(doc.toString()).setRole(EDITOR).setTeamMembersOnly(true).build());
        assertFails(() -> by(CAROL).openLink(OpenLinkRequest.newBuilder().setToken(membersOnly.getToken()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertThat(by(BOB).openLink(OpenLinkRequest.newBuilder().setToken(membersOnly.getToken()).build())
                .getEffectiveRole()).isEqualTo(EDITOR);

        // Team-members-only on a personal document: there is no team, so it opens for nobody else.
        UUID personal = document(ALICE, null);
        CreateLinkResponse nobody = by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(personal.toString())
                .setRole(VIEWER).setTeamMembersOnly(true).build());
        assertFails(() -> by(BOB).openLink(OpenLinkRequest.newBuilder().setToken(nobody.getToken()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);

        // A link made before the workspace restricted sharing no longer opens for outsiders.
        CreateLinkResponse open = by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString())
                .setRole(VIEWER).build());
        exec("INSERT INTO workspace (team_id, restrict_sharing) VALUES (?, true)", team);
        assertFails(() -> by(CAROL).openLink(OpenLinkRequest.newBuilder().setToken(open.getToken()).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        teamMember(team, dave, "guest");
        assertThat(by(DAVE).openLink(OpenLinkRequest.newBuilder().setToken(open.getToken()).build()).getEffectiveRole())
                .isEqualTo(VIEWER);

        assertFails(() -> by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString()).setRole(VIEWER)
                .build()), Status.Code.FAILED_PRECONDITION, ErrorReasons.TEAM_ROLE_INVALID);
        assertThat(by(ALICE).createLink(CreateLinkRequest.newBuilder().setDocumentId(doc.toString()).setRole(VIEWER)
                .setTeamMembersOnly(true).build()).getLink().getTeamMembersOnly()).isTrue();
        assertFails(() -> by(ALICE).updateLink(UpdateLinkRequest.newBuilder().setLinkId(membersOnly.getLink().getId())
                .setTeamMembersOnly(false).build()), Status.Code.FAILED_PRECONDITION, ErrorReasons.TEAM_ROLE_INVALID);
        assertFails(() -> by(ALICE).invite(invite(doc, carol, VIEWER)), Status.Code.FAILED_PRECONDITION,
                ErrorReasons.TEAM_ROLE_INVALID);
        assertFails(() -> by(ALICE).invite(inviteEmail(doc, "outside-" + UUID.randomUUID() + "@example.test", VIEWER)),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.TEAM_ROLE_INVALID);
        assertThat(by(ALICE).invite(invite(doc, bob, COMMENTER)).getMember().getRole()).isEqualTo(COMMENTER);
    }

    // -------------------------------------------------------------------------- access requests

    @Test
    void accessIsRequestedAndGrantedOrDeclined() {
        UUID doc = document(ALICE, null);
        String first = by(DAVE).requestAccess(RequestAccessRequest.newBuilder().setDocumentId(doc.toString())
                .setMessage("May I?").build()).getRequestId();
        assertThat(by(DAVE).requestAccess(RequestAccessRequest.newBuilder().setDocumentId(doc.toString()).build())
                .getRequestId()).isEqualTo(first);
        Mail toOwner = mailbox.getMailsSentTo(TestUsers.email(ALICE)).get(0);
        assertThat(mailbox.getMailsSentTo(TestUsers.email(ALICE))).hasSize(1);
        assertThat(toOwner.getText()).contains("May I?").contains(TestUsers.email(DAVE));
        by(ERIN).requestAccess(RequestAccessRequest.newBuilder().setDocumentId(doc.toString()).build());
        assertFails(() -> by(DAVE).requestAccess(RequestAccessRequest.newBuilder().setDocumentId(UUID.randomUUID().toString())
                .build()), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);

        by(ALICE).invite(invite(doc, bob, EDITOR));
        ListAccessRequestsRequest.Builder list = ListAccessRequestsRequest.newBuilder().setDocumentId(doc.toString());
        assertFails(() -> by(BOB).listAccessRequests(list.build()), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        ListAccessRequestsResponse page = by(ALICE).listAccessRequests(list.setPageSize(1).build());
        assertThat(page.getRequestsList()).extracting(AccessRequest::getId).containsExactly(first);
        AccessRequest request = page.getRequests(0);
        assertThat(request.getDisplayName()).isEqualTo("Dave Tester");
        assertThat(request.getEmail()).isEqualTo(TestUsers.email(DAVE));
        assertThat(request.getMessage()).isEqualTo("May I?");
        ListAccessRequestsResponse next = by(ALICE).listAccessRequests(list.setCursor(page.getNextCursor()).build());
        assertThat(next.getRequestsList()).extracting(AccessRequest::getAccountId).containsExactly(erin.toString());
        assertThat(next.getNextCursor()).isEmpty();

        ResolveAccessRequestRequest.Builder resolve = ResolveAccessRequestRequest.newBuilder().setRequestId(first);
        assertFails(() -> by(BOB).resolveAccessRequest(resolve.setGrant(VIEWER).build()), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        Member granted = by(ALICE).resolveAccessRequest(resolve.setGrant(VIEWER).build()).getMember();
        assertThat(granted.getAccountId()).isEqualTo(dave.toString());
        assertThat(granted.getRole()).isEqualTo(VIEWER);
        assertThat(mailbox.getMailsSentTo(TestUsers.email(DAVE)).get(0).getText()).contains("granted").contains("viewer");
        assertFails(() -> by(ALICE).resolveAccessRequest(resolve.build()), Status.Code.NOT_FOUND,
                ErrorReasons.DOCUMENT_NOT_FOUND);
        assertFails(() -> by(ALICE).resolveAccessRequest(ResolveAccessRequestRequest.newBuilder()
                .setRequestId(UUID.randomUUID().toString()).build()), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);

        String erins = next.getRequests(0).getId();
        assertThat(by(ALICE).resolveAccessRequest(ResolveAccessRequestRequest.newBuilder().setRequestId(erins).build())
                .hasMember()).isFalse();
        assertThat(mailbox.getMailsSentTo(TestUsers.email(ERIN)).get(0).getText()).contains("declined");
        assertThat(value("SELECT granted_role FROM access_request WHERE id = ?", UUID.fromString(erins))).isNull();
    }

    @Test
    void requestsReachEveryOwnerAndQuietRequestersGetNoMail() {
        UUID team = team(alice, "viewer");
        UUID quietAdmin = quietAccount("", "Quiet Admin");
        teamMember(team, quietAdmin, "admin");
        teamMember(team, bob, "admin");
        UUID doc = document(ALICE, team);
        String id = by(CAROL).requestAccess(RequestAccessRequest.newBuilder().setDocumentId(doc.toString()).build())
                .getRequestId();
        assertThat(mailbox.getMailsSentTo(TestUsers.email(ALICE))).hasSize(1);
        assertThat(mailbox.getMailsSentTo(TestUsers.email(BOB))).hasSize(1);
        exec("UPDATE account SET email = '' WHERE id = ?", carol);
        try {
            by(BOB).resolveAccessRequest(ResolveAccessRequestRequest.newBuilder().setRequestId(id).setGrant(EDITOR).build());
            assertThat(mailbox.getMailsSentTo(TestUsers.email(CAROL))).isEmpty();
        } finally {
            exec("UPDATE account SET email = ? WHERE id = ?", TestUsers.email(CAROL), carol);
        }
        // The owner asking for their own document: granting leaves them the owner.
        String own = by(ALICE).requestAccess(RequestAccessRequest.newBuilder().setDocumentId(doc.toString()).build())
                .getRequestId();
        assertThat(by(BOB).resolveAccessRequest(ResolveAccessRequestRequest.newBuilder().setRequestId(own).setGrant(VIEWER)
                .build()).getMember().getRole()).isEqualTo(OWNER);
    }

    // ------------------------------------------------------------------------------- ownership

    @Test
    void aPersonalDocumentMovesToItsNewOwner() {
        UUID doc = document(ALICE, null);
        assertFails(() -> by(ALICE).transferOwnership(transfer(doc, bob)), Status.Code.NOT_FOUND,
                ErrorReasons.MEMBER_NOT_FOUND);
        by(ALICE).invite(invite(doc, bob, EDITOR));
        assertFails(() -> by(BOB).transferOwnership(transfer(doc, bob)), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        TransferOwnershipResponse same = by(ALICE).transferOwnership(transfer(doc, alice));
        assertThat(same.getOwner().getAccountId()).isEqualTo(alice.toString());
        assertThat(same.getPreviousOwner().getAccountId()).isEqualTo(alice.toString());

        TransferOwnershipResponse moved = by(ALICE).transferOwnership(transfer(doc, bob));
        assertThat(moved.getOwner().getAccountId()).isEqualTo(bob.toString());
        assertThat(moved.getOwner().getRole()).isEqualTo(OWNER);
        assertThat(moved.getPreviousOwner().getRole()).isEqualTo(EDITOR);
        assertThat(value("SELECT owner_account_id FROM document WHERE id = ?", doc)).isEqualTo(bob);
        assertThat(as(docs, BOB).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build()).getDocument()
                .getSpaceId()).isEqualTo(bob.toString());
        assertThat(members(BOB, doc).getMembersList()).extracting(Member::getRole).containsExactly(OWNER, EDITOR);
    }

    @Test
    void aTeamDocumentPassesItsOwnerRow() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "admin");
        UUID doc = document(ALICE, team);
        share(doc, carol, "editor");
        TransferOwnershipResponse same = by(BOB).transferOwnership(transfer(doc, alice));
        assertThat(same.getOwner().getAccountId()).isEqualTo(alice.toString());

        TransferOwnershipResponse passed = by(BOB).transferOwnership(transfer(doc, carol));
        assertThat(passed.getOwner().getAccountId()).isEqualTo(carol.toString());
        assertThat(passed.getPreviousOwner().getAccountId()).isEqualTo(alice.toString());
        assertThat(passed.getPreviousOwner().getRole()).isEqualTo(EDITOR);
        assertThat(value("SELECT team_id FROM document WHERE id = ?", doc)).isEqualTo(team);

        // Bob, an admin, has opened it: his color row makes him one of the people listed.
        exec("INSERT INTO document_member (document_id, account_id, role, color_index) VALUES (?, ?, 'none', 1)", doc, bob);
        ListMembersResponse page = by(BOB).listMembers(ListMembersRequest.newBuilder().setDocumentId(doc.toString())
                .setPageSize(1).build());
        assertThat(page.getMembersList()).extracting(Member::getAccountId).containsExactly(carol.toString());
        assertThat(page.getTeamAccess().getTeamId()).isEqualTo(team.toString());
        assertThat(page.getTeamAccess().getTeamDefault()).isEqualTo(VIEWER);
        ListMembersResponse rest = by(BOB).listMembers(ListMembersRequest.newBuilder().setDocumentId(doc.toString())
                .setCursor(page.getNextCursor()).build());
        assertThat(rest.hasTeamAccess()).isFalse();
        assertThat(rest.getMembersList()).extracting(Member::getAccountId).contains(alice.toString(), bob.toString());
        Member admin = memberOf(rest, bob);
        assertThat(admin.getSourcesList()).containsExactly(AccessSource.ACCESS_SOURCE_TEAM_DEFAULT);

        // Without an owner row there is no previous owner to name.
        exec("DELETE FROM document_member WHERE document_id = ? AND role = 'owner'", doc);
        share(doc, dave, "viewer");
        TransferOwnershipResponse orphan = by(BOB).transferOwnership(transfer(doc, dave));
        assertThat(orphan.getOwner().getAccountId()).isEqualTo(dave.toString());
        assertThat(orphan.hasPreviousOwner()).isFalse();
    }

    static TransferOwnershipRequest transfer(UUID doc, UUID to) {
        return TransferOwnershipRequest.newBuilder().setDocumentId(doc.toString()).setNewOwnerAccountId(to.toString())
                .build();
    }
}
