package com.villagecompute.wiretuner.api.team;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.TeamRole;
import com.villagecompute.wiretuner.api.persistence.TeamInvite;

/** Slugs, role mappings and invitation messages. */
class TeamPartsTest {

    @Test
    void slugsAreDerivedTrimmedAndSuffixed() {
        assertThat(Slugs.derive("  Hello, World!  ")).isEqualTo("hello-world");
        assertThat(Slugs.derive("¡¿!")).isEqualTo(Slugs.FALLBACK);
        String longName = "a".repeat(70) + " b";
        assertThat(Slugs.derive(longName)).hasSize(64).matches("a{64}");
        assertThat(Slugs.withSuffix("a".repeat(64), "abc123")).hasSize(64).endsWith("-abc123");
        assertThat(Slugs.trim("-" + "b".repeat(62) + "-cd", 64)).isEqualTo("b".repeat(62));
    }

    @Test
    void teamRolesOrderAndMap() {
        assertThat(TeamRoles.atLeast(TeamRoles.OWNER, TeamRoles.ADMIN)).isTrue();
        assertThat(TeamRoles.atLeast(TeamRoles.GUEST, TeamRoles.MEMBER)).isFalse();
        assertThat(TeamRoles.toProto(TeamRoles.OWNER)).isEqualTo(TeamRole.TEAM_ROLE_OWNER);
        assertThat(TeamRoles.toProto(TeamRoles.GUEST)).isEqualTo(TeamRole.TEAM_ROLE_GUEST);
        assertThat(TeamRoles.fromProto(TeamRole.TEAM_ROLE_ADMIN)).isEqualTo(TeamRoles.ADMIN);
        assertThat(TeamRoles.fromProto(TeamRole.TEAM_ROLE_MEMBER)).isEqualTo(TeamRoles.MEMBER);
        assertThat(TeamRoles.fromProto(TeamRole.TEAM_ROLE_GUEST)).isEqualTo(TeamRoles.GUEST);
    }

    @Test
    void anAcceptedInvitationFromADeletedAccountStillReads() {
        TeamInvite row = new TeamInvite();
        row.id = UUID.randomUUID();
        row.teamId = UUID.randomUUID();
        row.email = "x@example.com";
        row.role = TeamRoles.MEMBER;
        row.expiresAt = Instant.now();
        row.acceptedAt = Instant.now();
        var invite = TeamMessages.invite(row);
        assertThat(invite.getInvitedByAccountId()).isEmpty();
        assertThat(invite.hasAcceptedAt()).isTrue();
    }

    @Test
    void tokensAreUrlSafeAndUnguessable() {
        String token = TeamGrpcService.token(TeamGrpcService.TOKEN_BYTES);
        assertThat(token).hasSize(43).matches("[A-Za-z0-9_-]+");
        assertThat(TeamGrpcService.token(TeamGrpcService.TOKEN_BYTES)).isNotEqualTo(token);
    }
}
