package com.villagecompute.wiretuner.api.grpc;

import io.grpc.Metadata;

/** The request metadata keys of docs/spec/api-conventions.adoc (Metadata). */
public final class GrpcMetadata {

    /** {@code Bearer <access token>} from Keycloak, on every call. */
    public static final Metadata.Key<String> AUTHORIZATION = key("authorization");
    /** {@code macos/<app version>/<build>}: feature gating and {@code CLIENT_TOO_OLD}. */
    public static final Metadata.Key<String> WT_CLIENT = key("wt-client");
    /** Stable per-install device id (not the replica id), for the account's device list. */
    public static final Metadata.Key<String> WT_DEVICE = key("wt-device");
    /** Client-generated id echoed into server logs and traces. */
    public static final Metadata.Key<String> WT_REQUEST_ID = key("wt-request-id");

    private GrpcMetadata() {
    }

    private static Metadata.Key<String> key(String name) {
        return Metadata.Key.of(name, Metadata.ASCII_STRING_MARSHALLER);
    }
}
