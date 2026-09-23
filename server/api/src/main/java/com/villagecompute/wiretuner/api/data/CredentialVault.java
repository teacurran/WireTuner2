package com.villagecompute.wiretuner.api.data;

import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Credentials in use (data-merge.adoc, Secret store and Fetch proxy; DATA-005, DATA-006): the one place
 * a secret is opened -- in memory, for one request -- and turned into the header the upstream expects.
 * For {@code OAUTH2_CLIENT} the access token comes from a client-credentials grant against the
 * credential's token URL (client authentication by HTTP Basic, RFC 6749 2.3.1), through the same SSRF
 * guard, and is cached in memory until 60 s before it expires; replacing the credential starts a new
 * cache entry. Concurrent requests share one token request.
 */
@ApplicationScoped
public class CredentialVault {

    static final Duration TOKEN_TIMEOUT = Duration.ofSeconds(30);
    static final long TOKEN_CAP = 1024 * 1024;
    static final long EXPIRY_MARGIN_S = 60;

    /** An opened credential: its row and its secret. Lives for one call. */
    public record Opened(CredentialRepository.Stored stored, Secret secret) {

        /** The request header name this credential sets, lower case. */
        public String headerName() {
            return "header".equals(stored.kind()) ? secret.headerName().toLowerCase(java.util.Locale.ROOT) : "authorization";
        }
    }

    /** One cached (or pending) access token; expires {@value #EXPIRY_MARGIN_S} s before the grant says. */
    static final class Token {
        Uni<String> value;
        volatile long expiresAt = Long.MAX_VALUE;

        boolean expired() {
            return System.nanoTime() - expiresAt >= 0;
        }
    }

    @Inject
    CredentialRepository repository;

    @Inject
    MasterKeys keys;

    @Inject
    Egress egress;

    final Map<String, Token> tokens = new ConcurrentHashMap<>();

    /** The named credential of the scope, opened; {@code CREDENTIAL_MISSING} when the scope holds none. */
    public Uni<Opened> open(DataScope scope, String name) {
        return repository.find(scope, name).map(stored -> {
            if (stored == null) {
                throw StatusExceptions.credentialMissing(name);
            }
            return new Opened(stored, Secret.decode(keys.envelope().open(stored.sealed(), scope.aad(name))));
        });
    }

    /** The header carrying the credential; an OAuth token is fetched (once, then cached) through {@code pins}. */
    public Uni<Map.Entry<String, String>> header(DataScope scope, Opened credential, Egress.Pins pins) {
        Secret secret = credential.secret();
        return switch (credential.stored().kind()) {
            case "bearer" -> Uni.createFrom().item(Map.entry("authorization", "Bearer " + secret.token()));
            case "basic" -> Uni.createFrom().item(Map.entry("authorization", "Basic " + basic(secret.username(), secret.password())));
            case "header" -> Uni.createFrom().item(Map.entry(credential.headerName(), secret.headerValue()));
            default -> token(scope, credential, pins).map(token -> Map.entry("authorization", "Bearer " + token));
        };
    }

    static String basic(String user, String password) {
        return Base64.getEncoder().encodeToString((user + ":" + password).getBytes(StandardCharsets.UTF_8));
    }

    private Uni<String> token(DataScope scope, Opened credential, Egress.Pins pins) {
        CredentialRepository.Stored stored = credential.stored();
        String key = scope.key() + "/" + stored.id() + "/" + (stored.rotatedAt() == null ? stored.createdAt() : stored.rotatedAt());
        Token token = tokens.compute(key, (k, cached) -> cached != null && !cached.expired() ? cached
                : pending(credential.secret(), pins));
        return token.value.onFailure().invoke(() -> tokens.remove(key, token));
    }

    private Token pending(Secret secret, Egress.Pins pins) {
        Token token = new Token();
        token.value = requestToken(secret, pins).map(grant -> {
            token.expiresAt = System.nanoTime() + Math.max(0, grant.expiresInSeconds() - EXPIRY_MARGIN_S) * 1_000_000_000L;
            return grant.accessToken();
        }).memoize().indefinitely();
        return token;
    }

    /** One client-credentials grant. */
    Uni<Grant> requestToken(Secret secret, Egress.Pins pins) {
        URI url = HostNames.parse(secret.tokenUrl(), "token_url");
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("authorization", "Basic " + basic(Templates.encode(secret.clientId()), Templates.encode(secret.clientSecret())));
        headers.put("content-type", "application/x-www-form-urlencoded");
        headers.put("accept", "application/json");
        String form = "grant_type=client_credentials"
                + (secret.oauthScope().isEmpty() ? "" : "&scope=" + Templates.encode(secret.oauthScope()));
        return egress.send(new Egress.Request("POST", url, headers, form.getBytes(StandardCharsets.UTF_8), TOKEN_TIMEOUT,
                TOKEN_CAP), pins).map(reply -> {
                    if (reply.status() / 100 != 2) {
                        throw StatusExceptions.upstreamError(reply.status());
                    }
                    return grant(reply.body());
                });
    }

    /** A token response's access token and lifetime. */
    record Grant(String accessToken, long expiresInSeconds) {
    }

    static Grant grant(byte[] body) {
        Object json;
        try {
            json = JsonTree.parse(body);
        } catch (IOException e) {
            json = null;
        }
        if (!(json instanceof Map<?, ?> map) || !(map.get("access_token") instanceof String token) || token.isEmpty()) {
            throw StatusExceptions.upstreamFailed("the token endpoint answered without an access token");
        }
        long expiresIn = map.get("expires_in") instanceof JsonTree.Num num ? (long) Double.parseDouble(num.text()) : 0;
        return new Grant(token, expiresIn);
    }
}
