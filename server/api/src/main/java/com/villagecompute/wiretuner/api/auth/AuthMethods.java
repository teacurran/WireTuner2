package com.villagecompute.wiretuner.api.auth;

import java.util.Optional;

/**
 * The {@code wt_auth_method} access-token claim (docs/spec/security.adoc, Accounts): {@code passkey},
 * {@code apple}, {@code password} or {@code sso:<idp alias>}. A token without the claim, or with a
 * value outside that set, is treated as {@code password}; callers log that.
 */
public final class AuthMethods {

    public static final String CLAIM = "wt_auth_method";
    public static final String PASSKEY = "passkey";
    public static final String APPLE = "apple";
    public static final String PASSWORD = "password";
    public static final String SSO_PREFIX = "sso:";

    private AuthMethods() {
    }

    /** True for a value the claim may legitimately carry. */
    public static boolean isValid(String value) {
        if (value == null) {
            return false;
        }
        return switch (value) {
            case PASSKEY, APPLE, PASSWORD -> true;
            default -> value.startsWith(SSO_PREFIX) && value.length() > SSO_PREFIX.length();
        };
    }

    /**
     * The {@code account_identity.provider} a sign-in by this method links, if the method is an
     * identity: {@code password}, {@code apple} or {@code sso:<alias>}. A passkey is not an identity
     * (it is registered on an account that is already signed in), so it links nothing.
     */
    public static Optional<String> identityProvider(String method) {
        return PASSKEY.equals(method) ? Optional.empty() : Optional.of(method);
    }
}
