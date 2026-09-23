package com.villagecompute.wiretuner.api.sync;

import java.util.Optional;

import com.google.protobuf.InvalidProtocolBufferException;
import com.google.protobuf.Message;
import com.google.protobuf.Parser;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.sync.v1.ChangeRejected;
import com.villagecompute.wiretuner.sync.v1.ErrorReason;

import io.grpc.StatusRuntimeException;

/**
 * Decoding of what the server itself stored (change_log bytes, Valkey payloads), and the
 * flattening of a rejected change into {@code ChangeRejected} for batch and bulk responses.
 */
final class Protos {

    /** {@code ChangeRejected.message} is capped at 1024 characters by sync.proto. */
    static final int MESSAGE_CAP = 1024;

    private Protos() {
    }

    /** Parses bytes this server wrote; a failure is a corrupt store, not a client error. */
    static <M extends Message> M parse(Parser<M> parser, byte[] bytes) {
        try {
            return parser.parseFrom(bytes);
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException("stored protobuf does not decode", e);
        }
    }

    static Change change(byte[] bytes) {
        return parse(Change.parser(), bytes);
    }

    /**
     * The rejection a unary push would have failed with, as {@code ChangeRejected}; empty when the
     * failure carries no WireTuner reason (an unauthenticated call, an internal error), which then
     * fails the whole call instead.
     */
    static Optional<ChangeRejected> rejected(Change change, Throwable failure) {
        if (!(failure instanceof StatusRuntimeException status)) {
            return Optional.empty();
        }
        return StatusExceptions.reasonOf(status).map(reason -> {
            String message = String.valueOf(status.getStatus().getDescription());
            return ChangeRejected.newBuilder()
                    .setReplica(change.getReplica())
                    .setSeq(change.getSeq())
                    .setReason(ErrorReason.valueOf("ERROR_REASON_" + reason))
                    .setCode(status.getStatus().getCode().value())
                    .setMessage(message.length() > MESSAGE_CAP ? message.substring(0, MESSAGE_CAP) : message)
                    .build();
        });
    }
}
