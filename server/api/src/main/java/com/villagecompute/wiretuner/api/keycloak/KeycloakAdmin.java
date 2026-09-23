package com.villagecompute.wiretuner.api.keycloak;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

import io.smallrye.mutiny.Uni;
import io.vertx.core.json.JsonObject;

/**
 * The slice of the Keycloak admin REST API the Apple secret job needs: a token for the admin user
 * (password grant on the admin realm's {@code admin-cli}), and reading and replacing one identity
 * provider of the WireTuner realm. Non-blocking over the JDK HTTP client.
 */
public class KeycloakAdmin {

    /** Where the admin API is and who signs in to it. */
    public record Connection(URI baseUrl, String realm, String adminRealm, String clientId, String username,
            String password) {
    }

    static final Duration TIMEOUT = Duration.ofSeconds(10);

    private final Connection connection;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();

    public KeycloakAdmin(Connection connection) {
        this.connection = connection;
    }

    /** Sets fields of the identity provider's config (a read-modify-write of its representation). */
    public Uni<Void> updateIdentityProviderConfig(String alias, JsonObject config) {
        return token().chain(token -> {
            URI uri = connection.baseUrl().resolve("/admin/realms/" + connection.realm()
                    + "/identity-provider/instances/" + alias);
            return send(HttpRequest.newBuilder(uri).header("Authorization", "Bearer " + token).GET(), 200)
                    .chain(body -> {
                        JsonObject provider = new JsonObject(body);
                        provider.getJsonObject("config").mergeIn(config);
                        return send(HttpRequest.newBuilder(uri).header("Authorization", "Bearer " + token)
                                .header("Content-Type", "application/json")
                                .PUT(HttpRequest.BodyPublishers.ofString(provider.encode())), 204);
                    });
        }).replaceWithVoid();
    }

    Uni<String> token() {
        String form = "grant_type=password&client_id=" + encode(connection.clientId()) + "&username="
                + encode(connection.username()) + "&password=" + encode(connection.password());
        URI uri = connection.baseUrl().resolve("/realms/" + connection.adminRealm() + "/protocol/openid-connect/token");
        return send(HttpRequest.newBuilder(uri).header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form)), 200)
                .map(body -> new JsonObject(body).getString("access_token"));
    }

    /** Sends the request; any status but {@code expected} is a failure naming it. */
    private Uni<String> send(HttpRequest.Builder request, int expected) {
        HttpRequest built = request.timeout(TIMEOUT).build();
        return Uni.createFrom().completionStage(() -> http.sendAsync(built, HttpResponse.BodyHandlers.ofString()))
                .map(response -> {
                    if (response.statusCode() != expected) {
                        throw new IllegalStateException("Keycloak admin " + built.method() + " " + built.uri().getPath()
                                + " answered " + response.statusCode());
                    }
                    return response.body();
                });
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
