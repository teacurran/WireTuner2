package com.villagecompute.wiretuner.api.grpc;

import java.time.Duration;
import java.util.Map;
import java.util.Optional;

import com.google.protobuf.Any;
import com.google.protobuf.InvalidProtocolBufferException;
import com.google.rpc.Code;
import com.google.rpc.ErrorInfo;
import com.google.rpc.RetryInfo;

import io.grpc.StatusRuntimeException;
import io.grpc.protobuf.StatusProto;

/**
 * Builds the gRPC errors of docs/spec/api-conventions.adoc (Errors): a standard status code with
 * the reason in {@code google.rpc.ErrorInfo} ({@code domain = "wiretuner.app"}) in the trailers, and
 * {@code google.rpc.RetryInfo} where the table says so. One factory per reason so every RPC raises
 * the same shape, and {@link #reasonOf} so tests and clients read it back.
 */
public final class StatusExceptions {

    private StatusExceptions() {
    }

    /** {@code UNAUTHENTICATED} with no reason: sign in again (missing or invalid token, revoked device). */
    public static StatusRuntimeException unauthenticated(String description) {
        return build(Code.UNAUTHENTICATED, description, null, null);
    }

    /** {@code UNAUTHENTICATED / TOKEN_EXPIRED}: refresh the token and retry. */
    public static StatusRuntimeException tokenExpired() {
        return withReason(Code.UNAUTHENTICATED, ErrorReasons.TOKEN_EXPIRED,
                "the access token has expired; refresh it and retry", Map.of());
    }

    /** {@code PERMISSION_DENIED / ROLE_INSUFFICIENT}: the caller's role on the document does not allow this. */
    public static StatusRuntimeException roleInsufficient(String required, String actual) {
        return withReason(Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT,
                "this call needs the " + required + " role on the document; the caller holds " + actual,
                Map.of("required", required, "actual", actual));
    }

    /** {@code FAILED_PRECONDITION / REPLICA_EXPIRED}: the replica was retired after long inactivity. */
    public static StatusRuntimeException replicaExpired(long replicaId) {
        return withReason(Code.FAILED_PRECONDITION, ErrorReasons.REPLICA_EXPIRED,
                "replica " + replicaId + " was retired; bootstrap from a snapshot with a new replica id",
                Map.of("replica", Long.toUnsignedString(replicaId)));
    }

    /** {@code FAILED_PRECONDITION / REPLICA_CONFLICT}: the same (replica, seq) arrived with different content. */
    public static StatusRuntimeException replicaConflict(long replicaId, long seq) {
        return withReason(Code.FAILED_PRECONDITION, ErrorReasons.REPLICA_CONFLICT,
                "replica " + replicaId + " seq " + seq + " was already accepted with different content; rotate the replica id",
                Map.of("replica", Long.toUnsignedString(replicaId), "seq", Long.toString(seq)));
    }

    /** {@code FAILED_PRECONDITION / CLIENT_TOO_OLD}: the document's feature level is above this client's. */
    public static StatusRuntimeException clientTooOld(int documentLevel, int clientLevel) {
        return withReason(Code.FAILED_PRECONDITION, ErrorReasons.CLIENT_TOO_OLD,
                "the document uses feature level " + documentLevel + "; this client supports " + clientLevel,
                Map.of("document_level", Integer.toString(documentLevel), "client_level", Integer.toString(clientLevel)));
    }

    /** {@code ABORTED / SEQ_GAP}: a change arrived before its predecessor; resend from the acked seq. */
    public static StatusRuntimeException seqGap(long expectedSeq, long receivedSeq) {
        return withReason(Code.ABORTED, ErrorReasons.SEQ_GAP,
                "expected seq " + expectedSeq + " but received " + receivedSeq + "; resend from the acked seq",
                Map.of("expected", Long.toString(expectedSeq), "received", Long.toString(receivedSeq)));
    }

    /** {@code RESOURCE_EXHAUSTED / RATE_LIMITED} with {@code RetryInfo}: back off for the delay. */
    public static StatusRuntimeException rateLimited(Duration retryAfter) {
        RetryInfo retry = RetryInfo.newBuilder()
                .setRetryDelay(com.google.protobuf.Duration.newBuilder()
                        .setSeconds(retryAfter.getSeconds())
                        .setNanos(retryAfter.getNano()))
                .build();
        return build(Code.RESOURCE_EXHAUSTED, "rate limited; retry after " + retryAfter,
                errorInfo(ErrorReasons.RATE_LIMITED, Map.of()), retry);
    }

