package com.villagecompute.wiretuner.api.data;

import java.nio.charset.StandardCharsets;

import com.villagecompute.wiretuner.data.v1.CredentialKind;
import com.villagecompute.wiretuner.data.v1.PutCredentialRequest;

import io.vertx.core.json.JsonObject;

/**
 * A credential's secret material in clear, alive only inside one request (data-merge.adoc, Secret
 * store). Encoded as JSON before sealing; {@link #toString} never shows a value, so a secret that
 * reaches a log line prints as {@code <redacted>}.
 */
public record Secret(String token, String username, String password, String headerName, String headerValue,
        String clientId, String clientSecret, String tokenUrl, String oauthScope) {

    public static final String REDACTED = "<redacted>";

    /** The secret fields of a put; the request's validation already matched them to the kind. */
    public static Secret of(PutCredentialRequest request) {
        return new Secret(request.getToken(), request.getUsername(), request.getPassword(), request.getHeaderName(),
                request.getHeaderValue(), request.getClientId(), request.getClientSecret(), request.getTokenUrl(),
                request.getOauthScope());
    }

    byte[] encode() {
        return new JsonObject()
                .put("token", token).put("username", username).put("password", password)
                .put("header_name", headerName).put("header_value", headerValue)
                .put("client_id", clientId).put("client_secret", clientSecret)
                .put("token_url", tokenUrl).put("oauth_scope", oauthScope)
                .encode().getBytes(StandardCharsets.UTF_8);
    }

    static Secret decode(byte[] json) {
        JsonObject o = new JsonObject(new String(json, StandardCharsets.UTF_8));
        return new Secret(o.getString("token"), o.getString("username"), o.getString("password"),
                o.getString("header_name"), o.getString("header_value"), o.getString("client_id"),
                o.getString("client_secret"), o.getString("token_url"), o.getString("oauth_scope"));
    }

    @Override
    public String toString() {
        return "Secret" + REDACTED;
    }

    /** The stored name of a kind. */
    static String kindName(CredentialKind kind) {
        return switch (kind) {
            case CREDENTIAL_KIND_BEARER -> "bearer";
            case CREDENTIAL_KIND_BASIC -> "basic";
            case CREDENTIAL_KIND_HEADER -> "header";
            default -> "oauth2_client";
        };
    }

    /** The kind a stored name names; the schema's CHECK keeps the set closed. */
    static CredentialKind kind(String name) {
        return switch (name) {
            case "bearer" -> CredentialKind.CREDENTIAL_KIND_BEARER;
            case "basic" -> CredentialKind.CREDENTIAL_KIND_BASIC;
            case "header" -> CredentialKind.CREDENTIAL_KIND_HEADER;
            default -> CredentialKind.CREDENTIAL_KIND_OAUTH2_CLIENT;
        };
    }
}
