package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class AuthMethodsTest {

    @Test
    void validMethods() {
        assertThat(AuthMethods.isValid("passkey")).isTrue();
        assertThat(AuthMethods.isValid("apple")).isTrue();
        assertThat(AuthMethods.isValid("password")).isTrue();
        assertThat(AuthMethods.isValid("sso:acme")).isTrue();
        assertThat(AuthMethods.isValid("sso:")).isFalse();
        assertThat(AuthMethods.isValid("magic-link")).isFalse();
        assertThat(AuthMethods.isValid(null)).isFalse();
    }

    @Test
    void passkeysAreNotIdentities() {
        assertThat(AuthMethods.identityProvider("passkey")).isEmpty();
        assertThat(AuthMethods.identityProvider("apple")).contains("apple");
        assertThat(AuthMethods.identityProvider("sso:acme")).contains("sso:acme");
    }
}
