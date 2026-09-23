package com.villagecompute.wiretuner.api.auth;

import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.opentelemetry.api.trace.Span;
import io.quarkus.grpc.GlobalInterceptor;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.Prioritized;
import jakarta.inject.Inject;

/**
 * Puts {@code wt-request-id} on the call's OpenTelemetry span (docs/spec/server.adoc, Observability).
 * Quarkus's gRPC tracing interceptor starts the server span at the default priority (0), after the
 * WireTuner interceptors; this one runs after it (a negative priority), while the span is current,
 * and reads the id {@link RequestIdInterceptor} bound for the request.
 */
@GlobalInterceptor
@ApplicationScoped
public class SpanRequestIdInterceptor implements ServerInterceptor, Prioritized {

    public static final int PRIORITY = -100;

    @Inject
    CallMetadata callMetadata;

    @Override
    public int getPriority() {
        return PRIORITY;
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(ServerCall<ReqT, RespT> call, Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {
        Span.current().setAttribute(RequestIdInterceptor.SPAN_ATTRIBUTE, callMetadata.requestId());
        return next.startCall(call, headers);
    }
}
