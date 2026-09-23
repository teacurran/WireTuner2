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
    public static final String VALIDATION_FAILED = "VALIDATION_FAILED";
    public static final String LINK_PASSWORD_REQUIRED = "LINK_PASSWORD_REQUIRED";
    public static final String LINK_INVALID = "LINK_INVALID";

    // Added by SRV-008, SRV-009 and SEC-001.
    public static final String DOCUMENT_EXISTS = "DOCUMENT_EXISTS";
    public static final String SPACE_NOT_FOUND = "SPACE_NOT_FOUND";
    public static final String FOLDER_NOT_FOUND = "FOLDER_NOT_FOUND";
    public static final String HISTORY_UNAVAILABLE = "HISTORY_UNAVAILABLE";
    public static final String BLOB_NOT_FOUND = "BLOB_NOT_FOUND";
    public static final String BLOB_MISMATCH = "BLOB_MISMATCH";
    public static final String TEAM_NOT_FOUND = "TEAM_NOT_FOUND";
    public static final String MEMBER_NOT_FOUND = "MEMBER_NOT_FOUND";
    public static final String INVITE_INVALID = "INVITE_INVALID";
    public static final String SLUG_TAKEN = "SLUG_TAKEN";
    public static final String ALREADY_MEMBER = "ALREADY_MEMBER";
    public static final String DOMAIN_TAKEN = "DOMAIN_TAKEN";
    public static final String DOMAIN_NOT_FOUND = "DOMAIN_NOT_FOUND";
    public static final String OWNER_MUST_TRANSFER = "OWNER_MUST_TRANSFER";
    public static final String TEAM_ROLE_INVALID = "TEAM_ROLE_INVALID";
    public static final String EMAIL_NOT_VERIFIED = "EMAIL_NOT_VERIFIED";
    public static final String SSO_REQUIRED = "SSO_REQUIRED";
    public static final String DOMAIN_UNVERIFIED = "DOMAIN_UNVERIFIED";

    // Added by SRV-011.
    public static final String MERGE_STALE = "MERGE_STALE";

    private ErrorReasons() {
    }
}
