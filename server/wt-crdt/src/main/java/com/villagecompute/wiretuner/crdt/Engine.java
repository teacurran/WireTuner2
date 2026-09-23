package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import java.util.List;

/**
 * The merge engine (docs/spec/crdt-model.adoc), mirroring {@code WTCRDT.Engine} type for type:
 * a {@link LamportClock}, the {@link NodeStore} and the {@link Schema} it merges with. Every op
 * applies to every state; an op the engine cannot use is a deterministic no-op ("Totality").
 *
 * <p>CRDT-001 implements registers: {@code SetFields} and the register part of
 * {@code CreateNode} (the node's kind and initial values; parent and position arrive with the
 * tree in CRDT-002). Other ops only advance the clock until their tasks land. Not thread-safe:
 * the snapshotter gives each document its own engine.
 */
public final class Engine {

    /** Version of the merge semantics this engine implements (docs/spec/crdt-model.adoc). */
    public static final String VERSION = "0.1.0";

    private final Schema schema;
    private final PathResolver resolver;
    private final LamportClock clock = new LamportClock();
    private final NodeStore store = new NodeStore();

    /** An engine over the generated merge table. */
    public Engine() {
        this(Schema.generated());
    }

    /** An engine over {@code schema}. */
    public Engine(Schema schema) {
        this.schema = schema;
        this.resolver = new PathResolver(schema);
    }

    /** The engine version, for health data and snapshot metadata. */
    public static String version() {
        return VERSION;
    }

    /** The merge table this engine uses. */
    public Schema schema() {
        return schema;
    }

    /** This replica's Lamport clock; every applied op advances it. */
    public LamportClock clock() {
        return clock;
    }

    /** The merged state. */
    public NodeStore store() {
        return store;
    }

    /** Applies every op of {@code change}; op {@code i} has id {@code (start_counter + i, replica)}. */
    public void apply(Change change) {
        List<Op> ops = change.getOpsList();
        for (int i = 0; i < ops.size(); i++) {
            apply(ops.get(i), new OpId(change.getStartCounter() + i, change.getReplica()));
        }
    }

    /** Applies one op with id {@code id}. */
    public void apply(Op op, OpId id) {
        clock.observe(id.counter());
        switch (op.getOpCase()) {
            case CREATE -> create(op.getCreate(), id);
            case SET -> set(op.getSet(), id);
            default -> {
                // Tree, sequence, text and set ops arrive with CRDT-002..007.
            }
        }
    }

    private void create(CreateNode create, OpId id) {
        WireMessage props = WireMessage.parse(create.getProps().toByteArray());
        int kind = props == null ? 0 : props.lastMessageOf(schema.kinds());
        if (kind == 0 || !store.create(id, kind)) {
            return;
        }
        for (PathResolver.Assignment write : resolver.initial(kind, props)) {
            store.write(id, write.path(), write.value(), id);
        }
    }

    private void set(SetFields set, OpId id) {
        OpId node = OpId.of(set.getNode());
        int kind = store.kind(node);
        WireMessage values = WireMessage.parse(set.getValues().toByteArray());
        if (kind == 0 || values == null) {
            return;
        }
        for (FieldPath path : set.getPathsList()) {
            List<PathResolver.Assignment> writes = resolver.resolve(kind, path, values);
            if (writes != null) {
                for (PathResolver.Assignment write : writes) {
                    store.write(node, write.path(), write.value(), id);
                }
            }
        }
    }

    /** The register at {@code path} of {@code node}, or {@code null} when never written. */
    public Register register(OpId node, RegisterPath path) {
        return store.register(node, path);
    }

    /** The retained writes to one register that lost (crdt-model.adoc, "Merge rules"). */
    public List<Write> losingWrites(OpId node, RegisterPath path) {
        return store.losingWrites(node, path);
    }

    /** The state hash of the merged state (32 bytes, {@link StateHash}). */
    public byte[] stateHash() {
        return StateHash.of(store);
    }
}
