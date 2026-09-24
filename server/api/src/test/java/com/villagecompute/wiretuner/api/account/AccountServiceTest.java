package com.villagecompute.wiretuner.api.account;

import static org.assertj.core.api.Assertions.assertThat;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.UUID;

import javax.sql.DataSource;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.MeRequest;
import com.villagecompute.wiretuner.account.v1.MeResponse;
import com.villagecompute.wiretuner.api.grpc.GrpcMetadata;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.grpc.Metadata;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.grpc.stub.MetadataUtils;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.keycloak.client.KeycloakTestClient;

import jakarta.inject.Inject;

/**
 * SRV-002 end to end: real access tokens from the Dev Service Keycloak (the compose realm file)
 * through the interceptor chain to {@code AccountService.Me}.
 */
@QuarkusTest
class AccountServiceTest {

    static final String EMAIL = "testuser@wiretuner.local";

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @Inject
    DataSource dataSource;

    final KeycloakTestClient keycloak = new KeycloakTestClient();

    /** Every test sees testuser for the first time. */
    @BeforeEach
    void forgetTestUser() throws SQLException {
        update("DELETE FROM account WHERE email = ?", EMAIL);
    }

    @Test
    void firstSightCreatesTheAccountIdentityAndDevice() throws SQLException {
        UUID device = UUID.randomUUID();
        MeResponse me = me(token("wiretuner-mac"), device.toString(), "macos/15.6/arm64", "req-first-sight");

        assertThat(me.getAccount().getEmail()).isEqualTo(EMAIL);
        assertThat(me.getAccount().getDisplayName()).isEqualTo("Test User");
        assertThat(UUID.fromString(me.getAccount().getId())).isNotNull();
        assertThat(me.getAccount().getIdentitiesList()).singleElement().satisfies(identity -> {
            assertThat(identity.getProvider()).isEqualTo("password");
            assertThat(identity.getEmail()).isEqualTo(EMAIL);
            assertThat(identity.getEmailVerified()).isTrue();
            assertThat(identity.getIsRelay()).isFalse();
        });
        assertThat(me.getDevice().getId()).isEqualTo(device.toString());
        // The realm has no wt_auth_method mapper on this client yet (SEC-004): defaulted and logged.
        assertThat(me.getDevice().getAuthMethod()).isEqualTo("password");
        assertThat(me.getDevice().getPlatform()).isEqualTo("macos");
        assertThat(me.getDevice().getCurrent()).isTrue();
        assertThat(me.getDevice().hasRevokedAt()).isFalse();
        assertThat(count("SELECT count(*) FROM device WHERE id = ?", device)).isEqualTo(1);
    }

    @Test
    void aSecondCallReusesTheAccountAndRefreshesTheDevice() throws SQLException {
        String token = token("wiretuner-mac");
        UUID device = UUID.randomUUID();
        MeResponse first = me(token, device.toString(), null, null);
        Instant stale = Instant.now().minusSeconds(3600);
        update("UPDATE device SET last_seen_at = ? WHERE id = ?", Timestamp.from(stale), device);

        MeResponse second = me(token, device.toString(), null, null);

        assertThat(second.getAccount().getId()).isEqualTo(first.getAccount().getId());
        assertThat(second.getAccount().getIdentitiesCount()).isEqualTo(1);
        assertThat(second.getDevice().getLastSeenAt().getSeconds()).isGreaterThan(stale.getEpochSecond());
        assertThat(count("SELECT count(*) FROM account WHERE email = ?", EMAIL)).isEqualTo(1);
    }

    @Test
    void theDeviceRecordsTheMethodOfTheTokenThatCreatedIt() throws SQLException {
        UUID passkeyMac = UUID.randomUUID();
        MeResponse me = me(token("wiretuner-test-passkey"), passkeyMac.toString(), "macos/15.6/arm64", null);
        assertThat(me.getDevice().getAuthMethod()).isEqualTo("passkey");
        // A passkey is registered on an account; it is not a linked identity.
        assertThat(me.getAccount().getIdentitiesList()).isEmpty();

        // The method is recorded once: a later password sign-in on the same Mac does not rewrite it.
        MeResponse later = me(token("wiretuner-mac"), passkeyMac.toString(), null, null);
        assertThat(later.getDevice().getAuthMethod()).isEqualTo("passkey");
        assertThat(later.getAccount().getIdentitiesList()).extracting(i -> i.getProvider()).containsExactly("password");
    }

