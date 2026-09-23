package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import org.hibernate.reactive.mutiny.Mutiny;

import com.google.protobuf.Descriptors.Descriptor;
import com.google.protobuf.Descriptors.FieldDescriptor;
import com.google.protobuf.Message;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.PathSegment;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.SqlClient;
import io.vertx.mutiny.sqlclient.Tuple;

/**
 * The history index of one change (COLLAB-020; history.adoc, Server): the nodes it names
 * ({@code change_node}, from {@link TouchedNodes}) and the names it gives nodes ({@code node_name}: a
 * {@code CreateNode} with its kind and {@code CommonProps.name}, a {@code SetFields} writing
 * {@code CommonProps.name}), read through the generic op shape; and, for the History panel's rows,
 * the registers it writes as display names. The ingest statement writes the index with the change
 * ({@link com.villagecompute.wiretuner.api.sync.ChangeIngest}); the other writers of the log (a
 * branch merge's replay, a copy's extra changes) call {@code write}, and a copy takes its source's
 * names up to the fork point ({@link #copyNames}).
 */
public final class ChangeIndex {

    /** Every kind message has {@code CommonProps common = 1}; its name is field 1. */
    static final int COMMON = 1;

    /** At most this many attributes per change (version.proto; a field name is well under its 64 characters). */
    static final int MAX_ATTRIBUTES = 32;

    /** A name given to a node: by its creation (with the kind's initial name) or by a rename. */
    public record Named(OpId node, int kind, String name) {
    }

    /** One change's index rows: the nodes it names and the names it gives. */
    public record Entries(List<OpId> nodes, List<Named> names) {

        /** The arguments of {@link #WRITE} for the change at {@code serverSeq}. */
        public Tuple tuple(UUID documentId, long serverSeq) {
            Tuple tuple = Tuple.of(documentId, serverSeq);
            for (Object column : columns()) {
                tuple.addValue(column);
            }
            return tuple;
        }

        /** The index as six arrays: node replicas and counters; named nodes' replicas, counters, kinds and names. */
        public Object[] columns() {
            return new Object[] {nodes.stream().map(OpId::replica).toArray(Long[]::new),
                    nodes.stream().map(OpId::counter).toArray(Long[]::new),
                    names.stream().map(n -> n.node().replica()).toArray(Long[]::new),
                    names.stream().map(n -> n.node().counter()).toArray(Long[]::new),
                    names.stream().map(Named::kind).toArray(Integer[]::new),
                    names.stream().map(Named::name).toArray(String[]::new)};
        }
    }

    /**
     * Inserts one change's index rows ($1 document, $2 server_seq, $3/$4 node replicas and counters,
     * $5..$8 named nodes' replicas, counters, kinds and names).
     */
    public static final String WRITE = """
            WITH n AS (
                INSERT INTO change_node (document_id, node_replica, node_counter, server_seq)
                SELECT $1, t.r, t.c, $2 FROM unnest($3::bigint[], $4::bigint[]) AS t(r, c)
                ON CONFLICT DO NOTHING
            )
            INSERT INTO node_name (document_id, node_replica, node_counter, server_seq, kind, name)
            SELECT $1, t.r, t.c, $2, t.k, t.n FROM unnest($5::bigint[], $6::bigint[], $7::int[], $8::text[]) AS t(r, c, k, n)
            ON CONFLICT DO NOTHING
            """;

    private ChangeIndex() {
    }

    /** The index rows of {@code change}: one name per node, the last the change gives it. */
    public static Entries entries(Change change) {
        List<OpId> nodes = new ArrayList<>(TouchedNodes.of(change));
        Map<OpId, Named> names = new LinkedHashMap<>();
        for (TouchedNodes.Named op : TouchedNodes.ops(change)) {
            Op body = op.op();
            if (body.hasCreate()) {
                NodeProps props = body.getCreate().getProps();
                names.put(op.node(), new Named(op.node(), props.getKindCase().getNumber(), name(props)));
            } else if (body.hasSet()) {
                for (FieldPath path : body.getSet().getPathsList()) {
                    if (isName(path)) {
                        names.put(op.node(), new Named(op.node(), path.getSegments(0).getField(),
                                name(body.getSet().getValues())));
                        break;
                    }
                }
            }
        }
        return new Entries(nodes, List.copyOf(names.values()));
    }

    /** Writes the index rows of {@code changes}, the first at {@code firstSeq}, through {@code client} (a connection). */
    public static Uni<Void> write(SqlClient client, UUID documentId, long firstSeq, List<Change> changes) {
        List<Tuple> rows = new ArrayList<>(changes.size());
        for (int i = 0; i < changes.size(); i++) {
            rows.add(entries(changes.get(i)).tuple(documentId, firstSeq + i));
        }
        return client.preparedQuery(WRITE).executeBatch(rows).replaceWithVoid();
    }

