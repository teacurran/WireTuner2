package com.villagecompute.wiretuner.api.grpc;

/**
 * The machine-readable {@code google.rpc.ErrorInfo.reason} values of docs/spec/api-conventions.adoc
 * (Errors). Clients branch on these, never on message text.
 */
public final class ErrorReasons {

    /** {@code ErrorInfo.domain} on every WireTuner error. */
    public static final String DOMAIN = "wiretuner.app";

    public static final String TOKEN_EXPIRED = "TOKEN_EXPIRED";
    public static final String ROLE_INSUFFICIENT = "ROLE_INSUFFICIENT";
    public static final String REPLICA_EXPIRED = "REPLICA_EXPIRED";
    public static final String REPLICA_CONFLICT = "REPLICA_CONFLICT";
    public static final String CLIENT_TOO_OLD = "CLIENT_TOO_OLD";
    public static final String SEQ_GAP = "SEQ_GAP";
    public static final String RATE_LIMITED = "RATE_LIMITED";
    public static final String STORAGE_QUOTA = "STORAGE_QUOTA";
    public static final String DOCUMENT_NOT_FOUND = "DOCUMENT_NOT_FOUND";
    public static final String HOST_NOT_ALLOWED = "HOST_NOT_ALLOWED";
    public static final String CREDENTIAL_MISSING = "CREDENTIAL_MISSING";
    public static final String RESPONSE_TOO_LARGE = "RESPONSE_TOO_LARGE";
    public static final String UPSTREAM_ERROR = "UPSTREAM_ERROR";

    private ErrorReasons() {
    }
}
