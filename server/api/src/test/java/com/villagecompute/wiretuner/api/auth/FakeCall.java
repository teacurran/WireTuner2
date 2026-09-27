package com.villagecompute.wiretuner.api.auth;

import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.Status;

/** A ServerCall that records how it was closed, and a handler that records whether it started. */
final class FakeCall extends ServerCall<Object, Object> {

    final MethodDescriptor<Object, Object> descriptor;
    Status closed;
    boolean started;

    FakeCall(String fullMethodName) {
        MethodDescriptor.Marshaller<Object> marshaller = new MethodDescriptor.Marshaller<>() {
            @Override
            public java.io.InputStream stream(Object value) {
                return java.io.InputStream.nullInputStream();
            }

            @Override
            public Object parse(java.io.InputStream stream) {
                return null;
            }
        };
        this.descriptor = MethodDescriptor.newBuilder(marshaller, marshaller)
                .setType(MethodDescriptor.MethodType.UNARY)
                .setFullMethodName(fullMethodName)
                .build();
    }

    ServerCallHandler<Object, Object> handler() {
        return (call, headers) -> {
            started = true;
            return new ServerCall.Listener<>() {
            };
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
    public void sendMessage(Object message) {
        // The fake call records nothing here: the tests only look at close().
    }

    @Override
    public void close(Status status, Metadata trailers) {
        closed = status;
    }

    @Override
    public boolean isCancelled() {
        return false;
    }

    @Override
    public MethodDescriptor<Object, Object> getMethodDescriptor() {
        return descriptor;
    }
}
