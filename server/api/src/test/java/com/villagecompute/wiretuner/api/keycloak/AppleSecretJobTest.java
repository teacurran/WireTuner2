package com.villagecompute.wiretuner.api.keycloak;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.spec.ECGenParameterSpec;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CopyOnWriteArrayList;

import org.eclipse.microprofile.config.ConfigProvider;
import org.jose4j.jws.JsonWebSignature;
import org.jose4j.jwt.JwtClaims;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.keycloak.client.KeycloakTestClient;
import io.quarkus.vertx.VertxContextSupport;
import io.smallrye.mutiny.Uni;
import io.vertx.core.json.JsonObject;

import jakarta.inject.Inject;

/**
 * SEC-004: the Apple secret job signs a Sign in with Apple client secret with the team's key and
 * writes it into the {@code apple} identity provider through the Keycloak admin API -- against a
 * fake admin endpoint (to read back exactly what was written) and against the test realm (after which
 * a sign-in still succeeds).
 */
@QuarkusTest
class AppleSecretJobTest {

    @Inject
    JobLocks locks;

    HttpServer server;
    final List<String> requests = new CopyOnWriteArrayList<>();
    final List<String> written = new CopyOnWriteArrayList<>();
    int getStatus = 200;

    KeyPair key;
    AppleClientSecret.Signer signer;

