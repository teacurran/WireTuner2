package com.villagecompute.wiretuner.api.comments;

import java.util.List;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.doc.v1.Anchor;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Comment;
import com.villagecompute.wiretuner.doc.v1.CommentThreadProps;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.ElementDelete;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.ElementInsert;
import com.villagecompute.wiretuner.doc.v1.ElementMove;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.GroupProps;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetAdd;
import com.villagecompute.wiretuner.doc.v1.SetDeleted;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.SetRemove;
import com.villagecompute.wiretuner.doc.v1.TextDelete;
import com.villagecompute.wiretuner.doc.v1.ElementIdRange;
import com.villagecompute.wiretuner.doc.v1.TextInsert;
import com.villagecompute.wiretuner.doc.v1.TextMark;
import com.villagecompute.wiretuner.doc.v1.TextMarkValue;

/** Changes that do things to comments, as the client's comment commands will write them (COLLAB-026). */
public final class CommentChanges {

    public static final OpId COMMENTS = OpId.newBuilder().setCounter(12).build();
    public static final OpId LAYERS = OpId.newBuilder().setCounter(4).build();
    static final ByteString POSITION = ByteString.copyFrom(new byte[] {(byte) 0x80});

    private CommentChanges() {
    }

    public static OpId op(Id id) {
        return id.opId();
    }

    public static ElementId element(Id id) {
        return id.elementId();
    }

    static PathSegment field(int number) {
        return PathSegment.newBuilder().setField(number).build();
    }

    static PathSegment element(ElementId id) {
        return PathSegment.newBuilder().setElement(id).build();
    }

    /** A path of fields from the node's kind. */
    public static FieldPath path(int... fields) {
        FieldPath.Builder path = FieldPath.newBuilder();
        for (int number : fields) {
            path.addSegments(field(number));
        }
        return path.build();
    }

    /** {@code comment_thread.comments[element].field...}; no field = the whole element. */
    public static FieldPath commentPath(Id element, int... fields) {
        FieldPath.Builder path = FieldPath.newBuilder().addSegments(field(210)).addSegments(field(7))
                .addSegments(element(element.elementId()));
        for (int number : fields) {
            path.addSegments(field(number));
        }
        return path.build();
    }

    public static NodeProps thread(CommentThreadProps.Builder props) {
        return NodeProps.newBuilder().setCommentThread(props).build();
    }

    public static NodeProps comments(Comment... comments) {
        return thread(CommentThreadProps.newBuilder().addAllComments(List.of(comments)));
    }

    public static Comment comment(String author, String... mentions) {
        return Comment.newBuilder().setAuthorAccountId(author).addAllMentions(List.of(mentions)).setWallTimeMs(1).build();
    }

    public static Op createThread(OpId parent) {
        return Op.newBuilder().setCreate(CreateNode.newBuilder().setParent(parent).setPosition(POSITION)
                .setProps(thread(CommentThreadProps.newBuilder()))).build();
    }

    public static Op createGroup(OpId parent) {
        return Op.newBuilder().setCreate(CreateNode.newBuilder().setParent(parent).setPosition(POSITION)
                .setProps(NodeProps.newBuilder().setGroup(GroupProps.getDefaultInstance()))).build();
    }

    public static Op set(Id node, NodeProps values, FieldPath... paths) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(node.opId()).addAllPaths(List.of(paths))
                .setValues(values)).build();
    }

    public static Op resolve(Id node, boolean resolved) {
        return set(node, thread(CommentThreadProps.newBuilder().setResolved(resolved)), path(210, 6));
    }

    public static Op insert(Id node, FieldPath sequence, NodeProps values, int count) {
        ElementInsert.Builder insert = ElementInsert.newBuilder().setNode(node.opId()).setSequence(sequence).setValues(values);
        for (int i = 0; i < count; i++) {
            insert.addPositions(ByteString.copyFrom(new byte[] {(byte) (0x80 + i)}));
        }
        return Op.newBuilder().setElementInsert(insert).build();
    }

    /** New comments in a thread, one per value. */
    public static Op reply(Id node, Comment... comments) {
        return insert(node, path(210, 7), comments(comments), comments.length);
    }

    public static Op type(Id node, Id comment, String chars) {
        return Op.newBuilder().setTextInsert(TextInsert.newBuilder().setNode(node.opId())
                .setText(commentPath(comment, 3)).setChars(chars)).build();
    }

    public static Op typeAt(Id node, FieldPath text, String chars) {
        return Op.newBuilder().setTextInsert(TextInsert.newBuilder().setNode(node.opId()).setText(text).setChars(chars))
                .build();
    }

    public static Op erase(Id node, FieldPath text, Id first) {
        return Op.newBuilder().setTextDelete(TextDelete.newBuilder().setNode(node.opId()).setText(text)
                .addRanges(ElementIdRange.newBuilder().setFirst(first.elementId()).setCount(1))).build();
    }

    public static Op mark(Id node, FieldPath text, Id at, TextMarkValue value) {
        Anchor anchor = Anchor.newBuilder().setChar(at.elementId()).build();
        return Op.newBuilder().setTextMark(TextMark.newBuilder().setNode(node.opId()).setText(text).setStart(anchor)
                .setEnd(anchor).setValue(value)).build();
    }

    public static Op add(Id node, FieldPath set, NodeProps values) {
        return Op.newBuilder().setSetAdd(SetAdd.newBuilder().setNode(node.opId()).setSet(set).setValues(values)).build();
    }

    public static Op remove(Id node, FieldPath set, NodeProps values) {
        return Op.newBuilder().setSetRemove(SetRemove.newBuilder().setNode(node.opId()).setSet(set).setValues(values))
                .build();
    }

    public static Op react(Id node, Id comment, String member, boolean add) {
        NodeProps values = comments(Comment.newBuilder().addReactions(member).build());
        return add ? add(node, commentPath(comment, 7), values) : remove(node, commentPath(comment, 7), values);
    }

    public static Op mention(Id node, Id comment, String... mentions) {
        return add(node, commentPath(comment, 6), comments(Comment.newBuilder().addAllMentions(List.of(mentions)).build()));
    }

    public static Op deleteComment(Id node, Id comment, boolean deleted) {
        return set(node, comments(Comment.newBuilder().setDeleted(deleted).build()), commentPath(comment, 8));
    }

    public static Op elementDelete(Id node, FieldPath... elements) {
        return Op.newBuilder().setElementDelete(ElementDelete.newBuilder().setNode(node.opId())
                .addAllElements(List.of(elements)).setDeleted(true)).build();
    }

    public static Op elementMove(Id node, FieldPath element) {
        return Op.newBuilder().setElementMove(ElementMove.newBuilder().setNode(node.opId()).setElement(element)
                .setPosition(POSITION)).build();
    }

    public static Op setDeleted(Id node, boolean deleted) {
        return Op.newBuilder().setSetDeleted(SetDeleted.newBuilder().setNode(node.opId()).setDeleted(deleted)).build();
    }

    public static Op move(Id node, OpId parent) {
        return Op.newBuilder().setMove(MoveNode.newBuilder().setNode(node.opId()).setParent(parent).setPosition(POSITION))
                .build();
    }

    public static Op noop() {
        return Op.newBuilder().setNoop(Noop.getDefaultInstance()).build();
    }

    /** A change of the ops, op i at counter {@code start} plus what the ops before it took. */
    public static Change changeOf(long replica, long seq, long start, Op... ops) {
        return Change.newBuilder().setReplica(replica).setSeq(seq).setStartCounter(start).setWallTimeMs(1)
                .setLabel("Comment " + seq).addAllOps(List.of(ops)).build();
    }
}
