package com.villagecompute.wiretuner.api.auth;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import com.google.rpc.ErrorInfo;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentMember;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberId;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLink;
import com.villagecompute.wiretuner.api.persistence.ShareLinkRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUse;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseId;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseRepository;
import com.villagecompute.wiretuner.api.persistence.Team;
import com.villagecompute.wiretuner.api.persistence.TeamMember;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.test.junit.QuarkusTest;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * SRV-002: the effective document role from each source, and the guard every RPC class calls
 * against each role (docs/spec/security.adoc, Document roles).
 */
@QuarkusTest
class DocumentRolesTest {

    /** The RPC classes by the minimum role they need; each real RPC names one of these. */
    enum RpcClass {
        /** Subscribe, FetchSnapshot, FetchChanges, blob download. */
        READ(Role.VIEWER),
        /** PushChange from a commenter session (comments collection only). */
        COMMENT(Role.COMMENTER),
        /** PushChange, blob upload, fork, versions. */
        EDIT(Role.EDITOR),
        /** Share, change roles, transfer, move, delete. */
        ADMINISTER(Role.OWNER);

        final Role minimum;

        RpcClass(Role minimum) {
            this.minimum = minimum;
        }
    }

    @Inject DocumentRoles roles;
    @Inject RoleGuard guard;
    @Inject AccountRepository accounts;
    @Inject TeamRepository teams;
    @Inject TeamMemberRepository teamMembers;
    @Inject DocumentRepository documents;
    @Inject DocumentMemberRepository members;
    @Inject ShareLinkRepository links;
    @Inject ShareLinkUseRepository linkUses;

    UUID owner;
    UUID stranger;
    Document personal;

    @BeforeEach
    void seed() {
        owner = account();
        stranger = account();
        personal = document(owner, null);
    }

    @Test
    void personalOwnerIsOwnerAndStrangersHaveNothing() {
        assertThat(role(personal.id, owner)).isEqualTo(Role.OWNER);
        assertThat(role(personal.id, stranger)).isEqualTo(Role.NONE);
        assertThat(role(UUID.randomUUID(), owner)).isEqualTo(Role.NONE);
    }

    @ParameterizedTest
    @EnumSource(value = Role.class, names = {"EDITOR", "COMMENTER", "VIEWER"})
    void explicitMembershipGrantsItsRole(Role granted) {
        member(personal.id, stranger, granted.dbName());
        assertThat(role(personal.id, stranger)).isEqualTo(granted);
    }

    @Test
    void teamRolesMapToDocumentRoles() {
        UUID admin = account();
        UUID member = account();
        UUID guest = account();
        Team team = team(owner, "commenter");
        teamMember(team.id, owner, "owner");
        teamMember(team.id, admin, "admin");
        teamMember(team.id, member, "member");
        teamMember(team.id, guest, "guest");
        Document doc = document(null, team.id);

        assertThat(role(doc.id, owner)).isEqualTo(Role.OWNER);
        assertThat(role(doc.id, admin)).isEqualTo(Role.OWNER);
        assertThat(role(doc.id, member)).isEqualTo(Role.COMMENTER);
        assertThat(role(doc.id, guest)).isEqualTo(Role.NONE);
        assertThat(role(doc.id, stranger)).isEqualTo(Role.NONE);

        // A guest sees documents explicitly shared with them; the effective role is the maximum.
        member(doc.id, guest, "viewer");
        member(doc.id, member, "editor");
        assertThat(role(doc.id, guest)).isEqualTo(Role.VIEWER);
        assertThat(role(doc.id, member)).isEqualTo(Role.EDITOR);
    }

    @Test
    void aTeamDocumentHasExactlyOneOwnerRow() {
        UUID creator = account();
        Team team = team(owner, "viewer");
        teamMember(team.id, creator, "member");
        Document doc = document(null, team.id);
        member(doc.id, creator, "owner");
        assertThat(role(doc.id, creator)).isEqualTo(Role.OWNER);
        assertThatThrownBy(() -> member(doc.id, stranger, "owner")).hasStackTraceContaining("document_member_one_owner");
    }

