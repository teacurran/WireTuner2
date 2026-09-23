package com.villagecompute.wiretuner.api.grpc;

import java.util.List;
import java.util.Map;

import com.google.protobuf.Descriptors.FieldDescriptor;
import com.google.protobuf.Message;
import com.google.protobuf.TextFormat;

/**
 * Log-safe text of a request (DATA-002): every field marked {@code debug_redact} in its proto -- the
 * secret fields of {@code wiretuner.data.v1.PutCredentialRequest} -- prints as {@code <redacted>}, at
 * any depth, and the rest as protobuf text. Every place that logs a data-service request uses it.
 */
public final class Redaction {

    public static final String REDACTED = "<redacted>";

    private Redaction() {
    }

    /** The message as one line of protobuf text with redacted fields replaced. */
    public static String print(Message message) {
        return TextFormat.printer().emittingSingleLine(true).printToString(redact(message));
    }

    /** A copy with every set {@code debug_redact} field (all of them strings) replaced by {@link #REDACTED}. */
    @SuppressWarnings("unchecked")
    static Message redact(Message message) {
        Message.Builder copy = message.toBuilder();
        for (Map.Entry<FieldDescriptor, Object> field : message.getAllFields().entrySet()) {
            FieldDescriptor descriptor = field.getKey();
            if (descriptor.getOptions().getDebugRedact()) {
                copy.setField(descriptor, REDACTED);
            } else if (descriptor.getJavaType() == FieldDescriptor.JavaType.MESSAGE) {
                if (descriptor.isRepeated()) {
                    copy.clearField(descriptor);
                    for (Object element : (List<Object>) field.getValue()) {
                        copy.addRepeatedField(descriptor, redact((Message) element));
                    }
                } else {
                    copy.setField(descriptor, redact((Message) field.getValue()));
                }
            }
        }
        return copy.build();
    }
}
