package com.villagecompute.wiretuner.api.comments;

import java.util.ArrayList;
import java.util.List;

import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Comment;
import com.villagecompute.wiretuner.doc.v1.CommentThreadProps;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.PathSegment;

/**
 * What a change does to comments (COLLAB-030; comments.adoc, Server): the ingest parse reads every op
 * once and says, per op, what the commenter role rule must check and what the server's record of
 * comments must learn. Pure: no state, so the role rule ({@link CommentRules}) and the record
 * ({@link CommentIndex}) look up what they need afterwards, in one query each.
 *
 * <p>Ops on comments are recognised by their field paths, which start at the node's kind field:
 * {@code comment_thread} is {@code NodeProps} field {@value #THREAD_FIELD}, so a path under a thread
 * starts with it. {@code CommentThreadProps.resolved} is field {@value #RESOLVED}, {@code comments}
 * field {@value #COMMENTS}; in a {@code Comment}, {@code author_account_id} is {@value #AUTHOR},
 * {@code body} {@value #BODY}, {@code mentions} {@value #MENTIONS}, {@code reactions}
 * {@value #REACTIONS} and {@code deleted} {@value #DELETED}. Node ops ({@code SetDeleted},
 * {@code MoveNode}) carry no path: whether their target is a thread is a lookup.
 */
public final class CommentOps {

    static final int THREAD_FIELD = 210;
    static final int RESOLVED = 6;
    static final int COMMENTS = 7;
    static final int AUTHOR = 2;
    static final int BODY = 3;
    static final int MENTIONS = 6;
    static final int REACTIONS = 7;
    static final int DELETED = 8;

    /** The comments collection 0:12. */
    static final Id COMMENTS_NODE = new Id(12, 0);

    private CommentOps() {
    }

    /** An OpId or ElementId: (counter, replica), ordered by counter then replica unsigned. */
    public record Id(long counter, long replica) implements Comparable<Id> {

        static Id of(OpId id) {
            return new Id(id.getCounter(), id.getReplica());
        }

        static Id of(com.villagecompute.wiretuner.doc.v1.ElementId id) {
            return new Id(id.getCounter(), id.getReplica());
        }

        @Override
        public int compareTo(Id other) {
            int byCounter = Long.compareUnsigned(counter, other.counter);
            return byCounter != 0 ? byCounter : Long.compareUnsigned(replica, other.replica);
        }

        OpId opId() {
            return OpId.newBuilder().setCounter(counter).setReplica(replica).build();
        }

        com.villagecompute.wiretuner.doc.v1.ElementId elementId() {
            return com.villagecompute.wiretuner.doc.v1.ElementId.newBuilder().setCounter(counter).setReplica(replica)
                    .build();
        }
    }

    /** One op's meaning for comments. */
    public sealed interface CommentOp {
    }

    /** An op on something other than comments: a node of another kind, or a path outside a thread. */
    public record Foreign() implements CommentOp {
    }

    /** A new comment_thread node under {@code parent}. */
    public record CreateThread(Id thread, Id parent) implements CommentOp {
    }

    /** {@code SetDeleted} ({@code delete}) or {@code MoveNode} of a node that may be a thread. */
    public record NodeOp(Id target, boolean delete, Id parent) implements CommentOp {
    }

    /** A write of a thread's own registers other than {@code resolved}: pin, page, common props. */
    public record ThreadWrite(Id target) implements CommentOp {
    }

    /** A write of {@code resolved} (or of the whole thread, which writes it too), with its op id. */
    public record Resolve(Id target, boolean resolved, Id op) implements CommentOp {
    }

    /**
     * Anything done to one existing comment: its registers, text, mentions, deletion. {@code ownerMay}
     * when an owner may do it to anyone's comment (deleting); {@code authors} are the
     * {@code author_account_id} values the op writes, which must be the caller, and
     * {@code authorRequired} when the op writes the author register (so it must name one);
     * {@code deleted} is the value it writes to {@code deleted}, or null.
     */
    public record ElementWrite(Id target, Id element, boolean ownerMay, List<String> authors, boolean authorRequired,
            Boolean deleted, Id op) implements CommentOp {
    }

