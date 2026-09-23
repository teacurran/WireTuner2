package com.villagecompute.wiretuner.api.auth;

import java.util.UUID;

/**
 * The resolved caller of one RPC (SRV-002).
 *
 * @param accountId the account row; created on first sight of the subject
 * @param subject the Keycloak subject
 * @param deviceId the {@code wt-device} id, or null when the call carried none
 * @param authMethod the token's {@code wt_auth_method}, defaulted to {@code password}
 * @param clientVersion the {@code wt-client} value, or null
 * @param requestId the {@code wt-request-id}, generated when the client sent none
 */
public record Principal(UUID accountId, String subject, UUID deviceId, String authMethod, String clientVersion,
        String requestId) {
}
