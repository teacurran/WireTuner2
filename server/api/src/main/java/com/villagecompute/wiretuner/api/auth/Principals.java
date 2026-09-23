package com.villagecompute.wiretuner.api.auth;

import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.AccountIdentity;
import com.villagecompute.wiretuner.api.persistence.AccountIdentityId;
import com.villagecompute.wiretuner.api.persistence.AccountIdentityRepository;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.Device;
import com.villagecompute.wiretuner.api.persistence.DeviceId;
import com.villagecompute.wiretuner.api.persistence.DeviceRepository;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.security.identity.CurrentIdentityAssociation;
import io.quarkus.security.identity.SecurityIdentity;
import io.smallrye.mutiny.Uni;

import org.eclipse.microprofile.jwt.JsonWebToken;
import org.jboss.logging.Logger;
import org.jose4j.jwt.consumer.ErrorCodes;
import org.jose4j.jwt.consumer.InvalidJwtException;

import jakarta.enterprise.context.RequestScoped;
import jakarta.inject.Inject;

/**
 * Principal resolution for one call (SRV-002): waits for quarkus-oidc's deferred
 * {@link SecurityIdentity}, maps its failures to {@code UNAUTHENTICATED} (with
 * {@code TOKEN_EXPIRED} when the token's {@code exp} has passed), reads the {@link TokenClaims},
 * and inside one transaction creates the {@code account} row on first sight of a subject, keeps
 * {@code account_identity} in step with the identity the token carries, and records the calling
 * device with the sign-in method it arrived with. The result is memoised for the request.
 */
@RequestScoped
public class Principals {

    private static final Logger LOG = Logger.getLogger(Principals.class);

    /** {@code device.last_seen_at} is refreshed at most this often, to keep the hot path read-only. */
    static final Duration SEEN_REFRESH = Duration.ofMinutes(1);

    @Inject
    CurrentIdentityAssociation identityAssociation;

    @Inject
    CallMetadata callMetadata;

    @Inject
    AccountRepository accounts;

    @Inject
    AccountIdentityRepository identities;

    @Inject
    DeviceRepository devices;

    private Uni<Principal> current;

    /** The caller, resolved once per request. Fails with a WireTuner status error when unauthenticated. */
    public Uni<Principal> current() {
        if (current == null) {
            current = resolve().memoize().indefinitely();
        }
        return current;
    }

    private Uni<Principal> resolve() {
        return identityAssociation.getDeferredIdentity()
                .onFailure().transform(Principals::authenticationFailure)
                .flatMap(this::fromIdentity);
    }

    private Uni<Principal> fromIdentity(SecurityIdentity identity) {
        if (identity.isAnonymous()) {
            return Uni.createFrom().failure(StatusExceptions.unauthenticated("missing bearer token"));
        }
        if (!(identity.getPrincipal() instanceof JsonWebToken jwt)) {
            return Uni.createFrom().failure(StatusExceptions.unauthenticated("bearer token is not a JWT"));
        }
        TokenClaims claims = TokenClaims.of(jwt);
        return Panache.withTransaction(() -> register(claims));
    }

    /** Runs inside the request's transaction (joining the RPC's own when it opened one). */
    Uni<Principal> register(TokenClaims claims) {
        return accounts.findBySubject(claims.subject())
                .flatMap(existing -> existing != null ? Uni.createFrom().item(existing) : createAccount(claims))
                .flatMap(account -> upkeepIdentity(account, claims).replaceWith(account))
                .flatMap(account -> touchDevice(account, claims)
                        .map(deviceId -> new Principal(account.id, account.subject, deviceId, claims.authMethod(),
                                callMetadata.clientVersion(), callMetadata.requestId())));
    }

    private Uni<Account> createAccount(TokenClaims claims) {
        Account account = new Account();
        account.id = UUID.randomUUID();
        account.subject = claims.subject();
        account.email = claims.email();
        account.displayName = claims.displayName();
        LOG.infof("first sight of subject %s: creating account %s", claims.subject(), account.id);
        return accounts.persist(account);
    }

    private Uni<Void> upkeepIdentity(Account account, TokenClaims claims) {
        return AuthMethods.identityProvider(claims.authMethod())
                .map(provider -> {
                    AccountIdentityId id = new AccountIdentityId(provider, claims.subject());
                    return identities.findById(id).flatMap(existing -> {
                        if (existing != null) {
                            return Uni.createFrom().voidItem();
                        }
                        AccountIdentity identity = new AccountIdentity();
                        identity.id = id;
                        identity.accountId = account.id;
                        identity.email = claims.email();
                        identity.emailVerified = claims.emailVerified();
                        identity.relay = claims.isRelayEmail();
                        LOG.infof("linking identity %s to account %s", provider, account.id);
                        return identities.persist(identity).replaceWithVoid();
                    });
                })
                .orElseGet(() -> Uni.createFrom().voidItem());
    }

    /** Creates or refreshes the device row; a revoked device is refused. Returns the device id, or null. */
    private Uni<UUID> touchDevice(Account account, TokenClaims claims) {
        UUID deviceId = callMetadata.deviceUuid();
        if (deviceId == null) {
            return Uni.createFrom().nullItem();
        }
        DeviceId id = new DeviceId(account.id, deviceId);
        return devices.findById(id).flatMap(existing -> {
            if (existing == null) {
                Device device = new Device();
                device.id = id;
                device.authMethod = claims.authMethod();
                device.platform = platformOf(callMetadata.clientVersion());
                LOG.infof("first sight of device %s for account %s, signed in by %s", deviceId, account.id,
                        claims.authMethod());
                return devices.persist(device).replaceWith(deviceId);
            }
            if (existing.revokedAt != null) {
                return Uni.createFrom().failure(StatusExceptions.unauthenticated("device revoked"));
            }
            Instant now = Instant.now();
            if (existing.lastSeenAt.plus(SEEN_REFRESH).isBefore(now)) {
                existing.lastSeenAt = now;
            }
            return Uni.createFrom().item(deviceId);
        });
    }

    /** {@code macos/15.6/arm64} to {@code macos}: the platform half of {@code wt-client}. */
    static String platformOf(String clientVersion) {
        if (clientVersion == null) {
            return "";
        }
        int slash = clientVersion.indexOf('/');
        return slash < 0 ? clientVersion : clientVersion.substring(0, slash);
    }

    /** quarkus-oidc's failure, as the status the client should branch on. */
    static Throwable authenticationFailure(Throwable failure) {
        if (isExpired(failure)) {
            return StatusExceptions.tokenExpired();
        }
        LOG.debugf(failure, "bearer token rejected");
        return StatusExceptions.unauthenticated("invalid bearer token");
    }

    /** True when the cause chain holds jose4j's verdict that {@code exp} has passed. */
    static boolean isExpired(Throwable failure) {
        for (Throwable t = failure; t != null; t = t.getCause()) {
            if (t instanceof InvalidJwtException jwt && jwt.hasErrorCode(ErrorCodes.EXPIRED)) {
                return true;
            }
        }
        return false;
    }
}
