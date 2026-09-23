package com.villagecompute.wiretuner.api.auth;

import com.villagecompute.wiretuner.api.grpc.GrpcMetadata;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.quarkus.grpc.GlobalInterceptor;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.Prioritized;
import jakarta.inject.Inject;

/**
 * Runs after Quarkus's security interceptor has attached the deferred OIDC {@code SecurityIdentity}
 * to the request. Binds {@code wt-device} and {@code wt-client} for the {@link Principal}, and
 * fails closed: a call to any service but health and reflection without a bearer token is closed
 * with {@code UNAUTHENTICATED} before the handler runs. Token validation itself is asynchronous and
 * happens in {@link Principals#current()}, inside the call's reactive session, where the account
 * and device rows are also written.
 */
@GlobalInterceptor
@ApplicationScoped
public class PrincipalInterceptor implements ServerInterceptor, Prioritized {

    public static final int PRIORITY = Integer.MAX_VALUE - 200;
    static final String BEARER_PREFIX = "Bearer ";
    static final String HEALTH_SERVICE = "grpc.health.v1.Health";
    static final String REFLECTION_PREFIX = "grpc.reflection.";

    @Inject
    CallMetadata callMetadata;

    @Override
    public int getPriority() {
        return PRIORITY;
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(ServerCall<ReqT, RespT> call, Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {
        if (isExempt(call.getMethodDescriptor().getServiceName())) {
            return next.startCall(call, headers);
        }
        callMetadata.deviceId(headers.get(GrpcMetadata.WT_DEVICE));
        callMetadata.clientVersion(headers.get(GrpcMetadata.WT_CLIENT));
        String authorization = headers.get(GrpcMetadata.AUTHORIZATION);
        if (!hasBearer(authorization)) {
            call.close(StatusExceptions.unauthenticated("missing bearer token").getStatus(), new Metadata());
            return new ServerCall.Listener<>() {
                // the call is closed; nothing to listen for
            };
        }
        callMetadata.bearerPresent(true);
        callMetadata.authorization(authorization);
        return next.startCall(call, headers);
    }

    /** Health (compose, the load balancer) and reflection (grpcurl in dev) carry no token. */
    static boolean isExempt(String serviceName) {
        return HEALTH_SERVICE.equals(serviceName) || serviceName.startsWith(REFLECTION_PREFIX);
    }

    static boolean hasBearer(String authorization) {
        return authorization != null
                && authorization.regionMatches(true, 0, BEARER_PREFIX, 0, BEARER_PREFIX.length())
                && !authorization.substring(BEARER_PREFIX.length()).isBlank();
    }
}
