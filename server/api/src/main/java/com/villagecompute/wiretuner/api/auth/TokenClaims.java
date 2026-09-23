package com.villagecompute.wiretuner.api.auth;

import org.eclipse.microprofile.jwt.Claims;
import org.eclipse.microprofile.jwt.JsonWebToken;
import org.jboss.logging.Logger;

import jakarta.json.JsonString;
import jakarta.json.JsonValue;

/**
 * What the server reads from a validated access token: the Keycloak subject, the asserted email and
 * whether the provider verified it, a display name, and the sign-in method.
 *
 * @param subject the Keycloak subject; the account key
 * @param email the token's {@code email} claim, or empty
 * @param emailVerified the token's {@code email_verified} claim, false when absent
 * @param displayName {@code name}, else {@code preferred_username}, else empty
 * @param authMethod a valid {@code wt_auth_method} value; {@code password} when the claim is absent or invalid
 * @param authMethodDefaulted true when {@code authMethod} was substituted, so the caller can log it
 */
public record TokenClaims(String subject, String email, boolean emailVerified, String displayName,
        String authMethod, boolean authMethodDefaulted) {

    private static final Logger LOG = Logger.getLogger(TokenClaims.class);

    /** Apple private relay addresses link but never count for workspace domains. */
    static final String APPLE_RELAY_SUFFIX = "@privaterelay.appleid.com";

    /** OIDC core's display name claim (MicroProfile JWT's {@code full_name} is not what Keycloak emits). */
    static final String NAME_CLAIM = "name";

    public static TokenClaims of(JsonWebToken jwt) {
        String method = string(jwt, AuthMethods.CLAIM);
        boolean defaulted = !AuthMethods.isValid(method);
        if (defaulted) {
            if (method == null) {
                LOG.infof("token for subject %s carries no %s claim; treating the sign-in as %s",
                        jwt.getSubject(), AuthMethods.CLAIM, AuthMethods.PASSWORD);
            } else {
                LOG.warnf("token for subject %s carries an unknown %s value '%s'; treating the sign-in as %s",
                        jwt.getSubject(), AuthMethods.CLAIM, method, AuthMethods.PASSWORD);
            }
            method = AuthMethods.PASSWORD;
        }
        String name = string(jwt, NAME_CLAIM);
        if (name == null) {
            name = string(jwt, Claims.preferred_username.name());
        }
        return new TokenClaims(jwt.getSubject(), orEmpty(string(jwt, Claims.email.name())),
                bool(jwt, Claims.email_verified.name()), orEmpty(name), method, defaulted);
    }

    public boolean isRelayEmail() {
        return email.toLowerCase().endsWith(APPLE_RELAY_SUFFIX);
    }

    /**
     * A claim as a string. smallrye-jwt returns standard claims as Java types and custom claims as
     * {@link JsonValue}s, so both are accepted.
     */
    static String string(JsonWebToken jwt, String claim) {
        Object value = jwt.getClaim(claim);
        if (value == null || value == JsonValue.NULL) {
            return null;
        }
        if (value instanceof JsonString js) {
            return js.getString();
        }
        return value.toString();
    }

    static boolean bool(JsonWebToken jwt, String claim) {
        Object value = jwt.getClaim(claim);
        if (value instanceof Boolean b) {
            return b;
        }
        return value == JsonValue.TRUE;
    }

    private static String orEmpty(String value) {
        return value == null ? "" : value;
    }
}
