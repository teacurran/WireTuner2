package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

import io.grpc.Metadata;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.context.Scope;
import io.opentelemetry.sdk.trace.ReadableSpan;
import io.opentelemetry.sdk.trace.SdkTracerProvider;

/** SRV-014: {@code wt-request-id} lands on the call's span, after tracing has started it. */
class SpanRequestIdInterceptorTest {

    @Test
    void theRequestIdIsASpanAttribute() {
        SpanRequestIdInterceptor interceptor = new SpanRequestIdInterceptor();
        interceptor.callMetadata = new CallMetadata();
        interceptor.callMetadata.requestId("req-span");
        assertThat(interceptor.getPriority()).isNegative();
        try (SdkTracerProvider tracing = SdkTracerProvider.builder().build()) {
            Span span = tracing.get("test").spanBuilder("call").startSpan();
            FakeCall call = new FakeCall("wiretuner.sync.v1.SyncService/Ack");
            try (Scope ignored = span.makeCurrent()) {
                interceptor.interceptCall(call, new Metadata(), call.handler());
            }
            assertThat(call.started).isTrue();
            assertThat(((ReadableSpan) span).getAttribute(AttributeKey.stringKey(RequestIdInterceptor.SPAN_ATTRIBUTE)))
                    .isEqualTo("req-span");
            span.end();
        }
    }
}
