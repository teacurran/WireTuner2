package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.jboss.logging.MDC;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.grpc.GrpcMetadata;

import io.grpc.Metadata;
import io.grpc.Status;

/** The synchronous half of the chain: request id and the fail-closed bearer check. */
class InterceptorsTest {

    static final String ME = "wiretuner.account.v1.AccountService/Me";

    @Test
    void chainOrderMatchesTheSpec() {
        // Highest priority runs first: request context (MAX-50), request id, Quarkus security
        // (MAX-100, validates the token), principal resolution.
        assertThat(new RequestIdInterceptor().getPriority()).isLessThan(Integer.MAX_VALUE - 50)
                .isGreaterThan(Integer.MAX_VALUE - 100);
        assertThat(new PrincipalInterceptor().getPriority()).isLessThan(Integer.MAX_VALUE - 100);
    }

    @Test
    void requestIdComesFromMetadata() {
        RequestIdInterceptor interceptor = new RequestIdInterceptor();
        interceptor.callMetadata = new CallMetadata();
        Metadata headers = new Metadata();
        headers.put(GrpcMetadata.WT_REQUEST_ID, "req-1");
        FakeCall call = new FakeCall(ME);
        interceptor.interceptCall(call, headers, call.handler());
        assertThat(call.started).isTrue();
        assertThat(interceptor.callMetadata.requestId()).isEqualTo("req-1");
        assertThat(MDC.get(RequestIdInterceptor.MDC_KEY)).isEqualTo("req-1");
    }

    @Test
    void requestIdIsMintedWhenAbsentOrBlank() {
        RequestIdInterceptor interceptor = new RequestIdInterceptor();
        interceptor.callMetadata = new CallMetadata();
        FakeCall call = new FakeCall(ME);
        interceptor.interceptCall(call, new Metadata(), call.handler());
        assertThat(UUID.fromString(interceptor.callMetadata.requestId())).isNotNull();

        Metadata blank = new Metadata();
        blank.put(GrpcMetadata.WT_REQUEST_ID, "  ");
        interceptor.interceptCall(call, blank, call.handler());
        assertThat(UUID.fromString(interceptor.callMetadata.requestId())).isNotNull();
    }

    @Test
    void healthAndReflectionNeedNoToken() {
        for (String method : new String[] {"grpc.health.v1.Health/Check",
                "grpc.reflection.v1.ServerReflection/ServerReflectionInfo"}) {
            FakeCall call = new FakeCall(method);
            principalInterceptor().interceptCall(call, new Metadata(), call.handler());
            assertThat(call.started).isTrue();
            assertThat(call.closed).isNull();
        }
    }

    @Test
    void aCallWithoutABearerIsClosed() {
        for (String authorization : new String[] {null, "Basic dXNlcjpwYXNz", "Bearer   ", "Bear"}) {
            Metadata headers = new Metadata();
            if (authorization != null) {
                headers.put(GrpcMetadata.AUTHORIZATION, authorization);
            }
            FakeCall call = new FakeCall(ME);
            principalInterceptor().interceptCall(call, headers, call.handler());
            assertThat(call.started).as(String.valueOf(authorization)).isFalse();
            assertThat(call.closed.getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        }
    }

    @Test
    void aBearerCallProceedsWithDeviceAndClientBound() {
        PrincipalInterceptor interceptor = principalInterceptor();
        Metadata headers = new Metadata();
        headers.put(GrpcMetadata.AUTHORIZATION, "bearer abc.def.ghi");
        headers.put(GrpcMetadata.WT_DEVICE, "dev-1");
        headers.put(GrpcMetadata.WT_CLIENT, "macos/1.0/7");
        FakeCall call = new FakeCall(ME);
        interceptor.interceptCall(call, headers, call.handler());
        assertThat(call.started).isTrue();
        assertThat(interceptor.callMetadata.bearerPresent()).isTrue();
        assertThat(interceptor.callMetadata.deviceId()).isEqualTo("dev-1");
        assertThat(interceptor.callMetadata.clientVersion()).isEqualTo("macos/1.0/7");
    }

    static PrincipalInterceptor principalInterceptor() {
        PrincipalInterceptor interceptor = new PrincipalInterceptor();
        interceptor.callMetadata = new CallMetadata();
        return interceptor;
    }
}
