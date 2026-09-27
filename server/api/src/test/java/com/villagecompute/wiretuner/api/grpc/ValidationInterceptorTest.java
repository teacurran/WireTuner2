package com.villagecompute.wiretuner.api.grpc;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;

import build.buf.protovalidate.exceptions.ValidationException;
import com.google.protobuf.Message;
import com.google.rpc.BadRequest;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.ListRequest;

import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.ServerCall;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.grpc.protobuf.StatusProto;

/** The protovalidate interceptor against a recording call and listener (no server needed). */
class ValidationInterceptorTest {

    /** Records how the call was closed and what reached the handler's listener. */
    static final class Recording extends ServerCall<Message, Message> {
        Status status;
        Metadata trailers;
        final List<String> events = new ArrayList<>();

        ServerCall.Listener<Message> listener() {
            return new ServerCall.Listener<>() {
                @Override
                public void onMessage(Message message) {
                    events.add("message");
                }

                @Override
                public void onHalfClose() {
                    events.add("halfClose");
                }

                @Override
                public void onCancel() {
                    events.add("cancel");
                }
            };
        }

        @Override
        public void request(int numMessages) {
            // The fake call records nothing here: the tests only look at close().
        }

        @Override
        public void sendHeaders(Metadata headers) {
            // The fake call records nothing here: the tests only look at close().
        }

        @Override
        public void sendMessage(Message message) {
            // The fake call records nothing here: the tests only look at close().
        }

        @Override
        public void close(Status status, Metadata trailers) {
            this.status = status;
            this.trailers = trailers;
        }

        @Override
        public boolean isCancelled() {
            return false;
        }

        @Override
        public MethodDescriptor<Message, Message> getMethodDescriptor() {
            return null;
        }
    }

    final ValidationInterceptor interceptor = new ValidationInterceptor();

    ServerCall.Listener<Message> start(Recording call) {
        return interceptor.interceptCall(call, new Metadata(), (c, h) -> call.listener());
    }

    @Test
    void aValidMessageReachesTheHandler() {
        Recording call = new Recording();
        ServerCall.Listener<Message> listener = start(call);
        listener.onMessage(GetRequest.newBuilder().setDocumentId("0190f5e2-7b3c-7d4e-8f00-000000000001").build());
        listener.onHalfClose();
        listener.onCancel();
        assertThat(call.status).isNull();
        assertThat(call.events).containsExactly("message", "halfClose", "cancel");
        assertThat(interceptor.getPriority()).isEqualTo(ValidationInterceptor.PRIORITY);
    }

    @Test
    void anInvalidMessageClosesTheCallWithTheViolations() throws Exception {
        Recording call = new Recording();
        ServerCall.Listener<Message> listener = start(call);
        listener.onMessage(GetRequest.newBuilder().setDocumentId("not-a-uuid").build());
        listener.onMessage(GetRequest.getDefaultInstance());
        listener.onHalfClose();
        listener.onCancel();

        assertThat(call.status.getCode()).isEqualTo(Status.Code.INVALID_ARGUMENT);
        assertThat(call.status.getDescription()).startsWith("request validation failed: document_id: ");
        // The handler only hears that the call is over.
        assertThat(call.events).containsExactly("cancel");
        StatusRuntimeException error = call.status.asRuntimeException(call.trailers);
        assertThat(StatusExceptions.reasonOf(error)).contains(ErrorReasons.VALIDATION_FAILED);
        BadRequest badRequest = StatusProto.fromThrowable(error).getDetailsList().stream()
                .filter(d -> d.is(BadRequest.class)).findFirst().orElseThrow().unpack(BadRequest.class);
        assertThat(badRequest.getFieldViolations(0).getField()).isEqualTo("document_id");
    }

    @Test
    void manyViolationsAreMergedPerFieldAndCounted() throws Exception {
        CreateRequest bad = CreateRequest.newBuilder().setDocumentId("x").setSpaceId("y").setFolderId("z").build();
        var result = interceptor.validator.validate(bad);
        var violations = ValidationInterceptor.violations(result.getViolations());
        assertThat(violations.get("document_id")).contains("; ");
        assertThat(violations).containsKeys("document_id", "space_id", "folder_id", "name");
        assertThat(ValidationInterceptor.describe(violations)).endsWith("(+1 more)");

        var messageLevel = ValidationInterceptor.violations(
                interceptor.validator.validate(ListRequest.getDefaultInstance()).getViolations());
        assertThat(ValidationInterceptor.describe(messageLevel)).startsWith("request: ");
    }

    @Test
    void anEvaluationFailureIsInternal() {
        interceptor.validator = message -> {
            throw new ValidationException("broken rule");
        };
        Recording call = new Recording();
        start(call).onMessage(GetRequest.getDefaultInstance());
        assertThat(call.status.getCode()).isEqualTo(Status.Code.INTERNAL);
        assertThat(call.events).containsExactly("cancel");
    }
}
