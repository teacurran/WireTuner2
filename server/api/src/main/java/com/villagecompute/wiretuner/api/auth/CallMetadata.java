package com.villagecompute.wiretuner.api.auth;

import java.util.UUID;

import jakarta.enterprise.context.RequestScoped;

/**
 * What the interceptors read from one call's metadata, bound synchronously while the gRPC context
 * is current and read later inside the reactive continuation (the request scope is propagated
 * across it; the gRPC {@code Context} is not).
 */
@RequestScoped
public class CallMetadata {

    private String requestId;
    private String deviceId;
    private String clientVersion;
    private boolean bearerPresent;
    private String authorization;

    public String requestId() {
        return requestId;
    }

    public void requestId(String value) {
        this.requestId = value;
    }

    /** The raw {@code wt-device} value; {@link #deviceUuid()} is the parsed form. */
    public String deviceId() {
        return deviceId;
    }

    public void deviceId(String value) {
        this.deviceId = value;
    }

    /** The {@code wt-device} id as a UUID, or null when absent or malformed. */
    public UUID deviceUuid() {
        if (deviceId == null) {
            return null;
        }
        try {
            return UUID.fromString(deviceId);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    public String clientVersion() {
        return clientVersion;
    }

    public void clientVersion(String value) {
        this.clientVersion = value;
    }

    public boolean bearerPresent() {
        return bearerPresent;
    }

    public void bearerPresent(boolean value) {
        this.bearerPresent = value;
    }

    /** The raw {@code authorization} header, when it carried a bearer token (a cache key, never logged). */
    public String authorization() {
        return authorization;
    }

    public void authorization(String value) {
        this.authorization = value;
    }
}