    /**
     * Writes {@code change}'s index rows at {@code serverSeq} in the caller's Hibernate Reactive
     * session, so they commit (and see an uncommitted document row) with the change it logs: a copy's
     * extra changes.
     */
    public static Uni<Void> write(Mutiny.Session session, UUID documentId, long serverSeq, Change change) {
        Entries entries = entries(change);
        return Multi.createFrom().iterable(entries.nodes())
                .onItem().transformToUniAndConcatenate(node -> session.createNativeQuery("""
                        INSERT INTO change_node (document_id, node_replica, node_counter, server_seq) VALUES (?1, ?2, ?3, ?4)
                        ON CONFLICT DO NOTHING
                        """).setParameter(1, documentId).setParameter(2, node.replica()).setParameter(3, node.counter())
                        .setParameter(4, serverSeq).executeUpdate())
                .collect().asList()
                .chain(() -> Multi.createFrom().iterable(entries.names())
                        .onItem().transformToUniAndConcatenate(named -> session.createNativeQuery("""
                                INSERT INTO node_name (document_id, node_replica, node_counter, server_seq, kind, name)
                                VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT DO NOTHING
                                """).setParameter(1, documentId).setParameter(2, named.node().replica())
                                .setParameter(3, named.node().counter()).setParameter(4, serverSeq)
                                .setParameter(5, named.kind()).setParameter(6, named.name()).executeUpdate())
                        .collect().asList())
                .replaceWithVoid();
    }

    /** Gives a copy the source's node names up to the fork point, in the caller's session. */
    public static Uni<Void> copyNames(Mutiny.Session session, UUID sourceId, UUID copyId, long atSeq) {
        return session.createNativeQuery("""
                INSERT INTO node_name (document_id, node_replica, node_counter, server_seq, kind, name)
                SELECT ?2, node_replica, node_counter, server_seq, kind, name FROM node_name
                WHERE document_id = ?1 AND server_seq <= ?3
                """).setParameter(1, sourceId).setParameter(2, copyId).setParameter(3, atSeq).executeUpdate()
                .replaceWithVoid();
    }

    /** Whether {@code path} is {@code [kind, common, name]}. */
    static boolean isName(FieldPath path) {
        List<PathSegment> segments = path.getSegmentsList();
        return segments.size() == 3 && segments.get(1).getField() == COMMON
                && segments.get(2).getField() == CommonProps.NAME_FIELD_NUMBER;
    }

    /** {@code CommonProps.name} of the kind {@code props} holds (every kind's field 1); empty when no kind is set. */
    static String name(NodeProps props) {
        if (props.getKindCase() == NodeProps.KindCase.KIND_NOT_SET) {
            return "";
        }
        Message kind = (Message) props.getField(NodeProps.getDescriptor().findFieldByNumber(props.getKindCase().getNumber()));
        return ((CommonProps) kind.getField(kind.getDescriptorForType().findFieldByNumber(COMMON))).getName();
    }

    /** The name the History panel shows for a node of {@code kind} that has none: the kind's ("Master page"). */
    public static String kindName(int kind) {
        FieldDescriptor field = NodeProps.getDescriptor().findFieldByNumber(kind);
        return field == null ? "" : display(field.getName());
    }

    /**
     * The registers {@code change} writes, as display names in first-written order: the field a
     * {@code SetFields} path names under its kind (under {@code CommonProps} the common field:
     * "Name", "Transform"), the sequence, text or set field of an element, text or set op,
     * "Deleted" for {@code SetDeleted} and "Order" for {@code MoveNode}. Creations name none.
     */
    public static List<String> attributes(Change change) {
        Set<String> names = new LinkedHashSet<>();
        for (Op op : change.getOpsList()) {
            switch (op.getOpCase()) {
                case SET -> op.getSet().getPathsList().forEach(path -> add(names, path));
                case SET_DELETED -> names.add("Deleted");
                case MOVE -> names.add("Order");
                case ELEMENT_INSERT -> add(names, op.getElementInsert().getSequence());
                case ELEMENT_MOVE -> add(names, op.getElementMove().getElement());
                case ELEMENT_DELETE -> op.getElementDelete().getElementsList().forEach(path -> add(names, path));
                case TEXT_INSERT -> add(names, op.getTextInsert().getText());
                case TEXT_DELETE -> add(names, op.getTextDelete().getText());
                case TEXT_MARK -> add(names, op.getTextMark().getText());
                case SET_ADD -> add(names, op.getSetAdd().getSet());
                case SET_REMOVE -> add(names, op.getSetRemove().getSet());
                default -> {
                    // CreateNode and Noop write no named register.
                }
            }
        }
        return names.stream().limit(MAX_ATTRIBUTES).toList();
    }

    private static void add(Set<String> names, FieldPath path) {
        String name = attribute(path);
        if (!name.isEmpty()) {
            names.add(name);
        }
    }

    /** The display name of the register {@code path} writes; empty when the path names no known field. */
    static String attribute(FieldPath path) {
        List<PathSegment> segments = path.getSegmentsList();
        FieldDescriptor kind = segments.isEmpty() ? null : NodeProps.getDescriptor().findFieldByNumber(segments.get(0).getField());
        if (kind == null || segments.size() < 2) {
            return "";
        }
        FieldDescriptor field = field(kind.getMessageType(), segments.get(1));
        if (field == null) {
            return "";
        }
        if (field.getNumber() == COMMON && segments.size() > 2) {
            FieldDescriptor common = field(CommonProps.getDescriptor(), segments.get(2));
            field = common == null ? field : common;
        }
        return display(field.getName());
    }

    private static FieldDescriptor field(Descriptor message, PathSegment segment) {
        return segment.hasElement() ? null : message.findFieldByNumber(segment.getField());
    }

    /** A proto field name as a label: {@code stroke_width} is "Stroke width". */
    static String display(String fieldName) {
        String spaced = fieldName.replace('_', ' ');
        return spaced.substring(0, 1).toUpperCase(Locale.ROOT) + spaced.substring(1);
    }
}
