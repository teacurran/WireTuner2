package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

import jakarta.json.Json;
import jakarta.json.JsonValue;

class TokenClaimsTest {

    @Test
    void aTokenWithoutTheClaimIsPassword() {
        TokenClaims claims = TokenClaims.of(new FakeJwt().with("sub", "s1"));
        assertThat(claims.subject()).isEqualTo("s1");
        assertThat(claims.authMethod()).isEqualTo("password");
        assertThat(claims.authMethodDefaulted()).isTrue();
        assertThat(claims.email()).isEmpty();
        assertThat(claims.displayName()).isEmpty();
        assertThat(claims.emailVerified()).isFalse();
    }

    @Test
    void anUnknownMethodIsPassword() {
        TokenClaims claims = TokenClaims.of(new FakeJwt().with("sub", "s1").with("wt_auth_method", Json.createValue("magic")));
        assertThat(claims.authMethod()).isEqualTo("password");
        assertThat(claims.authMethodDefaulted()).isTrue();
    }

    @Test
    void customClaimsArriveAsJsonValues() {
        TokenClaims claims = TokenClaims.of(new FakeJwt().with("sub", "s1")
                .with("wt_auth_method", Json.createValue("sso:acme"))
                .with("email", "a@acme.test")
                .with("email_verified", JsonValue.TRUE)
                .with("name", Json.createValue("Ada Lovelace"))
                .with("preferred_username", "ada"));
        assertThat(claims.authMethod()).isEqualTo("sso:acme");
        assertThat(claims.authMethodDefaulted()).isFalse();
        assertThat(claims.email()).isEqualTo("a@acme.test");
        assertThat(claims.emailVerified()).isTrue();
        assertThat(claims.displayName()).isEqualTo("Ada Lovelace");
        assertThat(claims.isRelayEmail()).isFalse();
    }

    @Test
    void standardClaimsArriveAsJavaTypes() {
        TokenClaims claims = TokenClaims.of(new FakeJwt().with("sub", "s1")
                .with("wt_auth_method", "apple")
                .with("email", "abc@PrivateRelay.AppleID.com")
                .with("email_verified", Boolean.TRUE)
                .with("name", JsonValue.NULL)
                .with("preferred_username", "abc"));
        assertThat(claims.authMethod()).isEqualTo("apple");
        assertThat(claims.emailVerified()).isTrue();
        assertThat(claims.displayName()).isEqualTo("abc");
        assertThat(claims.isRelayEmail()).isTrue();
    }

    @Test
    void falseVerification() {
        assertThat(TokenClaims.of(new FakeJwt().with("sub", "s").with("email_verified", Boolean.FALSE)).emailVerified()).isFalse();
        assertThat(TokenClaims.of(new FakeJwt().with("sub", "s").with("email_verified", JsonValue.FALSE)).emailVerified()).isFalse();
    }
}