    @Test
    void aDeletedTeamGrantsNothingByDefault() {
        UUID member = account();
        Team team = team(owner, "editor");
        teamMember(team.id, member, "member");
        Document doc = document(null, team.id);
        tx(() -> teams.findById(team.id).invoke(t -> t.deletedAt = Instant.now()));
        assertThat(role(doc.id, member)).isEqualTo(Role.NONE);
    }

    @Test
    void onlyUsedLiveShareLinksCount() {
        ShareLink editor = link(personal.id, "editor", null, null);
        ShareLink expired = link(personal.id, "editor", Instant.now().minusSeconds(60), null);
        ShareLink revoked = link(personal.id, "editor", null, Instant.now());
        ShareLink viewer = link(personal.id, "viewer", Instant.now().plusSeconds(3600), null);

        assertThat(role(personal.id, stranger)).isEqualTo(Role.NONE);
        use(expired, stranger);
        use(revoked, stranger);
        assertThat(role(personal.id, stranger)).isEqualTo(Role.NONE);
        use(viewer, stranger);
        assertThat(role(personal.id, stranger)).isEqualTo(Role.VIEWER);
        use(editor, stranger);
        assertThat(role(personal.id, stranger)).isEqualTo(Role.EDITOR);
    }

    @Test
    void usingALinkRecordsItOnce() {
        String token = "tok-" + UUID.randomUUID();
        ShareLink link = link(personal.id, "commenter", null, null, DocumentRoles.tokenHash(token));
        assertThat(tx(() -> roles.useShareLink(token, stranger))).isEqualTo(Role.COMMENTER);
        assertThat(tx(() -> roles.useShareLink(token, stranger))).isEqualTo(Role.COMMENTER);
        assertThat(tx(() -> linkUses.count("id.shareLinkId", link.id))).isEqualTo(1L);
        assertThat(role(personal.id, stranger)).isEqualTo(Role.COMMENTER);
    }

    @Test
    void anUnknownOrDeadLinkIsDocumentNotFound() {
        String token = "dead-" + UUID.randomUUID();
        link(personal.id, "editor", Instant.now().minusSeconds(1), null, DocumentRoles.tokenHash(token));
        for (String t : new String[] {token, "never-issued-" + UUID.randomUUID()}) {
            assertThatThrownBy(() -> tx(() -> roles.useShareLink(t, stranger)))
                    .satisfies(e -> assertThat(StatusExceptions.reasonOf(e)).contains("DOCUMENT_NOT_FOUND"));
        }
    }

    @Test
    void tokenHashIsLowerHexSha256() {
        assertThat(DocumentRoles.tokenHash("abc"))
                .isEqualTo("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assertThatThrownBy(() -> DocumentRoles.digestHex("NO-SUCH-DIGEST", "x")).isInstanceOf(IllegalStateException.class);
    }

    @ParameterizedTest
    @EnumSource(RpcClass.class)
    void eachRoleAgainstEachRpcClass(RpcClass rpc) {
        for (Role held : Role.values()) {
            UUID caller = held == Role.OWNER ? owner : account();
            if (held != Role.NONE && held != Role.OWNER) {
                member(personal.id, caller, held.dbName());
            }
            Principal principal = principal(caller);
            if (held == Role.NONE) {
                StatusRuntimeException e = guardFailure(principal, rpc.minimum);
                assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.NOT_FOUND);
                assertThat(StatusExceptions.reasonOf(e)).contains("DOCUMENT_NOT_FOUND");
            } else if (held.atLeast(rpc.minimum)) {
                RoleGuard.Grant grant = tx(() -> guard.require(principal, personal.id, rpc.minimum));
                assertThat(grant.role()).as(held + " on " + rpc).isEqualTo(held);
                assertThat(grant.principal()).isEqualTo(principal);
            } else {
                StatusRuntimeException e = guardFailure(principal, rpc.minimum);
                assertThat(e.getStatus().getCode()).as(held + " on " + rpc).isEqualTo(Status.Code.PERMISSION_DENIED);
                ErrorInfo info = StatusExceptions.errorInfo(e).orElseThrow();
                assertThat(info.getReason()).isEqualTo("ROLE_INSUFFICIENT");
                assertThat(info.getDomain()).isEqualTo("wiretuner.app");
                assertThat(info.getMetadataMap()).containsEntry("required", rpc.minimum.dbName())
                        .containsEntry("actual", held.dbName());
            }
        }
    }