    @Test
    void aCallWithoutADeviceHasNoDevice() {
        assertThat(me(token("wiretuner-mac"), null, null, null).hasDevice()).isFalse();
    }

    /** TEST-001 finding (d): a device id that is not a UUID is refused rather than read as none. */
    @Test
    void aDeviceThatIsNotAUuidIsRefused() {
        StatusRuntimeException e = meFailure("Bearer " + token("wiretuner-mac"), "not-a-uuid");
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.INVALID_ARGUMENT);
        assertThat(e.getStatus().getDescription()).isEqualTo("wt-device must be a UUID, got \"not-a-uuid\"");
        assertThat(StatusExceptions.reasonOf(e)).isEmpty();
    }

    @Test
    void aRevokedDeviceIsSignedOut() throws SQLException {
        String token = token("wiretuner-mac");
        UUID device = UUID.randomUUID();
        me(token, device.toString(), null, null);
        update("UPDATE device SET revoked_at = now() WHERE id = ?", device);

        StatusRuntimeException e = meFailure("Bearer " + token, device.toString());
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        assertThat(e.getStatus().getDescription()).isEqualTo("device revoked");
    }

    @Test
    void aMissingTokenIsUnauthenticated() {
        StatusRuntimeException e = meFailure(null, null);
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        assertThat(StatusExceptions.reasonOf(e)).isEmpty();
    }

    @Test
    void anInvalidTokenIsUnauthenticated() {
        String token = token("wiretuner-mac");
        String tampered = token.substring(0, token.length() - 4) + (token.endsWith("AAAA") ? "BBBB" : "AAAA");
        for (String authorization : new String[] {"Bearer not-a-jwt", "Bearer " + tampered}) {
            StatusRuntimeException e = meFailure(authorization, null);
            assertThat(e.getStatus().getCode()).as(authorization).isEqualTo(Status.Code.UNAUTHENTICATED);
            assertThat(StatusExceptions.reasonOf(e)).isEmpty();
        }
    }

    @Test
    void anExpiredTokenIsTokenExpired() throws InterruptedException {
        String token = token("wiretuner-test-expiring");
        Thread.sleep(2500);
        StatusRuntimeException e = meFailure("Bearer " + token, null);
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        assertThat(StatusExceptions.errorInfo(e).orElseThrow().getReason()).isEqualTo("TOKEN_EXPIRED");
        assertThat(StatusExceptions.errorInfo(e).orElseThrow().getDomain()).isEqualTo("wiretuner.app");
    }

    String token(String clientId) {
        return keycloak.getAccessToken("testuser", "testpass", clientId, null);
    }

    MeResponse me(String token, String device, String client, String requestId) {
        Metadata headers = new Metadata();
        headers.put(GrpcMetadata.AUTHORIZATION, "Bearer " + token);
        if (device != null) {
            headers.put(GrpcMetadata.WT_DEVICE, device);
        }
        if (client != null) {
            headers.put(GrpcMetadata.WT_CLIENT, client);
        }
        if (requestId != null) {
            headers.put(GrpcMetadata.WT_REQUEST_ID, requestId);
        }
        return account.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers)).me(MeRequest.getDefaultInstance());
    }

    StatusRuntimeException meFailure(String authorization, String device) {
        Metadata headers = new Metadata();
        if (authorization != null) {
            headers.put(GrpcMetadata.AUTHORIZATION, authorization);
        }
        if (device != null) {
            headers.put(GrpcMetadata.WT_DEVICE, device);
        }
        try {
            account.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers)).me(MeRequest.getDefaultInstance());
        } catch (StatusRuntimeException e) {
            return e;
        }
        throw new AssertionError("Me succeeded");
    }

    void update(String sql, Object... args) throws SQLException {
        try (Connection c = dataSource.getConnection(); PreparedStatement s = c.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                s.setObject(i + 1, args[i]);
            }
            s.executeUpdate();
        }
    }

    long count(String sql, Object arg) throws SQLException {
        try (Connection c = dataSource.getConnection(); PreparedStatement s = c.prepareStatement(sql)) {
            s.setObject(1, arg);
            try (ResultSet rs = s.executeQuery()) {
                rs.next();
                return rs.getLong(1);
            }
        }
    }
}
