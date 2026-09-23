package com.villagecompute.wiretuner.api.keycloak;

import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Uni;
import io.vertx.core.json.JsonObject;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The Apple secret job (docs/spec/server.adoc, Jobs; D-064): every 30 days it signs a new Sign in with
 * Apple client secret ({@link AppleClientSecret}, valid for {@code wt.apple.secret-lifetime}, 180 days)
 * and writes it, with the Services ID, into the realm's {@code apple} identity provider through the
 * Keycloak admin API, so the secret never expires in service. It runs at start too (after
 * {@code wt.apple.rotate-delay}). Without the team id, key id, Services ID and {@code .p8} key
 * ({@code WT_APPLE_TEAM_ID}, {@code WT_APPLE_KEY_ID}, {@code WT_APPLE_CLIENT_ID},
 * {@code WT_APPLE_PRIVATE_KEY}) it does nothing, which is the local default.
 */
@ApplicationScoped
public class AppleSecretJob {

    private static final Logger LOG = Logger.getLogger(AppleSecretJob.class);

    @ConfigProperty(name = "wt.apple.team-id")
    Optional<String> teamId;

    @ConfigProperty(name = "wt.apple.key-id")
    Optional<String> keyId;

    @ConfigProperty(name = "wt.apple.client-id")
    Optional<String> clientId;

    @ConfigProperty(name = "wt.apple.private-key")
    Optional<String> privateKey;

    @ConfigProperty(name = "wt.apple.idp-alias", defaultValue = "apple")
    String alias;

    @ConfigProperty(name = "wt.apple.secret-lifetime", defaultValue = "180D")
    Duration lifetime;

    @ConfigProperty(name = "wt.keycloak.url")
    URI keycloakUrl;

    @ConfigProperty(name = "wt.keycloak.realm", defaultValue = "wiretuner")
    String realm;

    @ConfigProperty(name = "wt.keycloak.admin-realm", defaultValue = "master")
    String adminRealm;

    @ConfigProperty(name = "wt.keycloak.admin-client-id", defaultValue = "admin-cli")
    String adminClientId;

    @ConfigProperty(name = "wt.keycloak.admin-username", defaultValue = "admin")
    String adminUsername;

    @ConfigProperty(name = "wt.keycloak.admin-password", defaultValue = "admin")
    String adminPassword;

    @Inject
    JobLocks locks;

    @Scheduled(identity = "apple-secret", every = "${wt.apple.rotate-every:720h}",
            delayed = "${wt.apple.rotate-delay:30s}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        Optional<AppleClientSecret.Signer> signer = signer();
        if (signer.isEmpty()) {
            LOG.debug("Sign in with Apple is not configured; not rotating its client secret");
            return Uni.createFrom().voidItem();
        }
        KeycloakAdmin admin = new KeycloakAdmin(new KeycloakAdmin.Connection(keycloakUrl, realm, adminRealm,
                adminClientId, adminUsername, adminPassword));
        return locks.exclusively("apple-secret", () -> rotate(signer.get(), admin, Instant.now())).replaceWithVoid();
    }

    /** The configured signer, when all four Apple values are set. */
    Optional<AppleClientSecret.Signer> signer() {
        return teamId.flatMap(team -> keyId.flatMap(key -> clientId.flatMap(client -> privateKey
                .map(pem -> new AppleClientSecret.Signer(team, key, client, pem)))));
    }

    /** Signs a secret valid from {@code now} and stores it, with the Services ID, in the identity provider. */
    Uni<Void> rotate(AppleClientSecret.Signer signer, KeycloakAdmin admin, Instant now) {
        String secret = AppleClientSecret.sign(signer, now, lifetime);
        return admin.updateIdentityProviderConfig(alias, new JsonObject()
                        .put("clientId", signer.clientId())
                        .put("clientSecret", secret))
                .invoke(() -> LOG.infof("rotated the Sign in with Apple client secret of identity provider %s", alias));
    }
}
