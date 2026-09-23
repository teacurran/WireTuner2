package com.villagecompute.wiretuner.api.grpc;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import build.buf.protovalidate.ValidationResult;
import build.buf.protovalidate.Validator;
import build.buf.protovalidate.ValidatorFactory;
import build.buf.protovalidate.exceptions.ValidationException;
import build.buf.validate.FieldPathElement;
import com.google.protobuf.Message;

import io.grpc.ForwardingServerCallListener;
import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.grpc.Status;
import io.quarkus.grpc.GlobalInterceptor;

import org.jboss.logging.Logger;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.Prioritized;

/**
 * The protovalidate interceptor (docs/spec/server.adoc, Services; api-conventions.adoc, Validation):
 * every inbound message -- each frame of a client stream included -- is checked against its
 * {@code buf.validate} rules before the handler sees it. A violation closes the call with
 * {@code INVALID_ARGUMENT / VALIDATION_FAILED} and the violations in {@code google.rpc.BadRequest}.
 * Runs after principal binding, so a call without a token is refused before its payload is read.
 */
@GlobalInterceptor
@ApplicationScoped
public class ValidationInterceptor implements ServerInterceptor, Prioritized {

    private static final Logger LOG = Logger.getLogger(ValidationInterceptor.class);

    public static final int PRIORITY = Integer.MAX_VALUE - 300;

    /** The status description travels in a header: list a few violations, count the rest. */
    static final int LISTED = 3;

    Validator validator = ValidatorFactory.newBuilder().build();

    @Override
    public int getPriority() {
        return PRIORITY;
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(ServerCall<ReqT, RespT> call, Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {
        return new ForwardingServerCallListener.SimpleForwardingServerCallListener<>(next.startCall(call, headers)) {
            private boolean aborted;

            @Override
            public void onMessage(ReqT message) {
                if (aborted) {
                    return;
                }
                Status refusal = check((Message) message, call);
                if (refusal != null) {
                    aborted = true;
                    super.onCancel();
                    return;
                }
                super.onMessage(message);
            }

            @Override
            public void onHalfClose() {
                if (!aborted) {
                    super.onHalfClose();
                }
            }

            @Override
            public void onCancel() {
                if (!aborted) {
                    super.onCancel();
                }
            }
        };
    }

    /** Validates one message; on a violation closes the call and returns the status it closed with. */
    Status check(Message message, ServerCall<?, ?> call) {
        Status status;
        Metadata trailers;
        try {
            ValidationResult result = validator.validate(message);
            if (result.isSuccess()) {
                return null;
            }
            Map<String, String> violations = violations(result.getViolations());
            var error = StatusExceptions.validationFailed("request validation failed: " + describe(violations), violations);
            status = error.getStatus();
            trailers = error.getTrailers();
        } catch (ValidationException e) {
            LOG.errorf(e, "protovalidate could not evaluate %s", message.getDescriptorForType().getFullName());
            status = Status.INTERNAL.withDescription("request validation error");
            trailers = new Metadata();
        }
        call.close(status, trailers);
        return status;
    }

    /** Field path (dotted field names; empty for message-level rules) to the rule's message, in order. */
    static Map<String, String> violations(List<build.buf.protovalidate.Violation> violations) {
        Map<String, String> byField = new LinkedHashMap<>();
        for (var violation : violations) {
            var proto = violation.toProto();
            String field = proto.getField().getElementsList().stream()
                    .map(FieldPathElement::getFieldName)
                    .collect(Collectors.joining("."));
            byField.merge(field, proto.getMessage(), (a, b) -> a + "; " + b);
        }
        return byField;
    }

    static String describe(Map<String, String> violations) {
        String listed = violations.entrySet().stream().limit(LISTED)
                .map(e -> (e.getKey().isEmpty() ? "request" : e.getKey()) + ": " + e.getValue())
                .collect(Collectors.joining("; "));
        int more = violations.size() - LISTED;
        return more > 0 ? listed + " (+" + more + " more)" : listed;
    }
}