    /** New comments (the opening one or replies): their element ids and their values. */
    public record NewComments(Id target, List<Id> elements, List<Comment> comments) implements CommentOp {
    }

    /** Reactions added or removed; each member must be the caller's ({@code <account>:<emoji>}). */
    public record Reaction(Id target, List<String> members) implements CommentOp {
    }

    /** Text typed into a comment's body: the first typing becomes the digest's quote. */
    public record Typed(Id target, Id element, String chars) implements CommentOp {
    }

    /** Accounts (or {@code team:<id>}) mentioned in a comment, by its mentions set or a mention mark. */
    public record Mentioned(Id target, Id element, List<String> mentions) implements CommentOp {
    }

    /** Where a path leads under a thread. */
    enum Kind {
        FOREIGN, THREAD, RESOLVED, COMMENTS, ELEMENT
    }

    record Place(Kind kind, Id element, int field) {
    }

    static final Place FOREIGN = new Place(Kind.FOREIGN, null, 0);

    /** Classifies a field path: under a thread or not, and where. Field 0 at an element = the whole element. */
    static Place place(FieldPath path) {
        List<PathSegment> segments = path.getSegmentsList();
        if (segments.isEmpty() || segments.get(0).getField() != THREAD_FIELD) {
            return FOREIGN;
        }
        if (segments.size() == 1) {
            return new Place(Kind.RESOLVED, null, 0);
        }
        int field = segments.get(1).getField();
        if (field == RESOLVED) {
            return new Place(Kind.RESOLVED, null, 0);
        }
        if (field != COMMENTS) {
            return new Place(field == 0 ? Kind.FOREIGN : Kind.THREAD, null, 0);
        }
        if (segments.size() == 2) {
            return new Place(Kind.COMMENTS, null, 0);
        }
        if (!segments.get(2).hasElement()) {
            return FOREIGN;
        }
        Id element = Id.of(segments.get(2).getElement());
        return new Place(Kind.ELEMENT, element, segments.size() == 3 ? 0 : segments.get(3).getField());
    }

    /** The meaning of every op of the change, in order; empty when nothing concerns comments. */
    public static List<CommentOp> parse(Change change) {
        List<CommentOp> out = new ArrayList<>();
        long counter = change.getStartCounter();
        for (Op op : change.getOpsList()) {
            read(op, new Id(counter, change.getReplica()), out);
            counter += Engine.counters(op);
        }
        return out;
    }