    @BeforeEach
    void setUp() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        key = generator.generateKeyPair();
        String pem = "-----BEGIN PRIVATE KEY-----\n"
                + Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.US_ASCII)).encodeToString(key.getPrivate().getEncoded())
                + "\n-----END PRIVATE KEY-----\n";
        signer = new AppleClientSecret.Signer("TEAM123456", "KEY1234567", "app.wiretuner.signin.test", pem);

        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/realms/master/protocol/openid-connect/token", exchange -> {
            requests.add("token " + new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            reply(exchange, 200, "{\"access_token\":\"admin-token\"}");
        });
        server.createContext("/admin/realms/wiretuner/identity-provider/instances/apple", exchange -> {
            requests.add(exchange.getRequestMethod() + " " + exchange.getRequestHeaders().getFirst("Authorization"));
            if ("GET".equals(exchange.getRequestMethod())) {
                reply(exchange, getStatus, "{\"alias\":\"apple\",\"enabled\":true,\"config\":{\"clientId\":\"old\","
                        + "\"clientSecret\":\"**********\",\"issuer\":\"https://appleid.apple.com\"}}");
            } else {
                written.add(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
                exchange.sendResponseHeaders(204, -1);
                exchange.close();
            }
        });
        server.start();
    }

    @AfterEach
    void tearDown() {
        server.stop(0);
    }

    static void reply(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        exchange.getResponseBody().write(bytes);
        exchange.close();
    }

    URI fake() {
        return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/");
    }

    AppleSecretJob job(boolean configured) {
        AppleSecretJob job = new AppleSecretJob();
        job.teamId = configured ? Optional.of(signer.teamId()) : Optional.empty();
        job.keyId = Optional.of(signer.keyId());
        job.clientId = Optional.of(signer.clientId());
        job.privateKey = Optional.of(signer.privateKeyPem());
        job.alias = "apple";
        job.lifetime = Duration.ofDays(180);
        job.keycloakUrl = fake();
        job.realm = "wiretuner";
        job.adminRealm = "master";
        job.adminClientId = "admin-cli";
        job.adminUsername = "admin";
        job.adminPassword = "s3cret&pw";
        job.locks = locks;
        return job;
    }

    static <T> T run(java.util.function.Supplier<Uni<T>> work) {
        try {
            return VertxContextSupport.subscribeAndAwait(work::get);
        } catch (RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }

    @Test
    void theJobWritesAFreshlySignedSecretAndTheServicesId() throws Exception {
        Instant before = Instant.now();
        run(job(true)::scheduled);
        assertThat(requests).containsExactly("token grant_type=password&client_id=admin-cli&username=admin&password=s3cret%26pw",
                "GET Bearer admin-token", "PUT Bearer admin-token");
        JsonObject provider = new JsonObject(written.get(0));
        JsonObject config = provider.getJsonObject("config");
        assertThat(provider.getString("alias")).isEqualTo("apple");
        assertThat(config.getString("clientId")).isEqualTo("app.wiretuner.signin.test");
        assertThat(config.getString("issuer")).isEqualTo("https://appleid.apple.com");

        JsonWebSignature jws = new JsonWebSignature();
        jws.setCompactSerialization(config.getString("clientSecret"));
        jws.setKey(key.getPublic());
        assertThat(jws.verifySignature()).isTrue();
        assertThat(jws.getAlgorithmHeaderValue()).isEqualTo("ES256");
        assertThat(jws.getKeyIdHeaderValue()).isEqualTo("KEY1234567");
        JwtClaims claims = JwtClaims.parse(jws.getPayload());
        assertThat(claims.getIssuer()).isEqualTo("TEAM123456");
        assertThat(claims.getSubject()).isEqualTo("app.wiretuner.signin.test");
        assertThat(claims.getAudience()).containsExactly("https://appleid.apple.com");
        assertThat(claims.getIssuedAt().getValue()).isBetween(before.getEpochSecond(), Instant.now().getEpochSecond());
        assertThat(claims.getExpirationTime().getValue() - claims.getIssuedAt().getValue())
                .isEqualTo(Duration.ofDays(180).toSeconds());
    }

    @Test
    void unconfiguredItDoesNothingAndAFailedCallFailsTheRun() {
        run(job(false)::scheduled);
        assertThat(requests).isEmpty();
        getStatus = 404;
        assertThatThrownBy(() -> run(() -> job(true).rotate(signer, new KeycloakAdmin(new KeycloakAdmin.Connection(fake(),
                "wiretuner", "master", "admin-cli", "admin", "admin")), Instant.now())))
                .hasMessageContaining("GET /admin/realms/wiretuner/identity-provider/instances/apple answered 404");
        assertThat(written).isEmpty();
    }

    @Test
    void aSecretNeverOutlivesSixMonthsAndNeedsAnEcKey() throws Exception {
        Instant now = Instant.parse("2026-09-23T00:00:00Z");
        JsonWebSignature jws = new JsonWebSignature();
        jws.setCompactSerialization(AppleClientSecret.sign(signer, now, Duration.ofDays(400)));
        JwtClaims claims = JwtClaims.parse(jws.getUnverifiedPayload());
        assertThat(claims.getExpirationTime().getValue() - now.getEpochSecond())
                .isEqualTo(AppleClientSecret.MAX_LIFETIME.toSeconds());
        AppleClientSecret.Signer broken = new AppleClientSecret.Signer("T", "K", "C", "-----BEGIN PRIVATE KEY-----\nAAAA\n");
        assertThatThrownBy(() -> AppleClientSecret.sign(broken, now, Duration.ofDays(1)))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("PKCS#8");
        assertThatThrownBy(() -> AppleClientSecret.sign(new AppleClientSecret.Signer("T", "K", "C", "not base64!"), now,
                Duration.ofDays(1))).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void theTestRealmTakesTheSecretAndSignInStillWorks() {
        String authServer = ConfigProvider.getConfig().getValue("quarkus.oidc.auth-server-url", String.class);
        URI keycloak = URI.create(authServer.substring(0, authServer.indexOf("/realms/")) + "/");
        KeycloakAdmin admin = new KeycloakAdmin(new KeycloakAdmin.Connection(keycloak, "wiretuner", "master", "admin-cli",
                "admin", "admin"));
        run(() -> job(true).rotate(signer, admin, Instant.now()));
        assertThat(new KeycloakTestClient().getAccessToken("alice", "testpass", "wiretuner-mac", null)).isNotBlank();
    }
}
