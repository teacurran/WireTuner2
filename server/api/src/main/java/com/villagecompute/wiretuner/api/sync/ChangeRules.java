package com.villagecompute.wiretuner.api.sync;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.PathSegment;

/**
 * The acceptance rules of docs/spec/sync-protocol.adoc (Server log) that protovalidate cannot
 * express: a change is at most 4 MiB encoded, and every field path its ops name is one the merge
 * table knows. The op count (at most 10,000) is a protovalidate rule on {@code Change.ops} and is
 * already enforced by the {@code ValidationInterceptor}. A violation is
 * {@code INVALID_ARGUMENT / VALIDATION_FAILED}, the violations keyed by {@code ops[i]}.
 */
public final class ChangeRules {

    /** The encoded size cap of one change (docs/spec/sync-protocol.adoc, Server log). */
    public static final int MAX_CHANGE_BYTES = 4 * 1024 * 1024;

    /** The encoded size cap of one bulk frame holding more than one change (api-conventions.adoc). */
    public static final int MAX_FRAME_BYTES = 1024 * 1024;

    private ChangeRules() {
    }

    /** Throws {@code VALIDATION_FAILED} unless the change is within limits and names only known paths. */
    public static void check(Schema schema, Change change) {
        int size = change.getSerializedSize();
        if (size > MAX_CHANGE_BYTES) {
            throw StatusExceptions.validationFailed("the change is " + size + " bytes encoded; the cap is " + MAX_CHANGE_BYTES,
                    Map.of("change", "encoded size exceeds " + MAX_CHANGE_BYTES + " bytes"));
        }
        Map<String, String> violations = new LinkedHashMap<>();
        List<Op> ops = change.getOpsList();
        for (int i = 0; i < ops.size(); i++) {
            for (FieldPath path : paths(ops.get(i))) {
                if (!known(schema, path)) {
                    violations.put("ops[" + i + "]", "names a field path the merge table does not know");
                }
            }
        }
        if (!violations.isEmpty()) {
            throw StatusExceptions.validationFailed("the change names field paths the merge table does not know: "
                    + String.join(", ", violations.keySet()), violations);
        }
    }

    /** The field paths one op names; none for the ops that address nodes only. */
    static List<FieldPath> paths(Op op) {
        return switch (op.getOpCase()) {
            case SET -> op.getSet().getPathsList();
            case ELEMENT_INSERT -> List.of(op.getElementInsert().getSequence());
            case ELEMENT_MOVE -> List.of(op.getElementMove().getElement());
            case ELEMENT_DELETE -> op.getElementDelete().getElementsList();
            case TEXT_INSERT -> List.of(op.getTextInsert().getText());
            case TEXT_DELETE -> List.of(op.getTextDelete().getText());
            case TEXT_MARK -> List.of(op.getTextMark().getText());
            case SET_ADD -> List.of(op.getSetAdd().getSet());
            case SET_REMOVE -> List.of(op.getSetRemove().getSet());
            default -> List.of();
        };
    }

    /**
     * True when every segment resolves in the merge table: field segments are looked up in the
     * message reached so far (starting at {@code NodeProps}, whose fields are the kinds); STRUCT and
     * VARIANT fields are entered; a SEQUENCE or TEXT field may be followed by one element segment,
     * after which a SEQUENCE continues in its element message and a TEXT character is a leaf;
     * nothing follows an ATOMIC or SET field. This is the path shape both engines resolve
     * (docs/spec/crdt-model.adoc, Field paths and registers); anything else would be a no-op there.
     */
    static boolean known(Schema schema, FieldPath path) {
        String message = Schema.ROOT;
        FieldPolicy container = null;
        for (PathSegment segment : path.getSegmentsList()) {
            if (segment.hasElement()) {
                if (container == null) {
                    return false;
                }
                message = container.elementMessage();
                container = null;
                continue;
            }
            FieldPolicy row = message == null ? null : schema.field(message, segment.getField());
            if (row == null) {
                return false;
            }
            message = switch (row.policy()) {
                case STRUCT, VARIANT -> row.typeName();
                case SEQUENCE, TEXT -> {
                    container = row;
                    yield null;
                }
                default -> null;
            };
        }
        return true;
    }
}