    @Test
    void theGuardResolvesTheCallerItself() {
        Principal principal = principal(owner);
        RoleGuard resolving = new RoleGuard();
        resolving.documentRoles = roles;
        resolving.principals = new Principals() {
            @Override
            public Uni<Principal> current() {
                return Uni.createFrom().item(principal);
            }
        };
        assertThat(tx(() -> resolving.require(personal.id, Role.OWNER)).role()).isEqualTo(Role.OWNER);
        assertThat(tx(resolving::authenticated)).isEqualTo(principal);
    }

    StatusRuntimeException guardFailure(Principal principal, Role minimum) {
        Throwable failure = null;
        try {
            tx(() -> guard.require(principal, personal.id, minimum));
        } catch (Throwable t) {
            failure = t;
        }
        assertThat(failure).isInstanceOf(StatusRuntimeException.class);
        return (StatusRuntimeException) failure;
    }

    Role role(UUID doc, UUID account) {
        return tx(() -> roles.effectiveRole(doc, account));
    }

    static Principal principal(UUID account) {
        return new Principal(account, "sub-" + account, null, "password", null, "req");
    }

    UUID account() {
        Account account = new Account();
        account.id = UUID.randomUUID();
        account.subject = "roles-" + account.id;
        tx(() -> accounts.persist(account));
        return account.id;
    }

    Team team(UUID ownerId, String defaultRole) {
        Team team = new Team();
        team.id = UUID.randomUUID();
        team.name = "Team";
        team.slug = "roles-" + team.id;
        team.ownerAccountId = ownerId;
        team.defaultDocumentRole = defaultRole;
        tx(() -> teams.persist(team));
        return team;
    }

    void teamMember(UUID team, UUID account, String role) {
        TeamMember member = new TeamMember();
        member.id = new TeamMemberId(team, account);
        member.role = role;
        tx(() -> teamMembers.persist(member));
    }

    Document document(UUID ownerId, UUID team) {
        Document doc = new Document();
        doc.id = UUID.randomUUID();
        doc.ownerAccountId = ownerId;
        doc.teamId = team;
        tx(() -> documents.persist(doc));
        return doc;
    }

    void member(UUID doc, UUID account, String role) {
        DocumentMember member = new DocumentMember();
        member.id = new DocumentMemberId(doc, account);
        member.role = role;
        tx(() -> members.persist(member));
    }

    ShareLink link(UUID doc, String role, Instant expires, Instant revoked) {
        return link(doc, role, expires, revoked, DocumentRoles.tokenHash(UUID.randomUUID().toString()));
    }

    ShareLink link(UUID doc, String role, Instant expires, Instant revoked, String hash) {
        ShareLink link = new ShareLink();
        link.id = UUID.randomUUID();
        link.documentId = doc;
        link.tokenHash = hash;
        link.role = role;
        link.expiresAt = expires;
        link.revokedAt = revoked;
        tx(() -> links.persist(link));
        return link;
    }

    void use(ShareLink link, UUID account) {
        ShareLinkUse use = new ShareLinkUse();
        use.id = new ShareLinkUseId(link.id, account);
        tx(() -> linkUses.persist(use));
    }
}
