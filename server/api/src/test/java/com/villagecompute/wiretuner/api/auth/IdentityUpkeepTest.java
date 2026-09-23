package com.villagecompute.wiretuner.api.auth;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.persistence.AccountIdentity;
import com.villagecompute.wiretuner.api.persistence.AccountIdentityRepository;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.DeviceId;
import com.villagecompute.wiretuner.api.persistence.DeviceRepository;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SRV-002 {@code account_identity} upkeep for methods the local realm cannot mint yet (Apple, a
 * workspace IdP: SEC-004): a token carrying an unseen identity links it to the subject's account.
 */
@QuarkusTest
class IdentityUpkeepTest {

    @Inject AccountRepository accounts;
    @Inject AccountIdentityRepository identities;
    @Inject DeviceRepository devices;
    @Inject SignInEffects signIn;

    @Test
    void anUnseenIdentityIsLinkedOnceToTheSameAccount() {
        String subject = "upkeep-" + UUID.randomUUID();
        UUID device = UUID.randomUUID();
        Principals principals = principals(device.toString(), "macos/15.6/arm64");

        Principal apple = tx(() -> principals.register(
                new TokenClaims(subject, "x1@privaterelay.appleid.com", true, "Relay", "apple", false)));
        assertThat(apple.authMethod()).isEqualTo("apple");
        assertThat(apple.deviceId()).isEqualTo(device);
        assertThat(apple.clientVersion()).isEqualTo("macos/15.6/arm64");
        assertThat(apple.requestId()).isEqualTo("req-upkeep");
        assertThat(tx(() -> devices.findById(new DeviceId(apple.accountId(), device))).authMethod).isEqualTo("apple");

        Principal sso = tx(() -> principals.register(new TokenClaims(subject, "ada@acme.test", true, "Ada", "sso:acme", false)));
        tx(() -> principals.register(new TokenClaims(subject, "ada@acme.test", true, "Ada", "sso:acme", false)));

        assertThat(sso.accountId()).isEqualTo(apple.accountId());
        assertThat(tx(() -> identities.listForAccount(apple.accountId())))
                .extracting(i -> i.id.provider(), i -> i.email, i -> i.relay, i -> i.emailVerified)
                .containsExactly(
                        org.assertj.core.groups.Tuple.tuple("apple", "x1@privaterelay.appleid.com", true, true),
                        org.assertj.core.groups.Tuple.tuple("sso:acme", "ada@acme.test", false, true));
        assertThat(tx(() -> accounts.findBySubject(subject)).displayName).isEqualTo("Relay");
    }

    @Test
    void anUnverifiedEmailIsRecordedAsUnverified() {
        String subject = "upkeep-" + UUID.randomUUID();
        Principal p = tx(() -> principals(null, null).register(
                new TokenClaims(subject, "someone@example.test", false, "", "password", true)));
        AccountIdentity identity = tx(() -> identities.listForAccount(p.accountId())).get(0);
        assertThat(identity.emailVerified).isFalse();
        assertThat(p.deviceId()).isNull();
    }

    Principals principals(String device, String client) {
        Principals principals = new Principals();
        principals.accounts = accounts;
        principals.identities = identities;
        principals.devices = devices;
        principals.signIn = signIn;
        principals.callMetadata = new CallMetadata();
        principals.callMetadata.deviceId(device);
        principals.callMetadata.clientVersion(client);
        principals.callMetadata.requestId("req-upkeep");
        return principals;
    }
}