    private static void read(Op op, Id id, List<CommentOp> out) {
        switch (op.getOpCase()) {
            case CREATE -> out.add(op.getCreate().getProps().hasCommentThread()
                    ? new CreateThread(id, Id.of(op.getCreate().getParent())) : new Foreign());
            case SET -> {
                Id node = Id.of(op.getSet().getNode());
                for (FieldPath path : op.getSet().getPathsList()) {
                    out.add(set(node, place(path), op.getSet().getValues(), id));
                }
            }
            case MOVE -> out.add(new NodeOp(Id.of(op.getMove().getNode()), false, Id.of(op.getMove().getParent())));
            case SET_DELETED -> out.add(new NodeOp(Id.of(op.getSetDeleted().getNode()), true, null));
            case ELEMENT_INSERT -> {
                Id node = Id.of(op.getElementInsert().getNode());
                Place place = place(op.getElementInsert().getSequence());
                if (place.kind() == Kind.COMMENTS) {
                    List<Id> elements = new ArrayList<>();
                    for (int i = 0; i < op.getElementInsert().getPositionsCount(); i++) {
                        elements.add(new Id(id.counter() + i, id.replica()));
                    }
                    out.add(new NewComments(node, elements, op.getElementInsert().getValues().getCommentThread()
                            .getCommentsList()));
                } else {
                    out.add(generic(node, place, id));
                }
            }
            case ELEMENT_MOVE -> out.add(generic(Id.of(op.getElementMove().getNode()), place(op.getElementMove().getElement()),
                    id));
            case ELEMENT_DELETE -> {
                Id node = Id.of(op.getElementDelete().getNode());
                for (FieldPath path : op.getElementDelete().getElementsList()) {
                    Place place = place(path);
                    out.add(place.kind() == Kind.ELEMENT && place.field() == 0
                            ? new ElementWrite(node, place.element(), true, List.of(), false,
                                    op.getElementDelete().getDeleted(), id)
                            : generic(node, place, id));
                }
            }
            case TEXT_INSERT -> {
                Id node = Id.of(op.getTextInsert().getNode());
                Place place = place(op.getTextInsert().getText());
                out.add(generic(node, place, id));
                if (place.kind() == Kind.ELEMENT && place.field() == BODY) {
                    out.add(new Typed(node, place.element(), op.getTextInsert().getChars()));
                }
            }
            case TEXT_DELETE -> out.add(generic(Id.of(op.getTextDelete().getNode()), place(op.getTextDelete().getText()), id));
            case TEXT_MARK -> {
                Id node = Id.of(op.getTextMark().getNode());
                Place place = place(op.getTextMark().getText());
                out.add(generic(node, place, id));
                if (place.kind() == Kind.ELEMENT && op.getTextMark().getValue().hasMention()) {
                    out.add(new Mentioned(node, place.element(), List.of(op.getTextMark().getValue().getMention())));
                }
            }
            case SET_ADD -> members(Id.of(op.getSetAdd().getNode()), place(op.getSetAdd().getSet()),
                    op.getSetAdd().getValues(), true, id, out);
            case SET_REMOVE -> members(Id.of(op.getSetRemove().getNode()), place(op.getSetRemove().getSet()),
                    op.getSetRemove().getValues(), false, id, out);
            default -> {
                // A Noop keeps its counter and concerns nothing.
            }
        }
    }

    /** One SetFields path. */
    private static CommentOp set(Id node, Place place, NodeProps values, Id id) {
        CommentThreadProps thread = values.getCommentThread();
        if (place.kind() == Kind.RESOLVED) {
            return new Resolve(node, thread.getResolved(), id);
        }
        if (place.kind() != Kind.ELEMENT) {
            return generic(node, place, id);
        }
        List<String> authors = new ArrayList<>();
        Boolean deleted = null;
        for (Comment comment : thread.getCommentsList()) {
            if (!comment.getAuthorAccountId().isEmpty()) {
                authors.add(comment.getAuthorAccountId());
            }
            deleted = comment.getDeleted();
        }
        boolean whole = place.field() == 0;
        boolean writesDeleted = whole || place.field() == DELETED;
        return new ElementWrite(node, place.element(), place.field() == DELETED, authors,
                whole || place.field() == AUTHOR, writesDeleted ? Boolean.TRUE.equals(deleted) : null, id);
    }

    /** A set op: reactions are checked by member, mentions are learned, anything else as its path says. */
    private static void members(Id node, Place place, NodeProps values, boolean add, Id id, List<CommentOp> out) {
        boolean element = place.kind() == Kind.ELEMENT;
        if (element && place.field() == REACTIONS) {
            List<String> members = new ArrayList<>();
            values.getCommentThread().getCommentsList().forEach(comment -> members.addAll(comment.getReactionsList()));
            out.add(new Reaction(node, members));
            return;
        }
        out.add(generic(node, place, id));
        if (add && element && place.field() == MENTIONS) {
            List<String> mentions = new ArrayList<>();
            values.getCommentThread().getCommentsList().forEach(comment -> mentions.addAll(comment.getMentionsList()));
            out.add(new Mentioned(node, place.element(), mentions));
        }
    }

    /** An op whose only relevance is where its path leads. */
    private static CommentOp generic(Id node, Place place, Id id) {
        return switch (place.kind()) {
            case FOREIGN -> new Foreign();
            case ELEMENT -> new ElementWrite(node, place.element(), false, List.of(), false, null, id);
            default -> new ThreadWrite(node);
        };
    }
}
