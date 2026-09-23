package com.villagecompute.wiretuner.api.share;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentMember;
import com.villagecompute.wiretuner.sync.v1.Participant;

/** The pure parts of sharing: role mapping, timestamps, the removal rule, ownership, link passwords. */
class SharePartsTest {

    @Test
    void requestRolesMapToRoles() {
        assertThat(ShareMessages.role(DocumentRole.DOCUMENT_ROLE_EDITOR)).isEqualTo(Role.EDITOR);
        assertThat(ShareMessages.role(DocumentRole.DOCUMENT_ROLE_COMMENTER)).isEqualTo(Role.COMMENTER);
        assertThat(ShareMessages.role(DocumentRole.DOCUMENT_ROLE_VIEWER)).isEqualTo(Role.VIEWER);
        assertThat(ShareMessages.role(DocumentRole.DOCUMENT_ROLE_UNSPECIFIED)).isEqualTo(Role.NONE);
    }

    @Test
    void theZeroTimestampIsNever() {
        assertThat(ShareMessages.instant(Timestamp.getDefaultInstance())).isNull();
        assertThat(ShareMessages.instant(Timestamp.newBuilder().setNanos(5).build())).isEqualTo(Instant.ofEpochSecond(0, 5));
        assertThat(ShareMessages.instant(Timestamp.newBuilder().setSeconds(7).build())).isEqualTo(Instant.ofEpochSecond(7));
    }

    static DocumentMember row(String role, UUID addedBy) {
        DocumentMember row = new DocumentMember();
        row.role = role;
        row.addedBy = addedBy;
        return row;
    }

    @Test
    void whoMayRemoveWhom() {
        UUID me = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        Principal principal = new Principal(me, "s", null, "password", null, "r");
        RoleGuard.Grant owner = new RoleGuard.Grant(principal, Role.OWNER);
        RoleGuard.Grant editor = new RoleGuard.Grant(principal, Role.EDITOR);
        RoleGuard.Grant viewer = new RoleGuard.Grant(principal, Role.VIEWER);
        assertThat(ShareGrpcService.mayRemove(owner, other, row("editor", null))).isTrue();
        assertThat(ShareGrpcService.mayRemove(viewer, me, row("viewer", null))).isTrue();
        assertThat(ShareGrpcService.mayRemove(viewer, other, row("viewer", me))).isFalse();
        assertThat(ShareGrpcService.mayRemove(editor, other, null)).isFalse();
        assertThat(ShareGrpcService.mayRemove(editor, other, row("viewer", other))).isFalse();
        assertThat(ShareGrpcService.mayRemove(editor, other, row("commenter", me))).isTrue();
        assertThat(ShareGrpcService.mayRemove(editor, other, row("editor", me))).isFalse();
    }

    @Test
    void theOwnerIsThePersonalOwnerOrTheOwnerRow() {
        UUID account = UUID.randomUUID();
        Document personal = new Document();
        personal.ownerAccountId = account;
        Document team = new Document();
        team.teamId = UUID.randomUUID();
        assertThat(ShareGrpcService.isOwner(personal, account, null)).isTrue();
        assertThat(ShareGrpcService.isOwner(team, account, row("owner", null))).isTrue();
        assertThat(ShareGrpcService.isOwner(team, account, row("editor", null))).isFalse();
        assertThat(ShareGrpcService.isOwner(team, account, null)).isFalse();
    }

    @Test
    void aRoleOfNoneIsAccessRemoved() {
        Participant actor = Participant.newBuilder().setUserId("a").build();
        assertThat(ShareGrpcService.roleEvent(Role.NONE, actor).hasAccessRemoved()).isTrue();
        assertThat(ShareGrpcService.roleEvent(Role.VIEWER, actor).getRoleChanged().getRole())
                .isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
    }

    @Test
    void linkPasswordsAreArgon2idAndVerifyOnlyThemselves() {
        String phc = LinkPasswords.hashNow("correct horse");
        assertThat(phc).startsWith("$argon2id$v=19$m=19456,t=2,p=1$");
        assertThat(LinkPasswords.verifyNow("correct horse", phc)).isTrue();
        assertThat(LinkPasswords.verifyNow("battery staple", phc)).isFalse();
        assertThat(LinkPasswords.hashNow("correct horse")).isNotEqualTo(phc);
        assertThat(ShareGrpcService.token()).hasSize(22).matches("[A-Za-z0-9_-]+");
    }

    @Test
    void roleNoticesCarryTheActorOnlyWhenThereIsOne() {
        Participant actor = Participant.newBuilder().setUserId(UUID.randomUUID().toString()).build();
        assertThat(RoleNotices.event(Role.NONE, actor).getAccessRemoved().getActor()).isEqualTo(actor);
        assertThat(RoleNotices.event(Role.NONE, Participant.getDefaultInstance()).getAccessRemoved().hasActor()).isFalse();
        assertThat(RoleNotices.event(Role.VIEWER, actor).getRoleChanged().getActor()).isEqualTo(actor);
        assertThat(RoleNotices.event(Role.EDITOR, Participant.getDefaultInstance()).getRoleChanged().hasActor()).isFalse();
        assertThat(RoleNotices.event(Role.EDITOR, actor).getRoleChanged().getRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_EDITOR);
    }
}
