package com.villagecompute.wiretuner.api.auth;

import java.util.UUID;

import com.villagecompute.wiretuner.api.grpc.GrpcMetadata;

import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.opentelemetry.api.trace.Span;
import io.quarkus.grpc.GlobalInterceptor;

import org.jboss.logging.MDC;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.Prioritized;
import jakarta.inject.Inject;

/**
 * First of the WireTuner interceptors (docs/spec/server.adoc, Services): takes {@code wt-request-id}
 * from the metadata (or mints one), puts it in the log MDC and on the current span, and binds it
 * for the {@link Principal}.
 *
 * <p>Ordering: Quarkus sorts global interceptors by priority and the highest runs first. Quarkus's
 * own request-context interceptor is {@code MAX_VALUE - 50} and its security interceptor
 * {@code MAX_VALUE - 100}; this one sits between them so the request scope is active and the id is
 * in the MDC before token validation logs anything.
 */
@GlobalInterceptor
@ApplicationScoped
public class RequestIdInterceptor implements ServerInterceptor, Prioritized {

    public static final int PRIORITY = Integer.MAX_VALUE - 90;
    public static final String MDC_KEY = "wt.request_id";
    public static final String SPAN_ATTRIBUTE = "wt.request_id";

    @Inject
    CallMetadata callMetadata;

    @Override
    public int getPriority() {
        return PRIORITY;
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(ServerCall<ReqT, RespT> call, Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {
        String requestId = headers.get(GrpcMetadata.WT_REQUEST_ID);
        if (requestId == null || requestId.isBlank()) {
            requestId = UUID.randomUUID().toString();
        }
        MDC.put(MDC_KEY, requestId);
        Span.current().setAttribute(SPAN_ATTRIBUTE, requestId);
        callMetadata.requestId(requestId);
        return next.startCall(call, headers);
    }
}
