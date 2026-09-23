package com.villagecompute.wiretuner.api.auth;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.AccountIdentityRepository;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.DeviceRepository;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SEC-002 and SEC-004 at sign-in: account linking by verified email only, a race-free first sight,
 * and auto-admit to workspaces whose verified domain matches a verified, non-relay address.
 */
@QuarkusTest
class SignInTest extends ServiceTestSupport {

    @Inject AccountRepository accounts;
    @Inject AccountIdentityRepository identities;
    @Inject DeviceRepository devices;
    @Inject SignInEffects signIn;

    Principals principals(UUID device) {
        Principals principals = new Principals();
        principals.accounts = accounts;
        principals.identities = identities;
        principals.devices = devices;
        principals.signIn = signIn;
        principals.callMetadata = new CallMetadata();
        principals.callMetadata.deviceId(device == null ? null : device.toString());
        principals.callMetadata.requestId("req-sign-in");
        return principals;
    }

    Principal register(UUID device, TokenClaims claims) {
        return tx(() -> principals(device).register(claims));
    }

    static TokenClaims claims(String subject, String email, boolean verified, String method) {
        return new TokenClaims(subject, email, verified, "Someone", method, false);
    }

    @Test
    void anUnverifiedIdentityNeverLinksToAnExistingAccount() {
        String subject = "link-" + UUID.randomUUID();
        Principal first = register(null, claims(subject, "p@example.test", true, "password"));
        Throwable refused = null;
        try {
            register(null, claims(subject, "p@example.test", false, "sso:acme"));
        } catch (RuntimeException e) {
            refused = e;
        }
        assertThat(StatusExceptions.reasonOf(refused)).contains(ErrorReasons.EMAIL_NOT_VERIFIED);
        // A verified one links; a passkey is no identity and needs none.
        register(null, claims(subject, "p@example.test", true, "apple"));
        assertThat(register(null, claims(subject, "p@example.test", false, "passkey")).accountId())
                .isEqualTo(first.accountId());
        assertThat(tx(() -> identities.listForAccount(first.accountId()))).extracting(i -> i.id.provider())
                .containsExactly("password", "apple");
    }

    @Test
    void concurrentFirstSightsMakeOneAccount() {
        String subject = "race-" + UUID.randomUUID();
        List<CompletableFuture<Principal>> calls = List.of(
                CompletableFuture.supplyAsync(() -> register(UUID.randomUUID(), claims(subject, "r@example.test", true, "password"))),
                CompletableFuture.supplyAsync(() -> register(UUID.randomUUID(), claims(subject, "r@example.test", true, "password"))),
                CompletableFuture.supplyAsync(() -> register(UUID.randomUUID(), claims(subject, "r@example.test", true, "password"))));
        List<UUID> ids = calls.stream().map(CompletableFuture::join).map(Principal::accountId).distinct().toList();
        assertThat(ids).hasSize(1);
        assertThat(count("SELECT count(*) FROM account WHERE subject = ?", subject)).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM account_identity WHERE provider_subject = ?", subject)).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM device WHERE account_id = ?", ids.get(0))).isEqualTo(3);
    }

    /** A live team whose workspace auto-admits and has verified {@code domain}; returns the team. */
    UUID workspace(String domain, boolean requireSso) {
        UUID owner = register(null, claims("owner-" + UUID.randomUUID(), "", true, "password")).accountId();
        UUID team = team(owner, "editor");
        exec("INSERT INTO workspace (team_id, sso_idp_alias, require_sso, auto_admit) VALUES (?, 'acme', ?, true)", team,
                requireSso);
        exec("INSERT INTO workspace_domain (team_id, domain, verification_token, verified_at) VALUES (?, ?, 't', now())",
                team, domain);
        return team;
    }

    boolean member(UUID team, UUID account) {
        return count("SELECT count(*) FROM team_member WHERE team_id = ? AND account_id = ?", team, account) == 1;
    }

    @Test
    void aVerifiedAddressOnAVerifiedDomainIsAdmittedAtSignIn() {
        String domain = "d" + UUID.randomUUID().toString().substring(0, 8) + ".example";
        UUID team = workspace(domain, false);
        // Unverified: not admitted.
        Principal unverified = register(UUID.randomUUID(), claims("u-" + UUID.randomUUID(), "u@" + domain, false, "password"));
        assertThat(member(team, unverified.accountId())).isFalse();
        // Verified, in upper case: admitted as a member, once.
        String subject = "v-" + UUID.randomUUID();
        Principal ada = register(UUID.randomUUID(), claims(subject, "Ada@" + domain.toUpperCase(), true, "password"));
        assertThat(member(team, ada.accountId())).isTrue();
        assertThat(value("SELECT role FROM team_member WHERE team_id = ? AND account_id = ?", team, ada.accountId()))
                .isEqualTo("member");
        register(UUID.randomUUID(), claims(subject, "Ada@" + domain, true, "password"));
        // A deleted team admits nobody.
        exec("UPDATE team SET deleted_at = now() WHERE id = ?", team);
        Principal late = register(UUID.randomUUID(), claims("l-" + UUID.randomUUID(), "late@" + domain, true, "password"));
        assertThat(member(team, late.accountId())).isFalse();
    }

    @Test
    void anAppleRelayAddressNeverMatchesAWorkspaceDomain() {
        exec("DELETE FROM workspace_domain WHERE domain = 'privaterelay.appleid.com'");
        UUID team = workspace("privaterelay.appleid.com", false);
        Principal relay = register(UUID.randomUUID(), claims("relay-" + UUID.randomUUID(), "x1y2@privaterelay.appleid.com",
                true, "apple"));
        assertThat(member(team, relay.accountId())).isFalse();
        assertThat(value("SELECT is_relay FROM account_identity WHERE account_id = ?", relay.accountId())).isEqualTo(true);
        exec("DELETE FROM workspace_domain WHERE team_id = ?", team);
    }

    @Test
    void aWorkspaceThatRequiresSsoAdmitsOnlyItsSsoSessions() {
        String domain = "s" + UUID.randomUUID().toString().substring(0, 8) + ".example";
        UUID team = workspace(domain, true);
        String subject = "sso-" + UUID.randomUUID();
        Principal byPassword = register(UUID.randomUUID(), claims(subject, "grace@" + domain, true, "password"));
        assertThat(member(team, byPassword.accountId())).isFalse();
        register(UUID.randomUUID(), claims(subject, "grace@" + domain, true, "sso:acme"));
        assertThat(member(team, byPassword.accountId())).isTrue();
    }
}