    /** {@code RESOURCE_EXHAUSTED / STORAGE_QUOTA}: the space's blob storage quota is full. */
    public static StatusRuntimeException storageQuota() {
        return withReason(Code.RESOURCE_EXHAUSTED, ErrorReasons.STORAGE_QUOTA,
                "the space's blob storage quota is full", Map.of());
    }

    /** {@code NOT_FOUND / DOCUMENT_NOT_FOUND}: deleted, or never visible to the caller. */
    public static StatusRuntimeException documentNotFound() {
        return withReason(Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND, "document not found", Map.of());
    }

    /** {@code PERMISSION_DENIED / HOST_NOT_ALLOWED}: a data-source fetch targets a host outside the allowlist. */
    public static StatusRuntimeException hostNotAllowed(String host) {
        return withReason(Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED,
                "host " + host + " is not in the scope's allowlist", Map.of("host", host));
    }

    /** {@code FAILED_PRECONDITION / CREDENTIAL_MISSING}: the source names a credential the scope does not hold. */
    public static StatusRuntimeException credentialMissing(String credential) {
        return withReason(Code.FAILED_PRECONDITION, ErrorReasons.CREDENTIAL_MISSING,
                "credential " + credential + " is not held by the scope", Map.of("credential", credential));
    }

    /** {@code RESOURCE_EXHAUSTED / RESPONSE_TOO_LARGE}: an upstream response exceeded the size cap. */
    public static StatusRuntimeException responseTooLarge(long capBytes) {
        return withReason(Code.RESOURCE_EXHAUSTED, ErrorReasons.RESPONSE_TOO_LARGE,
                "the upstream response exceeded " + capBytes + " bytes", Map.of("cap_bytes", Long.toString(capBytes)));
    }

    /** {@code UNAVAILABLE / UPSTREAM_ERROR}: the upstream API failed; details carry its status. */
    public static StatusRuntimeException upstreamError(int upstreamStatus) {
        return withReason(Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR,
                "the upstream API answered " + upstreamStatus, Map.of("upstream_status", Integer.toString(upstreamStatus)));
    }

    /** The {@code ErrorInfo} carried by a WireTuner status error, if any. */
    public static Optional<ErrorInfo> errorInfo(Throwable throwable) {
        com.google.rpc.Status status = StatusProto.fromThrowable(throwable);
        if (status == null) {
            return Optional.empty();
        }
        for (Any detail : status.getDetailsList()) {
            if (detail.is(ErrorInfo.class)) {
                return Optional.of(unpack(detail));
            }
        }
        return Optional.empty();
    }

    /** The reason of a WireTuner status error, if it carries one. */
    public static Optional<String> reasonOf(Throwable throwable) {
        return errorInfo(throwable).map(ErrorInfo::getReason);
    }

    /** The {@code RetryInfo} delay carried by a status error, if any. */
    public static Optional<Duration> retryDelayOf(Throwable throwable) {
        com.google.rpc.Status status = StatusProto.fromThrowable(throwable);
        if (status == null) {
            return Optional.empty();
        }
        for (Any detail : status.getDetailsList()) {
            if (detail.is(RetryInfo.class)) {
                com.google.protobuf.Duration d = unpackRetry(detail).getRetryDelay();
                return Optional.of(Duration.ofSeconds(d.getSeconds(), d.getNanos()));
            }
        }
        return Optional.empty();
    }

    private static StatusRuntimeException withReason(Code code, String reason, String description,
            Map<String, String> metadata) {
        return build(code, description, errorInfo(reason, metadata), null);
    }

    private static ErrorInfo errorInfo(String reason, Map<String, String> metadata) {
        return ErrorInfo.newBuilder().setReason(reason).setDomain(ErrorReasons.DOMAIN).putAllMetadata(metadata).build();
    }

    private static StatusRuntimeException build(Code code, String description, ErrorInfo info, RetryInfo retry) {
        com.google.rpc.Status.Builder status = com.google.rpc.Status.newBuilder()
                .setCode(code.getNumber())
                .setMessage(description);
        if (info != null) {
            status.addDetails(Any.pack(info));
        }
        if (retry != null) {
            status.addDetails(Any.pack(retry));
        }
        return StatusProto.toStatusRuntimeException(status.build());
    }

    private static ErrorInfo unpack(Any detail) {
        try {
            return detail.unpack(ErrorInfo.class);
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException("ErrorInfo detail does not decode", e);
        }
    }

    private static RetryInfo unpackRetry(Any detail) {
        try {
            return detail.unpack(RetryInfo.class);
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException("RetryInfo detail does not decode", e);
        }
    }
}
