package com.villagecompute.wiretuner.api.grpc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import java.util.Map;
import java.util.stream.Stream;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import com.google.protobuf.Any;
import com.google.protobuf.ByteString;
import com.google.rpc.ErrorInfo;

import io.grpc.Metadata;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.grpc.protobuf.StatusProto;

/** Every reason in the api-conventions table has a factory producing its code and an ErrorInfo. */
class StatusExceptionsTest {

    static Stream<Arguments> reasons() {
        return Stream.of(
                Arguments.of(StatusExceptions.tokenExpired(), Status.Code.UNAUTHENTICATED, ErrorReasons.TOKEN_EXPIRED, Map.of()),
                Arguments.of(StatusExceptions.roleInsufficient("editor", "viewer"), Status.Code.PERMISSION_DENIED,
                        ErrorReasons.ROLE_INSUFFICIENT, Map.of("required", "editor", "actual", "viewer")),
                Arguments.of(StatusExceptions.replicaExpired(-1L), Status.Code.FAILED_PRECONDITION,
                        ErrorReasons.REPLICA_EXPIRED, Map.of("replica", "18446744073709551615")),
                Arguments.of(StatusExceptions.replicaConflict(7, 3), Status.Code.FAILED_PRECONDITION,
                        ErrorReasons.REPLICA_CONFLICT, Map.of("replica", "7", "seq", "3")),
                Arguments.of(StatusExceptions.clientTooOld(4, 2), Status.Code.FAILED_PRECONDITION,
                        ErrorReasons.CLIENT_TOO_OLD, Map.of("document_level", "4", "client_level", "2")),
                Arguments.of(StatusExceptions.seqGap(5, 7), Status.Code.ABORTED, ErrorReasons.SEQ_GAP,
                        Map.of("expected", "5", "received", "7")),
                Arguments.of(StatusExceptions.rateLimited(Duration.ofMillis(1500)), Status.Code.RESOURCE_EXHAUSTED,
                        ErrorReasons.RATE_LIMITED, Map.of()),
                Arguments.of(StatusExceptions.storageQuota(), Status.Code.RESOURCE_EXHAUSTED, ErrorReasons.STORAGE_QUOTA, Map.of()),
                Arguments.of(StatusExceptions.documentNotFound(), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND, Map.of()),
                Arguments.of(StatusExceptions.hostNotAllowed("evil.test"), Status.Code.PERMISSION_DENIED,
                        ErrorReasons.HOST_NOT_ALLOWED, Map.of("host", "evil.test")),
                Arguments.of(StatusExceptions.credentialMissing("github"), Status.Code.FAILED_PRECONDITION,
                        ErrorReasons.CREDENTIAL_MISSING, Map.of("credential", "github")),
                Arguments.of(StatusExceptions.responseTooLarge(1024), Status.Code.RESOURCE_EXHAUSTED,
                        ErrorReasons.RESPONSE_TOO_LARGE, Map.of("cap_bytes", "1024")),
                Arguments.of(StatusExceptions.upstreamError(502), Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR,
                        Map.of("upstream_status", "502")));
    }

    @ParameterizedTest
    @MethodSource("reasons")
    void carriesCodeReasonDomainAndMetadata(StatusRuntimeException e, Status.Code code, String reason,
            Map<String, String> metadata) {
        assertThat(e.getStatus().getCode()).isEqualTo(code);
        assertThat(e.getStatus().getDescription()).isNotBlank();
        ErrorInfo info = StatusExceptions.errorInfo(e).orElseThrow();
        assertThat(info.getReason()).isEqualTo(reason);
        assertThat(info.getDomain()).isEqualTo("wiretuner.app");
        assertThat(info.getMetadataMap()).isEqualTo(metadata);
        assertThat(StatusExceptions.reasonOf(e)).contains(reason);
    }

    @Test
    void rateLimitedCarriesRetryInfo() {
        assertThat(StatusExceptions.retryDelayOf(StatusExceptions.rateLimited(Duration.ofMillis(1500))))
                .contains(Duration.ofMillis(1500));
        assertThat(StatusExceptions.retryDelayOf(StatusExceptions.storageQuota())).isEmpty();
    }

    @Test
    void unauthenticatedHasNoReason() {
        StatusRuntimeException e = StatusExceptions.unauthenticated("missing bearer token");
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        assertThat(e.getStatus().getDescription()).isEqualTo("missing bearer token");
        assertThat(StatusExceptions.reasonOf(e)).isEmpty();
    }

    @Test
    void foreignErrorsHaveNoDetails() {
        assertThat(StatusExceptions.reasonOf(new IllegalStateException("x"))).isEmpty();
        assertThat(StatusExceptions.retryDelayOf(new IllegalStateException("x"))).isEmpty();
        assertThat(StatusExceptions.reasonOf(Status.INTERNAL.asRuntimeException())).isEmpty();
    }

    @Test
    void aStatusWithOtherDetailsHasNoReason() {
        StatusRuntimeException retryOnly = StatusProto.toStatusRuntimeException(com.google.rpc.Status.newBuilder()
                .setCode(8).addDetails(Any.pack(com.google.rpc.RetryInfo.getDefaultInstance())).build());
        assertThat(StatusExceptions.reasonOf(retryOnly)).isEmpty();
        assertThat(StatusExceptions.retryDelayOf(retryOnly)).contains(Duration.ZERO);
    }

    @Test
    void undecodableDetailsAreReported() {
        Any badInfo = Any.newBuilder().setTypeUrl("type.googleapis.com/google.rpc.ErrorInfo")
                .setValue(ByteString.copyFrom(new byte[] {(byte) 0xff})).build();
        Any badRetry = Any.newBuilder().setTypeUrl("type.googleapis.com/google.rpc.RetryInfo")
                .setValue(ByteString.copyFrom(new byte[] {(byte) 0xff})).build();
        StatusRuntimeException info = StatusProto.toStatusRuntimeException(
                com.google.rpc.Status.newBuilder().setCode(13).addDetails(badInfo).build(), new Metadata());
        StatusRuntimeException retry = StatusProto.toStatusRuntimeException(
                com.google.rpc.Status.newBuilder().setCode(13).addDetails(badRetry).build(), new Metadata());
        assertThatThrownBy(() -> StatusExceptions.errorInfo(info)).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> StatusExceptions.retryDelayOf(retry)).isInstanceOf(IllegalStateException.class);
    }

    @Test
    void metadataKeysAreTheConventionNames() {
        assertThat(GrpcMetadata.AUTHORIZATION.name()).isEqualTo("authorization");
        assertThat(GrpcMetadata.WT_CLIENT.name()).isEqualTo("wt-client");
        assertThat(GrpcMetadata.WT_DEVICE.name()).isEqualTo("wt-device");
        assertThat(GrpcMetadata.WT_REQUEST_ID.name()).isEqualTo("wt-request-id");
    }
}
