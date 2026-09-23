package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

class RoleTest {

    @Test
    void storedNamesRoundTrip() {
        for (Role role : Role.values()) {
            assertThat(Role.fromDb(role.dbName())).isEqualTo(role);
        }
        assertThatThrownBy(() -> Role.fromDb("superuser")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rolesAreOrdered() {
        assertThat(Role.OWNER.atLeast(Role.EDITOR)).isTrue();
        assertThat(Role.EDITOR.atLeast(Role.EDITOR)).isTrue();
        assertThat(Role.COMMENTER.atLeast(Role.EDITOR)).isFalse();
        assertThat(Role.max(Role.VIEWER, Role.EDITOR)).isEqualTo(Role.EDITOR);
        assertThat(Role.max(Role.OWNER, Role.NONE)).isEqualTo(Role.OWNER);
    }
}
